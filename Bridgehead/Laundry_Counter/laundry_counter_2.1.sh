#!/usr/bin/env bash

# QoreStor Laundry Monitor (inotify-driven, simplified)
# - Color highlighting for increases/decreases
# - Logs events to a file
# - Threshold alerts
# - Reduced-CPU mode (rate-limited screen refresh)

BASE="/QSdata/ocaroot"
LOG_FILE="/var/log/qorestor_laundry_monitor.log"

DIR_THRESHOLD=1000       # per-dir threshold (0 = off)
TOTAL_THRESHOLD=10000    # global threshold (0 = off)

REDUCED_CPU=true
REFRESH_INTERVAL=2       # seconds between screen refreshes in reduced mode

# Make sure we're in bash with associative arrays support
if [ -z "${BASH_VERSION:-}" ]; then
    echo "This script must be run with bash, e.g.: bash $0" >&2
    exit 1
fi

shopt -s nullglob

declare -A counts
declare -A prev_counts

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Colors
color_reset=$(tput sgr0 2>/dev/null || echo "")
color_green=$(tput setaf 2 2>/dev/null || echo "")
color_red=$(tput setaf 1 2>/dev/null || echo "")
color_yellow=$(tput setaf 3 2>/dev/null || echo "")
color_magenta=$(tput setaf 5 2>/dev/null || echo "")
color_bold=$(tput bold 2>/dev/null || echo "")

init_counts() {
    while IFS= read -r line; do
        local count dir
        read -r count dir <<<"$line"
        counts["$dir"]=$count
        prev_counts["$dir"]=$count
    done < <(
        find "$BASE" \
          -regextype posix-extended \
          -type f \
          -regex "$BASE/[0-9]+/\\.ocarina_hidden/laundry/[0-9]+/[^/]+" \
          -printf '%h\n' 2>/dev/null \
        | sort \
        | uniq -c
    )
}

render() {
    clear
    echo "QoreStor Laundry File Monitor (inotify-driven)"
    echo "Base: $BASE"
    echo "Updated: $(date)"
    echo "--------------------------------------"

    local grand_total=0

    mapfile -t dirs < <(printf '%s\n' "${!counts[@]}" | sort)

    for dir in "${dirs[@]}"; do
        local cur=${counts["$dir"]}
        local prev=${prev_counts["$dir"]}
        [[ -z "$prev" ]] && prev=$cur

        local line_color="$color_reset"

        if (( DIR_THRESHOLD > 0 && cur >= DIR_THRESHOLD )); then
            line_color="${color_bold}${color_red}"
        else
            if (( cur > prev )); then
                line_color=$color_green
            elif (( cur < prev )); then
                line_color=$color_red
            else
                line_color=$color_reset
            fi
        fi

        printf "%s%-60s %10d%s\n" "$line_color" "$dir" "$cur" "$color_reset"

        grand_total=$((grand_total + cur))
        prev_counts["$dir"]=$cur
    done

    echo "--------------------------------------"
    if (( TOTAL_THRESHOLD > 0 && grand_total >= TOTAL_THRESHOLD )); then
        echo -e "${color_bold}${color_magenta}Grand Total Files: $grand_total (THRESHOLD EXCEEDED)${color_reset}"
    else
        echo "Grand Total Files: $grand_total"
    fi
}

update_count() {
    local dir="$1"
    local op="$2"      # +1 or -1
    local reason="$3"  # CREATE/DELETE/etc.

    local cur=${counts["$dir"]}
    [[ -z "$cur" ]] && cur=0

    if [[ "$op" == "+1" ]]; then
        cur=$((cur + 1))
    else
        cur=$((cur - 1))
        (( cur < 0 )) && cur=0
    fi

    counts["$dir"]=$cur

    printf '%s dir="%s" op="%s" reason="%s" count=%d\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$dir" "$op" "$reason" "$cur" >> "$LOG_FILE"
}

cleanup() {
    echo
    echo "Exiting qorestor_laundry_monitor."
}
trap 'cleanup; exit 0' INT TERM

init_counts
render

last_render=$(date +%s)

# Main inotify loop
inotifywait -m -r \
    -e create -e delete -e moved_to -e moved_from \
    --format '%w %f %e' \
    "$BASE" 2>/dev/null | \
while read -r watched_dir filename events; do
    fullpath="${watched_dir%/}/$filename"

    # Regex match for:
    # /QSdata/ocaroot/<int>/.ocarina_hidden/laundry/<int>/<file>
    if [[ "$fullpath" =~ ^$BASE/[0-9]+/\.ocarina_hidden/laundry/[0-9]+/[^/]+$ ]]; then
        parent_dir="${fullpath%/*}"

        op=""
        if [[ "$events" == *CREATE* || "$events" == *MOVED_TO* ]]; then
            op="+1"
        elif [[ "$events" == *DELETE* || "$events" == *MOVED_FROM* ]]; then
            op="-1"
        else
            continue
        fi

        update_count "$parent_dir" "$op" "$events"

        if [[ "$REDUCED_CPU" == true ]]; then
            now=$(date +%s)
            if (( now - last_render >= REFRESH_INTERVAL )); then
                render
                last_render=$now
            fi
        else
            render
        fi
    fi
done
