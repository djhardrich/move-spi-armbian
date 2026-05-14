# USE THIS AT YOUR OWN RISK!!! I AM NOT RESPONSIBLE IF YOUR MOVE/COMPUTER/OTHER HARDWARE IS DAMAGED OR HAS OTHER UNINTENDED SIDE EFFECTS.
# CURRENTLY TESTED ON MOVE WITH CM4 LITE 8GB RAM, CM5 TESTING UNDERWAY!!


# Ableton Move Armbian Image and SPI Kernel Driver

Clean-room port of the Move's two SoC-specific pieces - the `ablspi` kernel
module and the device tree - from the original Compute Module 4 (BCM2711,
Linux 5.15.92-rt57) image to **Armbian/Compute Module 5 (BCM2712, Linux 6.6 LTS +
PREEMPT_RT)**.

Everything else in `/opt/move` is pure aarch64 user space and rebuilds
unchanged against the new SDK; the XMOS-side firmware blobs in
`/opt/move/Firmware/` are hardware-side and ship as-is.

## What's here

```
port/
├── kernel/
│   ├── ablspi.c       Linux 6.6+ kernel driver, clean-room reimplementation
│   ├── Kbuild
│   ├── Makefile       Out-of-tree build
│   └── (this dir is a drop-in for any kernel >= 6.6)
├── dts/
│   ├── ablspi-move-cm5.dts        Overlay form (recommended)
│   ├── bcm2712-rpi-cm5-move.dts   Standalone wrapper DTS
│   └── ablspi-move-cm5.dtbo       Compiled overlay (regenerate with dtc)
└── README.md
```

## Provenance

The driver is reconstructed from three sources, all of which the project
owns lawfully:

1. **`ablspi.ko`** (GPL, 28 KB, retained debug symbols) - the
   shipped binary on the CM4 image. Used as the structural reference:
   function names, error strings, /proc layout, statistic counters,
   IRQ/swait/mmap topology. Running strings on ablspi.ko shows "alias=spi:ablspi , description=SPI driver for CM to XMOS communication , license=GPL, author=Ableton AG". Source has been requested, but at the time of publishing, not been provided.
 
2. **`ablspi.dtbo`** (decompiled) - the legacy DT binding:
   `compatible = "ablspi"`, `irq-gpio = <3>`, SPI0 chip-select 0, custom
   pinctrl pins 40-43.
3. **Ableton AG's `move-spi` user-space library**, GPL-2.0-or-later. This is the *canonical* ABI
   spec - it's the library MoveLauncher/MoveOriginal/MoveWebService and
   JackMoveDriver all link against to talk to the kernel module. Defines
   the ioctl numbers, the 4096-byte mmap layout (output region 0..2047,
   input region 2048..4095), the 768-byte frame size, the 20 MHz bus
   clock, and the wait-then-duplex-transfer hot path semantics.

No reverse engineering of the Ableton AG GPL-Licensed ablspi.ko binary was needed beyond confirming that
the recovered structure matches what the user-space library expects.

## ABI surface (must remain stable)

The Move user-space binaries call only two ioctls in the steady state:

| #  | name                                       | arg               | use      |
|----|--------------------------------------------|-------------------|----------|
| 10 | `ABLSPI_WAIT_AND_SEND_MESSAGE_WITH_SIZE`   | size in bytes     | hot path |
| 11 | `ABLSPI_SET_SPEED`                         | clock in Hz       | init     |

Plus `mmap(NULL, 4096, RW, MAP_SHARED, fd, 0)` to map the shared buffer.

The full table of 13 ioctls (0..12) is implemented for parity with the
original driver so test harnesses (`MoveLibBenchmark`, `MoveTestHardware`)
that exercise the legacy commands keep working. See `kernel/ablspi.c` lines
for the enum and per-command handlers.

## Shared buffer layout

Single page allocated with `alloc_pages(GFP_KERNEL | __GFP_ZERO, 0)`,
mapped to user space via `remap_pfn_range`. The SPI hot path does one
duplex transfer of `message_size` bytes (default 768) with
`tx_buf = buffer + 0` and `rx_buf = buffer + 2048`.

```
offset      size  direction      contents
─────────── ────  ─────────────  ─────────────────────────────────────
   0          80  CM → XMOS      output USB-MIDI (20 × 4 B)
  80           4  CM → XMOS      output display-status (u32 ack)
  84         172  CM → XMOS      output display-data chunk
 256         512  CM → XMOS      output audio (128 × stereo s16)
 ...
2048         248  XMOS → CM      input USB-MIDI events
2296           8  XMOS → CM      input display-status (drives chunk pull)
2304         512  XMOS → CM      input audio (128 × stereo s16)
```

Audio rate is fixed at 44.1 kHz, stereo, int16 little-endian, 128 samples
per frame (≈ 2.9 ms per duplex transfer).

## Driver behaviour notes

- **Real-time friendly.** Uses `request_threaded_irq` with a NULL primary
  handler so the wake path runs in a kernel thread that can be tuned with
  `chrt -p`. The original `/etc/init.d/move` script does exactly this
  (`chrt -p 91 \`pgrep ablspi\``); the threaded model means that scheme
  continues to work unchanged on the CM5 image.
- **Streaming DMA.** No DMA-coherent allocation - the SPI core maps the
  page on each transfer via the standard streaming DMA path. Acceptable
  for 768 B @ 20 MHz (~310 µs of bus time per frame).
- **Statistics.** `/proc/ableton/ablspi/<bus>.<cs>/{irq_count,
  failed_send_count, spi_tx_time}` mirror the original `/proc` entries
  byte-for-byte where possible (`spi_tx_time` is richer here - reports
  `last_ns`/`max_ns`/`total_ns`).
- **A note on `spi_get_chipselect()`.** Used because rpi-6.6.y took the
  multi-CS conversion. For pre-6.5 kernels, swap to `spi->chip_select`.

## Building the kernel module

Cross-compile against an rpi-6.6.y tree configured for arm64:

```sh
make -C port/kernel \
     KDIR=$HOME/src/linux-rpi-6.6.y \
     ARCH=arm64 \
     CROSS_COMPILE=aarch64-linux-gnu- \
     -j$(nproc)
```

Native build on the device (kernel headers installed):

```sh
ssh root@move.local "cd /root/port/kernel && make"
```

Install:

```sh
make -C port/kernel install KVER=6.6.x-rt-v8   # writes /lib/modules/<ver>/extra
```

Add to `/etc/modules-load.d/ablspi.conf` so it loads at boot, like the
CM4 image did:

```
ablspi
i2c-dev
spi-bcm2835    # or whatever the CM5 SPI driver is named on your kernel
```

## Building the device tree

Overlay form (recommended - drops in next to the existing rpi overlays):

```sh
cd port/dts
dtc -@ -W no-gpios_property -I dts -O dtb \
    -o ablspi-move-cm5.dtbo ablspi-move-cm5.dts

scp ablspi-move-cm5.dtbo root@move.local:/boot/firmware/overlays/
ssh root@move.local 'printf "dtoverlay=ablspi-move-cm5\n" >> /boot/firmware/config.txt'
```

Standalone form (replaces the entire DTB - matches the CM4 image's model
of shipping `move-cm4-complete-devicetree.dtb`):

```sh
cp port/dts/bcm2712-rpi-cm5-move.dts \
   $HOME/src/linux-rpi-6.6.y/arch/arm64/boot/dts/broadcom/
# append the new entry to broadcom/Makefile next to the other bcm2712 dtbs
make -C $HOME/src/linux-rpi-6.6.y \
     ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     broadcom/bcm2712-rpi-cm5-move.dtb
```

Then set `device_tree=bcm2712-rpi-cm5-move.dtb` in `config.txt`.

## What I deliberately did *not* do

- **`xmos-power-cycle` / `xmos-power-off`.** These are pure shell scripts
  that call `/opt/move/MoveXmosPower` (a userland binary that talks to
  `/dev/ablspi0.0` over the same ABI). They work as-is on the new image -
  no change required.
- **`setup-usb-network-gadget`.** Pure configfs script. Once the dwc2
  controller is enabled in peripheral mode (we did that in the DTS), the
  script attaches the NCM gadget unchanged.
- **Intel WiFi.** `iwlwifi` and `iwlmvm` are upstream drivers; CM5 still
  routes PCIe to the carrier slot. No port work needed beyond carrying
  `/lib/firmware/iwlwifi/*` into the new image.
- **A/B partition / SWUpdate.** Preserve the p1/p2/p3/p4 layout and the
  `/etc/swupdate*` config from the CM4 image verbatim. U-Boot environment
  variables (`default_part`, `fallback_part`, `bootcount`, `check_bootcount`)
  port one-to-one once you have a working U-Boot ≥ 2024.01 for BCM2712.

## Testing checklist

Once the new image boots:

1. `dmesg | grep ablspi` should show one
   `ablspi: ablspi0.0 ready: irq=N speed=20000000Hz frame=768 bytes` line.
2. `ls -l /dev/ablspi0.0` exists with the same permissions as before.
3. `cat /proc/ableton/ablspi/0.0/irq_count` increments once per XMOS
   frame (~3 ms / frame → ~340 / s when active).
4. Start `MoveLauncher` manually:
   `start-stop-daemon --start -c ableton -b /opt/move/MoveLauncher`.
   The LCD should come up, pads should respond, audio should pass through.
5. If the LCD stays blank but pads respond, the IRQ path works but the
   display-pull handshake is stuck - check `/proc/ableton/ablspi/0.0/irq_count`
   continues to climb. If it's frozen, the GPIO mapping / pin routing
   on the carrier differs from the CM4 layout.
   
## AI Assistance Disclaimer
This was developed with AI assistance, including Claude, Codex, and other AI assistants.

All architecture, implementation, and release decisions are reviewed by human maintainers.
AI-assisted content may still contain errors, so please validate functionality, security, and license compatibility before production use.
