# Building and testing a Move Armbian image

End-to-end guide for producing a Debian-based Move image and validating
it on hardware. Assumes you've completed the staging described in
[`armbian/README.md`](armbian/README.md) (board file, customize hook,
extension, fragment, source tree, verify.sh all in place under
`~/armbian-build/`).

## 0. Prerequisites

- An `armbian-build` checkout at `~/armbian-build` (or wherever — adjust
  paths below).
- A Linux host with Docker installed (Armbian-build builds inside a
  container by default).
- ≥ 30 GB free disk space for the build cache + output image.
- An SD card (≥ 8 GB) and a USB SD card reader.
- **Your Move's stock SD card preserved as a working recovery.** The
  Move is a CM4 Lite (no on-module eMMC) — the OS lives entirely on the
  SD card, so there's no on-device fallback. Keep your original stock
  Move SD in a safe place; the experimental image goes on a *separate*
  SD card. Swap cards to recover.
- SSH access to your existing stock Move (for [§1](#1-populate-optmove)).
- `rsync`, `dpkg-deb`, `fakeroot` on the host (`apt install rsync fakeroot`).

Verify the staging is intact:

```sh
ls ~/armbian-build/config/boards/move.csc \
   ~/armbian-build/userpatches/customize-image.sh \
   ~/armbian-build/userpatches/extensions/move-kernel-config.sh \
   ~/armbian-build/userpatches/move.fragment.config \
   ~/armbian-build/userpatches/overlay/move-bringup-src/debian/control \
   ~/armbian-build/userpatches/overlay/move-bringup-src/source/usr/share/move-bringup/overlays-src/ablspi-move-cm4.dts \
   ~/armbian-build/userpatches/overlay/move-bringup-src/source/usr/share/move-bringup/overlays-src/ablspi-move-cm5.dts \
   ~/armbian-build/userpatches/overlay/extras/verify.sh
```

All eight paths should exist. If any are missing, re-run the staging
procedure.

## 1. Populate `/opt/move` and `/data` from your own Move

Do this **first** — before the Armbian build — so your personal data
and the Move firmware are baked into the image rather than bolted on
afterward.

The Move's userspace binaries (`/opt/move/*`) and your personal user
content (`/data/*` — presets, sets, samples, settings) are both
Ableton-proprietary or personal, and **not** shipped by this repo. The
recommended path: run `extract-move-firmware.sh` once against your
stock Move SD, drop the two `.deb`s it produces into
`userpatches/overlay/extras/`, and Armbian's `customize-image.sh` will
`dpkg -i` them in the chroot in dependency order.

### 1a. Build the personal firmware + user-data debs (one-time, off-device)

```sh
# From your dev box, before the Armbian build. Boot the Move on its
# stock SD card, SSH-reachable, then:
./scripts/extract-move-firmware.sh \
    --host root@<stock-move-ip-or-hostname> \
    --output ~/armbian-build/userpatches/overlay/extras/
```

By default this produces **two** debs in the output directory:

| Deb | Source on the stock Move | Installed at | Size |
|-----|--------------------------|--------------|------|
| `move-firmware_<ver>-1_arm64.deb`            | `/opt/move/*` + vendored libs from `/usr/lib/` | `/opt/move/`               | ~70 MB |
| `move-user-data_<YYYYMMDD.HHMM>-1_arm64.deb` | `/data/*` (UserData, CoreLibrary, settings)    | `/var/lib/move-data/`      | depends on your library — could be GBs if you have a lot of samples |

The firmware deb also installs SONAME shims for `libusb-1.0.so` and
`libmp3lame.so` (which Ableton's binaries link to but Debian only ships
as versioned `.so.0`), and drops in an `ld.so.conf.d` entry for
`/opt/move/lib/`.

The user-data deb's postinst chowns `UserData/` to `ableton:users`
(uid 1000) to match the stock layout; everything else stays `root:root`.
Files land at `/var/lib/move-data/`, which the `data.mount` unit
bind-mounts at `/data` — so on first boot of your new image, `/data`
is pre-populated exactly as it was on your stock device.

Flags:

```sh
--no-data / --firmware-only   # skip /data, only produce firmware deb
--data-only                   # skip /opt/move, only produce user-data deb
--output DIR                  # output directory (default: cwd)
--host root@move.local        # ssh target (default)
--version VER                 # override firmware version string
```

Once both debs are in `userpatches/overlay/extras/`, `compile.sh` will
pick them up via `customize-image.sh` and install in this order:

```
customize-image.sh: installing move-firmware_3.18-1_arm64.deb
customize-image.sh: installing move-user-data_20260513.1903-1_arm64.deb
```

After flashing and booting, `/opt/move/MoveLauncher` is in place,
`/opt/move/lib/` is in `ld.so.cache`, `/data` is bind-mounted from the
pre-populated rootfs tree, and `move-launcher.service` comes up clean
with no "No Data Partition" splash.

### 1b. Manual rsync (alternative, if the script doesn't fit your flow)

If you'd rather populate `/opt/move` and `/data` on a running target
instead of baking them into the image:

```sh
# /opt/move proper + vendored libs:
rsync -aHAX --info=progress2 \
    root@<stock-move>:/opt/move/ \
    root@move.local:/opt/move/

ssh root@move.local 'mkdir -p /opt/move/lib'
for lib in libc++.so.1 libXSDBusCpp.so libXTCMalloc.so \
           libubootenv.so.0 libswupdate.so.0.1; do
    rsync -aHAX root@<stock-move>:/usr/lib/$lib \
                root@move.local:/opt/move/lib/
done
ssh root@move.local '
    echo "/opt/move/lib" > /etc/ld.so.conf.d/move.conf
    ldconfig
    cd /usr/lib/aarch64-linux-gnu
    [ -e libusb-1.0.so ]   || ln -s libusb-1.0.so.0   libusb-1.0.so
    [ -e libmp3lame.so ]   || ln -s libmp3lame.so.0   libmp3lame.so
'

# /data:  push to /var/lib/move-data/ so the bind-mount surfaces it.
rsync -aHAX --info=progress2 \
    --exclude='log/' --exclude='Scratch/' --exclude='**/.cache/' \
    root@<stock-move>:/data/ \
    root@move.local:/var/lib/move-data/
ssh root@move.local '
    chown -R ableton:users /var/lib/move-data/UserData
    systemctl restart move-launcher move-web
'
```

Re-run `verify.sh` — the WARNings about `/opt/move/MoveLauncher` and the
vendored libs should now turn to PASSes, and `findmnt /data` will pass.

### 1c. Legal note

The `move-firmware` deb contains Ableton-proprietary code; the
`move-user-data` deb contains your personal sets, samples, and
settings. **Do not redistribute either.** Ableton's EULA permits
personal use only — the firmware package is yours, built from your own
device, for your own image. Your user content is your own. The script
is in this repo because we don't distribute either; you do, to yourself.

## 2. Build the image

```sh
cd ~/armbian-build
./compile.sh BOARD=move BRANCH=current RELEASE=trixie \
             BUILD_DESKTOP=no BUILD_MINIMAL=yes \
             KERNEL_CONFIGURE=no
```

What each flag does:

| Flag                  | Effect                                                       |
|-----------------------|--------------------------------------------------------------|
| `BOARD=move`          | Selects our board file (`config/boards/move.csc`).           |
| `BRANCH=current`      | Uses Armbian's `current` kernel branch (rpi-6.18.y as of 2026). |
| `RELEASE=trixie`      | Debian 13 Trixie userspace. `bookworm` also works on `current`. |
| `BUILD_DESKTOP=no`    | Skip GNOME/KDE/etc.                                          |
| `BUILD_MINIMAL=yes`   | Server-style minimal rootfs.                                 |
| `KERNEL_CONFIGURE=no` | **Required.** Suppress `make menuconfig`; our extension merges the fragment unattended. |

First build takes 30-90 minutes depending on host CPU + cache state.
Subsequent builds are faster (compiler / source caches are kept under
`~/armbian-build/cache/`).

The build runs `customize-image.sh` inside the rootfs chroot. That hook:

1. Installs `build-essential debhelper dh-dkms device-tree-compiler` in
   the chroot.
2. `dpkg-buildpackage`s `move-bringup` + `ablspi-dkms` from
   `/tmp/overlay/move-bringup-src/`.
3. `apt`-installs both `.deb`s, which:
   - Compiles the two DT overlays (CM4 + CM5) into
     `/boot/firmware/overlays/ablspi-move-cm{4,5}.dtbo`.
   - Appends `[cm4]` and `[cm5]` filter sections to
     `/boot/firmware/config.txt` with the matching `dtoverlay=` lines.
   - Pins the kernel packages so `apt upgrade` can't replace our RT kernel.
4. Pre-creates the `ableton` user (UID 1000) with RT groups, sets root
   and ableton passwords (both `move`), and disables Armbian's firstrun
   wizard.

Output lands at `~/armbian-build/output/images/Armbian_*_move_*.img.xz`.

## 3. Flash to SD card

```sh
# Find your card
lsblk
# /dev/sdX is your SD reader — VERIFY before continuing

# Unzip + flash
xzcat ~/armbian-build/output/images/Armbian_*_move_*.img.xz | \
    sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Or use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) /
`rpi-imager` / Balena Etcher with the `.img.xz` directly.

**Flash to a fresh SD card — do not overwrite your stock Move SD.**
The Move uses a CM4 Lite (no eMMC), so the SD card *is* the OS. Power
off the Move, swap in the experimental SD card, power on. To get back
to your stock setup, power off and swap the original SD back in.

Recommended: label the cards physically. "MOVE STOCK" and
"MOVE ARMBIAN" written on tape on the cards is cheap insurance.

## 4. First boot

### 4a. Optional: pre-configure WiFi for headless setup

If you want the Move to come up on your WiFi immediately so you can SSH
in without serial console / USB-Ethernet:

1. Mount the SD card's FAT partition (`bootfs` / `boot`) on your laptop
   — it's the small partition with `config.txt` and `cmdline.txt`. FAT
   mounts cleanly on macOS, Windows, and Linux without extra tools.
2. Find `move-wifi.txt.example` on the partition. Copy it to
   `move-wifi.txt` (drop the `.example`).
3. Edit the file: set `SSID`, `PSK`, and `COUNTRY` (ISO 3166-1
   alpha-2). Save.
4. Safely eject the SD card, insert it into the Move, power on.

On first boot, `move-firstboot-wifi.service` reads the file, writes a
NetworkManager keyfile to `/etc/NetworkManager/system-connections/`,
**shreds the source file from the SD** so the PSK doesn't sit on a
partition that any laptop can mount, and brings the connection up.

You should be able to `ssh root@move.local` within ~30 seconds of
power-on (or check your router for the assigned IP if mDNS doesn't
resolve). Default password is `move` — change it immediately.

### 4b. Expected boot sequence

Power on the Move with the SD card inserted. Expected sequence:

1. **Pi bootloader** picks up `/boot/firmware/config.txt`, sees the
   `[cm4]` filter section, loads `ablspi-move-cm4.dtbo`.
2. **Linux kernel** boots (PREEMPT_RT — `uname -r` will end in
   `-rt-bcm2711` or similar).
3. **`data.mount`** fires as part of `local-fs.target`: bind-mounts
   `/var/lib/move-data` (populated at install time by `move-bringup`
   and, if you supplied it, the `move-user-data` deb) onto `/data`.
   This is what makes MoveLauncher's `findmnt --mountpoint /data`
   gate pass; without it the launcher spawns a `MoveMessageDisplay`
   child showing "No Data Partition" on the device screen.
   *(The older `move-firstboot-data.service` that carved a 4th
   ext4 partition on the SD is still shipped but disabled by default
   — bind-mount is lighter and just-as-functional for MoveLauncher.)*
4. **`ablspi.ko`** loads via `modules-load.d`, probes the `ablspi` DT
   node, creates `/dev/ablspi0.0` owned `root:ablspi 0660`. The driver
   sets SPI mode 3 (CPOL=1, CPHA=1) — required by the XMOS link;
   without it both directions are misclocked and MoveLauncher errors
   with `Couldn't decode USB MIDI message {…}` per frame.
5. **`move-xmos-init.service`** replays the stock SysEx init batch
   (CC prelude, `0xFF` System Reset, then `0x42`/`0x25`/`0x3A`/`0x1E`/
   `0x47`/`0x0D`/`0x37` queries) and verifies the XMOS reports back
   `mode=1 (standaloneMode)`. After this, pad/knob/button events are
   emitted as plain USB-MIDI on cable 0, ready for MoveLauncher (or a
   schwung-spi-based app like vimana2r) to consume.
6. **Network**: Ethernet via DHCP, plus the USB-Ethernet NCM gadget
   (172.16.254.1/24) for direct host attach.
7. **`avahi-daemon`** advertises the device as `move.local` over mDNS
   (the hostname is pre-seeded to `move` in `/etc/hostname` and
   `/etc/hosts`). Any mDNS-capable peer on the same LAN — macOS,
   Linux with `nss-mdns` or `systemd-resolved`, Windows with Bonjour
   Print Services — resolves `move.local` without DNS. The Move
   itself also resolves outbound `*.local` names via `libnss-mdns`.
   This is also what makes MoveLauncher's `org.freedesktop.Avahi`
   D-Bus hostname query succeed; without it the launcher journal
   fills with `Couldn't get host name … ServiceUnknown` errors.

SSH in once the network is up:

```sh
ssh root@move.local      # password: move
# or via USB-Ethernet: ssh root@172.16.254.1
```

Change passwords immediately:

```sh
passwd            # root
passwd ableton
```

### 4c. CM5 only: flash a modern BCM2712 EEPROM bootloader (one-time)

**Skip this on CM4 — it doesn't apply and the tool will refuse.**

A fresh CM5 ships with whatever second-stage bootloader Ableton
flashed to its onboard SPI EEPROM at the factory. That's typically
from 2023 or earlier and too old to honor the kernel's firmware-
mailbox calls for the BCM2712 USB power domain and the firmware-
managed clock list. Symptoms if you skip this step:

- `dmesg` spam: `raspberrypi-clk … error -22`,
  `genpd_provider USB: Failed to set power to 1 (-22)`, `vc4-drm …
  Couldn't stop firmware display driver: -22`.
- `/sys/class/udc/` empty → `move-usb-gadget.service` no-ops →
  no `usb0` interface, no USB-Ethernet tether via the Move's USB-C.
- `/sys/bus/platform/devices/1002000000.v3d/driver` absent → no GPU.
- `pispbe` driver doesn't bind → no ISP / camera pipeline.

**Important: don't use `rpi-eeprom-update -a` here.** The
Debian-packaged `rpi-eeprom` ships only the stale "default" channel
under `/lib/firmware/raspberrypi/bootloader-2712/default/` (typically
frozen circa late 2023), and `-a` flashes from that channel — leaving
you on a bootloader that still doesn't honor the modern mailbox
protocol. You want a *current* `pieeprom-*.bin` from the upstream
raspberrypi/rpi-eeprom repo, flashed via `-f`.

Recipe (with the most recent verified-working blob at time of
writing — bump the filename if a newer one exists upstream):

```sh
sudo apt update
# Both packages are installed best-effort by customize-image.sh during
# the image build (1.0.11+), but if the build couldn't find them in
# its apt sources, install them manually now. apt install is a no-op
# if they're already there:
sudo apt install -y libraspberrypi-bin rpi-eeprom

# Inspect the current EEPROM — anything before 2026 is stale on a Move:
vcgencmd bootloader_version
# Example stale output: "Aug  8 2023 ..." or even "Unable to get
# bootloader config" (vcgencmd present, EEPROM too old to answer).

# Fetch a current BCM2712 bootloader from upstream:
cd /tmp
wget https://github.com/raspberrypi/rpi-eeprom/raw/master/firmware-2712/latest/pieeprom-2026-05-13.bin
# (Browse https://github.com/raspberrypi/rpi-eeprom/tree/master/firmware-2712/latest
#  to pick the newest available .bin if 2026-05-13 has been superseded.)

# Stage the flash — the actual write happens on next reboot:
sudo rpi-eeprom-update -f /tmp/pieeprom-2026-05-13.bin
sudo reboot
```

After reboot, verify:

```sh
vcgencmd bootloader_version       # should show 2026-05-13 (or newer)
dmesg | grep -iE "genpd|raspberrypi-clk|vc4-drm.*Couldn"   # silent
ls /sys/class/udc/                # 1000480000.usb
systemctl is-active move-usb-gadget   # active
ip -br link | grep usb            # usb0
ls /dev/dri/                      # card0, card1, renderD128 (GPU live)
```

**Why it's a manual step, not auto:** flashing the EEPROM is a
hardware write; a botched flash can brick the CM5's boot ROM. The
ablspi/audio path works fine without it, so we don't gate first boot
on an EEPROM update — we let you decide when to take the small risk
for the bigger feature set. After your first successful manual
flash, `rpi-eeprom-update.service` runs at every boot and *would*
keep you current automatically — but it can only see the stale
`default` channel from the Debian package, so practically: re-run
the explicit `wget ... && rpi-eeprom-update -f` recipe whenever you
notice the bootloader has drifted significantly behind upstream.

CM4 users: this section does nothing for you — the CM4 boot chain
uses `bootcode.bin` + `start4.elf` from the FAT partition, not an
SPI EEPROM. dwc2/v3d/etc. work on CM4 without any of this.

## 5. Verify

Copy `verify.sh` to the device and run it:

```sh
ssh root@move.local 'sh -' < ~/armbian-build/userpatches/overlay/extras/verify.sh
```

It runs ~30 checks across:

- **Kernel identity** — `PREEMPT_RT`, key `CONFIG_*` bits via
  `/proc/config.gz`, `CONFIG_RT_GROUP_SCHED is not set`.
- **RT runtime** — `sched_rt_runtime_us`, PAM limits, cgroup hierarchy.
- **Storage** — `/data` is a real mount point (`findmnt /data`
  succeeds; shows the `/var/lib/move-data` bind source on rootfs).
- **Users** — `ableton` UID 1000, home `/data/UserData`, group
  membership (`ablspi audio realtime dialout plugdev video render sudo`).
- **Firstrun wizard** — `/root/.not_logged_in_yet` is gone.
- **ablspi** — module loaded, `/dev/ablspi0.0` exists with correct
  permissions.
- **DT** — `ableton,move` compatible advertised in `/proc/device-tree/`.
- **D-Bus** — policy + service files installed.
- **Services** — `move-{launcher,web,usb-gadget,xmos-shutdown}.service`
  enabled.
- **mDNS / Bonjour** — `avahi-daemon` + `libnss-mdns` installed, service
  enabled + active, `nsswitch.conf` has `mdns`, hostname is `move`, and
  `org.freedesktop.Avahi` owns its system-bus name.
- **`/opt/move`** — presence + library resolvability (WARN, not FAIL,
  since `/opt/move` is operator-supplied).
- **Kernel pinning** — preferences file + `apt-mark hold` state.

Output prefixes:

| Prefix | Meaning                                                          |
|--------|------------------------------------------------------------------|
| `PASS` | All good.                                                        |
| `WARN` | Non-critical — usually means an optional bit isn't populated yet. |
| `FAIL` | Critical — should be addressed before relying on the image.      |

Exit code is non-zero on any `FAIL`.

## 6. Recovery

The Move is a CM4 Lite — no eMMC, the SD card is the only boot medium.
Recovery is **physical SD swap**:

1. Power off the Move.
2. Eject the experimental SD card.
3. Insert your original stock Move SD card.
4. Power on. You're back to stock AbletonOS.

The Move hardware itself is unaffected by anything we do — see
[§6a](#6a-carrier-and-peripheral-safety) below for the threat model.

If `verify.sh` reports failures you can't fix in-place, edit
`~/armbian-build/userpatches/...`, rerun `./compile.sh`, reflash the
experimental SD. Each build/flash iteration is non-destructive to the
Move hardware.

### 6a. Carrier and peripheral safety

What could in theory damage the carrier / peripherals, and why each is
not a real risk here:

| Potential failure mode                           | Why we're fine                                                      |
|--------------------------------------------------|---------------------------------------------------------------------|
| Wrong GPIO direction driving against an output   | Our `ablspi.ko` sets GPIO3 as **input** via `gpiod_direction_input` before requesting IRQ. SPI0 pins are configured by the upstream `spi-bcm2835` driver using the same `pinctrl-0` group as Ableton's stock DT. |
| Wrong voltage / over-voltage                     | We set zero `over_voltage`, `force_turbo`, `arm_freq`, or PMIC tweaks. Power regulation stays at SoC defaults. |
| Wrong I2C address corrupting a chip              | I2C1 RTC at 0x51 matches stock exactly (NXP PCF85063). No other I2C writes happen. |
| Wrong SPI clock damaging the XMOS link           | Driver defaults to **20 MHz** (matches `ablspi.c` library). Stock Move uses 20 MHz. |
| Reprogramming firmware / EEPROMs                 | We never touch the RPi EEPROM, the XMOS firmware, or any one-time-programmable hardware. `move_xmos_fw_*.upgrade` blobs ship inside `move-firmware` but are only read by `MoveFirmwareUpdater`, which only runs when the user invokes it. |
| LCD/codec misprogramming                         | Both are XMOS-side. We never touch them from Linux. |
| Pads/encoders/buttons drive states               | All read by XMOS. Linux only receives input events over SPI. |

The Move's carrier is a passive board around the CM4 module. There's
nothing the OS can write that's not undoable by a power-cycle + SD swap.
The only nondestructive thing this image could potentially *break* is
its own software state, and the recovery path is plugging a different
SD card in.

## 6c. Known limitations

* **WiFi status icon shows "disconnected"** on the device even when the
  unit is online and reachable. MoveLauncher reads connection state via
  the `net.connman` D-Bus interface (ConnMan), which is the network
  manager on stock AbletonOS. We use NetworkManager instead, so
  MoveLauncher's `net.connman` call fails (visible as
  `Couldn't get initial Connection state. D-Bus error:
  [org.freedesktop.DBus.Error.ServiceUnknown] The name net.connman was
  not provided by any .service files` in the launcher journal).
  Networking itself works fine — only the on-device status indicator
  is stale. Workarounds:
  - Install ConnMan alongside NM and configure NM to leave the WiFi
    interface unmanaged via a keyfile-conf snippet:
    `[device-disable-wifi]` with `match-device=interface-name:wlan0`
    `managed=false`.
  - Or write an NM-state → ConnMan-D-Bus bridge (TODO). Stock's state
    files live under `/data/settings/connman/lib/connman/`; the file
    is a binary blob holding cached SSID profiles.

* **`swupdate` not running**. We ship a tiny stub
  (`swupdateprog-stub.service`) that just creates `/tmp/swupdateprog`
  and accepts connections without sending progress messages. This
  satisfies `MoveControlModeHandler`'s `progress_ipc_connect()`
  retry-loop dependency but means there is no real auto-update path —
  firmware updates have to be applied manually via
  `/opt/move/MoveFirmwareUpdater`. Upstream Debian's `swupdate`
  package is built `-DCONFIG_SIGNED_IMAGES`; running it would require
  providing a public key + signing all updates, which we don't want.

## 6d. CM5-specific known limitations

These three apply only when the Move carrier has a Compute Module 5
socketed (not CM4). All investigated against actual hardware (CM5
Rev 1.0, Armbian rpi-7.0.y kernel `7.0.6-edge-bcm2711`). ablspi/XMOS,
MoveLauncher, audio path, and built-in CM5 WiFi (brcmfmac) all work
normally on CM5; everything below is documented hardware or kernel-
level limitations that have no software fix from our side.

### PCF85063 RTC: hardware-unreachable on CM5

The Move's PCF85063 RTC is wired to the SODIMM pins originally
labelled "GPIO 44/45" on CM4. On CM4 (BCM2711) those SODIMM pins map
to BCM2711 GPIO 44/45 with i2c0 alt-functions, and the CM4 overlay
uses `&i2c0if + pinctrl &i2c0_gpio44` to wire I²C there. On CM5
those same SODIMM pins map to BCM2712 SoC pads named `emmc_dat5` /
`emmc_dat6` (pin 44/45 in the `107d504100.pinctrl-pinctrl-bcm2712`
namespace), and per the kernel pinctrl driver those pads have **no
I²C alt-functions whatsoever**:

```
PIN(44, vc_spi0, mtsif_alt, enet0, sd_card_a, mtsif_alt1,
    arm_jtag, pdm, spi_m),
PIN(45, vc_spi0, mtsif_alt, enet0, sd_card_a, mtsif_alt1,
    arm_jtag, pdm, spi_m),
```

The BCM2712 SODIMM pins that DO expose I²C (`bsc_m3`, alt5) are
GPIO 40/41 — physically different SODIMM pins from where the Move
carrier traced the RTC. No DT overlay can route signals across pads
that aren't physically wired.

Practical impact: `dmesg` shows `rtc-pcf85063 15-0051: error -ETIMEDOUT:
RTC chip is not present`; `/dev/rtc0` ends up bound to the BCM2712 AON
soft RTC instead, which has no battery backup. Time of day relies on
NTP (systemd-timesyncd / chrony) at each boot.

Recovery paths:
- Live with NTP. The Move userspace tolerates wall-clock drift
  before NTP corrects it; user-set timestamps just walk forward
  from epoch.
- Hardware mod: cut the RTC SDA/SCL traces, jumper them to the
  SODIMM pins that expose GPIO 40/41 on CM5, and add a DT overlay
  fragment targeting one of `/soc@107c000000/i2c@7d005...` (the
  `brcm,bcm2711-i2c` family controllers) with pinctrl on bcm2712
  pins 40/41 in function `bsc_m3`. Full details in the .dts header
  at `port/move-bringup/source/usr/share/move-bringup/overlays-src/ablspi-move-cm5.dts`.

Sources:
- `drivers/pinctrl/bcm/pinctrl-bcm2712.c` (rpi-6.12.y / rpi-7.0.y),
  `bcm2712_c0_gpio_pin_funcs` table — verbatim verified against the
  installed kernel via `/sys/kernel/debug/pinctrl/107d504100.pinctrl-pinctrl-bcm2712/pinmux-pins`
  on the running device.
- CM5 datasheet (datasheets.raspberrypi.com/cm5/cm5-datasheet.pdf),
  §"CM4 ↔ CM5 differences" — documents the pin-by-pin
  repurposing.

### USB-Ethernet NCM gadget + v3d + raspberrypi-clk: stale CM5 EEPROM

`move-usb-gadget.service` deliberately no-ops on a fresh CM5: its
`ConditionPathExistsGlob=/sys/class/udc/*` guard fails because no UDC
is registered. The full cascade in dmesg:

```
raspberrypi-clk soc@107c000000:firmware:clocks: probe ... error -22
genpd_provider USB: Failed to set power to 1 (-22)        (many times)
vc4-drm axi:gpu: [drm] Couldn't stop firmware display driver: -22
vc4_hvs 107c580000.hvs: Couldn't get core clock
rmem 3fd16700.nvram: probe with driver rmem failed with error -22
```

Root cause is the **CM5's onboard SPI EEPROM bootloader being stale**.
The kernel side is correct (`CONFIG_COMMON_CLK_RP1=y`, `PINCTRL_RP1=y`,
`PINCTRL_BCM2712=y` all enabled in Armbian's current 6.18 build, all
the right drivers built). The kernel sends `RPI_FIRMWARE_GET_CLOCKS`
(`0x00010007`) and `RPI_FIRMWARE_SET_POWER_STATE` (`0x00028001`) via
the mailbox; the firmware that the EEPROM-resident second-stage
bootloader brought up doesn't honor those tags on BCM2712 in the form
the kernel wants. Result: no firmware-managed clocks → no power
domain for `/axi/usb@480000` (dwc2) → no UDC → no NCM gadget. Same
upstream of v3d (GPU) and pispbe (ISP) failures.

The fix is to flash a current BCM2712 bootloader to the CM5's EEPROM:

```sh
sudo apt install libraspberrypi-bin rpi-eeprom    # provides vcgencmd + updater
vcgencmd bootloader_version                       # shows current
sudo rpi-eeprom-update -a                         # stages a flash
sudo reboot
```

After reboot the mailbox calls succeed, `genpd USB` enables, dwc2
binds, `/sys/class/udc/...` populates, `move-usb-gadget.service`
brings up the NCM endpoint, and v3d / pispbe probe cleanly.

**Why this isn't automated by our image:** `rpi-eeprom-update.service`
exists and is enabled — but on Armbian it fails because `vcgencmd`
(from `libraspberrypi-bin`) isn't installed by default. The Move
board config now includes both packages in `PACKAGE_LIST_BOARD` so
they ship in the rootfs, **but flashing the EEPROM is a hardware
write — one bad flash can brick the CM5's boot ROM** — so we leave
the actual `rpi-eeprom-update -a` as a deliberate user action, not
an automatic first-boot step. See §4c.

CM4 builds are unaffected; the CM4's BCM2711 has a different boot
chain and dwc2 + NCM gadget come up normally without any EEPROM work.

Sources:
- `dmesg | grep raspberrypi-clk` and `journalctl -u rpi-eeprom-update`
  on a fresh CM5 boot (Armbian `current` 6.18.29-bcm2711, May 2026).
- `vcgencmd` missing → `rpi-eeprom-update.service` exits with
  `vcgencmd: not found / Unable to get bootloader config`.
- The bcm2712 bootloader blobs ship with `rpi-eeprom` under
  `/lib/firmware/raspberrypi/bootloader-2712/{beta,critical,default,
  latest,stable}/` — just nothing flashes them on Armbian by default.
- Inline notes in `ablspi-move-cm5.dts` header explaining the
  `ConditionPathExistsGlob` guard rationale.

### Intel 9260 WiFi: probe fails with -12 ENOMEM, no software fix found

The Move carrier's Intel 9260 (8086:2526 "Thunder Peak" Wireless-AC
9x6x, on the carrier's M.2 / PCIe slot) fails to probe on CM5:

```
iwlwifi 0001:01:00.0: probe with driver iwlwifi failed with error -12
```

PCIe link itself is healthy: `brcm-pcie 1000110000.pcie: link up,
2.5 GT/s PCIe x1`, device enumerated, BAR assigned. The `-12`
(ENOMEM) is internal to `iwl_trans_pcie_alloc` in the iwlwifi driver.
The Armbian kernel build doesn't enable `CONFIG_IWLWIFI_DEBUG` or
`CONFIG_DYNAMIC_DEBUG`, so the exact failure site is not visible at
runtime.

Tested workarounds (every one fails with the same `-12`):

- `cma=128M coherent_pool=8M` kernel cmdline (bumped CMA 6 → 128 MiB,
  pool 1 → 8 MiB)
- `iwlwifi.disable_msi=1` module parameter
- `pcie_aspm=off` kernel cmdline
- `dtoverlay=pciex1-compat-pi5,no-l0s,l1ss` (disables PCIe L0s + L1SS
  substates on the external `pciex1` controller, which is where the
  9260 is attached: `pcie@1000110000` / segment 0001 in DT)
- `dtparam=pciex1_gen=1` (forces PCIe Gen 1 link speed)
- All of the above combined

Same `-12` pattern is documented in the broader Pi 5 / CM5 community
for other older PCIe WiFi chipsets (MediaTek MT7915e, MT7925e) on the
same brcmstb-pcie controller, all unresolved. The community PCIe
device DB at <https://pipci.jeffgeerling.com/> lists AX200 as
working "Full" on both Pi 5 and CM4, with **no entry** for the
9260, 8265, or 7260 (suggestive — nobody has reported these working).
The Raspberry Pi Foundation has not published an official
compatibility list or workaround for this.

Practical impact: none for the Move on CM5 — the CM5 carries its
own onboard WiFi/BT combo radio (CYW43455 on SDIO), driven by
`brcmfmac` as `wlan0`. NetworkManager handles it, and
`move-firstboot-wifi.service` writes the keyfile against it just as
on CM4. The Intel 9260 just sits unbound (~30 mA idle).

If functional 5 GHz / antenna-routed WiFi specifically via the
carrier's Intel card is critical, the recommended swap is Intel
AX200 or AX210 (per community DB; not Raspberry Pi guidance).

Sources:
- Our on-device test matrix (CM5 Rev 1.0, kernel
  `7.0.6-edge-bcm2711`).
- <https://github.com/raspberrypi/linux/issues/7026> — mt7915e
  identical `-12` pattern, no fix found.
- <https://github.com/raspberrypi/linux/issues/7046> — mt7925e
  identical `-12` pattern, Pi engineer `6by9` responded (asking for
  firmware logs) but no resolution.
- <https://pipci.jeffgeerling.com/> — community PCIe device DB;
  AX200 listed working, no entry for 9260/8265/7260.
- Industrial Monitor Direct blog suggested ASPM-off + force-gen1
  workarounds for the 8265 (similar chipset), but we tested those
  against the 9260 and they did not work:
  <https://industrialmonitordirect.com/ja/blogs/knowledgebase/intel-8265-wifi-card-raspberry-pi-5-pcie-probe-error-12-fix>
  (third-party source, not Pi Foundation).

## 7. Iterating

Common edits and what to do after them:

| You changed                                          | Re-run                                  |
|------------------------------------------------------|-----------------------------------------|
| `move.fragment.config`                               | full `compile.sh` (kernel rebuild)      |
| `customize-image.sh`                                 | full `compile.sh` (chroot rebuild)      |
| Anything under `overlay/move-bringup-src/source/`    | full `compile.sh` (deb rebuilt in chroot) |
| Kernel module source (`src/ablspi/ablspi.c`)         | full `compile.sh`, or in-place: scp + dkms install on running target |
| DT overlay source (`overlays-src/ablspi-move-cm*.dts`) | full `compile.sh`, or in-place: `dtc` on target then reboot |
| `move.csc`                                           | full `compile.sh`                       |
| `verify.sh`                                          | nothing — just rerun the script        |

For in-place iteration on a running target, the relevant paths are:

```
ablspi.c        →  /usr/src/ablspi-1.0.0/ablspi.c   then  dkms install ablspi/1.0.0 -k $(uname -r)
*.dts           →  /usr/share/move-bringup/overlays-src/*.dts  then run /etc/kernel/postinst.d/move-overlays
*.service       →  /lib/systemd/system/                        then  systemctl daemon-reload
99-move-*.conf  →  /etc/{sysctl,security/limits}.d/            then  sysctl --system / re-login
```

## 8. Reference

- Top-level overview: [`README.md`](README.md)
- Driver internals: [`kernel/`](kernel/)
- DT overlay sources: [`dts/`](dts/)
- Kernel config: [`kernel-config/move.fragment.config`](kernel-config/move.fragment.config)
- Packaging: [`move-bringup/README.md`](move-bringup/README.md)
- Armbian integration: [`armbian/README.md`](armbian/README.md)
- Firmware extractor: [`scripts/extract-move-firmware.sh`](scripts/extract-move-firmware.sh)
