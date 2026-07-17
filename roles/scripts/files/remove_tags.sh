#!/usr/bin/env bash
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
