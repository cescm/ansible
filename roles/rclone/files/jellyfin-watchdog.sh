#!/bin/bash
# jellyfin-watchdog.sh — Restart Jellyfin when it loses the rclone WebDAV mount
#
# Jellyfin maps /media3 -> /mnt/movistar_webdav/media (rclone fuse mount).
# When the Movistar session expires and is re-established, the FUSE mount
# stalls (host ls hangs / gateway 503) and Jellyfin keeps a stale handle.
# Also, if the container started BEFORE the mount recovered, its /media3 bind
# is stale and EMPTY. The media dir always has entries, so empty == stale.
# This watchdog detects both conditions and restarts the container so it
# re-reads the mount.
#
# Usage: ./jellyfin-watchdog.sh   (via systemd timer, every few minutes)
# Dependencies: timeout, ls, docker
# Container: jellyfin

set -euo pipefail

MOUNT="/mnt/movistar_webdav"
JF_CONTAINER="jellyfin"
JF_MEDIA="/media3"
LOG_TAG="jellyfin-watchdog"

# If the mount point isn't even present, nothing to watch
if [ ! -d "$MOUNT" ]; then
    exit 0
fi

# Test /media3 inside the container (ls may hang if the fuse is stalled; an
# empty output means stale bind captured before the mount recovered).
media=$(timeout 10 docker exec "$JF_CONTAINER" ls -A "$JF_MEDIA" 2>/dev/null || true)

if [ -z "$media" ]; then
    logger -t "$LOG_TAG" "$JF_MEDIA inside $JF_CONTAINER is empty/stalled, restarting $JF_CONTAINER"
    if ! docker restart "$JF_CONTAINER" > /dev/null 2>&1; then
        logger -t "$LOG_TAG" "Failed to restart $JF_CONTAINER"
        exit 1
    fi
    logger -t "$LOG_TAG" "$JF_CONTAINER restarted"
else
    exit 0
fi