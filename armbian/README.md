# Armbian board package for the Ableton Move

Drop-in tree for an [armbian-build](https://github.com/armbian/build)
checkout. Adds **one** community-supported board target — `move` — that
covers both CM4 and CM5 from a single config (Armbian's `bcm2711` family
already supports the whole 64-bit Pi/CM lineage, with `[cm4]`/`[cm5]`
filter sections in `config.txt` differentiating the two at boot time).

## What gets baked into the image

| Concern              | Mechanism                                                   |
|----------------------|-------------------------------------------------------------|
| Kernel               | rpi-6.18.y (`current`) or rpi-7.0.y (`edge`) + PREEMPT_RT   |
| Kernel config        | Fragment merged via `custom_kernel_config__` hook           |
| DT overlays          | Built from `.dts` sources, installed to `/boot/dtb/broadcom/overlay/` |
| `config.txt`         | Appended with `[cm4]/[cm5]` filter sections selecting the right overlay |
| `ableton` user       | UID 1000, home `/data/UserData`, groups `ablspi audio dialout plugdev sudo` |
| `ablspi` group       | GID 1000 (matches stock AbletonOS)                          |
| Default password     | `move` for both root and ableton (override in customize-image.sh) |
| Hostname             | `move`                                                      |
| Firstrun wizard      | **Skipped entirely** — `/root/.not_logged_in_yet` removed   |
| `/data` partition    | Created on first boot via `move-firstboot-data.service`     |
| `ablspi.ko`          | Installed via DKMS, auto-loaded by `modules-load.d`         |
| Services             | `move-{launcher,web,usb-gadget,xmos-shutdown}.service` enabled |
| D-Bus policy         | `move.conf` + two service files installed                   |

The standard Armbian rootfs-expansion mechanism (`/root/.rootfs_resize`)
fills the SD on first boot; **before** that, our firstboot script shrinks
the rootfs back to 6 GB and carves out a 4th partition for `/data`. From
that point on `/data` is mounted via `fstab` (`LABEL=data`).

## Tree

```
armbian/
├── config/
│   └── boards/
│       └── move.csc                       single board, BOARDFAMILY=bcm2711
└── userpatches/
    ├── customize-image.sh                 main chroot-time configurator
    ├── extensions/
    │   └── move-kernel-config.sh          custom_kernel_config__ hook
    └── extras/
        ├── README                         where the operator stages debs + fragment + dts
        └── verify.sh                      post-flash sanity check
```

## Usage

```sh
git clone https://github.com/armbian/build.git
cd build

# Stage the Move bits into the Armbian tree
PORT=/path/to/movenewimage/port
cp $PORT/armbian/config/boards/move.csc                 config/boards/
cp $PORT/armbian/userpatches/customize-image.sh         userpatches/
mkdir -p userpatches/extensions
cp $PORT/armbian/userpatches/extensions/*.sh            userpatches/extensions/
mkdir -p userpatches/extras userpatches/overlay/dts
cp $PORT/armbian/userpatches/extras/verify.sh           userpatches/extras/
cp $PORT/kernel-config/move.fragment.config             userpatches/
cp $PORT/dts/ablspi-move-cm*.dts                        userpatches/overlay/dts/

# Build the two .debs once and stage them
( cd $PORT/move-bringup && dpkg-buildpackage -us -uc -b )
cp $PORT/../*.deb                                       userpatches/overlay/extras/
# (The path above is the source-package parent. Adjust if you build elsewhere.)

# Build the image
./compile.sh BOARD=move BRANCH=current RELEASE=trixie \
             BUILD_DESKTOP=no BUILD_MINIMAL=yes \
             KERNEL_CONFIGURE=no
```

The compiled image lands under `output/images/Armbian_*_move_*.img`.
Flash it to an SD card with `dd` or `rpi-imager`, eMMC-flash via `rpiboot`,
or boot it from USB on the Move's eMMC carrier.

## Post-flash verification

After first boot, copy `userpatches/extras/verify.sh` to the target and
run it:

```sh
ssh root@move.local 'sh -' < userpatches/extras/verify.sh
```

It checks 20+ items in five buckets — kernel identity, partition layout,
user/group setup, ablspi presence, DT overlays, D-Bus, services,
`/opt/move`, USB gadget — and prints `PASS`/`WARN`/`FAIL` for each.
Exit code is non-zero on any failure.

## Verified facts (from Armbian's current sources, 2026)

- `BOARDFAMILY="bcm2711"` is the right family for both CM4 and CM5;
  see `config/sources/families/bcm2711.conf` in armbian/build.
- `current` branch tracks `github.com/raspberrypi/linux` on
  `rpi-6.18.y` (as of the snapshot used to write this).
- `OVERLAY_DIR="/boot/dtb/broadcom/overlay"` — the right place to install
  `.dtbo`s on an Armbian RPi image.
- `customize-image.sh` runs in a chroot with args
  `$RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP`; the host's
  `userpatches/overlay/` is bind-mounted at `/tmp/overlay`.
- `custom_kernel_config__<name>` is the correct hook for modifying the
  kernel `.config` between `olddefconfig` and the build — see
  `extensions/nomod.sh`, `extensions/lsmod.sh`, and
  `extensions/arm64-compat-vdso.sh` in the Armbian tree for further
  in-tree examples.
- `/root/.not_logged_in_yet` is the firstrun gate. Removing it skips
  the welcome wizard entirely; alternatively, populate it with the
  documented `PRESET_*` keys to drive the wizard non-interactively
  (`PRESET_USER_NAME`, `PRESET_USER_PASSWORD`, `PRESET_ROOT_PASSWORD`,
  `PRESET_DEFAULT_REALNAME`, `PRESET_LOCALE`, `PRESET_TIMEZONE`,
  `PRESET_USER_SHELL`, `PRESET_NET_*`, `PRESET_CONNECT_WIRELESS`,
  `SET_LANG_BASED_ON_LOCATION`, `PRESET_USER_KEY`, `PRESET_ROOT_KEY`,
  `PRESET_CONFIGURATION`). We use the skip approach because we've
  already created the user with the right UID/home/groups during
  customize-image.

## Caveats

- **Pre-existing UID 1000.** If something else in the base rootfs claims
  UID 1000 before we run, our `useradd` falls back to a dynamic UID and
  prints a warning. Inspect the rootfs (`grep 1000 /etc/passwd /etc/group`)
  in the chroot if you need to redirect a conflicting user.
- **U-Boot A/B failover.** Armbian's default RPi boot path does not use
  U-Boot at all (`BOOTCONFIG=none` in `bcm2711.conf` — the GPU bootloader
  loads the kernel directly from `/boot/firmware/`). The stock Move
  relies on a U-Boot `bootcount` for A/B failover; you give that up by
  going to Armbian. If you want it back, swap in `u-boot-rpi4-move-*.bin`
  from `recon/boot/` and adapt the boot chain accordingly.
- **The kernel fragment cannot fully reproduce Ableton's `.config`**
  byte-for-byte (`CONFIG_IKCONFIG` was off on the stock image, so no
  ground truth exists). It is sufficient to recreate the runtime
  behaviour observed via `lsmod`, `modules.builtin`, and `/sys`.
- **DKMS at firstboot.** `ablspi-dkms` rebuilds against any installed
  `linux-headers-*` package. Armbian's RPi BSP pulls headers
  automatically; confirm with `dkms status ablspi` after first boot
  (the `verify.sh` script also covers this).
