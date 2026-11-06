#!/bin/bash
# rclone-cache-flush.sh — Periodically flush VFS cache for rclone mounts
# Runs via systemd timer every 30 minutes to prevent cache from growing
# beyond expected bounds.

set -uo pipefail

LOG_TAG="rclone-cache-flush"

# Flush VFS cache for proxy mount (port 5574)
if curl -s -m 5 http://127.0.0.1:5574/vfs/forget 2>/dev/null | grep -q "OK\|null\|{}"; then
    logger -t "$LOG_TAG" "Flushed VFS cache for movistar_proxy (port 5574)"
else
    # Try alternative: use rclone rc command
    rclone rc vfs/forget --rc-addr 127.0.0.1:5574 2>/dev/null && \
        logger -t "$LOG_TAG" "Flushed VFS cache for movistar_proxy (port 5574)" || \
        logger -t "$LOG_TAG" "WARNING: failed to flush VFS cache for movistar_proxy"
fi

# Flush VFS cache for proxy root mount (port 5575)
if curl -s -m 5 http://127.0.0.1:5575/vfs/forget 2>/dev/null | grep -q "OK\|null\|{}"; then
    logger -t "$LOG_TAG" "Flushed VFS cache for movistar_proxy_root (port 5575)"
else
    rclone rc vfs/forget --rc-addr 127.0.0.1:5575 2>/dev/null && \
        logger -t "$LOG_TAG" "Flushed VFS cache for movistar_proxy_root (port 5575)" || \
        logger -t "$LOG_TAG" "WARNING: failed to flush VFS cache for movistar_proxy_root"
fi

exit 0