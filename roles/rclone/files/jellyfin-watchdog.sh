#!/bin/bash
# jellyfin-watchdog.sh — Restart Jellyfin when the rclone WebDAV mount is lost
#
# Jellyfin maps /media3 -> /mnt/movistar_webdav (rclone fuse mount).
# When the Movistar session expires and is re-established, the FUSE mount
# often stalls and Jellyfin keeps a stale handle, losing the remote library.
# This watchdog detects a non-responsive mount and restarts the jellyfin
# container so it re-reads the mount.
#
# Usage: ./jellyfin-watchdog.sh
#   Typically run via systemd timer (every few minutes).
#
# Dependencies: timeout, ls, docker
# Container: jellyfin

set -euo pipefail

MOUNT="/mnt/movistar_webdav"
LOG_TAG="jellyfin-watchdog"

# If the mount point isn't even present, nothing to watch
if [ ! -d "$MOUNT" ]; then
    exit 0
fi

# Test mount responsiveness (ls may hang if the fuse mount is stalled)
if timeout 10 ls "$MOUNT" > /dev/null 2>&1; then
    exit 0
fi

# Mount is stalled/unresponsive -> restart Jellyfin so it re-reads the mount
logger -t "$LOG_TAG" "Mount $MOUNT not responding, restarting jellyfin container"
if ! docker restart jellyfin > /dev/null 2>&1; then
    logger -t "$LOG_TAG" "Failed to restart jellyfin container"
    exit 1
fi

logger -t "$LOG_TAG" "jellyfin container restarted successfully"
