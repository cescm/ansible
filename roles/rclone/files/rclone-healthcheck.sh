#!/bin/bash
set -euo pipefail

MOUNT_RAW="/mnt/movistar"
MOUNT_CRYPT="/mnt/movistar_enc"
MOUNT_WEBDAV="/mnt/movistar_webdav"
HOST="micloud.movistar.es"
LOG_TAG="rclone-healthcheck"

if ! getent hosts "$HOST" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "DNS resolution failed for $HOST, skipping check"
    exit 0
fi

if ! timeout 10 ls "$MOUNT_RAW" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Mount $MOUNT_RAW not responding, restarting raw service"
    systemctl restart rclone-movistar.service
fi

if ! timeout 10 ls "$MOUNT_CRYPT" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Mount $MOUNT_CRYPT not responding, restarting crypt service"
    systemctl restart rclone-movistar-crypt.service
fi

if ! timeout 10 ls "$MOUNT_WEBDAV" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Mount $MOUNT_WEBDAV not responding, restarting webdav service"
    systemctl restart rclone-movistar-webdav.service
fi
