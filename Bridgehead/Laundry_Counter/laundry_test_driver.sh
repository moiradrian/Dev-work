#!/usr/bin/env bash

# Laundry monitor stress test:
# - Resolves BASE from /etc/oca/oca.cfg (TGTDIR) or /QSdata/ocaroot
# - Creates a temporary bucket under BASE/<tenant>/.ocarina_hidden/laundry/<bucket>
# - Generates nested subdirs and files quickly to exercise inotify + render
# - Optionally cleans up afterwards.
#
# Usage:
#   bash laundry_test_driver.sh [--tenant N] [--bucket N] [--files-per-dir N] [--depth N] [--delay-ms N] [--no-clean]
#
# Example (default paths, fast burst):
#   bash laundry_test_driver.sh
#
# Example (slower with more files):
#   bash laundry_test_driver.sh --files-per-dir 5 --depth 3 --delay-ms 50

set -euo pipefail

CFG_FILE="/etc/oca/oca.cfg"
BASE_DEFAULT="/QSdata/ocaroot"

TENANT="99999"
BUCKET="12345"
FILES_PER_DIR=3
DEPTH=3
DELAY_MS=10
CLEAN=true

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant) TENANT="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --files-per-dir) FILES_PER_DIR="$2"; shift 2 ;;
        --depth) DEPTH="$2"; shift 2 ;;
        --delay-ms) DELAY_MS="$2"; shift 2 ;;
        --no-clean) CLEAN=false; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
done

detect_base() {
    local value=""
    BASE="$BASE_DEFAULT"

    if [[ -f "$CFG_FILE" ]]; then
        value=$(grep -E '(^|\s)TGTDIR=' "$CFG_FILE" 2>/dev/null | head -n1 | sed 's/.*TGTDIR=//')
    fi

    if [[ -n "$value" && -d "$value" ]]; then
        BASE="$value"
    fi
}

detect_base

ROOT="$BASE/$TENANT/.ocarina_hidden/laundry/$BUCKET"

echo "Base: $BASE"
echo "Bucket: $ROOT"
echo "Files per dir: $FILES_PER_DIR"
echo "Depth: $DEPTH"
echo "Delay ms: $DELAY_MS"
echo "Clean afterwards: $CLEAN"
echo

mkdir -p "$ROOT"

delay() {
    local ms="$1"
    sleep "$(printf '0.%03d' "$ms")"
}

create_files() {
    local dir="$1"
    for i in $(seq 1 "$FILES_PER_DIR"); do
        local ts
        ts=$(date '+%H%M%S%3N' 2>/dev/null || date '+%s')
        local f="$dir/file_${ts}_$i"
        echo "data_${ts}" > "$f"
        delay "$DELAY_MS"
    done
}

create_tree() {
    local dir="$1"
    local depth="$2"
    create_files "$dir"
    (( depth <= 1 )) && return
    local sub="$dir/sub_$depth"
    mkdir -p "$sub"
    delay "$DELAY_MS"
    create_tree "$sub" $((depth - 1))
}

echo "Creating nested files..."
create_tree "$ROOT" "$DEPTH"

echo "Creation done. Inspect with your monitor now."

if $CLEAN; then
    read -r -p "Press Enter to delete created files (Ctrl+C to keep)..." _
fi

if $CLEAN; then
    if [[ -d "$ROOT" ]]; then
        find "$ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
    echo "Cleanup complete (bucket directory left in place)."
else
    echo "Cleanup skipped (--no-clean)."
fi
