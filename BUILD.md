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
