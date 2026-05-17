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

while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() { printf '[move-update-check] %s\n' "$*" >&2; }

if [ -z "${CHANNEL:-}" ]; then
    if [ -f "$CHANNEL_FILE" ]; then
        CHANNEL=$(cat "$CHANNEL_FILE" | tr -d '[:space:]')
    else
        CHANNEL="stable"
    fi
fi
log "channel: $CHANNEL"

CUR_VER=""
if [ -f /etc/os-release ]; then
    raw=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)
    CUR_VER=$(echo "$raw" | sed -nE 's/.*-v([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')
fi
if [ -z "$CUR_VER" ]; then
    log "WARNING: could not determine current version from /etc/os-release"
    CUR_VER="0.0"
fi
log "current version: $CUR_VER"

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

# Guard against non-HTTPS URLs from CDN response
case "$DL_URL" in
    https://*) ;;
    *) log "ERROR: CDN returned unsafe URL scheme: $DL_URL"; exit 1 ;;
esac

if [ "$DRY_RUN" = 1 ]; then
    log "DRY RUN — would download $DL_URL"
    exit 0
fi

TMP_SWU=$(mktemp /tmp/move-update-XXXXXX.swu)
trap 'rm -f "$TMP_SWU"' EXIT

log "downloading $DL_URL → $TMP_SWU"
curl -fL --progress-bar -o "$TMP_SWU" "$DL_URL"
log "download complete ($(du -h "$TMP_SWU" | cut -f1))"

if [ ! -x "$UPDATER" ]; then
    log "ERROR: $UPDATER not found or not executable"
    exit 1
fi
log "invoking $UPDATER --input $TMP_SWU"
"$UPDATER" --input "$TMP_SWU"
log "update installed successfully"
