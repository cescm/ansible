#!/bin/bash
# docker-backup.sh — Docker service directory backup with stop/start orchestration
#
# Iterates over Docker service directories, stops running containers,
# archives the service data with configurable compression and exclusions,
# then restarts services. Supports pre/post hooks per service, retention
# policies (by count and age), and per-service skip markers.
#
# Usage: ./docker-backup.sh [config-path]
#   Default config: /etc/docker-backup/docker-backup.conf
#
# Dependencies: docker, tar, logger
# Hooks: .backup-pre, .backup-post, .backup-skip (per service dir)

set -euo pipefail

CONFIG="${1:-/etc/docker-backup/docker-backup.conf}"
LOG_FILE="/var/log/docker-backup.log"
LOG_TAG="docker-backup"

if [[ ! -f "$CONFIG" ]]; then
    echo "Config $CONFIG not found. Create it or pass a custom path."
    exit 1
fi

source "$CONFIG"

BACKUP_DIR="${BACKUP_DIR:-/mnt/storage/backup/docker}"
SERVICES_DIR="${SERVICES_DIR:-/mnt/docker}"
RETENTION_COUNT="${RETENTION_COUNT:-7}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
COMPRESSION="${COMPRESSION:-zstd}"
SERVICE_FILTER="${SERVICE_FILTER:-}"

EXCLUDE_DIRS=(--exclude=cache --exclude=.cache --exclude=tmp --exclude=.tmp --exclude=node_modules --exclude=.git --exclude=__pycache__)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEST="${BACKUP_DIR}/${TIMESTAMP}"
SUCCESS=0
FAILED=0

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    logger -t "$LOG_TAG" "$*"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
}

has_compose() {
    [[ -f "${1}/compose.yml" || -f "${1}/docker-compose.yml" || -f "${1}/docker-compose.yaml" ]]
}

get_compose_file() {
    [[ -f "${1}/compose.yml" ]] && echo "${1}/compose.yml" && return
    [[ -f "${1}/docker-compose.yml" ]] && echo "${1}/docker-compose.yml" && return
    [[ -f "${1}/docker-compose.yaml" ]] && echo "${1}/docker-compose.yaml" && return
}

mkdir -p "$BACKUP_DIR" "$DEST"

# Build service list
SERVICES=()
if [[ -n "$SERVICE_FILTER" ]]; then
    for svc in $SERVICE_FILTER; do
        if [[ -d "${SERVICES_DIR}/${svc}" ]]; then
            SERVICES+=("$svc")
        else
            log "WARN: Service '$svc' not found in ${SERVICES_DIR}"
        fi
    done
else
    for d in "${SERVICES_DIR}"/*/; do
        [[ -d "$d" ]] && SERVICES+=("$(basename "$d")")
    done
fi

log "Starting Docker backup — ${#SERVICES[@]} services → ${DEST}"

for SERVICE in "${SERVICES[@]}"; do
    SERVICE_DIR="${SERVICES_DIR}/${SERVICE}"
    ARCHIVE="${DEST}/${SERVICE}.tar.zst"
    SERVICE_OK=true
    WAS_RUNNING=false
    COMPOSE_FILE=""

    if [[ -f "${SERVICE_DIR}/.backup-skip" ]]; then
        log "[${SERVICE}] SKIP — marker present"
        continue
    fi

    if has_compose "$SERVICE_DIR"; then
        COMPOSE_FILE=$(get_compose_file "$SERVICE_DIR")
        if docker compose -f "$COMPOSE_FILE" ps --status running -q 2>/dev/null | grep -q .; then
            WAS_RUNNING=true
        fi
    else
        if docker ps --format '{{.Names}}' | grep -qFx "$SERVICE"; then
            WAS_RUNNING=true
        fi
    fi

    # Pre-stop hook
    if [[ -x "${SERVICE_DIR}/.backup-pre" ]]; then
        log "[${SERVICE}] Running pre-hook..."
        "${SERVICE_DIR}/.backup-pre" "$DEST" >> "${DEST}/${SERVICE}.log" 2>&1 || true
    fi

    # Stop
    if [[ "$WAS_RUNNING" == true ]]; then
        log "[${SERVICE}] Stopping..."
        if [[ -n "$COMPOSE_FILE" ]]; then
            docker compose -f "$COMPOSE_FILE" down --timeout 30 >> "${DEST}/${SERVICE}.log" 2>&1 || true
        else
            docker stop "$SERVICE" -t 30 >> "${DEST}/${SERVICE}.log" 2>&1 || true
        fi
    fi

    # Archive
    log "[${SERVICE}] Archiving..."
    if tar --"$COMPRESSION" -cf "$ARCHIVE" -C "$SERVICE_DIR" "${EXCLUDE_DIRS[@]}" . >> "${DEST}/${SERVICE}.log" 2>&1; then
        SIZE=$(stat -c%s "$ARCHIVE" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "?")
        log "[${SERVICE}] OK (${SIZE})"
    else
        log "[${SERVICE}] FAILED"
        SERVICE_OK=false
    fi

    # Restore running state
    if [[ "$WAS_RUNNING" == true ]]; then
        log "[${SERVICE}] Starting..."
        if [[ -n "$COMPOSE_FILE" ]]; then
            docker compose -f "$COMPOSE_FILE" up -d >> "${DEST}/${SERVICE}.log" 2>&1 || true
        else
            docker start "$SERVICE" >> "${DEST}/${SERVICE}.log" 2>&1 || true
        fi
    fi

    # Post-start hook
    if [[ -x "${SERVICE_DIR}/.backup-post" ]]; then
        log "[${SERVICE}] Running post-hook..."
        "${SERVICE_DIR}/.backup-post" "$DEST" >> "${DEST}/${SERVICE}.log" 2>&1 || true
    fi

    if [[ "$SERVICE_OK" == true ]]; then SUCCESS=$((SUCCESS + 1)); else FAILED=$((FAILED + 1)); fi
done

echo "$TIMESTAMP" > "${DEST}/.timestamp"

# Retention: keep newest N, delete older than X days
log "Retention: keep ${RETENTION_COUNT}, delete >${RETENTION_DAYS}d"
mapfile -t SNAPSHOTS < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]' | sort -r || true)
DELETED=0

for i in "${!SNAPSHOTS[@]}"; do
    SNAP="${SNAPSHOTS[$i]}"
    NAME=$(basename "$SNAP")

    if [[ "$i" -lt "$RETENTION_COUNT" ]]; then
        log "  KEEP (newest #$((i+1))): $NAME"
        continue
    fi

    AGE_DAYS=999
    if [[ "$NAME" =~ ^([0-9]{8})_([0-9]{6})$ ]]; then
        SNAP_EPOCH=$(date -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]:0:2}:${BASH_REMATCH[2]:2:2}:${BASH_REMATCH[2]:4:2}" +%s 2>/dev/null || echo 0)
        [[ "$SNAP_EPOCH" -gt 0 ]] && AGE_DAYS=$(( ($(date +%s) - SNAP_EPOCH) / 86400 ))
    fi

    if [[ "$AGE_DAYS" -gt "$RETENTION_DAYS" ]]; then
        log "  DELETE (${AGE_DAYS}d): $NAME"
        rm -rf "$SNAP"
        ((DELETED++))
    else
        log "  KEEP (${AGE_DAYS}d): $NAME"
    fi
done

# Summary
if [[ "$FAILED" -eq 0 ]]; then
    log "Backup complete: ${SUCCESS} OK, ${DELETED} pruned"
else
    log "Backup finished with ERRORS: ${SUCCESS} OK, ${FAILED} FAILED, ${DELETED} pruned"
fi

exit "$FAILED"
