# swupdate shim — design spec

**Date:** 2026-05-16  
**Status:** awaiting user approval  
**Scope:** intercept Ableton Move firmware update flow; extract `/opt/move/` and `/data/`
from `.swu` payloads instead of flashing A/B partitions; add network update checking;
extend key extraction to cover offline SD card mode.

---

## 1. Problem

On the stock AbletonOS the `swupdate` daemon:
1. Listens on `/tmp/sockinstctrl` for a `.swu` data stream from `Updater`
2. Decrypts (AES-256-CBC) and extracts the CPIO archive
3. **Writes the root-filesystem ext4 image directly to `mmcblk0p2` or `mmcblk0p3`** — the
   inactive A/B partition — then reboots

On our Armbian system those partition names don't exist and the A/B boot machinery
(U-Boot, `libubootenv`) isn't present.  The `swupdateprog-stub.py` already satisfies
`MoveControlModeHandler`'s progress-socket dependency, but the control socket
`/tmp/sockinstctrl` is unhandled, so `Updater` errors immediately with
"Couldn't open software update IPC connection."

We need a replacement that:
- Accepts the same IPC from `Updater` (or its caller)
- Decrypts and unpacks the `.swu` safely
- Extracts `/opt/move/` and `/data/` from the embedded ext4 image
- Reports completion via the progress socket so `Updater` exits cleanly
- Checks the Ableton CDN (stable or beta channel) for available updates
- Never touches partition tables, boot partitions, or U-Boot env

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────┐
│ MoveLauncher / MoveOriginal                             │
│                                                         │
│  progress polling ──────────────────────────────────────┼──► /tmp/swupdateprog
│                                                         │         │
│  com.ableton.update D-Bus ──────────────────────────────┼──► move-update-dbus.service
│    registerSuccessfulStartup()                          │         (Python, replaces
│    factoryReset(as)                                     │          UpdateDBusService)
│                                                         │
│  spawns Updater /path/to/file.swu ──────────────────────┼──► Updater binary ──┐
│  web UI upload POST /api/v1/update ─────────────────────┼──► MoveWebService ───┤
└─────────────────────────────────────────────────────────┘    (both via         │
                                                            libswupdate.so)  ipc_inst_start()
                                                                                 ▼
                                                                      /tmp/sockinstctrl
                                                                     │
                                          ┌──────────────────────────┘
                                          ▼
                              move-swupdate-shim.service  (Python daemon)
                              ├── /tmp/swupdateprog       (progress socket)
                              └── /tmp/sockinstctrl       (control socket)
                                          │
                                          │  on .swu received:
                                          ▼
                              ┌─────────────────────────┐
                              │ .swu processing pipeline │
                              │  1. save stream → /tmp   │
                              │  2. cpio -id             │
                              │  3. AES-256-CBC decrypt  │
                              │  4. parse sw-description │
                              │  5. losetup + mount ext4 │
                              │  6. rsync /opt/move/     │
                              │  7. rsync /data/ (excl.) │
                              │  8. umount + cleanup     │
                              │  9. restart launcher     │
                              │ 10. write SUCCESS msg    │
                              └─────────────────────────┘

Network update check (separate path):
  move-update-check.sh  (run manually or via systemd timer)
  ├── reads /etc/move-swupdate/channel  (stable | beta)
  ├── GET https://hardware-updates.ableton.com/api/v1/update/move-{channel}/{version}
  ├── compare version, download .swu if newer
  └── exec /opt/move/Updater --input /tmp/move-update-XXXX.swu
          └──► triggers the control socket path above
```

---

## 3. Components

### 3.1 `move-swupdate-shim.py`

**Location:** `/usr/lib/move-bringup/move-swupdate-shim.py`  
**Replaces:** `swupdateprog-stub.py` (which is deleted)

Single `asyncio` daemon owning both sockets.

#### 3.1.1 Progress socket `/tmp/swupdateprog`

Identical behavior to current stub: bind, `chmod 0666`, accept connections, hold
open indefinitely.

New behaviour during updates: `ipc_wait_for_complete()` in `Updater` calls
`progress_ipc_connect()` internally, creating a **new** connection to the progress
socket after the `.swu` file is sent.  This new connection blocks on
`progress_ipc_receive()` waiting for a terminal status.  Our shim must write one
`progress_msg` to this connection (and to any other held clients) to unblock `Updater`.

`progress_msg` wire format (swupdate 2025.05, little-endian).
**Implementation note:** verify the magic value against the libswupdate 2025.05
source during implementation — the value below comes from the public swupdate source
tree and may differ in Ableton's build:

| offset | size | field        | success value          |
|--------|------|--------------|------------------------|
| 0      | 4    | magic        | `0x26011982`           |
| 4      | 4    | status       | `3` (SUCCESS) / `4` (FAILURE) |
| 8      | 4    | dwl_percent  | `100`                  |
| 12     | 8    | dwl_bytes    | total bytes received   |
| 20     | 4    | nsteps       | `1`                    |
| 24     | 4    | cur_step     | `1`                    |
| 28     | 4    | cur_percent  | `100`                  |
| 32     | 256  | cur_image    | `b"move-swupdate-shim\0"` |
| 288    | 64   | hnd_name     | `b"file\0"`            |
| 352    | 4    | source       | `0`                    |
| 356    | 4    | infolen      | `0`                    |
| 360    | 2048 | info         | `b"\0" * 2048`         |

Total: 2408 bytes.

#### 3.1.2 Control socket `/tmp/sockinstctrl`

`Updater` (via `ipc_inst_start()`) sends a 12-byte header then the raw `.swu` bytes:

```
struct ipc_header {
    uint32_t magic;    /* 0x14052001 */
    uint32_t command;  /* 0 = CMD_ACTIVATION */
    int32_t  iLen;     /* 0 for activation */
}
```

Server behaviour:
1. Accept connection
2. Read exactly 12 bytes; verify `magic == 0x14052001`; reject any other magic silently
3. If `command != 0` (CMD_ACTIVATION): read and discard `iLen` bytes if `iLen > 0`,
   then close — we only handle activation; no reply expected on the control socket
4. Stream all remaining bytes from the connection into a `tempfile.NamedTemporaryFile`
   until the client closes the write-end (EOF)
5. Call `process_swu(tmp_path)` — see §3.1.3
6. Write `progress_msg(SUCCESS or FAILURE)` to all progress clients
7. Close temp file

#### 3.1.3 `.swu` processing pipeline `process_swu(path)`

The pipeline handles two distinct `.swu` payload classes, both observed in the wild:

| Source | Encryption | Payload type | Destination |
|--------|-----------|-------------|-------------|
| Ableton firmware | AES-256-CBC | `raw`/`rawfile` (ext4 image) | `/opt/move/` + `/data/` rsynced from mounted ext4 |
| Third-party (e.g. Cycling '74 RNBO) | None | `archive` (tar.gz) | extracted to `path` field |

```
INPUT: path to .swu file

1. CPIO extract
   workdir = tempfile.mkdtemp(prefix="move-swu-")
   subprocess: cpio -id --quiet --warning=no-unknown-keyword < path  (cwd=workdir)
   Expect: sw-description, sw-description.sig, payload files

2. Signature verification (permissive)
   Attempt RSA-2048 verify of sw-description.sig against sw-description using
   /etc/move-swupdate/publickey.pem (Ableton's key).
   If verification FAILS: log warning "signature not verified with known key — 
   proceeding as root operator" and CONTINUE.  Do NOT abort.
   Third-party .swu files are expected to have a different signer.

3. Parse sw-description
   Read workdir/sw-description as libconfig text.
   Collect entries from both images[] and files[] arrays (swupdate uses both).
   For each entry:
     - filename, type, sha256, encrypted (default false), path (for archive),
       installed-directly (bool), properties{create-destination}

4. SHA-256 verify (all payloads)
   sha256(workdir/<filename>) must match sw-description sha256 field.
   Abort with FAILURE + log if mismatch.

5. Dispatch by type
   ┌─────────────────────────────────────────────────────────────────┐
   │ type == "raw" or "rawfile"  (Ableton firmware)                  │
   │                                                                 │
   │  a. AES-256-CBC decrypt (if encrypted=true)                     │
   │     Key/IV from /etc/move-swupdate/symmetrickey ("KEY IV\n")    │
   │     subprocess: openssl enc -d -aes-256-cbc -K $KEY -iv $IV    │
   │                 -nosalt -in <file>.enc -out <file>              │
   │                                                                 │
   │  b. Decompress if .gz suffix: gunzip → base.ext4               │
   │                                                                 │
   │  c. Mount ext4 read-only:                                       │
   │     mountpoint = tempfile.mkdtemp(prefix="move-swu-mnt-")       │
   │     mount -o ro,loop <base>.ext4 mountpoint                     │
   │                                                                 │
   │  d. rsync /opt/move/ (if present in image):                     │
   │     rsync -aHAX --delete                                        │
   │           --exclude='log/' --exclude='*.log'                    │
   │           mountpoint/opt/move/ /opt/move/                       │
   │     ldconfig                                                     │
   │                                                                 │
   │  e. rsync /data/ (if mountpoint/data/ is non-empty):            │
   │     rsync -aHAX                                                 │
   │           --exclude='UserData/'                                 │
   │           --exclude='log/' --exclude='Scratch/'                 │
   │           --exclude='**/.cache/' --exclude='**/Sentry/'         │
   │           --exclude='**/*.log' --exclude='**/lost+found/'       │
   │           mountpoint/data/ /var/lib/move-data/                  │
   │     Note: UserData/ excluded; CoreLibrary/ and settings/ updated│
   │                                                                 │
   │  f. umount mountpoint; rmdir mountpoint                        │
   └─────────────────────────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────────────┐
   │ type == "archive"  (third-party, e.g. RNBO)                     │
   │                                                                 │
   │  a. Remap destination path:                                     │
   │     entry.path.replace("/data/", "/var/lib/move-data/")         │
   │     (sw-description uses /data/ paths; we write to the          │
   │      bind-mount source)                                         │
   │                                                                 │
   │  b. create-destination:                                         │
   │     if properties.create-destination == "true":                 │
   │         os.makedirs(dest, exist_ok=True)                        │
   │                                                                 │
   │  c. Extract tarball:                                            │
   │     tar -xzf workdir/<filename> -C dest                        │
   │         --warning=no-unknown-keyword                             │
   │         (suppresses macOS xattr warnings from C74-built tars)   │
   │                                                                 │
   │  d. Fix ownership:                                              │
   │     chown -R ableton:users dest                                 │
   │     (tar may extract with source UID/GID, e.g. 501:staff from   │
   │      macOS builder — remap to ableton:users for Move access)    │
   └─────────────────────────────────────────────────────────────────┘

6. Run scripts (postinstall, etc.)
   For each entry in scripts[]:
     sha256-verify the script file (same as step 4)
     Make executable: chmod +x workdir/<script>
     Run as root (shim already runs as root):
       subprocess: bash workdir/<script>
     Scripts may call setcap, chown, create dirs — all work correctly
     since the shim runs as root.
     On script failure: log warning, continue to next script.

7. Cleanup
   shutil.rmtree(workdir, ignore_errors=True)

8. Restart launcher
   systemctl try-restart move-launcher.service move-web.service

RETURN: "success" or "failure" string
```

#### 3.1.4 Service unit `move-swupdate-shim.service`

Replaces `swupdateprog-stub.service` (which is removed from packaging).

```ini
[Unit]
Description=swupdate socket shim for Ableton Move
DefaultDependencies=no
After=local-fs.target
Before=move-launcher.service shutdown.target
Conflicts=shutdown.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/lib/move-bringup/move-swupdate-shim.py
Restart=always
RestartSec=1
User=root

[Install]
WantedBy=multi-user.target
```

---

### 3.2 `move-update-dbus.py`

**Location:** `/usr/lib/move-bringup/move-update-dbus.py`  
**Replaces:** `UpdateDBusService` (stock binary that crashes on Armbian due to missing
`/etc/fw_env.config` once libubootenv is called)

Owns `com.ableton.update` on the system bus.  Object path: `/com/ableton/Update`.

#### Methods

| Method | Signature | Armbian behaviour |
|--------|-----------|-------------------|
| `registerSuccessfulStartup()` | `-> void` | No-op. On stock AbletonOS this commits the current A/B partition as "booted successfully" via libubootenv. We have no A/B scheme. |
| `factoryReset(as)` | `as -> void` | The string array specifies reset categories (e.g. `["UserData", "Settings"]`). Wipe the corresponding subtrees of `/var/lib/move-data/` after stopping `move-launcher.service`. See §3.2.1. |

#### 3.2.1 `factoryReset` category mapping

| Category string | Action |
|-----------------|--------|
| `UserData`      | `rm -rf /var/lib/move-data/UserData` then recreate skeleton dirs |
| `Settings`      | `rm -rf /var/lib/move-data/settings` |
| `CoreLibrary`   | `rm -rf /var/lib/move-data/CoreLibrary` |
| (unknown)       | log warning, skip |

After wipe: `systemctl restart move-launcher.service`.

#### D-Bus service file (updated `com.ableton.update.service`)

```ini
[D-BUS Service]
Name=com.ableton.update
Exec=/usr/bin/python3 /usr/lib/move-bringup/move-update-dbus.py
User=root
SystemdService=move-update-dbus.service
```

#### Service unit `move-update-dbus.service`

```ini
[Unit]
Description=com.ableton.update D-Bus service for Armbian Move
After=dbus.service
Wants=dbus.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/lib/move-bringup/move-update-dbus.py
Restart=on-failure
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
```

---

### 3.3 `move-update-check.sh`

**Location:** `/usr/lib/move-bringup/move-update-check.sh`

Checks the Ableton CDN for a newer OS build and, if found, downloads and applies it.

```
CHANNEL   = cat /etc/move-swupdate/channel   (default: stable)
CUR_VER   = grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"'
            e.g. "abletonos-aarch64-rpi4-v3.18" → normalise to "3.18"
API_URL   = https://hardware-updates.ableton.com/api/v1/update/move-${CHANNEL}/${CUR_VER}

1. curl -sf $API_URL → JSON
2. Parse .version and .updatefiles[0].url with python3 -c / jq
3. If .version == CUR_VER or no update: exit 0 (already current)
4. Download URL to /tmp/move-update-${version}.swu  (curl -fL --progress-bar)
5. exec /opt/move/Updater --input /tmp/move-update-${version}.swu
   (Updater sends file to /tmp/sockinstctrl → our shim handles install)
6. On success: rm /tmp/move-update-*.swu
```

Invoked manually (`/usr/lib/move-bringup/move-update-check.sh`) or via a systemd
timer (optional, user-opt-in). Not enabled by default — auto-updates on an
embedded device with unknown network state is risky.

---

### 3.4 Key and channel configuration

All files in `/etc/move-swupdate/` — installed by `move-firmware.deb` (not in the
public repo).

| File | Content | Source |
|------|---------|--------|
| `symmetrickey` | `<64-hex-KEY> <32-hex-IV>\n` | Extracted from stock device |
| `publickey.pem` | RSA-2048 public key PEM | Extracted from stock device |
| `channel` | `stable` or `beta` (one line) | Default `stable` shipped by `move-bringup` |

The `channel` file is the only one shipped in `move-bringup.deb`; the key files are
packaged into `move-firmware.deb` by `extract-move-firmware.sh`.

---

### 3.5 `extract-move-firmware.sh` changes

Add two new extraction modes (peer to the existing SSH/rsync mode).

#### New flag: `--from-mount DIR`

Reads stock device files from a locally-mounted filesystem instead of SSH.
DIR is the root of the mounted stock partition
(e.g. `/run/media/user1/54828a59-bec1-434b-af47-131303d81d63`).

Extracts the same `/opt/move/` + vendored-libs content as the SSH path, plus
the swupdate key files (always included when `--from-mount` is used — no separate
`--keys` flag needed since an offline mount implies key extraction is the point).

```
./extract-move-firmware.sh --from-mount /run/media/user1/<uuid> [--output DIR]
```

#### New flag: `--keys` (SSH mode extension)

When using the default SSH mode, `--keys` additionally pulls
`/etc/swupdate/move-dev_symmetrickey` and `/etc/swupdate/move-dev_publickey.pem`
from the stock device and packages them into `move-firmware.deb` at
`/etc/move-swupdate/`.

```
./extract-move-firmware.sh --host root@move.local --keys
```

`--from-mount` always implies key extraction.  The existing `--firmware-only`,
`--data-only`, `--no-data` flags continue to work in both SSH and mount modes.

#### What gets packaged into `move-firmware.deb`

Existing content (unchanged):
- `/opt/move/*` + vendored libs + ld.so.conf

New (when keys extracted):
- `/etc/move-swupdate/symmetrickey`
- `/etc/move-swupdate/publickey.pem`

`move-firmware.deb` postinst: `chmod 0600 /etc/move-swupdate/symmetrickey` (key is
sensitive; readable only by root, same uid as the shim service).

---

## 4. Error handling

| Failure | Behaviour |
|---------|-----------|
| No key file at startup | Shim logs warning, still listens on sockets; update attempt will fail at decrypt step with FAILURE progress_msg |
| Bad IPC magic on control socket | Close connection silently, log debug |
| SHA-256 mismatch | FAILURE progress_msg + log; temp files cleaned up |
| AES decrypt failure | FAILURE progress_msg + log |
| ext4 mount failure | FAILURE progress_msg + log |
| rsync /opt/move/ failure | FAILURE progress_msg + leave old /opt/move/ intact |
| rsync /data/ failure | FAILURE progress_msg + leave old /var/lib/move-data/ intact |
| Updater disconnects mid-stream | Discard partial .swu, log warning, no install |
| move-launcher restart fails | Log; update data already installed — manual reboot will pick it up |

The shim never reboots the device. Move reboots are unnecessary since we rsync files
live rather than swapping root partitions.

---

## 5. Files changed

### New files (in `port/move-bringup/source/`)

| Path | Description |
|------|-------------|
| `usr/lib/move-bringup/move-swupdate-shim.py` | Main shim daemon |
| `lib/systemd/system/move-swupdate-shim.service` | Replaces swupdateprog-stub.service |
| `usr/lib/move-bringup/move-update-dbus.py` | com.ableton.update D-Bus service |
| `lib/systemd/system/move-update-dbus.service` | D-Bus service unit |
| `usr/lib/move-bringup/move-update-check.sh` | Network update check + download |
| `etc/move-swupdate/channel` | Default channel config (`stable`) |

### Deleted files

| Path | Reason |
|------|--------|
| `lib/move-bringup/swupdateprog-stub.py` | Replaced by move-swupdate-shim.py |
| `lib/systemd/system/swupdateprog-stub.service` | Replaced by move-swupdate-shim.service |

### Modified files

| Path | Change |
|------|--------|
| `usr/share/dbus-1/system-services/com.ableton.update.service` | Exec → move-update-dbus.py; SystemdService → move-update-dbus.service |
| `debian/control` | Add `python3-openssl` to Depends (for AES; or use subprocess openssl) |
| `debian/move-bringup.install` | Add new files, remove deleted files |
| `debian/move-bringup.postinst` | Enable move-swupdate-shim + move-update-dbus; disable swupdateprog-stub |
| `debian/changelog` | New version entry |
| `scripts/extract-move-firmware.sh` | --from-mount mode + --keys flag |

### Not committed to public repo

`/etc/move-swupdate/symmetrickey` and `publickey.pem` are packaged only inside the
user-built `move-firmware.deb` (personal, not-for-redistribution). The shim reads
them at runtime from `/etc/move-swupdate/`.

---

## 6. Testing plan

1. **Progress socket regression**: start shim, run `python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/tmp/swupdateprog'); import time; time.sleep(60)"` — should hold open without error. MoveLauncher should boot past the swupdate dependency.

2. **Control socket IPC**: write a minimal Python test client that sends the 12-byte header + a small dummy CPIO, verify shim writes FAILURE progress_msg (invalid CPIO) and doesn't crash.

3. **Full pipeline with real .swu**: download a `.swu` from the stable channel, feed via `Updater --input file.swu`, watch `journalctl -f -u move-swupdate-shim`, verify `/opt/move/` and `/var/lib/move-data/` are updated and `move-launcher.service` restarts cleanly.

4. **D-Bus service**: `busctl call com.ableton.update /com/ableton/Update com.ableton.update registerSuccessfulStartup` → should return immediately. `factoryReset as 1 UserData` → should stop launcher, wipe `/var/lib/move-data/UserData`, restart launcher.

5. **Key extraction**: `./extract-move-firmware.sh --from-mount /run/media/user1/<uuid>` → produces `move-firmware_*_arm64.deb` containing `/etc/move-swupdate/symmetrickey` and `publickey.pem`.

6. **Network check**: `move-update-check.sh` with a pinned old version string to force a "newer available" response; confirm `.swu` is downloaded and `Updater` is invoked.

7. **Third-party archive `.swu`** (RNBO): upload `rnbo-move-*.swu` via `http://move.local/testing/update`; confirm shim receives stream, extracts tarball to `/var/lib/move-data/UserData/`, fixes ownership, runs postinstall.sh (including `setcap`), and returns SUCCESS to the web UI.  This test validates the `archive` type path and permissive signature handling.
