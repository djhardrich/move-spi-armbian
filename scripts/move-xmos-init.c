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

int main(void)
{
    int fd = open(ABLSPI_DEV, O_RDWR);
    if (fd < 0) { perror("open " ABLSPI_DEV); return 1; }
    uint8_t *buf = mmap(NULL, MAILBOX_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (buf == MAP_FAILED) { perror("mmap"); return 1; }
    memset(buf, 0, MAILBOX_SIZE);
    if (ioctl(fd, ABLSPI_SET_SPEED, SPI_HZ) < 0) { perror("SET_SPEED"); return 1; }

    /* Wake the XMOS frame loop. The driver pre-arms the IRQ at probe so
     * the first WAIT_AND_SEND returns immediately and triggers a kick. */
    ioctl(fd, ABLSPI_SEND_MESSAGE_AND_WAIT, 0);
    for (int k = 0; k < 3; k++)
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);

    /* === Frame 1: the main query batch === */
    /* Bytes captured at +0.559s in the stock boot trace. */
    static const uint8_t frame1[] = {
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
    /* Send it. */
    ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);

    /* Let XMOS pick it up and reply. Don't overwrite OUT yet — keep the
     * same data so the XMOS sees it on multiple frames if needed. */
    for (int k = 0; k < 5; k++)
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);

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
    ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);
    for (int k = 0; k < 5; k++)
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);

    /* Clear OUT so we don't keep retransmitting. */
    memset(buf, 0, MIDI_OUT_BYTES);
    for (int k = 0; k < 30; k++)
        ioctl(fd, ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE, FRAME_SIZE);

    /* === Check: did the XMOS reply with sysex 0x47 mode=... ? === */
    /* IN MIDI region = 31 slots × 8 B. Layout per slot:
     *   [0] = (cable << 4) | CIN
     *   [1..3] = up to 3 MIDI bytes (CIN tells you how many)
     *   [4..7] = 32-bit timestamp
     * Reassemble the contiguous MIDI byte stream first, then scan it. */
    uint8_t stream[31 * 3];
    int slen = 0;
    for (int slot = 0; slot < 31; slot++) {
        uint8_t *s = buf + OFF_IN_MIDI + slot * 8;
        uint8_t cin = s[0] & 0x0F;
        int take = 0;
        switch (cin) {
        case 0x4:  /* SysEx start / continuation, 3 bytes */
        case 0x7:  /* SysEx end with 3 bytes */
        case 0x8:  /* Note-off */
        case 0x9:  /* Note-on */
        case 0xA:  /* Poly-AT */
        case 0xB:  /* CC */
        case 0xE:  /* Pitch-bend */
            take = 3; break;
        case 0xC:  /* Program change */
        case 0xD:  /* Channel pressure */
        case 0x6:  /* SysEx end with 2 bytes */
            take = 2; break;
        case 0x5:  /* SysEx end with 1 byte */
        case 0xF:  /* Single byte */
            take = 1; break;
        default:   /* 0x0/0x1/0x2/0x3 reserved-ish */
            take = 0; break;
        }
        for (int k = 0; k < take && slen < (int)sizeof(stream); k++)
            stream[slen++] = s[1 + k];
    }

    int ok = 0, mode = -1;
    const uint8_t pfx[] = { 0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x47 };
    for (int i = 0; i + (int)sizeof(pfx) + 1 < slen; i++) {
        if (memcmp(stream + i, pfx, sizeof(pfx)) == 0) {
            mode = stream[i + sizeof(pfx)];
            ok = 1;
            break;
        }
    }
    fprintf(stderr, "reassembled IN stream (%d B):", slen);
    for (int i = 0; i < slen; i++) fprintf(stderr, " %02x", stream[i]);
    fprintf(stderr, "\n");

    if (ok) {
        const char *names[] = { "controlSurfaceMode", "standaloneMode", "cmIsUsbHost" };
        const char *name = (mode >= 0 && mode <= 2) ? names[mode] : "unknown";
        fprintf(stderr, "OK: XMOS reports mode=%d (%s)\n", mode, name);
        return 0;
    } else {
        fprintf(stderr, "FAIL: did not see sysex 0x47 reply in IN region\n");
        hex("IN_MIDI[0..32]", buf + OFF_IN_MIDI, 32);
        return 1;
    }
}
