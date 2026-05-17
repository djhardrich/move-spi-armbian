# swupdate shim — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the no-op swupdateprog stub with a full Python daemon that intercepts swupdate IPC from MoveLauncher/MoveWebService, decrypts and extracts `.swu` firmware payloads to `/opt/move/` and `/data/`, handles both Ableton AES-encrypted ext4 images and third-party archive-type payloads, and replaces the crashing `UpdateDBusService` binary with a safe Python D-Bus shim.

**Architecture:** Single asyncio daemon (`move-swupdate-shim.py`) owns both `/tmp/swupdateprog` (progress socket, existing stub behaviour + terminal status writes) and `/tmp/sockinstctrl` (control socket, receives `.swu` streams). A separate `move-update-dbus.py` owns `com.ableton.update` on the system bus with no-op `registerSuccessfulStartup` and safe `factoryReset` implementations. Key files (`symmetrickey`, `publickey.pem`) are read from `/etc/move-swupdate/` at runtime and are never committed to the public repo — they're packaged only into the user-built `move-firmware.deb` via an extended `extract-move-firmware.sh`.

**Tech Stack:** Python 3 asyncio, `dbus-next` (already a Depends), `subprocess` for cpio/openssl/mount/rsync/tar, `struct` for binary IPC wire format, bash for `extract-move-firmware.sh` and `move-update-check.sh`.

---

## File Structure

### New files (created in this plan)

| Path | Responsibility |
|------|---------------|
| `port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py` | Main asyncio daemon: progress socket + control socket + .swu processing pipeline |
| `port/move-bringup/source/lib/systemd/system/move-swupdate-shim.service` | Replaces swupdateprog-stub.service |
| `port/move-bringup/source/usr/lib/move-bringup/move-update-dbus.py` | com.ableton.update D-Bus shim (no-op registerSuccessfulStartup, safe factoryReset) |
| `port/move-bringup/source/lib/systemd/system/move-update-dbus.service` | systemd unit for D-Bus shim |
| `port/move-bringup/source/usr/lib/move-bringup/move-update-check.sh` | Network update check + download |
| `port/move-bringup/source/etc/move-swupdate/channel` | Default channel config (`stable`) |

### Files deleted

| Path | Reason |
|------|--------|
| `port/move-bringup/source/lib/move-bringup/swupdateprog-stub.py` | Replaced by move-swupdate-shim.py |
| `port/move-bringup/source/lib/systemd/system/swupdateprog-stub.service` | Replaced by move-swupdate-shim.service |

### Files modified

| Path | Change |
|------|--------|
| `port/move-bringup/source/usr/share/dbus-1/system-services/com.ableton.update.service` | Point to move-update-dbus.py |
| `port/move-bringup/debian/control` | Add `openssl` to Depends (for AES decrypt via subprocess) |
| `port/move-bringup/debian/move-bringup.install` | Add new files, remove deleted |
| `port/move-bringup/debian/move-bringup.postinst` | Enable new services, disable old stub |
| `port/move-bringup/debian/changelog` | New version entry (1.0.14) |
| `port/scripts/extract-move-firmware.sh` | Add `--from-mount DIR` and `--keys` modes |

---

### Task 1: Create `move-swupdate-shim.service` and delete the old stub service

**Files:**
- Create: `port/move-bringup/source/lib/systemd/system/move-swupdate-shim.service`
- Delete: `port/move-bringup/source/lib/systemd/system/swupdateprog-stub.service`

- [ ] **Step 1: Create the service unit**

Write `port/move-bringup/source/lib/systemd/system/move-swupdate-shim.service`:

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

- [ ] **Step 2: Delete the old stub service**

```bash
git rm port/move-bringup/source/lib/systemd/system/swupdateprog-stub.service
```

- [ ] **Step 3: Commit**

```bash
git add port/move-bringup/source/lib/systemd/system/move-swupdate-shim.service
git commit -m "move-bringup: add move-swupdate-shim.service, remove swupdateprog-stub.service"
```

---

### Task 2: Create `move-swupdate-shim.py` — sockets and progress format only

This task builds the daemon skeleton: both sockets are bound, progress clients are
tracked, and the `build_progress_msg()` helper is complete. Processing is stubbed to
return `"failure"` so the code is testable before the pipeline is wired.

**Files:**
- Delete: `port/move-bringup/source/lib/move-bringup/swupdateprog-stub.py`
- Create: `port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py`

- [ ] **Step 1: Delete the old stub script**

```bash
git rm port/move-bringup/source/lib/move-bringup/swupdateprog-stub.py
```

- [ ] **Step 2: Write the skeleton shim**

Write `port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py`:

```python
#!/usr/bin/env python3
"""
move-swupdate-shim — intercepts swupdate IPC from MoveLauncher/MoveWebService.

Owns two UNIX sockets:
  /tmp/swupdateprog  — progress socket (clients poll for update status)
  /tmp/sockinstctrl  — control socket  (clients stream .swu payloads)

On .swu receipt: decrypts, extracts, rsyncs /opt/move/ and /data/, then
writes a terminal progress_msg to unblock ipc_wait_for_complete().
"""

import asyncio
import logging
import os
import shutil
import struct
import subprocess
import sys
import tempfile

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [swupdate-shim] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

PROGRESS_SOCK = "/tmp/swupdateprog"
CONTROL_SOCK  = "/tmp/sockinstctrl"

IPC_MAGIC_CONTROL  = 0x14052001
IPC_MAGIC_PROGRESS = 0x26011982

# progress_msg layout (swupdate 2025.05, little-endian, 2408 bytes total)
# struct { uint32 magic; uint32 status; uint32 dwl_pct; uint64 dwl_bytes;
#          uint32 nsteps; uint32 cur_step; uint32 cur_pct;
#          char cur_image[256]; char hnd_name[64];
#          uint32 source; uint32 infolen; char info[2048]; }
_PROGRESS_FMT = "<IIIQIIII256s64sII2048s"
assert struct.calcsize(_PROGRESS_FMT) == 2408

STATUS_SUCCESS = 3
STATUS_FAILURE = 4

# Registered progress clients (ipc_wait_for_complete creates a new connection)
_progress_clients: list[asyncio.StreamWriter] = []


def build_progress_msg(status: int, dwl_bytes: int = 0) -> bytes:
    return struct.pack(
        _PROGRESS_FMT,
        IPC_MAGIC_PROGRESS,
        status,
        100 if status == STATUS_SUCCESS else 0,
        dwl_bytes,
        1, 1,
        100 if status == STATUS_SUCCESS else 0,
        0,                                  # padding between cur_pct and cur_image
        b"move-swupdate-shim\x00",
        b"file\x00",
        0, 0,
        b"\x00" * 2048,
    )


async def _notify_progress(status: int, dwl_bytes: int = 0) -> None:
    msg = build_progress_msg(status, dwl_bytes)
    dead = []
    for w in _progress_clients:
        try:
            w.write(msg)
            await w.drain()
        except Exception:
            dead.append(w)
    for w in dead:
        _progress_clients.remove(w)


# ── progress socket handler ───────────────────────────────────────────────

async def _handle_progress_client(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    """Hold the connection open; write progress_msg when updates happen."""
    log.debug("progress client connected")
    _progress_clients.append(writer)
    try:
        # Block until the client disconnects (EOF / error)
        await reader.read(-1)
    except Exception:
        pass
    finally:
        if writer in _progress_clients:
            _progress_clients.remove(writer)
        try:
            writer.close()
        except Exception:
            pass
    log.debug("progress client disconnected")


# ── control socket handler ────────────────────────────────────────────────

IPC_HDR_FMT = "<IIi"   # magic, command, iLen
IPC_HDR_LEN = struct.calcsize(IPC_HDR_FMT)  # 12
CMD_ACTIVATION = 0


async def _handle_control_client(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    """Receive .swu stream from Updater / MoveWebService."""
    try:
        hdr = await reader.readexactly(IPC_HDR_LEN)
    except asyncio.IncompleteReadError:
        return

    magic, command, ilen = struct.unpack(IPC_HDR_FMT, hdr)
    if magic != IPC_MAGIC_CONTROL:
        log.debug("control: bad magic %#x, ignoring", magic)
        writer.close()
        return

    if command != CMD_ACTIVATION:
        log.info("control: unsupported command %d, discarding", command)
        if ilen > 0:
            await reader.read(ilen)
        writer.close()
        return

    log.info("control: CMD_ACTIVATION received, streaming .swu ...")

    # Stream payload to a temp file until EOF
    with tempfile.NamedTemporaryFile(
        prefix="move-swu-", suffix=".swu", delete=False
    ) as tmp:
        tmp_path = tmp.name
        total = 0
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            tmp.write(chunk)
            total += len(chunk)

    log.info("control: received %d bytes → %s", total, tmp_path)
    writer.close()

    result = await asyncio.get_event_loop().run_in_executor(
        None, process_swu, tmp_path
    )
    status = STATUS_SUCCESS if result == "success" else STATUS_FAILURE
    await _notify_progress(status, total)

    try:
        os.unlink(tmp_path)
    except OSError:
        pass


def process_swu(path: str) -> str:
    """Process a .swu file. Returns 'success' or 'failure'."""
    # Stub — pipeline implemented in Task 3
    log.warning("process_swu: STUB — returning failure (not yet implemented)")
    return "failure"


# ── socket helpers ────────────────────────────────────────────────────────

def _remove_socket(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


async def main() -> None:
    _remove_socket(PROGRESS_SOCK)
    _remove_socket(CONTROL_SOCK)

    prog_server = await asyncio.start_unix_server(
        _handle_progress_client, path=PROGRESS_SOCK
    )
    os.chmod(PROGRESS_SOCK, 0o666)

    ctrl_server = await asyncio.start_unix_server(
        _handle_control_client, path=CONTROL_SOCK
    )
    os.chmod(CONTROL_SOCK, 0o666)

    log.info("listening on %s and %s", PROGRESS_SOCK, CONTROL_SOCK)
    async with prog_server, ctrl_server:
        await asyncio.gather(
            prog_server.serve_forever(),
            ctrl_server.serve_forever(),
        )


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 3: Verify the struct packing**

The `_PROGRESS_FMT` assert fires at import time. Run it:

```bash
python3 -c "
import struct
_PROGRESS_FMT = '<IIIQIIII256s64sII2048s'
print('size =', struct.calcsize(_PROGRESS_FMT))
assert struct.calcsize(_PROGRESS_FMT) == 2408, 'BAD SIZE'
print('OK')
"
```

Expected output:
```
size = 2408
OK
```

If the assert fires, recount the format fields against the spec table in the design doc §3.1.1 and fix.

- [ ] **Step 4: Commit**

```bash
git add port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py
git commit -m "move-bringup: add move-swupdate-shim.py skeleton (sockets + progress wire format)"
```

---

### Task 3: Implement `process_swu()` — CPIO extract, sha256 verify, type dispatch

Replaces the stub `process_swu()` with the real pipeline. This task covers steps 1–4
(CPIO, signature, sw-description parse, sha256). The type handlers (raw ext4 and
archive) are added in Task 4.

**Files:**
- Modify: `port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py`

- [ ] **Step 1: Add imports at the top of the file**

Add these imports after `import tempfile` in the imports block:

```python
import hashlib
import re
```

- [ ] **Step 2: Replace the stub `process_swu()` with the full implementation**

Replace the entire `def process_swu(path: str) -> str:` function and its docstring with:

```python
KEY_FILE = "/etc/move-swupdate/symmetrickey"
PUBKEY_FILE = "/etc/move-swupdate/publickey.pem"


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _parse_sw_description(text: str) -> dict:
    """
    Minimal libconfig parser for sw-description.
    Returns {'version': str, 'files': [...], 'scripts': [...]}.
    Each file dict has: filename, type, sha256, encrypted, path, create_destination.
    Each script dict has: filename, sha256.
    """
    result = {"version": "", "files": [], "scripts": []}

    ver_m = re.search(r'version\s*=\s*"([^"]+)"', text)
    if ver_m:
        result["version"] = ver_m.group(1)

    def parse_block(block_text: str) -> dict:
        """Extract key=value pairs from one libconfig object block."""
        entry = {
            "filename": "", "type": "", "sha256": "",
            "encrypted": False, "path": "", "create_destination": False,
        }
        for k, v in re.findall(r'(\w[\w-]*)\s*=\s*"([^"]*)"', block_text):
            key = k.replace("-", "_")
            if key == "filename":
                entry["filename"] = v
            elif key == "type":
                entry["type"] = v
            elif key == "sha256":
                entry["sha256"] = v
            elif key == "path":
                entry["path"] = v
        # Boolean fields
        if re.search(r'encrypted\s*=\s*true', block_text):
            entry["encrypted"] = True
        if re.search(r'create-destination\s*=\s*"true"', block_text):
            entry["create_destination"] = True
        return entry

    # Extract files() and images() arrays (same structure for our purposes)
    for arr_name in ("files", "images"):
        arr_m = re.search(
            rf'{arr_name}\s*=\s*\((.+?)\);',
            text, re.DOTALL
        )
        if not arr_m:
            continue
        arr_text = arr_m.group(1)
        # Split on top-level `{...}` blocks
        depth = 0
        start = None
        for i, ch in enumerate(arr_text):
            if ch == "{":
                if depth == 0:
                    start = i + 1
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0 and start is not None:
                    block = arr_text[start:i]
                    result["files"].append(parse_block(block))

    # Extract scripts() array (only filename + sha256 matter)
    scripts_m = re.search(r'scripts\s*=\s*\((.+?)\);', text, re.DOTALL)
    if scripts_m:
        depth = 0
        start = None
        arr_text = scripts_m.group(1)
        for i, ch in enumerate(arr_text):
            if ch == "{":
                if depth == 0:
                    start = i + 1
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0 and start is not None:
                    block = arr_text[start:i]
                    s: dict = {"filename": "", "sha256": ""}
                    fn_m = re.search(r'filename\s*=\s*"([^"]+)"', block)
                    sh_m = re.search(r'sha256\s*=\s*"([^"]+)"', block)
                    if fn_m:
                        s["filename"] = fn_m.group(1)
                    if sh_m:
                        s["sha256"] = sh_m.group(1)
                    result["scripts"].append(s)

    return result


def _verify_rsa_signature(sw_desc_path: str, sig_path: str, pubkey_path: str) -> bool:
    """Verify sw-description RSA signature. Returns True on success."""
    try:
        r = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", pubkey_path,
             "-signature", sig_path, sw_desc_path],
            capture_output=True, text=True
        )
        return r.returncode == 0
    except Exception as e:
        log.debug("RSA verify exception: %s", e)
        return False


def _handle_raw_payload(entry: dict, workdir: str) -> str:
    """Decrypt (if needed), mount ext4, rsync /opt/move/ and /data/."""
    filename = entry["filename"]
    src = os.path.join(workdir, filename)

    # AES decrypt
    if entry["encrypted"]:
        if not os.path.exists(KEY_FILE):
            log.error("AES key file not found: %s", KEY_FILE)
            return "failure"
        key_text = open(KEY_FILE).read().strip().split()
        if len(key_text) < 2:
            log.error("Bad key file format in %s", KEY_FILE)
            return "failure"
        key_hex, iv_hex = key_text[0], key_text[1]
        dec = src + ".dec"
        r = subprocess.run(
            ["openssl", "enc", "-d", "-aes-256-cbc",
             "-K", key_hex, "-iv", iv_hex, "-nosalt",
             "-in", src, "-out", dec],
            capture_output=True
        )
        if r.returncode != 0:
            log.error("AES decrypt failed: %s", r.stderr.decode())
            return "failure"
        src = dec

    # Decompress if .gz
    if src.endswith(".gz"):
        base = src[:-3]
        r = subprocess.run(["gunzip", "-f", src], capture_output=True)
        if r.returncode != 0:
            log.error("gunzip failed: %s", r.stderr.decode())
            return "failure"
        src = base

    # Mount ext4 read-only
    mntdir = tempfile.mkdtemp(prefix="move-swu-mnt-")
    try:
        r = subprocess.run(
            ["mount", "-o", "ro,loop", src, mntdir],
            capture_output=True
        )
        if r.returncode != 0:
            log.error("mount failed: %s", r.stderr.decode())
            return "failure"
        try:
            result = _rsync_from_mount(mntdir)
        finally:
            subprocess.run(["umount", mntdir], capture_output=True)
    finally:
        try:
            os.rmdir(mntdir)
        except OSError:
            pass

    return result


def _rsync_from_mount(mntdir: str) -> str:
    """rsync /opt/move/ and /data/ from a mounted ext4 image."""
    result = "success"

    opt_src = os.path.join(mntdir, "opt", "move") + "/"
    if os.path.isdir(opt_src):
        log.info("rsyncing /opt/move/ ...")
        r = subprocess.run([
            "rsync", "-aHAX", "--delete",
            "--exclude=log/", "--exclude=*.log",
            opt_src, "/opt/move/",
        ], capture_output=True)
        if r.returncode != 0:
            log.error("rsync /opt/move/ failed: %s", r.stderr.decode())
            result = "failure"
        else:
            subprocess.run(["ldconfig"], capture_output=True)
            log.info("rsync /opt/move/ done")

    data_src = os.path.join(mntdir, "data") + "/"
    if os.path.isdir(data_src) and os.listdir(data_src):
        log.info("rsyncing /data/ → /var/lib/move-data/ ...")
        r = subprocess.run([
            "rsync", "-aHAX",
            "--exclude=UserData/",
            "--exclude=log/", "--exclude=Scratch/",
            "--exclude=**/.cache/", "--exclude=**/Sentry/",
            "--exclude=**/*.log", "--exclude=**/lost+found/",
            data_src, "/var/lib/move-data/",
        ], capture_output=True)
        if r.returncode != 0:
            log.error("rsync /data/ failed: %s", r.stderr.decode())
            result = "failure"
        else:
            log.info("rsync /data/ done")

    return result


def _handle_archive_payload(entry: dict, workdir: str) -> str:
    """Extract tar.gz to remapped destination, fix ownership."""
    filename = entry["filename"]
    src = os.path.join(workdir, filename)
    dest = entry["path"].replace("/data/", "/var/lib/move-data/")
    if not dest:
        dest = "/var/lib/move-data/"

    if entry["create_destination"]:
        os.makedirs(dest, exist_ok=True)

    log.info("extracting %s → %s", filename, dest)
    r = subprocess.run(
        ["tar", "-xzf", src, "-C", dest,
         "--warning=no-unknown-keyword"],
        capture_output=True
    )
    if r.returncode != 0:
        log.error("tar extract failed: %s", r.stderr.decode())
        return "failure"

    # Fix ownership: tar extracts with source UID/GID (e.g. 501:staff from macOS)
    subprocess.run(["chown", "-R", "ableton:users", dest], capture_output=True)
    log.info("archive extract done")
    return "success"


def process_swu(path: str) -> str:
    """Process a .swu file. Returns 'success' or 'failure'."""
    workdir = tempfile.mkdtemp(prefix="move-swu-")
    try:
        return _process_swu_inner(path, workdir)
    except Exception as e:
        log.exception("process_swu unhandled exception: %s", e)
        return "failure"
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _process_swu_inner(path: str, workdir: str) -> str:
    # 1. CPIO extract
    log.info("extracting CPIO from %s", path)
    with open(path, "rb") as f:
        r = subprocess.run(
            ["cpio", "-id", "--quiet", "--warning=no-unknown-keyword"],
            stdin=f, capture_output=True, cwd=workdir
        )
    if r.returncode != 0:
        log.error("cpio extract failed: %s", r.stderr.decode())
        return "failure"

    sw_desc_path = os.path.join(workdir, "sw-description")
    if not os.path.exists(sw_desc_path):
        log.error("sw-description not found in .swu")
        return "failure"

    # 2. Signature verification (permissive — third-party .swu won't match)
    sig_path = os.path.join(workdir, "sw-description.sig")
    if os.path.exists(sig_path) and os.path.exists(PUBKEY_FILE):
        ok = _verify_rsa_signature(sw_desc_path, sig_path, PUBKEY_FILE)
        if ok:
            log.info("sw-description signature verified with known key")
        else:
            log.warning(
                "signature not verified with known key — "
                "proceeding as root operator"
            )
    else:
        log.info("signature check skipped (sig or pubkey absent)")

    # 3. Parse sw-description
    sw_desc_text = open(sw_desc_path).read()
    desc = _parse_sw_description(sw_desc_text)
    log.info("sw-description version=%s, %d file(s), %d script(s)",
             desc["version"], len(desc["files"]), len(desc["scripts"]))

    # 4. SHA-256 verify all payloads
    for entry in desc["files"] + desc["scripts"]:
        if not entry["sha256"]:
            continue
        fpath = os.path.join(workdir, entry["filename"])
        if not os.path.exists(fpath):
            log.error("payload file missing: %s", entry["filename"])
            return "failure"
        actual = _sha256_file(fpath)
        if actual != entry["sha256"]:
            log.error(
                "SHA-256 mismatch for %s: expected %s got %s",
                entry["filename"], entry["sha256"], actual
            )
            return "failure"
        log.debug("sha256 OK: %s", entry["filename"])

    # 5. Dispatch by type
    result = "success"
    for entry in desc["files"]:
        ptype = entry["type"]
        if ptype in ("raw", "rawfile"):
            r2 = _handle_raw_payload(entry, workdir)
        elif ptype == "archive":
            r2 = _handle_archive_payload(entry, workdir)
        else:
            log.warning("unknown payload type %r — skipping", ptype)
            continue
        if r2 != "success":
            result = r2

    # 6. Run scripts
    for s in desc["scripts"]:
        sname = s["filename"]
        spath = os.path.join(workdir, sname)
        if not os.path.exists(spath):
            log.warning("script not found: %s", sname)
            continue
        os.chmod(spath, 0o755)
        log.info("running script: %s", sname)
        r3 = subprocess.run(["bash", spath], capture_output=True)
        if r3.returncode != 0:
            log.warning("script %s exited %d: %s",
                        sname, r3.returncode, r3.stderr.decode())
        else:
            log.info("script %s: OK", sname)

    # 7. Restart launcher
    if result == "success":
        log.info("restarting move-launcher + move-web ...")
        subprocess.run(
            ["systemctl", "try-restart",
             "move-launcher.service", "move-web.service"],
            capture_output=True
        )

    log.info("process_swu result: %s", result)
    return result
```

- [ ] **Step 3: Commit**

```bash
git add port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py
git commit -m "move-bringup: implement process_swu() pipeline in move-swupdate-shim.py"
```

---

### Task 4: Quick syntax check of `move-swupdate-shim.py`

- [ ] **Step 1: Syntax-check the file on the build host**

```bash
python3 -m py_compile \
  port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py \
  && echo "syntax OK"
```

Expected: `syntax OK`. Fix any syntax errors before continuing.

- [ ] **Step 2: Test struct size assertion**

```bash
python3 -c "
import sys
sys.path.insert(0, 'port/move-bringup/source/usr/lib/move-bringup')
import move_swupdate_shim  # triggers assert at import
print('assert OK')
" 2>&1 | grep -E 'assert|OK|Error'
```

Since the file uses `if __name__ == '__main__'`, importing it won't run `main()`. Expected output includes `assert OK` or no assertion error. If the file can't be imported as a module (name has hyphens), test it differently:

```bash
python3 - <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "shim",
    "port/move-bringup/source/usr/lib/move-bringup/move-swupdate-shim.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("import OK, msg size =", len(mod.build_progress_msg(3, 0)))
EOF
```

Expected: `import OK, msg size = 2408`

---

### Task 5: Create `move-update-dbus.service` and `move-update-dbus.py`

**Files:**
- Create: `port/move-bringup/source/lib/systemd/system/move-update-dbus.service`
- Create: `port/move-bringup/source/usr/lib/move-bringup/move-update-dbus.py`

- [ ] **Step 1: Write the service unit**

Write `port/move-bringup/source/lib/systemd/system/move-update-dbus.service`:

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

- [ ] **Step 2: Write the D-Bus shim**

Write `port/move-bringup/source/usr/lib/move-bringup/move-update-dbus.py`:

```python
#!/usr/bin/env python3
"""
move-update-dbus — com.ableton.update D-Bus service for Armbian Move.

Replaces UpdateDBusService (stock binary) which crashes on Armbian because
it calls libubootenv to read/write U-Boot environment variables that don't
exist on our SD-based Armbian system.

Implements two methods on com.ableton.update / /com/ableton/Update:
  registerSuccessfulStartup() — no-op (stock: commits A/B boot slot)
  factoryReset(as)           — wipes /var/lib/move-data/ subtrees by category
"""

import asyncio
import logging
import os
import shutil
import subprocess
import sys

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method
from dbus_next import BusType

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [update-dbus] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)

DATA_ROOT = "/var/lib/move-data"

CATEGORY_MAP = {
    "UserData":    "UserData",
    "Settings":    "settings",
    "CoreLibrary": "CoreLibrary",
}

USERDATA_SKELETON = [
    "UserData",
]


class UpdateService(ServiceInterface):
    def __init__(self):
        super().__init__("com.ableton.update")

    @method()
    def registerSuccessfulStartup(self):
        """No-op: stock implementation commits A/B boot slot via libubootenv."""
        log.info("registerSuccessfulStartup() — no-op on Armbian")

    @method()
    def factoryReset(self, categories: "as"):
        log.info("factoryReset(%s)", categories)
        # Stop launcher before wiping
        subprocess.run(
            ["systemctl", "stop", "move-launcher.service", "move-web.service"],
            capture_output=True
        )
        for cat in categories:
            if cat not in CATEGORY_MAP:
                log.warning("factoryReset: unknown category %r — skipping", cat)
                continue
            target = os.path.join(DATA_ROOT, CATEGORY_MAP[cat])
            if os.path.exists(target):
                log.info("wiping %s", target)
                shutil.rmtree(target, ignore_errors=True)
            # Recreate skeleton for UserData
            if cat == "UserData":
                os.makedirs(target, exist_ok=True)
                try:
                    import pwd, grp
                    uid = pwd.getpwnam("ableton").pw_uid
                    gid = grp.getgrnam("users").gr_gid
                    os.chown(target, uid, gid)
                    os.chmod(target, 0o2775)
                except Exception as e:
                    log.warning("could not chown UserData: %s", e)

        # Restart launcher
        subprocess.run(
            ["systemctl", "start", "move-launcher.service"],
            capture_output=True
        )
        log.info("factoryReset done")


async def main():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    service = UpdateService()
    bus.export("/com/ableton/Update", service)
    await bus.request_name("com.ableton.update")
    log.info("com.ableton.update ready at /com/ableton/Update")
    await bus.wait_for_disconnect()


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 3: Syntax-check**

```bash
python3 -m py_compile \
  port/move-bringup/source/usr/lib/move-bringup/move-update-dbus.py \
  && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 4: Update `com.ableton.update.service` D-Bus activation file**

Read the current file first:

```bash
cat port/move-bringup/source/usr/share/dbus-1/system-services/com.ableton.update.service
```

Replace the entire file content with:

```ini
[D-BUS Service]
Name=com.ableton.update
Exec=/usr/bin/python3 /usr/lib/move-bringup/move-update-dbus.py
User=root
SystemdService=move-update-dbus.service
```

- [ ] **Step 5: Commit**

```bash
git add \
  port/move-bringup/source/lib/systemd/system/move-update-dbus.service \
  port/move-bringup/source/usr/lib/move-bringup/move-update-dbus.py \
  port/move-bringup/source/usr/share/dbus-1/system-services/com.ableton.update.service
git commit -m "move-bringup: add move-update-dbus.py replacing UpdateDBusService"
```

---

### Task 6: Create `move-update-check.sh` and `etc/move-swupdate/channel`

**Files:**
- Create: `port/move-bringup/source/usr/lib/move-bringup/move-update-check.sh`
- Create: `port/move-bringup/source/etc/move-swupdate/channel`

- [ ] **Step 1: Write the channel config file**

Write `port/move-bringup/source/etc/move-swupdate/channel`:

```
stable
```

(Exactly one line, no trailing blank lines beyond the newline.)

- [ ] **Step 2: Write the update check script**

Write `port/move-bringup/source/usr/lib/move-bringup/move-update-check.sh`:

```bash
#!/bin/bash
# move-update-check.sh — check Ableton CDN for newer Move OS firmware.
#
# Usage: move-update-check.sh [--channel stable|beta] [--dry-run]
#
# Reads /etc/move-swupdate/channel for the default channel.
# Downloads and installs via /opt/move/Updater if a newer version is available.

set -euo pipefail

CHANNEL_FILE="/etc/move-swupdate/channel"
UPDATER="/opt/move/Updater"
CDN_BASE="https://hardware-updates.ableton.com/api/v1/update"
DRY_RUN=0

# ── arg parsing ─────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() { printf '[move-update-check] %s\n' "$*" >&2; }

# ── read channel ─────────────────────────────────────────────────────────────
if [ -z "${CHANNEL:-}" ]; then
    if [ -f "$CHANNEL_FILE" ]; then
        CHANNEL=$(cat "$CHANNEL_FILE" | tr -d '[:space:]')
    else
        CHANNEL="stable"
    fi
fi
log "channel: $CHANNEL"

# ── read current version ──────────────────────────────────────────────────────
CUR_VER=""
if [ -f /etc/os-release ]; then
    raw=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)
    # Normalise "abletonos-aarch64-rpi4-v3.18" → "3.18"
    CUR_VER=$(echo "$raw" | sed -nE 's/.*-v([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')
fi
if [ -z "$CUR_VER" ]; then
    log "WARNING: could not determine current version from /etc/os-release"
    CUR_VER="0.0"
fi
log "current version: $CUR_VER"

# ── query CDN ────────────────────────────────────────────────────────────────
API_URL="${CDN_BASE}/move-${CHANNEL}/${CUR_VER}"
log "querying $API_URL"
JSON=$(curl -sf --max-time 15 "$API_URL" || true)
if [ -z "$JSON" ]; then
    log "no response from CDN (offline or up-to-date)"
    exit 0
fi

NEW_VER=$(echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version',''))" 2>/dev/null || true)
if [ -z "$NEW_VER" ] || [ "$NEW_VER" = "$CUR_VER" ]; then
    log "already at latest ($CUR_VER)"
    exit 0
fi
log "update available: $CUR_VER → $NEW_VER"

DL_URL=$(echo "$JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
files = d.get('updatefiles', [])
print(files[0]['url'] if files else '')
" 2>/dev/null || true)
if [ -z "$DL_URL" ]; then
    log "ERROR: no download URL in CDN response"
    exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN — would download $DL_URL"
    exit 0
fi

# ── download ─────────────────────────────────────────────────────────────────
TMP_SWU=$(mktemp /tmp/move-update-XXXXXX.swu)
trap 'rm -f "$TMP_SWU"' EXIT

log "downloading $DL_URL → $TMP_SWU"
curl -fL --progress-bar -o "$TMP_SWU" "$DL_URL"
log "download complete ($(du -h "$TMP_SWU" | cut -f1))"

# ── install via Updater ───────────────────────────────────────────────────────
if [ ! -x "$UPDATER" ]; then
    log "ERROR: $UPDATER not found or not executable"
    exit 1
fi
log "invoking $UPDATER --input $TMP_SWU"
"$UPDATER" --input "$TMP_SWU"
log "update installed successfully"
```

- [ ] **Step 3: Make the script executable in git**

```bash
chmod +x port/move-bringup/source/usr/lib/move-bringup/move-update-check.sh
```

- [ ] **Step 4: Commit**

```bash
git add \
  port/move-bringup/source/usr/lib/move-bringup/move-update-check.sh \
  port/move-bringup/source/etc/move-swupdate/channel
git commit -m "move-bringup: add move-update-check.sh and etc/move-swupdate/channel"
```

---

### Task 7: Update debian packaging metadata

**Files:**
- Modify: `port/move-bringup/debian/control`
- Modify: `port/move-bringup/debian/move-bringup.install`
- Modify: `port/move-bringup/debian/move-bringup.postinst`
- Modify: `port/move-bringup/debian/changelog`

- [ ] **Step 1: Update `debian/control` — add `openssl` to Depends**

In `port/move-bringup/debian/control`, in the `Package: move-bringup` Depends field,
add `openssl` after `python3-dbus-next,`. The AES decrypt step calls `openssl enc`
via subprocess; `openssl` is the package that ships the command-line tool.

Find the Depends block and add `openssl,` on a new indented line after `python3-dbus-next,`.

The Depends section should contain:

```
Depends: ${misc:Depends}, ${shlibs:Depends},
         ablspi-dkms,
         adduser,
         avahi-daemon,
         dbus,
         device-tree-compiler,
         libnss-mdns,
         openssl,
         python3,
         python3-dbus-next,
         systemd-sysv,
         udev
```

- [ ] **Step 2: Update `debian/move-bringup.install` — swap stub for shim**

Replace the two stub lines:

```
source/lib/systemd/system/swupdateprog-stub.service   lib/systemd/system
source/lib/move-bringup/swupdateprog-stub.py          usr/lib/move-bringup
```

With the new lines (and add the other new files):

```
source/lib/systemd/system/move-swupdate-shim.service  lib/systemd/system
source/usr/lib/move-bringup/move-swupdate-shim.py     usr/lib/move-bringup
source/lib/systemd/system/move-update-dbus.service    lib/systemd/system
source/usr/lib/move-bringup/move-update-dbus.py       usr/lib/move-bringup
source/usr/lib/move-bringup/move-update-check.sh      usr/lib/move-bringup
source/etc/move-swupdate/channel                      etc/move-swupdate
```

- [ ] **Step 3: Update `debian/move-bringup.postinst` — replace stub with shim**

Find the block that enables `swupdateprog-stub.service`:

```sh
        if [ -d /run/systemd/system ]; then
            systemctl enable swupdateprog-stub.service >/dev/null 2>&1 || true
            systemctl start swupdateprog-stub.service >/dev/null 2>&1 || true
        fi
```

Replace it with:

```sh
        if [ -d /run/systemd/system ]; then
            # Disable the old stub if it's still around from a prior install
            systemctl disable --now swupdateprog-stub.service >/dev/null 2>&1 || true
            systemctl enable --now move-swupdate-shim.service >/dev/null 2>&1 || true
            systemctl enable --now move-update-dbus.service >/dev/null 2>&1 || true
        fi
```

Also add the two new services to the existing `for u in ...` loop that enables the core
services (so they're re-enabled on upgrade without the start):

In the loop:
```sh
            for u in move-usb-gadget.service \
                     move-xmos-init.service \
                     move-launcher.service \
                     move-web.service \
                     move-xmos-shutdown.service \
                     move-connman-shim.service; do
```

Add `move-swupdate-shim.service \` and `move-update-dbus.service \` to the list.

- [ ] **Step 4: Add changelog entry**

Prepend to `port/move-bringup/debian/changelog`:

```
move-bringup (1.0.14-1) unstable; urgency=medium

  * Replace swupdateprog-stub with move-swupdate-shim: full asyncio daemon
    that intercepts /tmp/sockinstctrl and /tmp/swupdateprog, processes .swu
    payloads (Ableton AES-encrypted ext4 and third-party archive types),
    rsyncs /opt/move/ and /data/, and writes terminal progress_msg to
    unblock ipc_wait_for_complete(). Fixes RNBO web-upload "Network Error".
  * Add move-update-dbus.py: Python D-Bus shim for com.ableton.update,
    replacing UpdateDBusService which crashes on Armbian (no libubootenv
    /etc/fw_env.config). Implements registerSuccessfulStartup() as no-op
    and factoryReset(as) with safe /var/lib/move-data/ subtree wipe.
  * Add move-update-check.sh: checks Ableton CDN (stable/beta channel)
    for newer firmware; downloads and installs via /opt/move/Updater.
  * Add etc/move-swupdate/channel: default channel config (stable).
  * Add openssl to Depends (for AES-256-CBC decrypt of firmware payloads).

 -- Move Port <move-port@localhost>  Sat, 16 May 2026 00:00:00 +0000
```

- [ ] **Step 5: Commit packaging changes**

```bash
git add \
  port/move-bringup/debian/control \
  port/move-bringup/debian/move-bringup.install \
  port/move-bringup/debian/move-bringup.postinst \
  port/move-bringup/debian/changelog
git commit -m "move-bringup 1.0.14: packaging for swupdate shim + update D-Bus shim"
```

---

### Task 8: Extend `extract-move-firmware.sh` with `--from-mount` and `--keys`

**Files:**
- Modify: `port/scripts/extract-move-firmware.sh`

- [ ] **Step 1: Add new variables and flags to the arg parsing block**

After the `SSH_OPTS` variable declaration (line ~57), add:

```bash
FROM_MOUNT=""       # path to mounted stock rootfs (--from-mount DIR)
PULL_KEYS=0         # extract swupdate key files (--keys, always on with --from-mount)
```

In the `while [ $# -gt 0 ]` arg parsing block, add two new cases before the `-h|--help` case:

```bash
        --from-mount)      FROM_MOUNT="$2"; PULL_KEYS=1; shift 2 ;;
        --keys)            PULL_KEYS=1; shift ;;
```

- [ ] **Step 2: Update the USAGE comment block**

Update the `# USAGE` section (lines 25-46) to include the new flags:

```bash
# USAGE
# ─────
#   ./extract-move-firmware.sh [--host root@move.local] [--output DIR]
#                              [--version VER] [--keep-tmp]
#                              [--no-data | --data-only] [--firmware-only]
#                              [--from-mount DIR] [--keys]
#
# Modes:
#   (default)           SSH to a live Move device and rsync firmware + data
#   --from-mount DIR    Read from a locally-mounted stock rootfs partition
#                       (e.g. /run/media/user1/<uuid>). Always extracts keys.
#                       DIR must be the root of the mounted stock partition.
#
# By default produces TWO debs in <output-dir>:
#   - move-firmware_<version>_arm64.deb     : /opt/move/* + vendored libs
#   - move-user-data_<date>_arm64.deb       : the full /data tree
#
# Flags:
#   --firmware-only   skip the /data pull
#   --no-data         alias for --firmware-only
#   --data-only       only pull /data; skip /opt/move
#   --keys            (SSH mode) also extract swupdate key files
#   --output DIR      write debs to DIR instead of cwd
```

- [ ] **Step 3: Replace the SSH-only verification and rsync sections with mode-aware versions**

The script currently hard-checks SSH at step 1 and rsyncs at steps 4 and 12. We need to:
- Skip the SSH checks when `--from-mount` is given
- Branch the rsync calls to use local `cp`/`rsync` from `$FROM_MOUNT` instead

**After** the arg-parsing block and `log`/`fatal` definitions, add this guard block
(before step 1 "Verify the host"):

```bash
# ── from-mount mode: validate the mount path ────────────────────────────────
if [ -n "$FROM_MOUNT" ]; then
    [ -d "$FROM_MOUNT" ] || fatal "--from-mount path does not exist: $FROM_MOUNT"
    [ -f "$FROM_MOUNT/etc/os-release" ] || \
        fatal "$FROM_MOUNT does not look like a rootfs (no /etc/os-release)"
    [ -d "$FROM_MOUNT/opt/move" ] || \
        fatal "$FROM_MOUNT/opt/move not found; wrong partition?"
    log "using --from-mount: $FROM_MOUNT"
fi
```

**Wrap the SSH verification block** (steps 1–2) in a conditional:

```bash
# ── 1. Verify the host is actually a Move (SSH mode only) ───────────────────
if [ -z "$FROM_MOUNT" ]; then
    log "checking $HOST"
    if ! ssh "${SSH_OPTS[@]}" "$HOST" 'true' 2>/dev/null; then
        fatal "cannot ssh to $HOST"
    fi

    remote_os=$(ssh "${SSH_OPTS[@]}" "$HOST" 'cat /etc/os-release 2>/dev/null | grep -E "^ID=" || true')
    if ! echo "$remote_os" | grep -q 'ableton'; then
        log "WARNING: $HOST does not look like an AbletonOS device"
        log "         /etc/os-release ID is: $remote_os"
        log "         continuing anyway in 3s; ctrl-C to abort..."
        sleep 3
    fi

    remote_arch=$(ssh "${SSH_OPTS[@]}" "$HOST" 'uname -m')
    if [ "$remote_arch" != "aarch64" ]; then
        fatal "$HOST architecture is $remote_arch, expected aarch64"
    fi

    if ! ssh "${SSH_OPTS[@]}" "$HOST" '[ -x /opt/move/MoveLauncher ]'; then
        fatal "$HOST does not have /opt/move/MoveLauncher; not a Move?"
    fi
fi
```

**Replace step 2 "Resolve version"** with a mode-aware version:

```bash
# ── 2. Resolve version ──────────────────────────────────────────────────────
if [ -z "$VERSION" ]; then
    if [ -n "$FROM_MOUNT" ]; then
        raw_ver=$(grep -E '^VERSION_ID=' "$FROM_MOUNT/etc/os-release" \
            | cut -d= -f2 | tr -d '"' || true)
    else
        raw_ver=$(ssh "${SSH_OPTS[@]}" "$HOST" \
            'grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d "\""')
    fi
    if [ -z "$raw_ver" ]; then
        VERSION="0.0.0-$(date +%Y%m%d)"
        log "could not read VERSION_ID; defaulting to $VERSION"
    else
        VERSION=$(echo "$raw_ver" \
            | sed -nE 's/.*-v([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')
        [ -z "$VERSION" ] && VERSION="$(date +%Y%m%d)"
    fi
fi
log "package version: $VERSION"
```

**Replace step 4 "Pull /opt/move"** with a mode-aware block:

```bash
# ── 4. Pull /opt/move ───────────────────────────────────────────────────────
if [ -n "$FROM_MOUNT" ]; then
    log "rsync /opt/move/ from $FROM_MOUNT (local)"
    rsync -aHAX \
          --exclude='*.log' \
          --exclude='log/' \
          --exclude='Scratch/' \
          "$FROM_MOUNT/opt/move/" "$PKGROOT/opt/move/"
else
    log "rsync /opt/move/  (this is the big one, ~70 MB)"
    rsync -aHAX --info=progress2 \
          -e "ssh ${SSH_OPTS[*]}" \
          --exclude='*.log' \
          --exclude='log/' \
          --exclude='Scratch/' \
          "$HOST:/opt/move/" "$PKGROOT/opt/move/"
fi
```

**Replace step 5 "Pull the vendored libraries"** with a mode-aware block (change
only the `files=$(ssh ...)` and the `rsync` lines):

```bash
log "pulling vendored libs to /opt/move/lib/"
VENDORED_PREFIXES=(
    libc++
    libXSDBusCpp
    libXTCMalloc
    libubootenv
    libswupdate
)
for prefix in "${VENDORED_PREFIXES[@]}"; do
    if [ -n "$FROM_MOUNT" ]; then
        files=$(ls "$FROM_MOUNT/usr/lib/${prefix}.so"* 2>/dev/null | tr '\n' ' ' || true)
    else
        files=$(ssh "${SSH_OPTS[@]}" "$HOST" \
                "ls /usr/lib/${prefix}.so* 2>/dev/null" | tr '\n' ' ')
    fi
    if [ -z "$files" ]; then
        log "  - ${prefix}.so* (not found; skipping)"
        continue
    fi
    log "  + ${prefix}.so*  ($(echo "$files" | wc -w | tr -d ' ') file(s))"
    for f in $files; do
        if [ -n "$FROM_MOUNT" ]; then
            rsync -aHAX "$f" "$PKGROOT/opt/move/lib/"
        else
            rsync -aHAX -e "ssh ${SSH_OPTS[*]}" \
                  "$HOST:$f" "$PKGROOT/opt/move/lib/"
        fi
    done
done
```

**Add a key extraction block after step 10 "postinst: ldconfig + restart services"**
(still inside the `if [ "$PULL_FIRMWARE" = 1 ]; then` block, before `fi`):

```bash
# ── 10b. Extract swupdate keys (--keys / --from-mount always) ───────────────
if [ "$PULL_KEYS" = 1 ]; then
    log "extracting swupdate key files"
    mkdir -p "$PKGROOT/etc/move-swupdate"

    if [ -n "$FROM_MOUNT" ]; then
        SYM_SRC="$FROM_MOUNT/etc/swupdate/move-dev_symmetrickey"
        PUB_SRC="$FROM_MOUNT/etc/swupdate/move-dev_publickey.pem"
        [ -f "$SYM_SRC" ] || fatal "symmetrickey not found at $SYM_SRC"
        [ -f "$PUB_SRC" ] || fatal "publickey.pem not found at $PUB_SRC"
        cp "$SYM_SRC" "$PKGROOT/etc/move-swupdate/symmetrickey"
        cp "$PUB_SRC" "$PKGROOT/etc/move-swupdate/publickey.pem"
    else
        scp "${SSH_OPTS[@]/#/-o}" \
            "$HOST:/etc/swupdate/move-dev_symmetrickey" \
            "$PKGROOT/etc/move-swupdate/symmetrickey" \
            || fatal "could not copy symmetrickey from $HOST"
        scp "${SSH_OPTS[@]/#/-o}" \
            "$HOST:/etc/swupdate/move-dev_publickey.pem" \
            "$PKGROOT/etc/move-swupdate/publickey.pem" \
            || fatal "could not copy publickey.pem from $HOST"
    fi
    chmod 0600 "$PKGROOT/etc/move-swupdate/symmetrickey"
    log "keys staged at $PKGROOT/etc/move-swupdate/"

    # postinst: lock down the key file after install
    # Append to the existing postinst rather than replacing it
    cat >> "$PKGROOT/DEBIAN/postinst" <<'POSTEOF'
        # Protect swupdate key files
        if [ -f /etc/move-swupdate/symmetrickey ]; then
            chmod 0600 /etc/move-swupdate/symmetrickey
            chown root:root /etc/move-swupdate/symmetrickey
        fi
POSTEOF
fi
```

**Replace step 12 "/data → move-user-data deb"** rsync with a mode-aware version:

```bash
    if [ -n "$FROM_MOUNT" ]; then
        log "rsync /data/ from $FROM_MOUNT (local)"
        rsync -aHAX \
              --exclude='log/' \
              --exclude='Scratch/' \
              --exclude='**/.cache/' \
              --exclude='**/Sentry/' \
              --exclude='**/*.log' \
              --exclude='**/lost+found/' \
              "$FROM_MOUNT/data/" "$DATAROOT/var/lib/move-data/"
    else
        log "rsync /data/  (this may take a while if the user has samples)"
        rsync -aHAX --info=progress2 \
              -e "ssh ${SSH_OPTS[*]}" \
              --exclude='log/' \
              --exclude='Scratch/' \
              --exclude='**/.cache/' \
              --exclude='**/Sentry/' \
              --exclude='**/*.log' \
              --exclude='**/lost+found/' \
              "$HOST:/data/" "$DATAROOT/var/lib/move-data/"
    fi
```

- [ ] **Step 4: Verify the script parses cleanly**

```bash
bash -n port/scripts/extract-move-firmware.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 5: Commit**

```bash
git add port/scripts/extract-move-firmware.sh
git commit -m "extract-move-firmware.sh: add --from-mount and --keys modes"
```

---

### Task 9: Deploy and smoke-test on device

These steps run on the Move device at 192.168.1.199 (root/move). They are manual
test steps, not automated. Perform them in order.

- [ ] **Step 1: Build the deb on the host**

```bash
cd port/move-bringup
dpkg-buildpackage -us -uc -b --host-arch arm64
ls ../move-bringup_*.deb
```

If `dpkg-buildpackage` is not available on the build host, use the Armbian
`customize-image.sh` build path instead. Either way, confirm a `.deb` is produced.

- [ ] **Step 2: Transfer and install**

```bash
scp -o PubkeyAuthentication=no -o IdentitiesOnly=yes \
    ../move-bringup_1.0.14-1_arm64.deb root@192.168.1.199:/tmp/
ssh -o PubkeyAuthentication=no -o IdentitiesOnly=yes root@192.168.1.199 \
    "dpkg -i /tmp/move-bringup_1.0.14-1_arm64.deb"
```

- [ ] **Step 3: Smoke-test progress socket (regression check)**

```bash
ssh -o PubkeyAuthentication=no -o IdentitiesOnly=yes root@192.168.1.199 \
    "python3 -c \"
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/swupdateprog')
print('connected, holding 3s')
time.sleep(3)
print('OK')
\""
```

Expected: `connected, holding 3s` then `OK` with no error.

- [ ] **Step 4: Check both services are running**

```bash
ssh -o PubkeyAuthentication=no -o IdentitiesOnly=yes root@192.168.1.199 \
    "systemctl status move-swupdate-shim.service move-update-dbus.service"
```

Both should be `active (running)`.

- [ ] **Step 5: Smoke-test D-Bus shim**

```bash
ssh -o PubkeyAuthentication=no -o IdentitiesOnly=yes root@192.168.1.199 \
    "busctl call com.ableton.update /com/ableton/Update com.ableton.update registerSuccessfulStartup"
```

Expected: returns immediately with no error (method has no return value).

- [ ] **Step 6: Test RNBO .swu upload**

From the build host browser, navigate to `http://move.local/testing/update`.
Upload `/home/user1/Downloads/rnbo-move-1.4.3-alpha.1.swu`.

Watch logs on device:
```bash
ssh -o PubkeyAuthentication=no -o IdentitiesOnly=yes root@192.168.1.199 \
    "journalctl -f -u move-swupdate-shim"
```

Expected log sequence:
```
control: CMD_ACTIVATION received, streaming .swu ...
control: received XXXXXX bytes → /tmp/move-swuXXXXXX.swu
extracting CPIO from ...
signature not verified with known key — proceeding as root operator
sha256 OK: rnbo-move.tar.gz
extracting rnbo-move.tar.gz → /var/lib/move-data/UserData/
archive extract done
running script: postinstall.sh
script postinstall.sh: OK
restarting move-launcher + move-web ...
process_swu result: success
```

The web UI should show a success response instead of "Network Error".

- [ ] **Step 7: Verify RNBO ownership and capabilities**

```bash
ssh -o PubkeyAuthentication=no -o IdentitiesOnly=yes root@192.168.1.199 \
    "ls -la /data/UserData/rnbo/bin/rnbomovecontrol && \
     getcap /data/UserData/rnbo/bin/rnbomovecontrol"
```

Expected:
- File is owned by `ableton:users` (not `501:staff`)
- `getcap` shows `cap_kill,cap_ipc_lock,cap_sys_nice,cap_sys_resource=eip`

If capabilities are missing, the RNBO postinstall.sh ran as root but `setcap` needs
the filesystem to support xattrs. Check:
```bash
ssh -o PubkeyAuthentication=no -o IdentitiesOnly=yes root@192.168.1.199 \
    "mount | grep ' / '"
```
The root fs must be ext4 with `user_xattr` (default on Armbian). If missing, run
`setcap` manually and investigate the mount options.

---

### Task 10: Final commit — version bump and release notes

- [ ] **Step 1: Verify changelog version matches the deb**

```bash
head -3 port/move-bringup/debian/changelog
```

Should show `move-bringup (1.0.14-1)`.

- [ ] **Step 2: Tag the release**

```bash
git tag -a move-bringup-1.0.14 -m "move-bringup 1.0.14: swupdate shim, update D-Bus shim"
```

(Only after device tests pass in Task 9.)

---

## Spec coverage check

| Spec requirement | Task |
|-----------------|------|
| `/tmp/swupdateprog` progress socket (hold + terminal msg) | Task 2 |
| `/tmp/sockinstctrl` control socket + 12-byte header | Task 2 |
| CPIO extract + sha256 verify | Task 3 |
| RSA signature check (permissive) | Task 3 |
| AES-256-CBC decrypt (openssl subprocess) | Task 3 |
| ext4 loopback mount + rsync /opt/move/ | Task 3 |
| rsync /data/ with UserData excluded | Task 3 |
| Third-party archive extraction + ownership fix | Task 3 |
| Run sw-description scripts | Task 3 |
| Restart move-launcher after install | Task 3 |
| move-swupdate-shim.service unit | Task 1 |
| Delete swupdateprog-stub (service + script) | Tasks 1, 2 |
| com.ableton.update D-Bus shim + service unit | Task 5 |
| factoryReset category wipe | Task 5 |
| move-update-check.sh (CDN + download + invoke Updater) | Task 6 |
| etc/move-swupdate/channel default config | Task 6 |
| debian/control add openssl | Task 7 |
| debian/move-bringup.install updated | Task 7 |
| debian/move-bringup.postinst updated | Task 7 |
| debian/changelog 1.0.14 entry | Task 7 |
| extract-move-firmware.sh --from-mount mode | Task 8 |
| extract-move-firmware.sh --keys mode | Task 8 |
| Key files never committed to public repo | (design constraint — not a task) |
| Device smoke tests | Task 9 |
