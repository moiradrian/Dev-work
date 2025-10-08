#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/oca/oca_test.cfg"
BACKUP_DIR="/etc/oca"
LOG_DIR="/var/log/oca_edit"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DRY_RUN=false
SCAN_ONLY=false
MOUNTPOINT=""

NEW_LINE=""
REFCNT_OLD="export PLATFORM_DS_REFCNTS_ON_SSD=0"
REFCNT_NEW="export PLATFORM_DS_REFCNTS_ON_SSD=1"
LOG_FILE=""
SUMMARY=()
BACKUP_FILE=""

usage() {
    echo "Usage: $0 [--dry-run] [--scan-only] [MOUNTPOINT]"
    echo
    echo "  --dry-run    Show what config edits would do, without modifying files"
    echo "  --scan-only  Only scan and sum refcount data sizes (no edits)"
    echo "  MOUNTPOINT   Optional mountpoint for edit mode; prompted if omitted"
}

# ---- System Info ----
capture_system_info() {
    if ! command -v system &>/dev/null; then
        echo "Warning: 'system' command not found. Skipping system info."
        return
    fi
    echo "=== SYSTEM INFO ==="
    system --show | egrep -i '^(System Name|Current Time|System ID|Product Name|Version|Build|Repository location|Metadata location)'
    echo
}

get_repo_location() {
    if ! command -v system &>/dev/null; then
        echo "Error: 'system' command not found; cannot determine Repository location." >&2
        return 1
    fi
    local repo
    repo="$(system --show | awk -F': ' '/^Repository location/ {print $2}' | sed 's/[[:space:]]*$//')"
    if [[ -z "${repo:-}" ]]; then
        echo "Error: Could not parse Repository location from 'system --show'." >&2
        return 1
    fi
    if [[ ! -d "$repo" ]]; then
        echo "Error: Parsed Repository location '$repo' does not exist or is not a directory." >&2
        return 1
    fi
    printf "%s" "$repo"
}

# ---- Human-readable bytes ----
human_bytes() {
    # Prefer numfmt if available (IEC, GiB/TiB style)
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --format="%.2f" "$1"
        return
    fi
    # Fallback awk (IEC)
    awk -v b="$1" '
        function fmt(x, u) { printf("%.2f %sB\n", x, u); }
        BEGIN {
            v=b+0
            if (v<1024) { fmt(v, ""); exit }
            v/=1024; if (v<1024) { fmt(v,"Ki"); exit }
            v/=1024; if (v<1024) { fmt(v,"Mi"); exit }
            v/=1024; if (v<1024) { fmt(v,"Gi"); exit }
            v/=1024; fmt(v,"Ti");
        }'
}

# ---- Arg parsing ----
parse_args() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true; shift ;;
            --scan-only)
                SCAN_ONLY=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                args+=("$1"); shift ;;
        esac
    done

    # Only require/derive mountpoint if we are NOT in scan-only mode
    if ! $SCAN_ONLY; then
        if [[ ${#args[@]} -gt 0 ]]; then
            MOUNTPOINT="${args[0]}"
        else
            read -rp "Enter the mountpoint name: " MOUNTPOINT
        fi
        if [[ -z "$MOUNTPOINT" ]]; then
            echo "Error: Mountpoint cannot be empty (edit mode)." >&2
            exit 1
        fi
        NEW_LINE="export TGTSSDDIR=/${MOUNTPOINT}/ssd/"
    fi
}

# ---- Logging ----
setup_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/oca_edit_${TIMESTAMP}.log"
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo "=== OCA Config Edit Script ==="
    echo "Run timestamp: $(date)"
    echo "Config file: $CONFIG_FILE"
    echo "Backup dir: $BACKUP_DIR"
    echo "Log file: $LOG_FILE"
    echo "Dry run: $DRY_RUN"
    echo "Scan only: $SCAN_ONLY"
    if ! $SCAN_ONLY; then
        echo "Mountpoint: $MOUNTPOINT"
    fi
    echo

    capture_system_info
}

# ---- Scan-only implementation ----
scan_refcnt_sizes() {
    local repo
    repo="$(get_repo_location)" || { echo "Scan aborted."; exit 1; }

    echo "Scanning refcount data under: $repo"
    echo "Matching integer directories and summing '.ocarina_hidden/refcnt' recursively"
    echo

    local -A per_dir_bytes=()
    local -i found=0
    local total_bytes=0

    shopt -s nullglob
    for d in "$repo"/*; do
        [[ -d "$d" ]] || continue
        local base
        base="$(basename -- "$d")"
        # only pure integers
        if [[ "$base" =~ ^[0-9]+$ ]]; then
            found+=1
            local refdir="$d/.ocarina_hidden/refcnt"
            local bytes=0
            if [[ -d "$refdir" ]]; then
                # Use du -sb (Linux) to get total bytes; fallback if unavailable
                if du -sb "$refdir" >/dev/null 2>&1; then
                    bytes="$(du -sb "$refdir" 2>/dev/null | awk '{print $1}')"
                else
                    # Portable fallback: sum file sizes
                    bytes="$(
                        find "$refdir" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'
                    )"
                fi
            else
                echo "Note: Missing refcount path for $base -> $refdir (counted as 0)."
            fi
            per_dir_bytes["$base"]="$bytes"
            total_bytes=$(( total_bytes + bytes ))
        fi
    done
    shopt -u nullglob

    if (( found == 0 )); then
        echo "No integer-named directories found under $repo."
        SUMMARY+=("✘ Scan: 0 integer dirs found under $repo")
        return 0
    fi

    echo "=== Refcount Sizes by Directory ==="
    # Sort numerically by key for stable output
    for key in $(printf "%s\n" "${!per_dir_bytes[@]}" | sort -n); do
        hb=$(human_bytes "${per_dir_bytes[$key]}")
        printf "Directory %s: %s\n" "$key" "$hb"
    done
    echo

    grand_human=$(human_bytes "$total_bytes")
    echo "Total Refcount Size: $grand_human"
    echo

    SUMMARY+=("✔ Scan: $found integer dirs")
    SUMMARY+=("✔ Total Refcount Size: $grand_human")
}

# ---- Edit-mode pieces (unchanged behavior) ----
dry_run_preview() {
    echo "[DRY RUN] Would insert after 'export TGTDIR':"
    echo "  $NEW_LINE"
    SUMMARY+=("✔ Would insert: $NEW_LINE")

    if grep -q "^$REFCNT_OLD" "$CONFIG_FILE"; then
        echo "[DRY RUN] Would also change:"
        echo "  $REFCNT_OLD"
        echo "  → $REFCNT_NEW"
        SUMMARY+=("✔ Would change: $REFCNT_OLD → $REFCNT_NEW")
    else
        echo "[DRY RUN] No PLATFORM_DS_REFCNTS_ON_SSD=0 line found, no change made there."
        SUMMARY+=("✘ No PLATFORM_DS_REFCNTS_ON_SSD=0 found")
    fi
    echo
    echo "[DRY RUN] Preview of changes:"
    awk -v newline="$NEW_LINE" -v old="$REFCNT_OLD" -v new="$REFCNT_NEW" '
        BEGIN { done_insert=0 }
        /^export TGTDIR/ && !done_insert {
            print
            print newline
            done_insert=1
            next
        }
        $0 == old { print new; next }
        { print }
    ' "$CONFIG_FILE" | diff -u "$CONFIG_FILE" - || true
}

make_backup() {
    BACKUP_FILE="${BACKUP_DIR}/oca.cfg.refcount_script.bak_${TIMESTAMP}"
    cp -p "$CONFIG_FILE" "$BACKUP_FILE"
    echo "Backup created at: $BACKUP_FILE"
    SUMMARY+=("✔ Backup created: $BACKUP_FILE")
    echo
}

apply_changes() {
    awk -v newline="$NEW_LINE" -v old="$REFCNT_OLD" -v new="$REFCNT_NEW" '
        BEGIN { done_insert=0 }
        /^export TGTDIR/ && !done_insert {
            print
            print newline
            done_insert=1
            next
        }
        $0 == old { print new; changed_refcnt=1; next }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    echo "Line inserted:"
    echo "  $NEW_LINE"
    SUMMARY+=("✔ Inserted: $NEW_LINE")

    if grep -q "^$REFCNT_NEW" "$CONFIG_FILE"; then
        echo "Updated: $REFCNT_OLD → $REFCNT_NEW"
        SUMMARY+=("✔ Updated: $REFCNT_OLD → $REFCNT_NEW")
    else
        echo "No PLATFORM_DS_REFCNTS_ON_SSD=0 line found, nothing changed there."
        SUMMARY+=("✘ No PLATFORM_DS_REFCNTS_ON_SSD=0 found")
    fi

    echo
    echo "Changes made (compared to backup):"
    diff -u "$BACKUP_FILE" "$CONFIG_FILE" || true
}

print_summary() {
    echo
    echo "=== SUMMARY ==="
    for line in "${SUMMARY[@]}"; do
        echo "$line"
    done
    echo "Run complete. Log saved to: $LOG_FILE"
}

main() {
    parse_args "$@"
    setup_logging

    if $SCAN_ONLY; then
        scan_refcnt_sizes
        print_summary
        exit 0
    fi

    # Edit mode
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file $CONFIG_FILE not found!"
        exit 1
    fi

    if $DRY_RUN; then
        dry_run_preview
        print_summary
        exit 0
    fi

    make_backup
    apply_changes
    print_summary
}

main "$@"
