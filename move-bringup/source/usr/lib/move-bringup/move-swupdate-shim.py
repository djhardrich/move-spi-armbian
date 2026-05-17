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
import hashlib
import re
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
_PROGRESS_FMT = "<IIIQIII256s64sII2048s"
assert struct.calcsize(_PROGRESS_FMT) == 2408

STATUS_RUN     = 2
STATUS_SUCCESS = 3
STATUS_FAILURE = 4

# Registered progress clients (ipc_wait_for_complete creates a new connection)
_progress_clients: list[asyncio.StreamWriter] = []

# Current update state — read by the progress socket on-connect and by
# command-3 (ipc_get_status) responses so late-connecting clients see live pct.
_current_status: int = STATUS_SUCCESS
_current_pct:    int = 0


def build_progress_msg(
    status: int,
    dwl_bytes: int = 0,
    cur_pct: int = 0,
    cur_image: str = "move-swupdate-shim",
) -> bytes:
    img_b = (cur_image.encode()[:255] + b"\x00").ljust(256, b"\x00")
    pct = 100 if status == STATUS_SUCCESS else cur_pct
    return struct.pack(
        _PROGRESS_FMT,
        IPC_MAGIC_PROGRESS,  # magic
        status,              # status
        pct,                 # dwl_percent
        dwl_bytes,           # dwl_bytes (uint64)
        1,                   # nsteps
        1,                   # cur_step
        pct,                 # cur_percent
        img_b,               # cur_image[256]
        b"file\x00",         # hnd_name[64]
        0,                   # source
        0,                   # infolen
        b"\x00" * 2048,      # info[2048]
    )


async def _notify_raw(msg: bytes) -> None:
    dead = []
    for w in _progress_clients:
        try:
            w.write(msg)
            await w.drain()
        except Exception:
            dead.append(w)
    for w in dead:
        _progress_clients.remove(w)


async def _notify_progress(status: int, dwl_bytes: int = 0, cur_pct: int = 0) -> None:
    await _notify_raw(build_progress_msg(status, dwl_bytes, cur_pct))


# ── progress socket handler ───────────────────────────────────────────────

async def _handle_progress_client(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    """Hold the connection open; poll _current_pct/_current_status and push
    a progress_msg on every change.  Exits when the client disconnects or
    STATUS_SUCCESS/FAILURE is sent."""
    log.debug("progress client connected")
    _progress_clients.append(writer)
    last_pct    = -1
    last_status = -1
    try:
        while True:
            pct    = _current_pct
            status = _current_status
            if pct != last_pct or status != last_status:
                last_pct    = pct
                last_status = status
                writer.write(build_progress_msg(status, cur_pct=pct))
                await writer.drain()
                if status in (STATUS_SUCCESS, STATUS_FAILURE):
                    break
            # Yield to the event loop; check again in 100 ms.
            try:
                await asyncio.wait_for(reader.read(1), timeout=0.1)
                break   # client sent EOF / disconnected early
            except asyncio.TimeoutError:
                pass
            except Exception:
                break
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
# ipc_inst_start_ext() writes sizeof(struct ipc_message) = 3120 bytes and
# then reads back exactly 3120 bytes, checking response[4] == 1 (ACCEPT).
IPC_MSG_SIZE = 3120
CMD_ACTIVATION = 0


async def _handle_control_client(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    """Receive .swu stream from Updater / MoveWebService."""
    global _current_status, _current_pct
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
        # ipc_get_status() and similar: drain + reply with current progress.
        log.debug("control: command %d — draining and acking (pct=%d)", command, _current_pct)
        try:
            await reader.readexactly(IPC_MSG_SIZE - IPC_HDR_LEN)
        except asyncio.IncompleteReadError:
            pass
        response = bytearray(IPC_MSG_SIZE)
        struct.pack_into("<I", response, 0, IPC_MAGIC_CONTROL)  # magic
        struct.pack_into("<I", response, 4, 1)                  # ACCEPT
        pm = build_progress_msg(_current_status, cur_pct=_current_pct)
        response[12:12 + len(pm)] = pm                          # embed progress_msg in data field
        writer.write(bytes(response))
        await writer.drain()
        writer.close()
        return

    log.info("control: CMD_ACTIVATION received, draining struct body ...")

    # ipc_inst_start_ext() writes a fixed 3120-byte ipc_message struct then
    # reads back exactly 3120 bytes and checks response[4] == 1 (ACCEPT).
    # We must consume the remaining (3120 - 12) struct bytes and echo back
    # the full 3120-byte response before the client starts streaming .swu.
    remaining = IPC_MSG_SIZE - IPC_HDR_LEN
    try:
        await reader.readexactly(remaining)
    except asyncio.IncompleteReadError:
        log.warning("control: truncated ipc_message struct")

    response = bytearray(IPC_MSG_SIZE)
    struct.pack_into("<I", response, 4, 1)   # response[4] = 1 → ACCEPT
    writer.write(bytes(response))
    await writer.drain()
    log.info("control: ACK sent (3120-byte response, offset4=1), reading .swu stream ...")

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

    loop = asyncio.get_running_loop()
    _current_status = STATUS_RUN
    _current_pct    = 0

    def _progress_cb(pct: int, label: str = "installing") -> None:
        global _current_pct
        _current_pct = pct
        msg = build_progress_msg(STATUS_RUN, cur_pct=pct, cur_image=label)
        asyncio.run_coroutine_threadsafe(_notify_raw(msg), loop)

    result = await loop.run_in_executor(
        None, lambda: process_swu(tmp_path, _progress_cb)
    )
    status = STATUS_SUCCESS if result == "success" else STATUS_FAILURE
    _current_status = status
    _current_pct    = 100 if status == STATUS_SUCCESS else _current_pct
    await _notify_progress(status, total)

    try:
        os.unlink(tmp_path)
    except OSError:
        pass

    if result == "success":
        # Give MoveWebService 5 s to process the success notification and
        # send its HTTP 200 to the browser before we restart anything.
        await asyncio.sleep(5)
        log.info("restarting move-launcher.service ...")
        proc = await asyncio.create_subprocess_exec(
            "systemctl", "try-restart", "move-launcher.service",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        log.info("move-launcher.service restarted")


KEY_FILE = "/etc/move-swupdate/symmetrickey"
PUBKEY_FILE = "/etc/move-swupdate/publickey.pem"


def _safe_workdir_path(workdir: str, filename: str) -> "str | None":
    """Return absolute path only if it resolves inside workdir, else None."""
    candidate = os.path.normpath(os.path.join(workdir, filename))
    if candidate.startswith(workdir.rstrip("/") + "/"):
        return candidate
    return None


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _extract_paren_block(text: str, key: str) -> "str | None":
    """Find key = ( ... ) in libconfig text using paren-depth counting.
    Returns the content between the outer parens, or None if not found."""
    m = re.search(rf'\b{key}\s*=\s*\(', text)
    if not m:
        return None
    start = m.end()
    depth = 1
    for i in range(start, len(text)):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start:i]
    return None


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
        if re.search(r'encrypted\s*=\s*true', block_text):
            entry["encrypted"] = True
        if re.search(r'create-destination\s*=\s*"true"', block_text):
            entry["create_destination"] = True
        return entry

    for arr_name in ("files", "images"):
        arr_text = _extract_paren_block(text, arr_name)
        if arr_text is None:
            continue
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

    scripts_block = _extract_paren_block(text, "scripts")
    if scripts_block is not None:
        depth = 0
        start = None
        arr_text = scripts_block
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


def _handle_raw_payload(entry: dict, workdir: str, progress=None, pct_start: int = 40, pct_end: int = 90) -> str:
    _p = progress or (lambda *_: None)
    filename = entry["filename"]
    src = _safe_workdir_path(workdir, filename)
    if src is None:
        log.error("raw payload filename escapes workdir: %s", filename)
        return "failure"

    if entry["encrypted"] or filename.endswith(".enc"):
        enc_src = src
        dec_name = src[:-4] if src.endswith(".enc") else src + ".dec"
        if dec_name.endswith(".gz"):
            # Decrypt + decompress in one pipeline — never writes .gz to disk
            # (saves ~650 MB on constrained devices).
            final = dec_name[:-3]
            log.info("decrypt+gunzip pipeline: %s → %s",
                     os.path.basename(enc_src), os.path.basename(final))
            err = _aes_decrypt_gunzip(enc_src, final)
            if err:
                log.error("raw payload decrypt+gunzip failed: %s", err)
                return "failure"
            src = final
        else:
            err = _aes_decrypt(enc_src, dec_name)
            if err:
                log.error("raw payload decrypt failed: %s", err)
                return "failure"
            src = dec_name
            if src.endswith(".gz"):
                base = src[:-3]
                r = subprocess.run(["gunzip", "-f", src], capture_output=True)
                if r.returncode != 0:
                    log.error("gunzip failed: %s", r.stderr.decode())
                    return "failure"
                src = base
        # Free encrypted source now that we have the decompressed output
        try:
            os.unlink(enc_src)
        except OSError:
            pass
        log.info("decrypted → %s", os.path.basename(src))
    else:
        if src.endswith(".gz"):
            base = src[:-3]
            r = subprocess.run(["gunzip", "-f", src], capture_output=True)
            if r.returncode != 0:
                log.error("gunzip failed: %s", r.stderr.decode())
                return "failure"
            src = base

    mntdir = tempfile.mkdtemp(prefix="move-swu-mnt-")
    _p(pct_start + int((pct_end - pct_start) * 0.3), "mounting")
    try:
        r = subprocess.run(
            ["mount", "-o", "ro,loop", src, mntdir],
            capture_output=True
        )
        if r.returncode != 0:
            log.error("mount failed: %s", r.stderr.decode())
            return "failure"
        try:
            result = _rsync_from_mount(mntdir, _p, pct_start + int((pct_end - pct_start) * 0.5), pct_end)
        finally:
            subprocess.run(["umount", mntdir], capture_output=True)
            try:
                open("/proc/sys/vm/drop_caches", "w").write("1\n")
            except OSError:
                pass
    finally:
        try:
            os.rmdir(mntdir)
        except OSError:
            pass

    return result


def _install_missing_libs(mntdir: str) -> None:
    """Find libs that /opt/move/ binaries need but that are missing on the
    running system, then copy them from the mounted firmware image.

    This handles firmware updates that ship a library in a system path
    (e.g. /usr/lib/) rather than /opt/move/lib/, which our rsync doesn't
    cover. We only copy to /opt/move/lib/, never touching Armbian packages.
    """
    import glob as _glob

    # Collect all executable files under /opt/move/
    executables = []
    for dirpath, _, filenames in os.walk("/opt/move"):
        for fname in filenames:
            fpath = os.path.join(dirpath, fname)
            if os.access(fpath, os.X_OK):
                executables.append(fpath)

    if not executables:
        return

    # Run ldd on all of them at once; stderr carries "not a dynamic executable"
    # warnings for scripts which we ignore.
    missing: set = set()
    try:
        r = subprocess.run(["ldd", "--"] + executables, capture_output=True, text=True)
        for line in r.stdout.splitlines():
            m = re.match(r'\s+(\S+)\s+=>\s+not found', line)
            if m:
                missing.add(m.group(1))
    except Exception as e:
        log.debug("ldd scan error: %s", e)
        return

    if not missing:
        log.debug("all libs resolved after update")
        return

    log.info("missing lib(s) after update: %s", " ".join(sorted(missing)))

    search_roots = [
        os.path.join(mntdir, "opt", "move", "lib"),
        os.path.join(mntdir, "usr", "lib"),
        os.path.join(mntdir, "usr", "lib", "aarch64-linux-gnu"),
        os.path.join(mntdir, "lib"),
        os.path.join(mntdir, "lib", "aarch64-linux-gnu"),
    ]

    os.makedirs("/opt/move/lib", exist_ok=True)

    for libname in sorted(missing):
        placed = False
        for sdir in search_roots:
            for candidate in sorted(_glob.glob(os.path.join(sdir, libname + "*"))):
                if not os.path.isfile(candidate) or os.path.islink(candidate):
                    continue
                dest = os.path.join("/opt/move/lib", os.path.basename(candidate))
                try:
                    shutil.copy2(candidate, dest)
                    log.info("installed %s ← %s", os.path.basename(candidate),
                             os.path.relpath(candidate, mntdir))
                    placed = True
                    break
                except Exception as e:
                    log.warning("copy %s failed: %s", candidate, e)
            if placed:
                break
        if not placed:
            log.warning("lib %s not found in firmware image — may fail to launch", libname)


def _rsync_from_mount(mntdir: str, progress=None, pct_start: int = 65, pct_end: int = 90) -> str:
    _p = progress or (lambda *_: None)
    result = "success"

    opt_src = os.path.join(mntdir, "opt", "move") + "/"
    if os.path.isdir(opt_src):
        _p(pct_start, "syncing /opt/move")
        log.info("rsyncing /opt/move/ ...")
        r = subprocess.run([
            "rsync", "-aHAX", "--delete",
            "--exclude=log/", "--exclude=*.log",
            # Protect lib/ from deletion: firmware updates may not ship
            # /opt/move/lib/ but vendor .so files there are still needed.
            "--filter=P lib/",
            opt_src, "/opt/move/",
        ], capture_output=True)
        if r.returncode != 0:
            log.error("rsync /opt/move/ failed: %s", r.stderr.decode())
            result = "failure"
        else:
            _p(pct_start + int((pct_end - pct_start) * 0.35), "resolving libs")
            _install_missing_libs(mntdir)
            subprocess.run(["ldconfig"], capture_output=True)
            log.info("rsync /opt/move/ done")

    data_src = os.path.join(mntdir, "data") + "/"
    if os.path.isdir(data_src) and os.listdir(data_src):
        _p(pct_start + int((pct_end - pct_start) * 0.5), "syncing /data")
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


def _read_aes_key() -> "tuple[str,str] | str":
    """Return (key_hex, iv_hex) or an error string."""
    if not os.path.exists(KEY_FILE):
        return f"AES key file not found: {KEY_FILE}"
    with open(KEY_FILE) as kf:
        parts = kf.read().strip().split()
    if len(parts) < 2:
        return f"bad key file format: {KEY_FILE}"
    return parts[0], parts[1]


def _aes_decrypt(src: str, dst: str) -> "str | None":
    """Decrypt src → dst with key from KEY_FILE. Returns error string or None."""
    k = _read_aes_key()
    if isinstance(k, str):
        return k
    key_hex, iv_hex = k
    r = subprocess.run(
        ["openssl", "enc", "-d", "-aes-256-cbc",
         "-K", key_hex, "-iv", iv_hex, "-nosalt",
         "-in", src, "-out", dst],
        capture_output=True
    )
    if r.returncode != 0:
        return f"openssl decrypt failed: {r.stderr.decode('utf-8', errors='replace').strip()}"
    return None


def _aes_decrypt_gunzip(src: str, dst: str) -> "str | None":
    """Decrypt src and decompress through gunzip in one pipeline → dst.
    Avoids materialising the intermediate .gz on disk at all.
    Returns error string or None."""
    k = _read_aes_key()
    if isinstance(k, str):
        return k
    key_hex, iv_hex = k
    with open(dst, "wb") as out_f:
        dec = subprocess.Popen(
            ["openssl", "enc", "-d", "-aes-256-cbc",
             "-K", key_hex, "-iv", iv_hex, "-nosalt", "-in", src],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        gz = subprocess.Popen(
            ["gunzip", "-c"],
            stdin=dec.stdout, stdout=out_f, stderr=subprocess.PIPE,
        )
        dec.stdout.close()
        _, gz_err  = gz.communicate()
        _, dec_err = dec.communicate()
    if dec.returncode != 0:
        return f"openssl decrypt failed: {dec_err.decode('utf-8', errors='replace').strip()}"
    if gz.returncode != 0:
        return f"gunzip failed: {gz_err.decode('utf-8', errors='replace').strip()}"
    return None


def _handle_archive_payload(entry: dict, workdir: str) -> str:
    filename = entry["filename"]
    src = _safe_workdir_path(workdir, filename)
    if src is None:
        log.error("archive payload filename escapes workdir: %s", filename)
        return "failure"
    raw_dest = entry["path"].replace("/data/", "/var/lib/move-data/")
    if not raw_dest:
        raw_dest = "/var/lib/move-data/"
    dest = os.path.normpath(raw_dest)
    if not (dest == "/var/lib/move-data" or dest.startswith("/var/lib/move-data/")):
        log.error("archive destination outside allowed tree: %s", dest)
        return "failure"

    if entry["create_destination"]:
        os.makedirs(dest, exist_ok=True)

    if entry["encrypted"] or filename.endswith(".enc"):
        dec = src[:-4] if src.endswith(".enc") else src + ".dec"
        err = _aes_decrypt(src, dec)
        if err:
            log.error("archive decrypt failed: %s", err)
            return "failure"
        src = dec
        log.info("decrypted → %s", os.path.basename(src))

    log.info("extracting %s → %s", os.path.basename(src), dest)
    r = subprocess.run(
        ["tar", "-xzf", src, "-C", dest],
        capture_output=True
    )
    if r.returncode != 0:
        log.error("tar extract failed: %s", r.stderr.decode('utf-8', errors='replace'))
        return "failure"

    # If this archive ships rnbo runnercontent, sync the cache and pre-populated
    # sqlite into Documents/rnbo/ now.  The vendor postinstall.sh has a
    # [ ! -d Documents/rnbo ] guard that skips the copy on reinstalls, so we
    # do it here before scripts run to ensure rnbomovecontrol finds the correct DB.
    rnbo_rc  = os.path.join(dest, "rnbo", "share", "runnercontent", "rnbo")
    rnbo_doc = os.path.join(dest, "Documents", "rnbo")
    if os.path.isdir(rnbo_rc):
        os.makedirs(rnbo_doc, exist_ok=True)
        rc_cache  = rnbo_rc  + "/cache/"
        doc_cache = rnbo_doc + "/cache/"
        if os.path.isdir(rc_cache.rstrip("/")):
            subprocess.run(["rsync", "-a", "--delete", rc_cache, doc_cache],
                           capture_output=True)
        rc_sqlite  = os.path.join(rnbo_rc,  "oscqueryrunner.sqlite")
        dst_sqlite = os.path.join(rnbo_doc, "oscqueryrunner.sqlite")
        if os.path.exists(rc_sqlite):
            shutil.copy2(rc_sqlite, dst_sqlite)
        subprocess.run(["chown", "-R", "ableton:users", rnbo_doc], capture_output=True)
        log.info("rnbo: synced runnercontent/cache + sqlite → %s", rnbo_doc)

    subprocess.run(["chown", "-R", "ableton:users", dest], capture_output=True)
    log.info("archive extract done")
    return "success"


def process_swu(path: str, progress=None) -> str:
    """Process a .swu file. Returns 'success' or 'failure'."""
    workdir = tempfile.mkdtemp(prefix="move-swu-")
    try:
        return _process_swu_inner(path, workdir, progress or (lambda *_: None))
    except Exception as e:
        log.exception("process_swu unhandled exception: %s", e)
        return "failure"
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _process_swu_inner(path: str, workdir: str, progress) -> str:
    # 1. CPIO extract
    progress(5, "extracting")
    log.info("extracting CPIO from %s", path)
    with open(path, "rb") as f:
        r = subprocess.run(
            ["cpio", "-id", "--quiet"],
            stdin=f, capture_output=True, cwd=workdir
        )
    if r.returncode != 0:
        log.error("cpio extract failed: %s", r.stderr.decode().strip())
        with open(path, "rb") as _dbg:
            _hdr = _dbg.read(128)
        log.error("cpio fail — first 128 bytes hex: %s", _hdr.hex())
        log.error("cpio fail — printable: %s", _hdr.decode("latin-1", errors="replace").replace("\n", "\\n")[:200])
        import shutil as _sh
        _sh.copy2(path, "/tmp/move-swu-failed-last.swu")
        log.error("cpio fail — payload saved to /tmp/move-swu-failed-last.swu")
        return "failure"

    sw_desc_path = os.path.join(workdir, "sw-description")
    if not os.path.exists(sw_desc_path):
        log.error("sw-description not found in .swu")
        return "failure"

    # CPIO extraction done — delete the .swu now to free ~670 MB before the
    # decrypt+decompress step materialises the ext4 image (~2 GB).
    try:
        os.unlink(path)
        log.debug("deleted .swu after CPIO extract")
    except OSError:
        pass

    # 2. Signature verification (permissive)
    progress(20, "verifying")
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
    with open(sw_desc_path) as f:
        sw_desc_text = f.read()
    try:
        with open("/tmp/move-sw-description-last.txt", "w") as _f:
            _f.write(sw_desc_text)
    except Exception:
        pass
    desc = _parse_sw_description(sw_desc_text)
    log.info("sw-description version=%s, %d file(s), %d script(s)",
             desc["version"], len(desc["files"]), len(desc["scripts"]))

    # 4. SHA-256 verify all payloads
    progress(30, "verifying")
    for entry in desc["files"] + desc["scripts"]:
        if not entry["sha256"]:
            continue
        fpath = _safe_workdir_path(workdir, entry["filename"])
        if fpath is None:
            log.error("payload filename escapes workdir: %s", entry["filename"])
            return "failure"
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

    # 5. Dispatch by type — allocate progress range 40-90 across payloads
    n_files = max(len(desc["files"]), 1)
    result = "success"
    for i, entry in enumerate(desc["files"]):
        pct = 40 + int(50 * i / n_files)
        ptype = entry["type"]
        if ptype in ("raw", "rawfile"):
            progress(pct, "installing")
            r2 = _handle_raw_payload(entry, workdir, progress, pct, pct + int(50 / n_files))
        elif ptype == "archive":
            progress(pct, "installing")
            r2 = _handle_archive_payload(entry, workdir)
        else:
            log.warning("unknown payload type %r — skipping", ptype)
            continue
        if r2 != "success":
            result = r2

    # 6. Scripts: run postinstall scripts extracted from the .swu. Treat
    # failures as non-fatal warnings — firmware postinstalls that call
    # fw_setenv/fw_printenv (U-Boot, absent on Armbian) will exit non-zero
    # but the payload files are already in place and that is what matters.
    progress(95, "finalizing")
    for s in desc["scripts"]:
        script_path = os.path.join(workdir, s["filename"])
        if not os.path.exists(script_path):
            log.info("script %s not found in workdir, skipping", s["filename"])
            continue
        log.info("running script %s", s["filename"])
        try:
            r = subprocess.run(
                ["bash", script_path],
                capture_output=True, text=True, timeout=120
            )
            if r.returncode != 0:
                log.warning("script %s exited %d: %s",
                            s["filename"], r.returncode,
                            (r.stderr or r.stdout).strip()[:400])
            else:
                log.info("script %s completed OK", s["filename"])
        except subprocess.TimeoutExpired:
            log.warning("script %s timed out after 120 s", s["filename"])
        except Exception as e:
            log.warning("script %s failed: %s", s["filename"], e)

    log.info("process_swu result: %s", result)
    return result


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
