#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="."
OUT_DIR="./tars_out"
QUARANTINE_BASE="$OUT_DIR/quarantine"

EXECUTE=false
OVERWRITE=false
ONLY_PART=""

while (( $# )); do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --overwrite) OVERWRITE=true; shift ;;
    --only) ONLY_PART="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$f" | awk '{print $1}'
  else
    echo "ERROR: sha256sum or shasum required" >&2; exit 1
  fi
}

restore_root="$SRC_DIR"
conflict_dir="$SRC_DIR/restored"
if ! $OVERWRITE; then mkdir -p -- "$conflict_dir"; fi

mapfile -t MAPS < <(find "$QUARANTINE_BASE" -type f -name 'moved_map.tsv' | sort)
if (( ${#MAPS[@]} == 0 )); then echo "No moved_map.tsv files found under $QUARANTINE_BASE"; exit 0; fi
echo "Found ${#MAPS[@]} quarantine map(s)."
$EXECUTE || echo "DRY-RUN mode (use --execute to restore files)."
$OVERWRITE && echo "Overwrite mode ENABLED."

restored=0; skipped=0; failed=0

for mapfile in "${MAPS[@]}"; do
  qdir="$(dirname "$mapfile")"
  qbase="$(basename "$qdir")"; part="${qbase%%_*}"
  [[ -n "$ONLY_PART" && "$part" != "$ONLY_PART" ]] && continue
  echo "Processing: $mapfile (part=$part)"

  while IFS=$'\t' read -r original_rel qname sha size_bytes; do
    [[ "$original_rel" == "original_rel" ]] && continue; [[ -z "$original_rel" ]] && continue
    src_path="$qdir/$qname"
    if [[ ! -f "$src_path" ]]; then echo "MISSING: $src_path"; skipped=$((skipped+1)); continue; fi
    dest_path="$restore_root/$original_rel"; dest_dir="$(dirname "$dest_path")"
    final_dest="$dest_path"
    if [[ -e "$dest_path" && "$OVERWRITE" == false ]]; then
      final_dest="$conflict_dir/$original_rel"; dest_dir="$(dirname "$final_dest")"
      echo "CONFLICT: $dest_path -> $final_dest"
    fi
    if $EXECUTE; then
      mkdir -p -- "$dest_dir"
      if $OVERWRITE; then mv -f -- "$src_path" "$final_dest"
      else mv -n -- "$src_path" "$final_dest" || { echo "FAILED: $src_path"; failed=$((failed+1)); continue; }; fi
      sha_after="$(sha256_file "$final_dest")"
      if [[ "$sha_after" != "$sha" ]]; then echo "CHECKSUM FAIL: $final_dest"; failed=$((failed+1)); continue; fi
      restored=$((restored+1))
    else echo "[DRYRUN] restore: $src_path -> $final_dest"; restored=$((restored+1)); fi
  done < "$mapfile"
done

echo "Restore summary: restored=$restored skipped=$skipped failed=$failed"
if ! $EXECUTE; then echo "Dry-run. Re-run with --execute."; fi
