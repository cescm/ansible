#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="."
OUT_DIR="./tars_out"
QUARANTINE_BASE="$OUT_DIR/quarantine"

MAX_MB=4092
MAX_BYTES=$(( MAX_MB * 1024 * 1024 ))

JOBS=6

HEADER_PER_FILE=512
TAR_SAFETY_BUFFER=$(( 1 * 1024 * 1024 ))

DRY_RUN=false
VERIFY_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if $DRY_RUN && $VERIFY_ONLY; then echo "ERROR: --dry-run and --verify-only are mutually exclusive." >&2; exit 1; fi

mkdir -p -- "$OUT_DIR" "$QUARANTINE_BASE"

file_size() {
  if stat --version >/dev/null 2>&1; then stat -c%s -- "$1"
  else stat -f%z -- "$1"; fi
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | awk '{print $1}'
  else shasum -a 256 -- "$1" | awk '{print $1}'; fi
}

utc_stamp() { date -u +"%Y%m%dT%H%M%SZ"; }

with_lock() {
  local lockdir="$1"; shift; local tries=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1)); (( tries > 600 )) && { echo "ERROR: lock timeout: $lockdir" >&2; return 1; }; sleep 0.1
  done
  "$@" || { rmdir "$lockdir" 2>/dev/null || true; return 1; }
  rmdir "$lockdir" 2>/dev/null || true
}

INDEX_FILE="$OUT_DIR/index.tsv"
append_index() {
  local line="$1"
  with_lock "$OUT_DIR/.index.lock" bash -c '
    idx="'"$INDEX_FILE"'"
    if [[ ! -f "$idx" ]]; then printf "%s\n" "part\ttarfile\ttar_bytes\tmanifest_txt\tchecksum_file\tquarantine_dir\tfile_count\ttotal_input_bytes\tcreated_utc" > "$idx"; fi
    printf "%s\n" "'"$line"'" >> "$idx"
  '
}

mapfile -t PLAN_LISTS < <(find "$OUT_DIR" -maxdepth 1 -type f -name 'part-*.list' | sort)

if (( ${#PLAN_LISTS[@]} > 0 )); then
  echo "Resume mode: found existing plan (.list files)."
else
  if $VERIFY_ONLY; then echo "VERIFY-ONLY: no plan (.list) files found. Nothing to verify." >&2; exit 1; fi
  if $DRY_RUN; then find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.7z' -o -iname '*.rar' \) -print | sort; exit 0; fi

  echo "No plan found. Creating new batching plan..."
  mapfile -d '' ARCHIVES < <(find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.7z' -o -iname '*.rar' \) -print0 | sort -z)
  if [[ ${#ARCHIVES[@]} -eq 0 ]]; then echo "No .zip / .7z / .rar files found in '$SRC_DIR'."; exit 0; fi

  batch=1; current_files=(); current_size=0
  write_list() { local b="$1"; local -n arr="$2"; local list="$OUT_DIR/part-$(printf "%03d" "$b").list"; (( ${#arr[@]} )) || return; : > "$list"; for f in "${arr[@]}"; do printf '%s\0' "${f#"$SRC_DIR"/}" >> "$list"; done; echo "Planned $(basename "$list") (${#arr[@]} files)"; }

  for f in "${ARCHIVES[@]}"; do
    f="${f%$'\0'}"; sz=$(file_size "$f")
    new_count=$(( ${#current_files[@]} + 1 )); est_overhead=$(( HEADER_PER_FILE * new_count + TAR_SAFETY_BUFFER )); est_total=$(( current_size + sz + est_overhead ))
    if (( est_total > MAX_BYTES )); then write_list "$batch" current_files; batch=$((batch + 1)); current_files=(); current_size=0; fi
    single_est=$(( sz + HEADER_PER_FILE + TAR_SAFETY_BUFFER ))
    if (( single_est > MAX_BYTES )); then echo "WARNING: skipping oversized file: $(basename "$f")"; continue; fi
    current_files+=("$f"); current_size=$(( current_size + sz ))
  done
  write_list "$batch" current_files
  mapfile -t PLAN_LISTS < <(find "$OUT_DIR" -maxdepth 1 -type f -name 'part-*.list' | sort)
fi

TOTAL_PARTS=${#PLAN_LISTS[@]}
echo "Plan parts: $TOTAL_PARTS"

if $VERIFY_ONLY; then
  echo "VERIFY-ONLY: validating outputs and quarantine integrity..."
  ok=0; bad=0; part_idx=0
  for list in "${PLAN_LISTS[@]}"; do
    part_idx=$((part_idx + 1)); part="$(basename "$list" .list)"; tar="$OUT_DIR/$part.tar"; txt="$OUT_DIR/$part.txt"; sha="$OUT_DIR/$part.sha256"; done="$OUT_DIR/$part.done"
    pct=$(( part_idx * 100 / TOTAL_PARTS )); echo "[$pct%] Verifying $part ..."
    if [[ ! -f "$tar" || ! -f "$txt" || ! -f "$sha" || ! -f "$done" ]]; then echo "  FAIL: missing outputs for $part"; bad=$((bad+1)); continue; fi
    tsize=$(file_size "$tar"); if (( tsize > MAX_BYTES )); then echo "  FAIL: tar exceeds limit"; bad=$((bad+1)); continue; fi
    qdir="$(awk -F= '$1=="quarantine_dir"{print $2}' "$done" 2>/dev/null || true)"
    if [[ -z "$qdir" || ! -d "$qdir" ]]; then echo "  FAIL: quarantine_dir invalid"; bad=$((bad+1)); continue; fi
    moved_map="$qdir/moved_map.tsv"; if [[ ! -f "$moved_map" ]]; then echo "  FAIL: moved_map.tsv missing"; bad=$((bad+1)); continue; fi
    mismatch=0; checked=0
    while IFS=$'\t' read -r orel qname sh sz; do
      [[ "$orel" == "original_rel" ]] && continue; [[ -z "$orel" ]] && continue; fpath="$qdir/$qname"
      if [[ ! -f "$fpath" ]]; then mismatch=$((mismatch+1)); continue; fi
      [[ "$(sha256_file "$fpath")" != "$sh" ]] && mismatch=$((mismatch+1)); checked=$((checked+1))
    done < "$moved_map"
    if (( mismatch > 0 )); then echo "  FAIL: $mismatch errors ($checked checked)"; bad=$((bad+1)); continue; fi
    echo "  OK: $checked files verified"; ok=$((ok+1))
  done
  echo "VERIFY summary: OK=$ok FAIL=$bad"; exit $(( bad > 0 ? 2 : 0 ))
fi

wait_for_slot() { while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 0.2; done; }

unique_quarantine_name() {
  local qdir="$1" rel="$2" sha="$3"; local filename base ext sha12 candidate n
  filename="$(basename "$rel")"; ext=""; base="$filename"
  if [[ "$filename" == *.* ]]; then ext=".${filename##*.}"; base="${filename%.*}"; fi
  sha12="${sha:0:12}"; candidate="${base}__${sha12}${ext}"
  if [[ ! -e "$qdir/$candidate" ]]; then printf "%s" "$candidate"; return 0; fi
  n=1; while [[ -e "$qdir/${base}__${sha12}_$n${ext}" ]]; do n=$((n+1)); done; printf "%s" "${base}__${sha12}_$n${ext}"
}

process_part() {
  local list="$1"; local part="$(basename "$list" .list)"
  local tar="$OUT_DIR/$part.tar" txt="$OUT_DIR/$part.txt" sha="$OUT_DIR/$part.sha256" done="$OUT_DIR/$part.done"
  if [[ -f "$done" ]]; then echo "SKIP (done): $part"; return 0; fi
  if $DRY_RUN; then echo "[DRYRUN] would process $part"; return 0; fi

  local existing_qdir=""
  existing_qdir="$(find "$QUARANTINE_BASE" -maxdepth 1 -type d -name "${part}_*" | sort | tail -n 1 || true)"
  local qdir
  if [[ -n "$existing_qdir" ]]; then qdir="$existing_qdir"; else qdir="$QUARANTINE_BASE/${part}_$(utc_stamp)"; mkdir -p -- "$qdir"; fi

  local moved_map="$qdir/moved_map.tsv"
  if [[ ! -f "$moved_map" ]]; then printf "%s\n" "original_rel\tquarantine_name\tsha256\tsize_bytes" > "$moved_map"; fi

  local total_files; total_files=$(tr -cd '\0' < "$list" | wc -c | awk '{print $1}'); [[ -z "$total_files" || "$total_files" -lt 0 ]] && total_files=0

  build_tar_with_limit() {
    local tmp_tar="$tar.tmp.$$"; tar -C "$SRC_DIR" --null -T "$list" -cf "$tmp_tar"
    local actual; actual=$(file_size "$tmp_tar")
    if (( actual <= MAX_BYTES )); then mv -f -- "$tmp_tar" "$tar"; return 0; fi
    rm -f -- "$tmp_tar"; return 1
  }

  if [[ ! -f "$tar" ]]; then
    echo "Creating $part.tar ..."
    if ! build_tar_with_limit; then
      echo "WARNING: tar exceeds limit; trimming $part list..."
      mapfile -d '' items < "$list"
      while (( ${#items[@]} > 0 )); do
        unset 'items[-1]'; : > "$list"
        for rel in "${items[@]}"; do printf '%s\0' "$rel" >> "$list"; done
        (( ${#items[@]} == 0 )) && { echo "ERROR: cannot create tar <= limit for $part"; return 0; }
        build_tar_with_limit && break
      done
    fi
  else
    local tsize; tsize=$(file_size "$tar"); if (( tsize > MAX_BYTES )); then echo "ERROR: existing tar exceeds limit: $tar"; return 1; fi
    echo "Tar exists (resume): $(basename "$tar")"
  fi

  local tar_bytes; tar_bytes=$(file_size "$tar")
  declare -A moved_sha moved_size moved_name
  while IFS=$'\t' read -r orel qname sh sz; do
    [[ "$orel" == "original_rel" ]] && continue; [[ -z "$orel" ]] && continue
    moved_sha["$orel"]="$sh"; moved_size["$orel"]="$sz"; moved_name["$orel"]="$qname"
  done < "$moved_map" || true

  : > "$txt"; : > "$sha"; local file_count=0 total_input_bytes=0
  local idx=0
  while IFS= read -r -d '' rel; do
    idx=$((idx+1)); local pct=0; (( total_files > 0 )) && pct=$(( idx * 100 / total_files ))
    echo "  [$part $pct%] $rel"
    local src="$SRC_DIR/$rel" sh sz
    if [[ -f "$src" ]]; then sz=$(file_size "$src"); sh=$(sha256_file "$src")
    else sh="${moved_sha[$rel]:-}"; sz="${moved_size[$rel]:-}"; if [[ -z "$sh" || -z "$sz" ]]; then echo "WARNING: missing $rel"; continue; fi; fi
    printf "%s %s\n" "$rel" "$sz" >> "$txt"; printf "%s %s\n" "$sh" "$rel" >> "$sha"
    file_count=$((file_count+1)); total_input_bytes=$((total_input_bytes+sz))
  done < "$list"

  idx=0
  while IFS= read -r -d '' rel; do
    idx=$((idx+1)); local pct=0; (( total_files > 0 )) && pct=$(( idx * 100 / total_files ))
    local src="$SRC_DIR/$rel"
    if [[ -n "${moved_name[$rel]:-}" && -f "$qdir/${moved_name[$rel]}" ]]; then continue; fi
    if [[ ! -f "$src" ]]; then echo "WARNING: cannot quarantine missing: $rel"; continue; fi
    local sz_expected sh_expected; sz_expected=$(file_size "$src"); sh_expected=$(sha256_file "$src")
    sh_before=$(sha256_file "$src"); if [[ "$sh_before" != "$sh_expected" ]]; then echo "ERROR: checksum changed before move $rel"; return 1; fi
    local qname dest; qname="$(unique_quarantine_name "$qdir" "$rel" "$sh_expected")"; dest="$qdir/$qname"
    echo "  [$part move $pct%] -> $qname"; mv -f -- "$src" "$dest"
    sh_after=$(sha256_file "$dest"); if [[ "$sh_after" != "$sh_expected" ]]; then echo "ERROR: checksum mismatch after move $rel"; return 1; fi
    printf "%s\t%s\t%s\t%s\n" "$rel" "$qname" "$sh_expected" "$sz_expected" >> "$moved_map"
  done < "$list"

  local created; created="$(utc_stamp)"
  { echo "part=$part"; echo "tar=$(basename "$tar")"; echo "tar_bytes=$tar_bytes"; echo "manifest_txt=$(basename "$txt")"; echo "checksum_file=$(basename "$sha")"; echo "quarantine_dir=$qdir"; echo "file_count=$file_count"; echo "total_input_bytes=$total_input_bytes"; echo "created_utc=$created"; } > "$done"
  append_index "${part}\t$(basename "$tar")\t${tar_bytes}\t$(basename "$txt")\t$(basename "$sha")\t${qdir}\t${file_count}\t${total_input_bytes}\t${created}"
  echo "DONE: $part (tar_bytes=$tar_bytes, files=$file_count)"
}

count_done() { find "$OUT_DIR" -maxdepth 1 -type f -name 'part-*.done' | wc -l | awk '{print $1}'; }
echo "Starting creation with $JOBS parallel jobs..."
for list in "${PLAN_LISTS[@]}"; do
  wait_for_slot
  (process_part "$list"; done_now=$(count_done); overall=$(( done_now * 100 / TOTAL_PARTS )); echo "[OVERALL $overall%] $done_now/$TOTAL_PARTS") &
done
wait; echo "All parts finished."; echo "Index: $INDEX_FILE"
