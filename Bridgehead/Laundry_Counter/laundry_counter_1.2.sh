#!/usr/bin/env bash

BASE="/QSdata/ocaroot"

shopt -s nullglob

# Hide cursor while monitoring (and restore it on exit)
tput civis
trap 'tput cnorm; exit' INT TERM

while true; do
    # Move cursor to top-left and clear from there to end of screen
    tput cup 0 0
    tput ed

    echo "Laundry File Monitor"
    echo "Updated: $(date)"
    echo "--------------------------------------"

    grand_total=0

    for first_level in "$BASE"/*; do
        [[ -d "$first_level" ]] || continue
        name1=$(basename "$first_level")
        [[ "$name1" =~ ^[0-9]+$ ]] || continue

        laundry_root="$first_level/.ocarina_hidden/laundry"
        [[ -d "$laundry_root" ]] || continue

        for second_level in "$laundry_root"/*; do
            [[ -d "$second_level" ]] || continue
            name2=$(basename "$second_level")
            [[ "$name2" =~ ^[0-9]+$ ]] || continue

            count=$(find "$second_level" -maxdepth 1 -type f 2>/dev/null | wc -l)
            printf "%-60s %10d\n" "$second_level" "$count"
            grand_total=$((grand_total + count))
        done
    done

    echo "--------------------------------------"
    echo "Grand Total Files: $grand_total"
    echo

    sleep 30
done
