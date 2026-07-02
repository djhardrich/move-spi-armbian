# Move Manager "Unable to stat path" fix

## Symptom

In Move Manager (`move.local`), the **Sets** page loads, but **Recordings**, **Samples**,
and **Presets** show an error modal:

> **Error** — No options. Unable to stat path "Track Presets"

(The named path varies: "Recordings", "Samples", or "Track Presets".)

This affects this Armbian build because the rootfs and user data live on a single partition,
unlike a stock Move.

## Quick fix

```bash
# On the Move (as root):
sudo scripts/fix-move-manager-quota.sh

# Or from a workstation:
scripts/fix-move-manager-quota.sh --host root@move.local
```

The script is idempotent, backs up the original to `/opt/move/MoveWebService.orig`, and
refuses to run if the binary doesn't match the expected bytes. Roll back with
`scripts/fix-move-manager-quota.sh --rollback`.

After running, reload `move.local` and open Recordings / Samples / Presets. The storage bar
will read ~192 GB free (cosmetic — see below).

## Root cause

It is **not** missing directories or bad permissions. All four content folders exist under
`/data/UserData/UserLibrary/` (`Sets`, `Recordings`, `Samples`, `Track Presets`) with correct
ownership (`ableton:users`), and the web service resolves their full paths correctly.

The real failure is in `/opt/move/MoveWebService`. For each content page it calls:

```c
quotactl(QCMD(Q_GETQUOTA, USRQUOTA), "/dev/mmcblk0p4", getuid() /* ableton, 1000 */, &dqblk)
```

`/dev/mmcblk0p4` is **hardcoded** in the binary — it is the data partition on a stock Move,
which is mounted with disk quotas enabled. On success the handler reads `dqb_bhardlimit`
(total) and `dqb_curspace` (used) to draw Move Manager's storage bar, so the bar is the
per-user **quota**.

On this build the rootfs/data are on a single partition (typically `/dev/mmcblk0p2`) and
**`/dev/mmcblk0p4` does not exist**, so `quotactl` fails. The directory-listing handler
treats that quota-stat failure as fatal and returns the misleading
`No options. Unable to stat path "X"`.

Evidence from `journalctl -u move-web.service`:

```
Listing directory content for "/data/UserData/UserLibrary/Recordings"
Unable to get quota stats for "/dev/mmcblk0p4"          <- the actual failure
Reply error: No options. Unable to stat path "Recordings"
```

**Sets appears to work** only because the Sets *page* also renders from another source
(flip-model / D-Bus browser / Cloud); its directory listing fails the same way underneath.

### Why a device-only fix isn't enough

The quota function uses `quotactl` only — there is **no `statvfs` fallback**. Even if pointed
at the real device, `quotactl(Q_GETQUOTA…)` would still fail because this build has no quota
infrastructure: ext4 has no `quota` feature, no `usrquota` mount option, no `aquota.*` files,
and the `quota*` userspace tools aren't installed. Enabling real quotas on the live rootfs is
fiddly and pointless here (single partition, no storage-cap intent), so we patch the binary.

## What the patch does

Two in-place edits (aarch64, little-endian) make the listing ignore the `quotactl` result and
report a fixed storage figure. `.text` has `Address 0x24ccc0 / Off 0x23ccc0`, so
**file_offset = VA − 0x10000** for the reference image
(`sha256 e7b9251f4e07c4ca63dfd8a8cba169b612bf8582d061b84ed920cad874f1596b`).

### Edit A — always take the success branch
VA `0x2fe1e0`, file offset `0x2ee1e0`:

| | instruction | bytes |
|---|---|---|
| before | `cbz w21, 0x2fe398` | `d5 0d 00 34` |
| after  | `b   0x2fe398`      | `6e 00 00 14` |

### Edit B — synthesize storage values
VA `0x2fe398`–`0x2fe3a4`, file offsets `0x2ee398`–`0x2ee3a7`:

| offset | before | after |
|---|---|---|
| `0x2ee398` | `ldr x8,[sp,#8]`  `e8 07 40 f9` | `mov x8,#0x3000000000`  `08 06 c0 d2` |
| `0x2ee39c` | `ldr x9,[sp,#24]` `e9 0f 40 f9` | `mov x9,x8`             `e9 03 08 aa` |
| `0x2ee3a0` | `lsl x8,x8,#10`   `08 d5 76 d3` | `nop`                   `1f 20 03 d5` |
| `0x2ee3a4` | `sub x9,x8,x9`    `09 01 09 cb` | `nop`                   `1f 20 03 d5` |

The following `stp x9,x8,[x19]` then stores **free = total = 0x3000000000 (192 GiB)** and the
function returns success. All pages load; the storage bar reads ~192 GB free (cosmetic only —
there is no quota, nothing is capped).

## Verify

The `/api/v1/data/<category>` endpoint needs the browser's session credentials (a `curl` from
the device returns `401`), so verify in the browser, then check the log:

```bash
journalctl -u move-web.service --since '5 min ago' \
  | grep -iE 'Listing directory|quota|No options|Unable to stat'
# Expect: "Listing directory content for ..." lines, and NO "quota"/"No options" errors.
```

## Rollback

```bash
scripts/fix-move-manager-quota.sh --rollback
# or manually:
cp -a /opt/move/MoveWebService.orig /opt/move/MoveWebService
systemctl restart move-web.service
```

## If a Move update changes MoveWebService

An update that replaces `/opt/move/MoveWebService` reverts the patch and the symptom returns.
Re-run `scripts/fix-move-manager-quota.sh`. If the binary differs at the patch sites the script
aborts safely; re-derive the offsets:

1. `objdump -d MoveWebService` and locate the call to `quotactl@plt` plus the nearby string
   load for `"Unable to get quota stats for"` — that function is the target.
2. **Edit A** = the `cbz` that follows the quotactl return check (`mov wNN, w0` then
   `cbz wNN, <success>`); change it to an unconditional `b <success>`.
3. **Edit B** = at `<success>`, the `ldr [sp,#8]` / `ldr [sp,#24]` / `lsl #10` / `sub`
   sequence feeding `stp x9,x8,[x19]`; replace with
   `mov x8,#0x3000000000` / `mov x9,x8` / `nop` / `nop`.
4. Convert each VA to a file offset with `offset = VA - (text.Address - text.Off)` (from
   `readelf -SW`) and update the addresses at the top of the script.

## Alternative (not used here)

Enable real ext4 quotas on the rootfs + `setquota` for uid 1000 + repoint the device string
`p4`→`p2`. Faithful to stock (accurate storage bar) but invasive on a live root partition;
rejected for this single-partition build.
