#!/bin/sh
# =====================================================
# Tailscale Updater v4.8 - pfSense / FreeBSD 15
# NO-HANG FIX: removes pkg update dependency
# =====================================================

set -eu

PKG_NAME="tailscale"
LOG_FILE="/var/log/tailscale_update.log"
LOCK_FILE="/var/run/tailscale_update.lock"

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

log() {
    msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
    logger -t tailscale-update "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# -------------------------
# Lock (PID safe)
# -------------------------
if [ -f "$LOCK_FILE" ]; then
    OLD_PID="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "Another instance running (PID $OLD_PID)"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# -------------------------
# pkg-static
# -------------------------
PKG_STATIC="/usr/local/sbin/pkg-static"
[ -x "$PKG_STATIC" ] || PKG_STATIC="/usr/sbin/pkg-static"
[ -x "$PKG_STATIC" ] || die "pkg-static not found"

log "Using pkg-static: $PKG_STATIC"

# -------------------------
# Preconditions
# -------------------------
command -v tailscaled >/dev/null 2>&1 || die "tailscaled not found"

# -------------------------
# Versions (NO pkg update)
# -------------------------
PKG_VER="$($PKG_STATIC query '%v' "$PKG_NAME" 2>/dev/null || true)"
[ -n "$PKG_VER" ] || PKG_VER="0"

RUNTIME_VER="$(tailscale version 2>/dev/null | head -n1 | awk '{print $1}' || true)"
[ -n "$RUNTIME_VER" ] || RUNTIME_VER="unknown"

log "pkg version: $PKG_VER"
log "runtime version: $RUNTIME_VER"

# -------------------------
# Candidate version (lightweight)
# -------------------------
CANDIDATE_VER="$($PKG_STATIC rquery '%v' "$PKG_NAME" 2>/dev/null || echo "$PKG_VER")"

log "candidate version: $CANDIDATE_VER"

if [ "$(pkg version -t "$PKG_VER" "$CANDIDATE_VER")" != "<" ]; then
    log "No upgrade required"
    exit 0
fi

log "Upgrade required: $PKG_VER -> $CANDIDATE_VER"

# -------------------------
# Upgrade
# -------------------------
export IGNORE_OSVERSION=yes

log "Installing update..."

$PKG_STATIC upgrade -y "$PKG_NAME" \
    || die "pkg upgrade failed"

# -------------------------
# Restart
# -------------------------
log "Restarting tailscaled..."

service tailscaled restart 2>/dev/null || service tailscaled start \
    || die "service restart failed"

sleep 3

# -------------------------
# Health check
# -------------------------
if tailscale status >/dev/null 2>&1; then
    log "Tailscale healthy"
else
    log "WARNING: tailscale not responding"
fi

log "Update completed successfully"
