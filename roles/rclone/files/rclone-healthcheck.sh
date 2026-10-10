#!/bin/bash
set -euo pipefail

MOUNT_WEBDAV="/mnt/movistar_webdav"
MOUNT_ROOT="/mnt/movistar_webdav_root"
JELLYFIN_CONTAINER="jellyfin"
JELLYFIN_MEDIA_PATH="/media3"
LOG_TAG="rclone-healthcheck"
NEEDED_RESTART=false

# Probe the crypt mount (ls may hang if the fuse mount is stalled while
# the service still reports active). On failure restart the service: the mount
# gets a fresh FUSE superblock, so Jellyfin's bind must be refreshed too.
if ! timeout 10 ls "$MOUNT_WEBDAV" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Mount $MOUNT_WEBDAV not responding, restarting webdav service"
    systemctl restart rclone-movistar-webdav.service || \
        logger -t "$LOG_TAG" "WARNING: restart rclone-movistar-webdav.service failed"
    NEEDED_RESTART=true
fi

# Same probe for the RAW root mount (its service is independent).
if ! timeout 10 ls "$MOUNT_ROOT" > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Mount $MOUNT_ROOT not responding, restarting webdav-root service"
    systemctl restart rclone-movistar-webdav-root.service || \
        logger -t "$LOG_TAG" "WARNING: restart rclone-movistar-webdav-root.service failed"
fi

# If rclone was restarted, the FUSE superblock changed and Jellyfin's
# Docker bind mount is now stale. Restart Jellyfin to pick up the new mount.
if [ "$NEEDED_RESTART" = true ]; then
    logger -t "$LOG_TAG" "rclone was restarted, restarting $JELLYFIN_CONTAINER to refresh stale bind mount"
    docker restart "$JELLYFIN_CONTAINER" 2>&1 | logger -t "$LOG_TAG" || \
        logger -t "$LOG_TAG" "WARNING: failed to restart $JELLYFIN_CONTAINER"
    exit 0
fi

# Even with healthy mounts, Jellyfin's /media3 bind can be stale EMPTY: a
# container start that preceded the mount recovery captured the old (empty)
# FUSE layer. The media dir always has entries, so empty == stale bind.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$JELLYFIN_CONTAINER"; then
    media=$(timeout 10 docker exec "$JELLYFIN_CONTAINER" ls -A "$JELLYFIN_MEDIA_PATH" 2>/dev/null || true)
    if [ -z "$media" ]; then
        logger -t "$LOG_TAG" "Jellyfin container $JELLYFIN_MEDIA_PATH is stale/empty, restarting container"
        docker restart "$JELLYFIN_CONTAINER" 2>&1 | logger -t "$LOG_TAG" || \
            logger -t "$LOG_TAG" "WARNING: failed to restart $JELLYFIN_CONTAINER"
    fi
fi

exit 0