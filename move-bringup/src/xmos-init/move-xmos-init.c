// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * move-xmos-init — replay stock MoveLauncher's XMOS init handshake.
 *
 * Reverse-engineered from movesniff capture-20260409-025914.bin (a stock
 * Move boot trace). At +0.559s after open(/dev/ablspi0.0), stock
 * MoveLauncher pumps this exact batch of SysEx queries and CCs into the
 * OUT MIDI region:
 *
 *   1. F0 7E 01 06 01 F7                            Universal Identity Req
 *   2. F0 00 21 1D 01 01 42 00 F7                   system status query
 *   3. F0 00 21 1D 01 01 25 F7                      serial query
 *   4. F0 00 21 1D 01 01 3A F7                      state report query
 *   5. F0 00 21 1D 01 01 1E 01 F7                   host setter (enable)
 *   6. F0 00 21 1D 01 01 47 F7                      get-mode query
 *   7. B0 00 7E                                     CC ch0 cc0 val126
 *   8. F0 00 21 1D 01 01 0D F7                      version query
 *   9. F0 00 21 1D 01 01 37 <15-byte audio-IO> F7   audio I/O init
 *
 * After this batch, the XMOS flips into "send UI events as plain MIDI on
 * cable 0" mode and pad/knob/button presses arrive as note-on / poly-AT /
 * CC events that schwung-spi-based apps (vimana2r, etc.) can consume.
 *
 * Run this once after ablspi probes and before launching any Move app.
 * Exit code 0 on success (XMOS replied as expected), 1 if anything failed.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define ABLSPI_DEV                           "/dev/ablspi0.0"
#define ABLSPI_SET_SPEED                     11
#define ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE 10
#define ABLSPI_SEND_MESSAGE_AND_WAIT          4

#define MAILBOX_SIZE                         4096
#define OFF_OUT_MIDI                         0
#define MIDI_OUT_BYTES                       80
#define OFF_IN_MIDI                          2048
#define MIDI_IN_BYTES                        248
#define FRAME_SIZE                           768
#define SPI_HZ                               20000000

/* Pack a stream of MIDI bytes (one or more complete messages) into the
 * OUT MIDI region as USB-MIDI 4-byte packets. Returns number of packets
 * written. Caller guarantees `dst` has room for ~ceil(bytes*4/3). */
static int pack_midi(uint8_t *dst, int dst_slots,
                     const uint8_t *src, int n)
{
    int slot = 0, i = 0;
    int in_sysex = 0;

    while (i < n) {
        if (slot >= dst_slots) return -1;
        uint8_t *p = dst + slot * 4;
        uint8_t b = src[i];

        if (b == 0xF0) {
            /* SysEx start — pack with CIN 0x4 for the first 3 bytes. */
            in_sysex = 1;
            /* find F7 within the next few bytes to pick the right CIN */
            int sx_end = -1;
            for (int k = i; k < n; k++) if (src[k] == 0xF7) { sx_end = k; break; }
            if (sx_end < 0) {
                fprintf(stderr, "pack_midi: SysEx without F7\n");
                return -1;
            }
            int remaining = sx_end - i + 1;
            if (remaining <= 3) {
                /* whole SysEx fits in one packet — CIN 5/6/7 */
                uint8_t cin = (remaining == 1) ? 0x5 :
                              (remaining == 2) ? 0x6 : 0x7;
                p[0] = cin;
                p[1] = (remaining >= 1) ? src[i+0] : 0;
                p[2] = (remaining >= 2) ? src[i+1] : 0;
                p[3] = (remaining >= 3) ? src[i+2] : 0;
                i += remaining;
                in_sysex = 0;
            } else {
                p[0] = 0x4;
                p[1] = src[i+0]; p[2] = src[i+1]; p[3] = src[i+2];
                i += 3;
            }
            slot++;
        } else if (in_sysex) {
            /* SysEx continuation. */
            int sx_end = -1;
            for (int k = i; k < n; k++) if (src[k] == 0xF7) { sx_end = k; break; }
            if (sx_end < 0) {
                fprintf(stderr, "pack_midi: SysEx continuation without F7\n");
                return -1;
            }
            int remaining = sx_end - i + 1;
            if (remaining >= 4) {
                p[0] = 0x4;
                p[1] = src[i+0]; p[2] = src[i+1]; p[3] = src[i+2];
                i += 3;
            } else {
                uint8_t cin = (remaining == 1) ? 0x5 :
                              (remaining == 2) ? 0x6 : 0x7;
                p[0] = cin;
                p[1] = (remaining >= 1) ? src[i+0] : 0;
                p[2] = (remaining >= 2) ? src[i+1] : 0;
                p[3] = (remaining >= 3) ? src[i+2] : 0;
                i += remaining;
                in_sysex = 0;
            }
            slot++;
        } else if ((b & 0xF0) == 0xB0 || (b & 0xF0) == 0x90 ||
                   (b & 0xF0) == 0x80 || (b & 0xF0) == 0xA0 ||
                   (b & 0xF0) == 0xE0) {
            /* Channel-voice 3-byte status. */
            if (i + 2 >= n) return -1;
            uint8_t type = (b >> 4) & 0xF;
            p[0] = type;  /* CIN == status nibble for 3-byte channel-voice */
            p[1] = b;
            p[2] = src[i+1];
            p[3] = src[i+2];
            i += 3;
            slot++;
        } else if ((b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0) {
            /* Channel-voice 2-byte. */
            if (i + 1 >= n) return -1;
            uint8_t type = (b >> 4) & 0xF;
            p[0] = type;
            p[1] = b;
            p[2] = src[i+1];
            p[3] = 0;
            i += 2;
            slot++;
        } else if (b >= 0xF8) {
            /* System Real-Time (single-byte): 0xF8..0xFF. Includes 0xFF
             * (System Reset) and 0xFE (Active Sensing). USB-MIDI encodes
             * these with CIN 0xF (Single Byte). */
            p[0] = 0xF;
            p[1] = b;
            p[2] = 0;
            p[3] = 0;
            i += 1;
            slot++;
        } else {
            fprintf(stderr, "pack_midi: unhandled byte 0x%02x at %d\n", b, i);
            return -1;
        }
    }
    return slot;
}

static void hex(const char *tag, const uint8_t *p, int n) {
    fprintf(stderr, "  %s:", tag);
    for (int i = 0; i < n; i++) fprintf(stderr, " %02x", p[i]);
    fprintf(stderr, "\n");
}

/* Walk the IN MIDI region as 31 × 8-byte slots, reassembling the contiguous
 * MIDI byte stream out of USB-MIDI CIN-tagged packets. Used to check each
 * frame for a 0x47 mode reply — the XMOS only holds a reply in the mailbox
 * for ~1 frame before overwriting it with the next event, so we have to
 * sample every frame instead of just at the end. */
static int reassemble_in(const uint8_t *in, uint8_t *out, int out_cap)
{
    int slen = 0;
    for (int slot = 0; slot < 31; slot++) {
        const uint8_t *s = in + slot * 8;
        uint8_t cin = s[0] & 0x0F;
        int take = 0;
        switch (cin) {
        case 0x4: case 0x7: case 0x8: case 0x9:
        case 0xA: case 0xB: case 0xE:           take = 3; break;
        case 0xC: case 0xD: case 0x6:           take = 2; break;
        case 0x5: case 0xF:                     take = 1; break;
        default:                                take = 0; break;
        }
        for (int k = 0; k < take && slen < out_cap; k++)
            out[slen++] = s[1 + k];
    }
    return slen;
}

/* Scan an already-reassembled MIDI byte stream for a Move sysex 0x47 reply.
 * Returns the mode byte (0/1/2) on success or -1 if not found. */
static int find_mode_reply(const uint8_t *stream, int slen)
{
    static const uint8_t pfx[] = { 0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x47 };
    for (int i = 0; i + (int)sizeof(pfx) + 1 < slen; i++) {
        if (memcmp(stream + i, pfx, sizeof(pfx)) == 0)
            return stream[i + sizeof(pfx)];
    }
    return -1;
}

int main(void)
{
    int fd = open(ABLSPI_DEV, O_RDWR);
    if (fd < 0) { perror("open " ABLSPI_DEV); return 1; }
    uint8_t *buf = mmap(NULL, MAILBOX_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (buf == MAP_FAILED) { perror("mmap"); return 1; }
    memset(buf, 0, MAILBOX_SIZE);
    if (ioctl(fd, ABLSPI_SET_SPEED, SPI_HZ) < 0) { perror("SET_SPEED"); return 1; }

    /* Stock MoveLauncher (verified in capture-20260513-235610) only ever
     * uses SetSpeed (above) and WAIT_AND_SEND_MESSAGE_WITH_SIZE for the
     * entire session. NO kickoff transfer is needed: our driver pre-arms
     * the IRQ completion at probe, so the first WAIT_SEND_SIZE returns
     * immediately. Previous versions of this tool called
     * SEND_MESSAGE_AND_WAIT(0) here, which our driver rejects as -EINVAL
     * (size=0). Match the stock pattern exactly. */

    /* === Frame 0: the prelude. ===
     * Stock MoveLauncher sends two CCs at +0.551 s — about 8 ms BEFORE
     * the SysEx query batch — and the XMOS replies with a single CC
     * 2 ms later. Without this prelude the XMOS appears to silently
     * ignore subsequent SysEx (it stays in its pre-init state-reporting
     * mode and never flips to USB-MIDI emission). This pair almost
     * certainly serves as a "host is alive, begin listening" handshake. */
    static const uint8_t frame0[] = {
        0xB0, 0x00, 0x02,   /* CC ch=0 cc=0 val=2  */
        0xB0, 0x01, 0x40,   /* CC ch=0 cc=1 val=64 */
    };
    memset(buf, 0, MIDI_OUT_BYTES);
    {
        int slots = pack_midi(buf + OFF_OUT_MIDI, MIDI_OUT_BYTES / 4,
                              frame0, sizeof(frame0));
        if (slots < 0) { fprintf(stderr, "pack_midi failed (prelude)\n"); return 1; }
        fprintf(stderr, "prelude: %d slots, %zu MIDI bytes\n", slots, sizeof(frame0));
    }
    ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);
    /* Hold the prelude for ~8 ms (~3 frames at 344 Hz) before continuing
     * — matches the +0.551 → +0.559 s gap in the stock trace. */
    for (int k = 0; k < 3; k++)
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);

    /* === Frame 1: the main query batch ===
     * Bytes captured at +0.674s in capture-20260513-235610. The very
     * first byte stock writes here is 0xFF — a one-byte MIDI System
     * Reset real-time message that decodes as "raw ff" in the movesniff
     * log. Without this prefix the XMOS appears to never flip from its
     * internal raw-event mode to USB-MIDI emission, so include it. */
    static const uint8_t frame1[] = {
        /* MIDI System Reset (real-time) — flips the XMOS event-emitter
         * state machine before processing the SysEx queries below. */
        0xFF,
        /* Universal Identity Request */
        0xF0, 0x7E, 0x01, 0x06, 0x01, 0xF7,
        /* cmd 0x42 system status query */
        0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x42, 0x00, 0xF7,
        /* cmd 0x25 serial query */
        0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x25, 0xF7,
        /* cmd 0x3A state report query */
        0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x3A, 0xF7,
        /* cmd 0x1E enable flag */
        0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x1E, 0x01, 0xF7,
        /* cmd 0x47 get-mode */
        0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x47, 0xF7,
        /* CC ch=0 cc=0 val=126 (function unknown, follow the trace verbatim) */
        0xB0, 0x00, 0x7E,
    };
    memset(buf, 0, MIDI_OUT_BYTES);
    int slots = pack_midi(buf + OFF_OUT_MIDI, MIDI_OUT_BYTES / 4,
                          frame1, sizeof(frame1));
    if (slots < 0) { fprintf(stderr, "pack_midi failed (frame 1)\n"); return 1; }
    fprintf(stderr, "frame1: %d slots, %zu MIDI bytes\n", slots, sizeof(frame1));
    hex("OUT0..32", buf + OFF_OUT_MIDI, 32);
    /* Send the batch and watch the IN region every frame for the 0x47
     * mode reply. The XMOS only holds each reply slot for ~1 frame before
     * overwriting it with the next event, so we have to sample on every
     * cycle, not just at the end. */
    int captured_mode = -1;
    uint8_t accum[256] = {0};
    int accum_len = 0;
    for (int k = 0; k < 24; k++) {
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);
        uint8_t frame_stream[31 * 3];
        int frame_len = reassemble_in(buf + OFF_IN_MIDI,
                                      frame_stream, sizeof(frame_stream));
        if (frame_len > 0) {
            int take = frame_len;
            if (accum_len + take > (int)sizeof(accum))
                take = sizeof(accum) - accum_len;
            memcpy(accum + accum_len, frame_stream, take);
            accum_len += take;
            int m = find_mode_reply(frame_stream, frame_len);
            if (m >= 0) { captured_mode = m; break; }
        }
    }

    /* === Frame 2: version query + audio-IO setup === */
    /* Inner buffer of the 0x37 envelope from the trace (15 bytes). We
     * use the volume=0dB pattern (TLV keys 4/5 and 10/11 all 0x00). */
    static const uint8_t frame2[] = {
        /* cmd 0x0D version query */
        0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x0D, 0xF7,
        /* cmd 0x37 audio-IO envelope, inner buffer = "volume 0 dB"
         * (TLV keys 4,5,10,11 = 0x00 = 0 dB); other slots zero-padded */
        0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x37,
        0x04, 0x00, 0x00,  0x05, 0x00, 0x00,
        0x0A, 0x00, 0x00,  0x0B, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0xF7,
    };
    memset(buf, 0, MIDI_OUT_BYTES);
    slots = pack_midi(buf + OFF_OUT_MIDI, MIDI_OUT_BYTES / 4,
                      frame2, sizeof(frame2));
    if (slots < 0) { fprintf(stderr, "pack_midi failed (frame 2)\n"); return 1; }
    fprintf(stderr, "frame2: %d slots, %zu MIDI bytes\n", slots, sizeof(frame2));
    hex("OUT0..32", buf + OFF_OUT_MIDI, 32);
    /* Send frame 2 and keep sampling. If we already captured a mode reply
     * during frame 1's wait, keep going only to flush the XMOS pipeline. */
    ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);
    for (int k = 0; k < 24 && captured_mode < 0; k++) {
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);
        uint8_t frame_stream[31 * 3];
        int frame_len = reassemble_in(buf + OFF_IN_MIDI,
                                      frame_stream, sizeof(frame_stream));
        if (frame_len > 0) {
            int take = frame_len;
            if (accum_len + take > (int)sizeof(accum))
                take = sizeof(accum) - accum_len;
            memcpy(accum + accum_len, frame_stream, take);
            accum_len += take;
            int m = find_mode_reply(frame_stream, frame_len);
            if (m >= 0) { captured_mode = m; break; }
        }
    }

    /* Final pass: also scan the accumulated multi-frame stream in case the
     * SysEx 0x47 reply got split across frames so no single frame held the
     * full prefix. */
    if (captured_mode < 0)
        captured_mode = find_mode_reply(accum, accum_len);

    /* Clear OUT so we don't keep retransmitting. */
    memset(buf, 0, MIDI_OUT_BYTES);
    for (int k = 0; k < 5; k++)
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);

    fprintf(stderr, "accumulated IN stream over %d frames (%d B):",
            captured_mode >= 0 ? 1 : 48, accum_len);
    for (int i = 0; i < accum_len && i < 192; i++)
        fprintf(stderr, " %02x", accum[i]);
    if (accum_len > 192) fprintf(stderr, " …");
    fprintf(stderr, "\n");

    if (captured_mode >= 0) {
        const char *names[] = { "controlSurfaceMode", "standaloneMode", "cmIsUsbHost" };
        const char *name = (captured_mode <= 2) ? names[captured_mode] : "unknown";
        fprintf(stderr, "OK: XMOS reports mode=%d (%s)\n",
                captured_mode, name);
        return 0;
    }
    fprintf(stderr, "FAIL: did not see sysex 0x47 reply during 48 frames\n");
    hex("IN_MIDI[0..32] (final)", buf + OFF_IN_MIDI, 32);
    return 1;
}
