#!/bin/bash
# ============================================================================
# rclone-rc-to-prometheus.sh
# ============================================================================
# Converts the rclone mount RC-API stats into Prometheus textfile format.
#
# Purpose:
#   The rclone mount unit (rclone-movistar-webdav.service) runs with
#   --rc --rc-addr 127.0.0.1:5572, exposing the RC API on localhost.
#   This script POSTs to /vfs/stats and /core/stats and writes Prometheus
#   metrics to the node-exporter textfile directory so they are scraped by
#   Prometheus and rendered by the Grafana dashboard 'Rclone Mounts'
#   (uid rclone-mounts).
#
# Scheduling:
#   systemd units rclone-rc-exporter.service (oneshot, runs this script) +
#   rclone-rc-exporter.timer (every 30s: OnBootSec=30s OnUnitActiveSec=30s).
#
# Output: $OUT_DIR/rclone.prom  (atomic write via TMP + mv).
#   Down = only 'rclone_mount_up 0' is written; Up = full metric set.
#
# Metrics emitted:
#   rclone_mount_up, rclone_vfs_cache_objects, rclone_vfs_cache_bytes,
#   rclone_vfs_cache_upload_queued, rclone_vfs_cache_upload_in_progress,
#   rclone_vfs_cache_errored_files, rclone_vfs_cache_out_of_space,
#   rclone_vfs_in_use, rclone_core_transferred_bytes (counter),
#   rclone_core_errors (counter), rclone_core_transfers_in_flight.
#
# Note: rclone RC endpoints require HTTP POST (GET returns 404).
# ============================================================================
set -u

RC_ADDR="${RCLONE_RC_ADDR:-127.0.0.1:5572}"
OUT_DIR="${RCLONE_TEXTFILE_DIR:-/mnt/docker/monitoring/textfile}"
OUT_FILE="$OUT_DIR/rclone.prom"

TMP="$OUT_FILE.$$"

unset vfs_stats
vfs_stats=$(curl -s -X POST --max-time 10 "http://${RC_ADDR}/vfs/stats")

if [ -z "$vfs_stats" ]; then
    printf 'rclone_mount_up 0\n' > "$TMP"
    mv "$TMP" "$OUT_FILE"
    exit 0
fi

unset core_stats
core_stats=$(curl -s -X POST --max-time 10 "http://${RC_ADDR}/core/stats")

printf '%s\n' \
    "${vfs_stats}" \
    "${core_stats}" \
| python3 -c '
import json, sys

raw = sys.stdin.read()
parts = raw.split("\n")
merged = {}
buf = ""
for line in parts:
    buf += line
    try:
        merged = json.loads(buf)
        buf = ""
    except json.JSONDecodeError:
        continue

vfs = merged.get("diskCache", {})
core = merged.get("core", merged)

out = []
out.append("rclone_mount_up 1")

def gauge(name, value):
    out.append(f"{name} {value}")

cached = merged.get("diskCache", {})
out.append("# HELP rclone_vfs_cache_objects Number of files in the VFS cache.")
out.append("# TYPE rclone_vfs_cache_objects gauge")
gauge("rclone_vfs_cache_objects", cached.get("files", 0))
out.append("# HELP rclone_vfs_cache_bytes Bytes used by the VFS cache.")
out.append("# TYPE rclone_vfs_cache_bytes gauge")
gauge("rclone_vfs_cache_bytes", cached.get("bytesUsed", 0))
out.append("# HELP rclone_vfs_cache_upload_queued Files waiting to be uploaded.")
out.append("# TYPE rclone_vfs_cache_upload_queued gauge")
gauge("rclone_vfs_cache_upload_queued", cached.get("uploadsQueued", 0))
out.append("# HELP rclone_vfs_cache_upload_in_progress Uploads in progress.")
out.append("# TYPE rclone_vfs_cache_upload_in_progress gauge")
gauge("rclone_vfs_cache_upload_in_progress", cached.get("uploadsInProgress", 0))
out.append("# HELP rclone_vfs_cache_errored_files Files in cache that failed to upload.")
out.append("# TYPE rclone_vfs_cache_errored_files gauge")
gauge("rclone_vfs_cache_errored_files", cached.get("erroredFiles", 0))
out.append("# HELP rclone_vfs_cache_out_of_space Whether the cache is out of space (1/0).")
out.append("# TYPE rclone_vfs_cache_out_of_space gauge")
gauge("rclone_vfs_cache_out_of_space", 1 if cached.get("outOfSpace") else 0)
out.append("# HELP rclone_vfs_in_use Number of files open in the VFS.")
out.append("# TYPE rclone_vfs_in_use gauge")
gauge("rclone_vfs_in_use", merged.get("inUse", 0))

if "bytes" in core or "transferred" in core:
    out.append("# HELP rclone_core_transferred_bytes Total bytes transferred.")
    out.append("# TYPE rclone_core_transferred_bytes counter")
    gauge("rclone_core_transferred_bytes", core.get("bytes", 0))
    out.append("# HELP rclone_core_errors Cumulative errors.")
    out.append("# TYPE rclone_core_errors counter")
    gauge("rclone_core_errors", core.get("errors", 0))
    out.append("# HELP rclone_core_transfers_in_flight Transfers currently active.")
    out.append("# TYPE rclone_core_transfers_in_flight gauge")
    transferring = core.get("transferring", [])
    gauge("rclone_core_transfers_in_flight", len(transferring) if isinstance(transferring, list) else 0)

print("\n".join(out))
' > "$TMP"

if [ -f "$TMP" ]; then
    mv "$TMP" "$OUT_FILE"
else
    printf 'rclone_mount_up 0\n' > "$OUT_FILE"
fi

exit 0