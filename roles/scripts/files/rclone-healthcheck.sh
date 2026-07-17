#!/bin/bash
set -euo pipefail

MOUNT_POINT="/mnt/movistar"
HOST="micloud.movistar.es"
LOG_TAG="rclone-healthcheck"

if ! getent hosts "$HOST" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "DNS resolution failed for $HOST, skipping check"
    exit 0
fi

if ! timeout 10 ls "$MOUNT_POINT" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Mount $MOUNT_POINT not responding but DNS OK, restarting raw service"
    systemctl restart rclone-movistar.service
fi
