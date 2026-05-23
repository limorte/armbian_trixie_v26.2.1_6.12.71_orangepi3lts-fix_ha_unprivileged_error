#!/usr/bin/env bash
# Fix Home Assistant Supervised "unhealthy: privileged" / "Not privileged to run udev monitor!"
# caused by AppArmor 4.x on Debian 13 (trixie) blocking netlink due to `deny network raw,`
# in the hassio-supervisor profile.
#
# Run as root on each board:    sudo ./fix-hassio-privileged.sh
# Or remotely:                   ssh root@HOST 'bash -s' < fix-hassio-privileged.sh

set -euo pipefail

PROFILE=/var/lib/homeassistant/apparmor/hassio-supervisor
BACKUP_DIR=/root/hassio-apparmor-backup
TS=$(date +%Y%m%d-%H%M%S)

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -f "$PROFILE" ]] || die "profile not found: $PROFILE (is this a HA Supervised host?)"
command -v apparmor_parser >/dev/null || die "apparmor_parser missing"
command -v docker >/dev/null || die "docker missing"
docker inspect hassio_supervisor >/dev/null 2>&1 || die "hassio_supervisor container not found"

log "host: $(hostname)  |  profile: $PROFILE"

if ! grep -q '^[[:space:]]*deny network raw,' "$PROFILE"; then
    ok "profile already clean (no 'deny network raw,' found) — nothing to patch"
    ALREADY_PATCHED=1
else
    ALREADY_PATCHED=0
    mkdir -p "$BACKUP_DIR"
    cp -a "$PROFILE" "$BACKUP_DIR/hassio-supervisor.bak.$TS"
    ok "backup -> $BACKUP_DIR/hassio-supervisor.bak.$TS"

    REMOVED=$(grep -c '^[[:space:]]*deny network raw,' "$PROFILE")
    sed -i '/^[[:space:]]*deny network raw,[[:space:]]*$/d' "$PROFILE"
    ok "removed $REMOVED occurrence(s) of 'deny network raw,'"

    if grep -q '^[[:space:]]*deny network raw,' "$PROFILE"; then
        die "sanity check failed: 'deny network raw,' still present"
    fi
fi

log "reloading AppArmor profile"
apparmor_parser -r "$PROFILE" || die "apparmor_parser -r failed"
ok "profile reloaded"

log "verifying pyudev works inside hassio_supervisor"
if docker exec hassio_supervisor python3 -c \
   'import pyudev; pyudev.Monitor.from_netlink(pyudev.Context())' 2>/dev/null; then
    ok "pyudev netlink monitor opens successfully"
else
    warn "pyudev still fails — restarting container to re-evaluate state"
fi

if [[ $ALREADY_PATCHED -eq 0 ]]; then
    log "restarting hassio_supervisor"
    docker restart hassio_supervisor >/dev/null
    ok "restarted — waiting 40s for Supervisor to come up"
    sleep 40
fi

log "checking 'ha resolution info' (this takes a few seconds)"
RES_OUT=$(ha resolution info 2>&1 | tr -d '\r' || true)
SUP_OUT=$(ha supervisor info 2>&1 | tr -d '\r' || true)

# 'unhealthy:' can appear as "unhealthy: []" (clean) or "unhealthy:" followed by "- foo" lines (dirty).
UNHEALTHY_LIST=$(printf '%s\n' "$RES_OUT" \
    | awk '/^unhealthy:[[:space:]]*\[\]/{exit} /^unhealthy:[[:space:]]*$/{flag=1;next} /^[a-z_]+:/{flag=0} flag {print}' \
    | sed 's/^- *//' | tr '\n' ',' | sed 's/,$//')
HEALTHY=$(printf '%s\n' "$SUP_OUT" | awk -F': ' '/^healthy:/{print $2; exit}')

echo
echo "================ RESULT ================"
echo "  healthy:   ${HEALTHY:-unknown}"
if [[ -z "$UNHEALTHY_LIST" ]]; then
    ok "unhealthy list is empty"
else
    warn "still unhealthy: $UNHEALTHY_LIST"
fi
echo "========================================"

if [[ "${HEALTHY:-}" == "true" && -z "$UNHEALTHY_LIST" ]]; then
    ok "$(hostname): FIXED"
    exit 0
else
    die "$(hostname): not healthy yet - check 'docker logs hassio_supervisor' and 'ha resolution info'"
fi
