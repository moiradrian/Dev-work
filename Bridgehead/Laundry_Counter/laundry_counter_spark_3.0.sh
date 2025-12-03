#!/usr/bin/env bash
# Laundry bucket monitor with periodic sampling + sparklines
# - Bucket-level totals only: <BASE>/<int>/.ocarina_hidden/laundry/<bucket>
# - Periodic rescan (default 2s) to avoid missing bursts
# - Per-sample delta and rolling sparkline (up/neutral/down coloring)

set -Eeuo pipefail

CFG_FILE="/etc/oca/oca.cfg"
BASE_DEFAULT="/QSdata/ocaroot"

SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-2}"   # seconds between samples
SPARK_POINTS="${SPARK_POINTS:-30}"        # samples to keep per bucket
RESYNC_INTERVAL="${RESYNC_INTERVAL:-30}"  # inotify mode: full rescan cadence (sec)
INOTIFY_MODE=0
INOTIFY_PID=0
LAST_RESYNC=0

# Colors (best effort)
color_reset=$(tput sgr0 2>/dev/null || echo "")
color_green=$(tput setaf 2 2>/dev/null || echo "")
color_red=$(tput setaf 1 2>/dev/null || echo "")
color_dim=$(tput dim 2>/dev/null || echo "")
color_bold=$(tput bold 2>/dev/null || echo "")
color_yellow=$(tput setaf 3 2>/dev/null || echo "")
color_magenta=$(tput setaf 5 2>/dev/null || echo "")
color_cyan=$(tput setaf 6 2>/dev/null || echo "")
hide_cursor() { tput civis 2>/dev/null || true; }
show_cursor() { tput cnorm 2>/dev/null || true; }

detect_base() {
    BASE="$BASE_DEFAULT"
    if [[ -f "$CFG_FILE" ]]; then
        local val
        val=$(grep -E '(^|\s)TGTDIR=' "$CFG_FILE" 2>/dev/null | head -n1 | sed 's/.*TGTDIR=//' | tr -d '\r')
        # Trim surrounding quotes and any trailing slash so find/regex paths line up
        val="${val%/}"
        val="${val%\"}"
        val="${val#\"}"
        val="${val%\'}"
        val="${val#\'}"
        if [[ -n "$val" && -d "$val" ]]; then
            BASE="$val"
        fi
    fi
}

parse_args() {
    while (($#)); do
        case "$1" in
            --inotify) INOTIFY_MODE=1 ;;
            -h|--help)
                cat <<'EOF'
Usage: laundry_counter_spark_3.0.sh [--inotify]
  --inotify    Use inotifywait for event-driven updates (requires inotify-tools)
EOF
                exit 0
                ;;
        esac
        shift
    done
}

parse_args "$@"
detect_base

declare -A counts
declare -A prev_counts
declare -A sparks  # space-separated values per bucket
declare -A spark_tokens  # corresponding color tokens per bucket (G/R/D)
total_added=0
total_removed=0
initialized=0
SPINNER_PID=0

start_spinner() {
    local msg="${1:-Starting...}"
    {
        local chars='|/-\' i=0
        local colors=("$color_green" "$color_yellow" "$color_magenta" "$color_cyan" "$color_red")
        local ci=0 n=${#colors[@]}
        while true; do
            local c=${chars:i%${#chars}:1}
            local col=${colors[ci]}
            printf "\r%s %s%s%s" "$msg" "$col" "$c" "$color_reset"
            i=$(( (i + 1) % ${#chars} ))
            ci=$(( (ci + 1) % n ))
            sleep 0.1
        done
    } &
    SPINNER_PID=$!
}

stop_spinner() {
    if ((SPINNER_PID > 0)); then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=0
        printf "\r\033[K"
    fi
}

now_ms() {
    printf '%s\n' "$(($(date +%s%N) / 1000000))"
}

spark_line() {
    local values_str="$1" tokens_str="$2"
    [[ -z "$values_str" ]] && { echo ""; return; }
    local blocks=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
    local vals=($values_str)
    local toks=($tokens_str)
    local min="${vals[0]}" max="${vals[0]}"
    local v t out="" range idx i
    for v in "${vals[@]}"; do
        ((v < min)) && min="$v"
        ((v > max)) && max="$v"
    done
    range=$((max - min))
    for i in "${!vals[@]}"; do
        v="${vals[$i]}"
        t="${toks[$i]:-D}"
        if ((range == 0)); then
            idx=3
        else
            idx=$((((v - min) * (${#blocks[@]} - 1)) / range))
            ((idx < 0)) && idx=0
            ((idx > ${#blocks[@]} - 1)) && idx=${#blocks[@]}-1
        fi
        case "$t" in
            G) out+="${color_green}${blocks[$idx]}${color_reset}" ;;
            R) out+="${color_red}${blocks[$idx]}${color_reset}" ;;
            *) out+="${color_dim}${blocks[$idx]}${color_reset}" ;;
        esac
    done
    echo "$out"
}

scan_buckets() {
    # Use shell globbing to pick only bucket roots (BASE/<int>/.ocarina_hidden/laundry/<int>)
    local bucket_glob="${BASE%/}"/[0-9]*/.ocarina_hidden/laundry/[0-9]*
    local buckets=()
    shopt -s nullglob
    for d in $bucket_glob; do
        [[ -d "$d" ]] && buckets+=("$d")
    done
    shopt -u nullglob
    printf '%s\n' "${buckets[@]}" | sort
}

bucket_dir_for() {
    local path="$1"
    # Walk up until we hit the bucket root (BASE/<int>/.ocarina_hidden/laundry/<int>)
    local dir="$path"
    while [[ -n "$dir" && "$dir" != "/" ]]; do
        case "$dir" in
            "$BASE"/[0-9]*/.ocarina_hidden/laundry/[0-9]*)
                echo "$dir"
                return
                ;;
        esac
        dir="${dir%/*}"
    done
}

init_bucket_if_needed() {
    local bucket="$1"
    if [[ ! -v counts["$bucket"] ]]; then
        local cnt
        cnt=$(find "$bucket" -type f -printf '.' 2>/dev/null | wc -c || true)
        if [[ -z "$cnt" || "$cnt" == "0" && -n "$(find "$bucket" -type f -print -quit 2>/dev/null)" ]]; then
            cnt=$(find "$bucket" -type f -print 2>/dev/null | wc -l || true)
        fi
        counts["$bucket"]=$((cnt))
    fi
}

sample_counts() {
    # Snapshot current counts to prev_counts
    prev_counts=()
    for b in "${!counts[@]}"; do
        prev_counts["$b"]=${counts["$b"]}
    done

    counts=()
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        counts["$dir"]=0
    done < <(scan_buckets)

    # Count files per bucket directly (GNU find for speed; fallback to wc -l if needed)
    for b in "${!counts[@]}"; do
        local cnt
        cnt=$(find "$b" -type f -printf '.' 2>/dev/null | wc -c || true)
        # If -printf is unsupported (non-GNU), fallback to line count
        if [[ -z "$cnt" || "$cnt" == "0" && -n "$(find "$b" -type f -print -quit 2>/dev/null)" ]]; then
            cnt=$(find "$b" -type f -print 2>/dev/null | wc -l || true)
        fi
        counts["$b"]=$((cnt))
    done
}

start_inotify_listener() {
    if ! command -v inotifywait >/dev/null 2>&1; then
        INOTIFY_MODE=0
        echo "inotifywait not found; falling back to scan mode" >&2
        return
    fi
    INOTIFY_MODE=1
    {
        inotifywait -m -r -e create -e delete -e moved_to -e moved_from --format '%e %w%f' "$BASE" 2>/dev/null |
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local event path bucket
            event=${line%% *}
            path=${line#* }
            [[ "$event" == *ISDIR* ]] && continue
            bucket=$(bucket_dir_for "$path")
            [[ -z "$bucket" ]] && continue
            init_bucket_if_needed "$bucket"
            case "$event" in
                *CREATE*|*MOVED_TO*)
                    counts["$bucket"]=$((counts["$bucket"] + 1))
                    ;;
                *DELETE*|*MOVED_FROM*)
                    if [[ ${counts["$bucket"]:-0} -gt 0 ]]; then
                        counts["$bucket"]=$((counts["$bucket"] - 1))
                    fi
                    ;;
            esac
        done
    } &
    INOTIFY_PID=$!
}

update_spark() {
    local bucket="$1" val="$2" tok="$3"
    local vals toks
    vals="${sparks[$bucket]:-}"
    toks="${spark_tokens[$bucket]:-}"

    if [[ -z "$vals" ]]; then
        vals="$val"
        toks="$tok"
    else
        vals="$vals $val"
        toks="$toks $tok"
        # trim to SPARK_POINTS
        local vals_arr=($vals) toks_arr=($toks)
        local n=${#vals_arr[@]}
        if ((n > SPARK_POINTS)); then
            vals_arr=("${vals_arr[@]: -$SPARK_POINTS}")
            toks_arr=("${toks_arr[@]: -$SPARK_POINTS}")
        fi
        vals="${vals_arr[*]}"
        toks="${toks_arr[*]}"
    fi
    sparks["$bucket"]="$vals"
    spark_tokens["$bucket"]="$toks"
}

render() {
    # Build output in memory and write once to minimize flicker
    local buffer="" line
    append() { buffer+="$1"$'\n'; }

    append "Laundry Bucket Monitor (sparkline sampling)"
    append "Mode: $([[ $INOTIFY_MODE -eq 1 ]] && echo INOTIFY || echo SCAN) | Sample interval: ${SAMPLE_INTERVAL}s$([[ $INOTIFY_MODE -eq 1 ]] && printf ' | Resync: %ss' \"$RESYNC_INTERVAL\")"
    append "Base: $BASE"
    append "Updated: $(date)"
    append "--------------------------------------"

    if ((${#counts[@]} == 0)); then
        append "(no buckets found under $BASE)"
        printf '\033[H'
        printf '%s' "$buffer"
        printf '\033[J'
        return
    fi

    mapfile -t buckets < <(printf '%s\n' "${!counts[@]}" | sort)
    local grand=0
    for b in "${buckets[@]}"; do
        local cur=${counts["$b"]}
        local prev=${prev_counts["$b"]:-$cur}
        local delta=$((cur - prev))
        grand=$((grand + cur))

        if ((initialized == 1)); then
            if ((delta > 0)); then
                total_added=$((total_added + delta))
            elif ((delta < 0)); then
                total_removed=$((total_removed + (-delta)))
            fi
        fi

        # Choose spark value: if no change, reuse last height but dim it
        local spark_val="$delta" tok="D"
        if ((delta > 0)); then
            tok="G"
        elif ((delta < 0)); then
            tok="R"
        else
            # reuse last height if present
            if [[ -n "${sparks[$b]:-}" ]]; then
                local last_vals=(${sparks[$b]})
                spark_val="${last_vals[$((${#last_vals[@]}-1))]}"
            else
                spark_val=0
            fi
        fi

        update_spark "$b" "$spark_val" "$tok"
        local spark_str
        spark_str=$(spark_line "${sparks[$b]}" "${spark_tokens[$b]}")

        local delta_str=""
        if ((delta > 0)); then
            delta_str="${color_green}+${delta}${color_reset}"
        elif ((delta < 0)); then
            delta_str="${color_red}${delta}${color_reset}"
        else
            delta_str="${color_dim}+0${color_reset}"
        fi

        printf -v line "%-30s %-55s %7d %7s" "$spark_str" "$b" "$cur" "$delta_str"
        append "$line"
    done
    append "--------------------------------------"
    printf -v line "Pending files: %d    Added: %s%d%s    Removed: %s%d%s" \
        "$grand" \
        "$color_green" "$total_added" "$color_reset" \
        "$color_red" "$total_removed" "$color_reset"
    append "$line"

    # Clear first to avoid leftover characters when lines shrink, then render buffer
    printf '\033[H\033[J'
    printf '%s' "$buffer"
    initialized=1
}

main() {
    trap '[[ $INOTIFY_PID -gt 0 ]] && kill "$INOTIFY_PID" 2>/dev/null; show_cursor; exit 0' INT TERM
    trap '[[ $INOTIFY_PID -gt 0 ]] && kill "$INOTIFY_PID" 2>/dev/null; show_cursor' EXIT
    hide_cursor
    start_spinner "Starting..."
    sample_counts
    stop_spinner
    LAST_RESYNC=$(date +%s)
    if ((INOTIFY_MODE)); then
        start_inotify_listener
    fi
    render
    # Initialize prev_counts after first render so deltas start at 0
    prev_counts=()
    for b in "${!counts[@]}"; do
        prev_counts["$b"]=${counts["$b"]}
    done
    while true; do
        sleep "$SAMPLE_INTERVAL"
        if ((INOTIFY_MODE)); then
            if ((RESYNC_INTERVAL > 0)); then
                local now
                now=$(date +%s)
                if ((now - LAST_RESYNC >= RESYNC_INTERVAL)); then
                    sample_counts
                    LAST_RESYNC=$now
                fi
            fi
            render
            prev_counts=()
            for b in "${!counts[@]}"; do
                prev_counts["$b"]=${counts["$b"]}
            done
        else
            sample_counts
            render
        fi
    done
}

main
