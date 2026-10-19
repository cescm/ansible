#!/usr/bin/env bash
# remove_tags.sh — Strip 'tags' field from ui/ui_car.json files
#
# Iterates through all subdirectories and removes the 'tags' array
# from each ui/ui_car.json file using jq. Useful for Stash scene
# management where auto-tagged cars need cleanup.
#
# Usage: ./remove_tags.sh
#   Run from the root directory containing car folders.
#
# Dependencies: jq

echo "Removing tags for all cars in all folders"
for folder in *; do
        if [[ -d "$folder" ]]; then
                echo "$folder"
                if [[ ! -f "$folder"/ui/ui_car.json ]]; then
                        echo "File not found!"
                fi
                jq 'del(.tags)' "$folder"/ui/ui_car.json > temp.json && mv temp.json "$folder"/ui/ui_car.json
        fi
done
