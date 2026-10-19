#!/usr/bin/env bash
# file2folder.sh — Move each file into its own subdirectory
#
# Takes a directory and moves each file inside it into a new subfolder
# named after the file's basename (without extension). Skips files
# whose target folder already exists.
#
# Usage: ./file2folder.sh [directory]
#   Defaults to current directory if no argument given.
#
# Dependencies: bash

set -euo pipefail

dir="${1:-.}"

for f in "$dir"/*; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  name="${base%.*}"
  if [ -d "$dir/$name" ]; then
    echo "Ya existe la carpeta '$name', saltando '$base'"
    continue
  fi
  mkdir "$dir/$name"
  mv "$f" "$dir/$name/"
done
