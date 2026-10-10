#!/bin/bash
#
# Cleans the VFS cache of the RAW gateway root mount (webdav: remote).
# Runs as ExecStartPre of rclone-movistar-webdav-root.service.
# Refuses while the mount is still active (safety: never delete a cache in use).
set -euo pipefail

MOUNT="/mnt/movistar_webdav_root"
CACHE="/mnt/movistar_webdav_root_cache"

if mountpoint -q "$MOUNT"; then
    echo "ERROR: mount $MOUNT still active, aborting cache clean" >&2
    exit 1
fi

if [ -d "$CACHE" ]; then
    for dir in vfs vfsMeta; do
        if [ -d "$CACHE/$dir" ]; then
            rm -rf -- "$CACHE/$dir"
        fi
    done
fi

exit 0