#!/bin/bash
# fix-move-manager-quota.sh
#
# Fix Move Manager's "No options. Unable to stat path ..." error on the
# Recordings / Samples / Presets pages of move.local.
#
# WHY THIS EXISTS
# ───────────────
# Stock Move stores user content on a dedicated data partition,
# /dev/mmcblk0p4, and mounts it with disk quotas enabled. Move Manager's
# web backend (/opt/move/MoveWebService) hardcodes that device: for every
# content listing it calls
#
#     quotactl(QCMD(Q_GETQUOTA, USRQUOTA), "/dev/mmcblk0p4", uid, &dqblk)
#
# to populate the storage bar, and it treats a quota-stat *failure* as
# fatal to the whole listing.
#
# On this Armbian build the rootfs/data live on a single partition
# (typically /dev/mmcblk0p2) and /dev/mmcblk0p4 does not exist, so the
# quotactl call fails and every content page returns:
#
#     No options. Unable to stat path "Recordings"   (or Samples / Track Presets)
#
# The directories themselves are fine - this is purely the hardcoded
# quota device. The "Sets" page appears to work only because it also
# renders from another source.
#
# WHAT THIS DOES
# ──────────────
# Patches /opt/move/MoveWebService (aarch64) so the listing no longer
# depends on quotactl, and reports a fixed, sane storage figure instead
# of garbage:
#
#   Edit A: force the success branch after the quota check
#           cbz w21, <ok>   ->   b <ok>
#   Edit B: replace the quota math with a constant 192 GiB free/total
#           ldr/ldr/lsl/sub ->   mov x8,#0x3000000000 ; mov x9,x8 ; nop ; nop
#
# The patch is a fixed-length, in-place edit of 20 bytes. There is no
# quota on this build, so nothing is actually capped; the storage bar
# becomes cosmetic (always ~192 GB free).
#
# SAFETY
# ──────
# The script verifies the exact pre-patch instruction bytes at the two
# sites before writing anything. If they don't match (different
# MoveWebService version), it aborts without modifying the binary and
# points you at docs/MOVE_MANAGER_QUOTA_FIX.md for how to re-derive the
# offsets. The original is always backed up to MoveWebService.orig.
#
# USAGE
# ─────
#   On the Move (as root):
#     ./fix-move-manager-quota.sh [--binary PATH] [--dry-run] [--rollback]
#
#   From a workstation:
#     ./fix-move-manager-quota.sh --host root@move.local
#     ssh root@move.local 'bash -s' < fix-move-manager-quota.sh
#
# Reference: docs/MOVE_MANAGER_QUOTA_FIX.md

set -euo pipefail

BINARY="/opt/move/MoveWebService"
SERVICE="move-web.service"
HOST=""
DRY_RUN=0
ROLLBACK=0

# Virtual addresses of the two patch sites (stable for the May 2026 image;
# see docs if your binary differs). File offsets are derived from the ELF
# .text section so they self-correct if the section layout changes.
EDIT_A_VA=0x2fe1e0
EDIT_B_VA=0x2fe398

# Expected bytes (little-endian) BEFORE patching.
A_BEFORE="d5 0d 00 34"                                              # cbz  w21, <ok>
B_BEFORE="e8 07 40 f9 e9 0f 40 f9 08 d5 76 d3 09 01 09 cb"         # ldr;ldr;lsl;sub
# Bytes AFTER patching.
A_AFTER="6e 00 00 14"                                              # b    <ok>
B_AFTER="08 06 c0 d2 e9 03 08 aa 1f 20 03 d5 1f 20 03 d5"         # mov x8,#..;mov x9,x8;nop;nop

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo ">>> $*"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | head -n -1; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --binary)   BINARY="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help)  usage ;;
    *)          die "unknown option: $1 (try --help)" ;;
  esac
done

# If targeting a remote host, copy ourselves over and run there.
if [ -n "$HOST" ]; then
  note "Running on $HOST ..."
  args=""
  [ "$DRY_RUN" = 1 ]  && args="$args --dry-run"
  [ "$ROLLBACK" = 1 ] && args="$args --rollback"
  exec ssh "$HOST" "bash -s -- $args" < "$0"
fi

[ "$(id -u)" = 0 ] || die "must run as root (use --host root@move.local, or sudo)"
[ -f "$BINARY" ]   || die "binary not found: $BINARY"

command -v dd >/dev/null || die "dd not found"
command -v od >/dev/null || die "od not found"

# bytes_at OFFSET COUNT  ->  "xx xx xx ..."
bytes_at() { dd if="$BINARY" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tx1 | tr -s ' ' | sed 's/^ //; s/ $//'; }

restart_service() {
  if command -v systemctl >/dev/null && systemctl list-unit-files | grep -q "^$SERVICE"; then
    systemctl restart "$SERVICE"; sleep 2
    systemctl is-active "$SERVICE"
  else
    note "systemd unit $SERVICE not found - restart the web service manually."
  fi
}

# ── Rollback ────────────────────────────────────────────────────────────
if [ "$ROLLBACK" = 1 ]; then
  [ -f "$BINARY.orig" ] || die "no backup at $BINARY.orig"
  note "Restoring $BINARY from .orig"
  [ "$DRY_RUN" = 1 ] && { note "(dry-run) would cp -a $BINARY.orig $BINARY and restart"; exit 0; }
  cp -a "$BINARY.orig" "$BINARY"
  restart_service
  note "Rolled back."
  exit 0
fi

# ── Derive file offsets from the ELF .text section ──────────────────────
read TADDR TOFF < <(readelf -SW "$BINARY" | awk '$2==".text"{print "0x"$5, "0x"$6}')
[ -n "${TADDR:-}" ] || die "could not read .text section (need readelf)"
DELTA=$(( TADDR - TOFF ))
A_OFF=$(( EDIT_A_VA - DELTA ))
B_OFF=$(( EDIT_B_VA - DELTA ))
note "binary:   $BINARY"
note ".text:    addr=$(printf 0x%x $TADDR) off=$(printf 0x%x $TOFF)  (delta=$(printf 0x%x $DELTA))"
note "Edit A @  $(printf 0x%x $A_OFF)   Edit B @  $(printf 0x%x $B_OFF)"

# ── Idempotency: already patched? ───────────────────────────────────────
if [ "$(bytes_at $A_OFF 4)" = "$A_AFTER" ] && [ "$(bytes_at $B_OFF 16)" = "$B_AFTER" ]; then
  note "Already patched - nothing to do."
  exit 0
fi

# ── Safety: refuse unless the pre-patch bytes match exactly ─────────────
GOT_A="$(bytes_at $A_OFF 4)"; GOT_B="$(bytes_at $B_OFF 16)"
if [ "$GOT_A" != "$A_BEFORE" ] || [ "$GOT_B" != "$B_BEFORE" ]; then
  echo "Pre-patch bytes do not match the known MoveWebService image:" >&2
  echo "  Edit A expected [$A_BEFORE] got [$GOT_A]" >&2
  echo "  Edit B expected [$B_BEFORE] got [$GOT_B]" >&2
  die "aborting (binary differs). See docs/MOVE_MANAGER_QUOTA_FIX.md to re-derive offsets."
fi
note "Pre-patch bytes verified."

if [ "$DRY_RUN" = 1 ]; then
  note "(dry-run) would back up to $BINARY.orig and write 20 bytes; no changes made."
  exit 0
fi

# ── Back up, patch a copy, verify, swap in, restart ─────────────────────
[ -f "$BINARY.orig" ] || cp -a "$BINARY" "$BINARY.orig"
TMP="$BINARY.patched.$$"
cp -a "$BINARY" "$TMP"
# write helper: "xx xx .." -> bytes at offset in $TMP
write_bytes() { local off="$1"; shift; local esc=""; for b in $*; do esc="$esc\\x$b"; done
                printf "$esc" | dd of="$TMP" bs=1 seek="$off" conv=notrunc 2>/dev/null; }
write_bytes "$A_OFF" $A_AFTER
write_bytes "$B_OFF" $B_AFTER

# verify the copy now holds the AFTER bytes and differs by exactly the patch
[ "$(dd if="$TMP" bs=1 skip=$A_OFF count=4  2>/dev/null | od -An -tx1 | tr -s ' ' | sed 's/^ //; s/ $//')" = "$A_AFTER" ] || { rm -f "$TMP"; die "Edit A verify failed"; }
[ "$(dd if="$TMP" bs=1 skip=$B_OFF count=16 2>/dev/null | od -An -tx1 | tr -s ' ' | sed 's/^ //; s/ $//')" = "$B_AFTER" ] || { rm -f "$TMP"; die "Edit B verify failed"; }
DIFFS=$(cmp -l "$BINARY.orig" "$TMP" | wc -l | tr -d ' ')
[ "$DIFFS" -le 20 ] || { rm -f "$TMP"; die "unexpected diff size ($DIFFS bytes) - aborting"; }
note "Patched copy verified ($DIFFS bytes changed)."

if command -v systemctl >/dev/null && systemctl list-unit-files | grep -q "^$SERVICE"; then
  systemctl stop "$SERVICE" || true
fi
cp -a "$TMP" "$BINARY"
rm -f "$TMP"
restart_service
note "Done. Reload move.local and open Recordings / Samples / Presets."
note "Backup kept at $BINARY.orig  (rollback: $0 --rollback)"
