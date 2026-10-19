#!/usr/bin/env bash
# compress.sh — Batch folder compression to 7z with parallel jobs
#
# Compresses all subdirectories in the current directory into 7z archives
# using 7z with solid compression. Runs up to MAX_JOBS in parallel.
# Supports pause/resume with the 'P' key.
#
# Usage: ./compress.sh
#   Press 'P' to pause/resume compression
#
# Dependencies: 7z (p7zip), bash
# Config: MAX_JOBS=6, THREADS=2

set -e

MAX_JOBS=6
THREADS=2

paused=0
jobs=0

# Key listener (runs in background)
key_listener() {
  while true; do
    read -rsn1 key
    if [[ "$key" == "p" || "$key" == "P" ]]; then
      if [ "$paused" -eq 0 ]; then
        paused=1
        echo -e "\n⏸ PAUSED (press P to resume)"
      else
        paused=0
        echo -e "\n▶ RESUMED"
      fi
    fi
  done
}

key_listener &

for dir in */; do
  folder="${dir%/}"

  # Pause loop
  while [ "$paused" -eq 1 ]; do
    sleep 0.2
  done

  echo "Compressing: $folder"

  (
    7z a -t7z -mx=7 -mmt="$THREADS" "${folder}.7z" "$folder" &&
    rm -rf "$folder"
  ) &

  jobs=$((jobs + 1))

  if [ "$jobs" -ge "$MAX_JOBS" ]; then
    wait
    jobs=0
  fi
done

wait
echo "✅ Done"
