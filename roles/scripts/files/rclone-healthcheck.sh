#!/bin/bash
set -euo pipefail

MOUNT_WEBDAV="/mnt/movistar_webdav"
JELLYFIN_CONTAINER="jellyfin"
JELLYFIN_MEDIA_PATH="/media2"
LOG_TAG="rclone-healthcheck"
NEEDED_RESTART=false

if ! timeout 10 ls "$MOUNT_WEBDAV" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Mount $MOUNT_WEBDAV not responding, restarting webdav service"
    systemctl restart rclone-movistar-webdav.service
    NEEDED_RESTART=true
fi

# If rclone was restarted, the FUSE superblock changed and Jellyfin's
# Docker bind mount is now stale. Restart Jellyfin to pick up the new mount.
if [ "$NEEDED_RESTART" = true ]; then
    logger -t "$LOG_TAG" "rclone was restarted, restarting $JELLYFIN_CONTAINER to refresh stale bind mount"
    docker restart "$JELLYFIN_CONTAINER" 2>&1 | logger -t "$LOG_TAG" || \
        logger -t "$LOG_TAG" "WARNING: failed to restart $JELLYFIN_CONTAINER"
    exit 0
fi

# Also check Jellyfin container mount even if the host mount looks healthy.
# The bind mount can be stale from a previous rclone restart that already
# recovered on the host.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$JELLYFIN_CONTAINER"; then
    if ! timeout 10 docker exec "$JELLYFIN_CONTAINER" ls "$JELLYFIN_MEDIA_PATH" > /dev/null 2>&1; then
        logger -t "$LOG_TAG" "Jellyfin container mount $JELLYFIN_MEDIA_PATH is stale, restarting container"
        docker restart "$JELLYFIN_CONTAINER" 2>&1 | logger -t "$LOG_TAG" || \
            logger -t "$LOG_TAG" "WARNING: failed to restart $JELLYFIN_CONTAINER"
    fi
fi