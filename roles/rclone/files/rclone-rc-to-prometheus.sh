#!/bin/bash
# ============================================================================
# rclone-rc-to-prometheus.sh
# ============================================================================
# Converts the rclone mount RC-API stats into Prometheus textfile format.
#
# Purpose:
#   Both rclone mount units run with --rc --rc-addr:
#     rclone-movistar-webdav.service      : 127.0.0.1:5572 (crypt mount)
#     rclone-movistar-webdav-root.service : 127.0.0.1:5573 (RAW root mount)
#   This script POSTs to /vfs/stats and /core/stats for each mount and writes
#   Prometheus metrics to the node-exporter textfile directory so they are
#   scraped by Prometheus and rendered by Grafana.
#
# Scheduling:
#   systemd units rclone-rc-exporter.service (oneshot, runs this script) +
#   rclone-rc-exporter.timer (every 30s: OnBootSec=30s OnUnitActiveSec=30s).
#
# Output:
#   $OUT_DIR/rclone.prom       (crypt mount, metric names unchanged)
#   $OUT_DIR/rclone-root.prom  (RAW root mount, prefixed rclone_root_* so both
#                               files coexist without duplicate-series/HELP)
#   Down = only '..._mount_up 0' is written; Up = full metric set.
#
# Metrics emitted (crypt): rclone_mount_up, rclone_vfs_cache_objects,
#   rclone_vfs_cache_bytes, rclone_vfs_cache_upload_queued,
#   rclone_vfs_cache_upload_in_progress, rclone_vfs_cache_errored_files,
#   rclone_vfs_cache_out_of_space, rclone_vfs_in_use,
#   rclone_core_transferred_bytes (counter), rclone_core_errors (counter),
#   rclone_core_transfers_in_flight.  Root: same set prefixed rclone_root_.
#
# Note: rclone RC endpoints require HTTP POST (GET returns 404).
# ============================================================================
set -u

OUT_DIR="${RCLONE_TEXTFILE_DIR:-/mnt/docker/monitoring/textfile}"
mkdir -p "$OUT_DIR"

emit() {
  local rc_addr="$1"
  local prefix="$2"
  local out_file="$3"
  local tmp="$out_file.$$"
  local vfs_stats core_stats

  vfs_stats=$(curl -s -X POST --max-time 10 "http://${rc_addr}/vfs/stats")

  if [ -z "$vfs_stats" ]; then
    printf 'rclone_%smount_up 0\n' "$prefix" > "$tmp"
    mv "$tmp" "$out_file"
    return 0
  fi

  core_stats=$(curl -s -X POST --max-time 10 "http://${rc_addr}/core/stats")

  printf '%s\n' "${vfs_stats}" "${core_stats}" \
  | PREFIX="$prefix" python3 -c '
import json, sys, os

prefix = os.environ.get("PREFIX", "")

raw = sys.stdin.read()
parts = raw.split("\n")
merged = {}
buf = ""
for line in parts:
    buf += line
    try:
        parsed = json.loads(buf)
        merged.update(parsed)
        buf = ""
    except json.JSONDecodeError:
        continue

cached = merged.get("diskCache", {})
core = merged.get("core", merged)

out = []
out.append(f"rclone_{prefix}mount_up 1")

def gauge(name, value):
    out.append(f"rclone_{prefix}{name} {value}")

out.append(f"# HELP rclone_{prefix}vfs_cache_objects Number of files in the VFS cache.")
out.append(f"# TYPE rclone_{prefix}vfs_cache_objects gauge")
gauge("vfs_cache_objects", cached.get("files", 0))
out.append(f"# HELP rclone_{prefix}vfs_cache_bytes Bytes used by the VFS cache.")
out.append(f"# TYPE rclone_{prefix}vfs_cache_bytes gauge")
gauge("vfs_cache_bytes", cached.get("bytesUsed", 0))
out.append(f"# HELP rclone_{prefix}vfs_cache_upload_queued Files waiting to be uploaded.")
out.append(f"# TYPE rclone_{prefix}vfs_cache_upload_queued gauge")
gauge("vfs_cache_upload_queued", cached.get("uploadsQueued", 0))
out.append(f"# HELP rclone_{prefix}vfs_cache_upload_in_progress Uploads in progress.")
out.append(f"# TYPE rclone_{prefix}vfs_cache_upload_in_progress gauge")
gauge("vfs_cache_upload_in_progress", cached.get("uploadsInProgress", 0))
out.append(f"# HELP rclone_{prefix}vfs_cache_errored_files Files in cache that failed to upload.")
out.append(f"# TYPE rclone_{prefix}vfs_cache_errored_files gauge")
gauge("vfs_cache_errored_files", cached.get("erroredFiles", 0))
out.append(f"# HELP rclone_{prefix}vfs_cache_out_of_space Whether the cache is out of space (1/0).")
out.append(f"# TYPE rclone_{prefix}vfs_cache_out_of_space gauge")
gauge("vfs_cache_out_of_space", 1 if cached.get("outOfSpace") else 0)
out.append(f"# HELP rclone_{prefix}vfs_in_use Number of files open in the VFS.")
out.append(f"# TYPE rclone_{prefix}vfs_in_use gauge")
gauge("vfs_in_use", merged.get("inUse", 0))

if "bytes" in core or "transferred" in core:
    out.append(f"# HELP rclone_{prefix}core_transferred_bytes Total bytes transferred.")
    out.append(f"# TYPE rclone_{prefix}core_transferred_bytes counter")
    gauge("core_transferred_bytes", core.get("bytes", 0))
    out.append(f"# HELP rclone_{prefix}core_errors Cumulative errors.")
    out.append(f"# TYPE rclone_{prefix}core_errors counter")
    gauge("core_errors", core.get("errors", 0))
    out.append(f"# HELP rclone_{prefix}core_transfers_in_flight Transfers currently active.")
    out.append(f"# TYPE rclone_{prefix}core_transfers_in_flight gauge")
    transferring = core.get("transferring", [])
    gauge("core_transfers_in_flight", len(transferring) if isinstance(transferring, list) else 0)

print("\n".join(out))
' > "$tmp"

  if [ -s "$tmp" ]; then
    mv "$tmp" "$out_file"
  else
    printf 'rclone_%smount_up 0\n' "$prefix" > "$out_file"
  fi
}

# Crypt mount: 127.0.0.1:5572 -> rclone.prom (backwards-compatible names)
emit 127.0.0.1:5572 "" "$OUT_DIR/rclone.prom"
# RAW root mount: 127.0.0.1:5573 -> rclone-root.prom (rclone_root_* namespace)
emit 127.0.0.1:5573 "root_" "$OUT_DIR/rclone-root.prom"

exit 0