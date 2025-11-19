#!/usr/bin/env bash

BASE="/QSdata/ocaroot"

# Hide cursor while monitoring (restore on exit)
tput civis
trap 'tput cnorm; exit' INT TERM

while true; do
    # Move cursor to top-left and clear to end of screen
    tput cup 0 0
    tput ed

    echo "Laundry File Monitor"
    echo "Updated: $(date)"
    echo "--------------------------------------"

    grand_total=0

    # One single find over the tree:
    #   - type f: only files
    #   - regex: /QSdata/ocaroot/<int>/.ocarina_hidden/laundry/<int>/<file>
    mapfile -t lines < <(
        find "$BASE" \
          -regextype posix-extended \
          -type f \
          -regex "$BASE/[0-9]+/\\.ocarina_hidden/laundry/[0-9]+/[^/]+" \
          -printf '%h\n' 2>/dev/null \
        | sort \
        | uniq -c
    )

    for line in "${lines[@]}"; do
        # uniq -c output: "<count> <dir>"
        read -r count dir <<<"$line"
        printf "%-60s %10d\n" "$dir" "$count"
        grand_total=$((grand_total + count))
    done

    echo "--------------------------------------"
    echo "Grand Total Files: $grand_total"
    echo

    sleep 30
done
