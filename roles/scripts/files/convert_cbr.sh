#!/bin/bash

# --- Configuration ---
DELETE_ORIGINAL="yes"        # set to "yes" to delete .cbr after conversion
MAX_JOBS=4                   # number of parallel conversions
COMICS_DIR="$1"              # directory containing your comics

# --- Check input ---
if [ -z "$COMICS_DIR" ]; then
    echo "Usage: $0 /path/to/comics"
    exit 1
fi

echo "Starting conversion in: $COMICS_DIR"

# --- Export variables for child processes ---
export DELETE_ORIGINAL

# --- Prepare folders ---
CORRUPT_DIR="$COMICS_DIR/Corrupt"
mkdir -p "$CORRUPT_DIR"
FAILED_LOG="$CORRUPT_DIR/failed.txt"
: > "$FAILED_LOG"   # clear previous log

# --- Count total files ---
TOTAL=$(find "$COMICS_DIR" -type f -name "*.cbr" | wc -l)
echo "Found $TOTAL CBR files to convert."

# --- FIFO for progress reporting ---
FIFO=$(mktemp -u)
mkfifo "$FIFO"
exec 3<>"$FIFO"
rm "$FIFO"

COMPLETED=0

# --- Conversion function ---
convert_file() {
    cbr_file="$1"
    temp_dir=$(mktemp -d)
    [ ! -d "$temp_dir" ] && echo "ERROR: Could not create temp dir. Skipping." >&2 && echo "done" >&3 && return

    # Extract archive
    if command -v unar >/dev/null 2>&1; then
        unar -o "$temp_dir" "$cbr_file" >/dev/null
        status=$?
    elif [ -x "/usr/bin/unrar" ]; then
        /usr/bin/unrar e -o+ "$cbr_file" "$temp_dir" >/dev/null
        status=$?
    else
        echo "ERROR: Neither unar nor unrar found. Install one. Skipping." >&2
        rm -rf -- "$temp_dir"
        echo "done" >&3
        return
    fi

    # Handle extraction failure
    if [ $status -ne 0 ]; then
        echo "ERROR: Extraction failed for: $cbr_file" >&2
        mv "$cbr_file" "$CORRUPT_DIR/"
        echo "$cbr_file" >> "$FAILED_LOG"
        echo "MOVED: $cbr_file -> $CORRUPT_DIR"
        rm -rf -- "$temp_dir"
        echo "done" >&3
        return
    fi

    # Prepare CBZ path
    base_name=$(basename "$cbr_file" .cbr)
    dir_name=$(dirname "$cbr_file")
    cbz_file="$dir_name/$base_name.cbz"

    # Skip if CBZ exists
    [ -f "$cbz_file" ] && rm -rf -- "$temp_dir" && echo "done" >&3 && return

    # Zip images in natural order
    find "$temp_dir" -type f | sort -V | zip -0 -j "$cbz_file" -@ >/dev/null
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create CBZ: $cbr_file" >&2
        mv "$cbr_file" "$CORRUPT_DIR/"
        echo "$cbr_file" >> "$FAILED_LOG"
        echo "MOVED: $cbr_file -> $CORRUPT_DIR"
        rm -rf -- "$temp_dir"
        echo "done" >&3
        return
    fi

    # Clean up temporary extraction folder
    rm -rf -- "$temp_dir"

    # Delete original CBR if requested
    if [ "$DELETE_ORIGINAL" = "yes" ]; then
        rm -- "$cbr_file"
        echo "DELETED: $cbr_file"
    fi

    echo "SUCCESS: Converted to $cbz_file"
    echo "done" >&3
}

export -f convert_file
export CORRUPT_DIR
export FAILED_LOG

# --- Track progress ---
(
    while read -r _; do
        COMPLETED=$((COMPLETED+1))
        echo -ne "Progress: $COMPLETED/$TOTAL\r"
    done <&3
) &

# --- Main conversion loop ---
find "$COMICS_DIR" -type f -name "*.cbr" -print0 \
    | xargs -0 -n1 -P"$MAX_JOBS" bash -c 'convert_file "$0"'

wait

echo -e "\n---"
echo "Conversion complete."
echo "Check $CORRUPT_DIR for any corrupt files."
