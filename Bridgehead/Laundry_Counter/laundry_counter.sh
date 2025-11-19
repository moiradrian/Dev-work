#!/usr/bin/env bash

BASE="/QSdata/ocaroot"
grand_total=0

# Make globs that match nothing expand to nothing (instead of themselves)
shopt -s nullglob

for first_level in "$BASE"/*; do
    # Only directories
    [[ -d "$first_level" ]] || continue

    # Name must be an integer
    name1=$(basename "$first_level")
    [[ "$name1" =~ ^[0-9]+$ ]] || continue

    laundry_root="$first_level/.ocarina_hidden/laundry"
    [[ -d "$laundry_root" ]] || continue

    # Second integer directory level under .../.ocarina_hidden/laundry/
    for second_level in "$laundry_root"/*; do
        [[ -d "$second_level" ]] || continue

        name2=$(basename "$second_level")
        [[ "$name2" =~ ^[0-9]+$ ]] || continue

        # Count regular files (non-recursive) in this directory
        count=$(find "$second_level" -maxdepth 1 -type f 2>/dev/null | wc -l)

        echo "$second_level: $count"
        grand_total=$((grand_total + count))
    done
done

echo "Grand total files: $grand_total"
