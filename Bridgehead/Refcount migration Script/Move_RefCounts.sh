#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/oca/oca_test.cfg"
BACKUP_DIR="/etc/oca"
LOG_DIR="/var/log/oca_edit"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DRY_RUN=false
MOUNTPOINT=""

NEW_LINE=""
REFCNT_OLD="export PLATFORM_DS_REFCNTS_ON_SSD=0"
REFCNT_NEW="export PLATFORM_DS_REFCNTS_ON_SSD=1"
LOG_FILE=""
SUMMARY=()

usage() {
    echo "Usage: $0 [--dry-run] [MOUNTPOINT]"
    echo
    echo "  --dry-run   Show what changes would be made without modifying the file"
    echo "  MOUNTPOINT  Optional argument. If not given, script will prompt for it."
}

parse_args() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            args+=("$1")
            shift
            ;;
        esac
    done

    if [[ ${#args[@]} -gt 0 ]]; then
        MOUNTPOINT="${args[0]}"
    else
        read -rp "Enter the mountpoint name: " MOUNTPOINT
    fi

    if [[ -z "$MOUNTPOINT" ]]; then
        echo "Error: Mountpoint cannot be empty."
        exit 1
    fi

    NEW_LINE="export TGTSSDDIR=/${MOUNTPOINT}/ssd/"
}

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
    echo "Mountpoint: $MOUNTPOINT"
    echo
}

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
    local backup_file="$1"
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
    ' "$CONFIG_FILE" >"${CONFIG_FILE}.tmp"

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
    diff -u "$backup_file" "$CONFIG_FILE" || true
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
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file $CONFIG_FILE not found!"
        exit 1
    fi

    parse_args "$@"
    setup_logging

    if $DRY_RUN; then
        dry_run_preview
        print_summary
        exit 0
    fi

    make_backup
    apply_changes "$BACKUP_FILE"
    print_summary
}

main "$@"
