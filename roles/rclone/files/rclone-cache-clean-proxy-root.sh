#!/bin/bash
set -euo pipefail

if mountpoint -q /mnt/movistar_proxy_root; then
    echo "ERROR: mount /mnt/movistar_proxy_root still active, aborting cache clean" >&2
    exit 1
fi

if [ -d /mnt/movistar_proxy_root_cache ]; then
    for dir in vfs vfsMeta; do
        if [ -d "/mnt/movistar_proxy_root_cache/$dir" ]; then
            rm -rf -- "/mnt/movistar_proxy_root_cache/$dir"
        fi
    done
fi

exit 0