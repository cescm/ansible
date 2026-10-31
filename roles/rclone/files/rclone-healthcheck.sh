#!/bin/bash
# Healthcheck for the rclone -> o2cloud-gateway -> Movistar WebDAV stack.
#
# The mount can be broken for two very different reasons:
#   1. The FUSE mount is stalled            -> restarting rclone fixes it.
#   2. The O2 session expired (gateway 503) -> restarting rclone fixes nothing.
#
# This script asks the gateway directly before touching anything, so an expired
# O2 session produces one log line (and the gateway's own Telegram alert)
# instead of a restart loop that also bounces Jellyfin every 5 minutes.
#
# Restarts are rate limited: at most one per service every MIN_RESTART_SECONDS.

set -uo pipefail

MOUNT_WEBDAV="/mnt/movistar_webdav"
MOUNT_ROOT="/mnt/movistar_webdav_root"
JELLYFIN_CONTAINER="jellyfin"
JELLYFIN_MEDIA_PATH="/media3"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:8088}"
GATEWAY_ENV="${GATEWAY_ENV:-/mnt/docker/o2cloud-webdav/.env}"
LOG_TAG="rclone-healthcheck"
STATE_DIR="/run/rclone-healthcheck"
MIN_RESTART_SECONDS="${MIN_RESTART_SECONDS:-600}"

mkdir -p "$STATE_DIR"

log() { logger -t "$LOG_TAG" "$*"; }

# Emit a message only when the recorded state for $1 changes, so a persistent
# condition does not fill the journal every 5 minutes.
log_on_change() {
    local key="$1" state="$2" msg="$3"
    local file="$STATE_DIR/$key.state"
    local prev=""
    [ -r "$file" ] && prev="$(cat "$file" 2>/dev/null || true)"
    if [ "$prev" != "$state" ]; then
        log "$msg"
        printf '%s\n' "$state" > "$file"
    fi
}

# Return 0 (skip) if $1 was restarted less than MIN_RESTART_SECONDS ago.
# Otherwise record the current time as the last restart and return 1.
rate_limited() {
    local key="$1" now last
    now=$(date +%s)
    last=$(cat "$STATE_DIR/$key.stamp" 2>/dev/null || true)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$MIN_RESTART_SECONDS" ]; then
        return 0
    fi
    printf '%s\n' "$now" > "$STATE_DIR/$key.stamp"
    return 1
}

read_env_var() {
    local key="$1" file="$2" value
    [ -r "$file" ] || return 1
    value=$(sed -n "s/^${key}=//p" "$file" | head -n 1 | tr -d '\r')
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    printf '%s' "$value"
}

# PROPFIND the gateway itself (bypassing rclone) and print the HTTP status.
# 207/200 = gateway healthy, 503 = O2 session expired, 000 = no answer.
gateway_probe() {
    local user pass code
    user=$(read_env_var WEBDAV_USERNAME "$GATEWAY_ENV" || true)
    pass=$(read_env_var WEBDAV_PASSWORD "$GATEWAY_ENV" || true)
    if [ -z "$user" ] || [ -z "$pass" ]; then
        printf '000\n'
        return 0
    fi
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' \
        -X PROPFIND -u "$user:$pass" "$GATEWAY_URL/dav/encrypted/" 2>/dev/null || true)
    printf '%s\n' "${code:-000}"
}

restart_service() {
    local service="$1"
    if rate_limited "$service"; then
        log "restart of $service suppressed (already restarted within ${MIN_RESTART_SECONDS}s)"
        return 0
    fi
    log "restarting $service"
    systemctl restart "$service" || log "WARNING: restart of $service failed"
}

restart_jellyfin() {
    local reason="$1"
    if rate_limited "$JELLYFIN_CONTAINER"; then
        log "restart of $JELLYFIN_CONTAINER suppressed (already restarted within ${MIN_RESTART_SECONDS}s)"
        return 0
    fi
    log "restarting $JELLYFIN_CONTAINER ($reason)"
    docker restart "$JELLYFIN_CONTAINER" > /dev/null 2>&1 || \
        log "WARNING: failed to restart $JELLYFIN_CONTAINER"
}

gateway_status=$(gateway_probe)

case "$gateway_status" in
    200|207)
        log_on_change gateway ok "gateway healthy (PROPFIND /dav/encrypted -> $gateway_status)"
        ;;
    503)
        # The O2 session is gone. Restarting rclone/Jellyfin only causes churn.
        log_on_change gateway expired \
            "O2 session expired (gateway returned 503): leaving rclone and Jellyfin alone; run o2-relogin.sh to import a fresh session"
        exit 0
        ;;
    000|502|504)
        log_on_change gateway "upstream-$gateway_status" \
            "gateway unreachable or upstream error (PROPFIND -> $gateway_status): restarting rclone cannot fix this, leaving mounts alone"
        exit 0
        ;;
    *)
        log_on_change gateway "other-$gateway_status" \
            "gateway returned unexpected status $gateway_status on PROPFIND /dav/encrypted: not restarting rclone"
        exit 0
        ;;
esac

NEEDED_RESTART=false

# Probe the crypt mount. `ls` may hang if the FUSE mount is stalled while the
# service still reports active; a restart gives it a fresh FUSE superblock.
if ! timeout 10 ls "$MOUNT_WEBDAV" > /dev/null 2>&1; then
    log "mount $MOUNT_WEBDAV not responding (gateway is healthy)"
    restart_service rclone-movistar-webdav.service
    NEEDED_RESTART=true
fi

# Same probe for the RAW root mount (independent systemd unit).
if ! timeout 10 ls "$MOUNT_ROOT" > /dev/null 2>&1; then
    log "mount $MOUNT_ROOT not responding (gateway is healthy)"
    restart_service rclone-movistar-webdav-root.service
fi

# A restarted FUSE mount invalidates Jellyfin's bind mount.
if [ "$NEEDED_RESTART" = true ]; then
    restart_jellyfin "rclone mount was restarted"
    exit 0
fi

# Even with healthy mounts, Jellyfin's bind can be stale EMPTY: a container
# start that preceded a mount recovery captured the old (empty) FUSE layer.
# The media dir always has entries, so empty means stale.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$JELLYFIN_CONTAINER"; then
    media=$(timeout 10 docker exec "$JELLYFIN_CONTAINER" ls -A "$JELLYFIN_MEDIA_PATH" 2>/dev/null || true)
    if [ -z "$media" ]; then
        restart_jellyfin "stale/empty $JELLYFIN_MEDIA_PATH bind mount"
    fi
fi

exit 0
