#!/bin/bash
# ============================================================================
# rclone-cache-clean.sh
# ============================================================================
# Wipes the VFS cache of the rclone WebDAV mount.
#
# Purpose:
#   Runs as ExecStartPre of rclone-movistar-webdav.service so every mount
#   (re)start begins with a clean VFS cache. Removes /mnt/movistar_webdav_cache
#   vfs metadata under vfs/ and vfsMeta/ so no stale entries survive restarts.
#
# Safety:
#   Refuses to run while the mount is still active (mountpoint -q); aborts
#   with exit 1 to let systemd fail the unit start instead of deleting a cache
#   in use.
# ============================================================================
set -euo pipefail

if mountpoint -q /mnt/movistar_webdav; then
    echo "ERROR: mount /mnt/movistar_webdav still active, aborting cache clean" >&2
    exit 1
fi

if [ -d /mnt/movistar_webdav_cache ]; then
    for dir in vfs vfsMeta; do
        if [ -d "/mnt/movistar_webdav_cache/$dir" ]; then
            rm -rf -- "/mnt/movistar_webdav_cache/$dir"
        fi
    done
fi

exit 0