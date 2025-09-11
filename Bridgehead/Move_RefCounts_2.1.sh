#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/oca/oca_test.cfg"
BACKUP_DIR="/etc/oca"
LOG_DIR="/var/log/oca_edit"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DRY_RUN=false
SCAN_ONLY=false
VERIFY_CHECKSUM=false
MOUNTPOINT=""
SCAN_FOUND=0
SCAN_TOTAL_BYTES=0
SCAN_MAP=""
grand_human=""
hb=""
COPIED_FILES=0

NEW_LINE=""
REFCNT_OLD="export PLATFORM_DS_REFCNTS_ON_SSD=0"
REFCNT_NEW="export PLATFORM_DS_REFCNTS_ON_SSD=1"
LOG_FILE=""
SUMMARY=()
BACKUP_FILE=""

DRY_COPY_FILES=0
DRY_COPY_BYTES=0

usage() {
    echo "Usage: $0 [--dry-run] [--scan-only] [--checksum-verify] [MOUNTPOINT]"
    echo
    echo "  --dry-run           Show what would happen (scan + rsync -n stats + config preview)"
    echo "  --scan-only         Only scan and sum refcount sizes (no copy, no edits)"
    echo "  --checksum-verify   Use rsync --checksum during verify step (slower, strongest check)"
    echo "  MOUNTPOINT          Target mount name for TGTSSDDIR in edit mode; prompted if omitted"
}

# ---- System Info ----
capture_system_info() {
    if ! command -v system &>/dev/null; then
        echo "Warning: 'system' command not found. Skipping system info."
        return
    fi
    echo "=== SYSTEM INFO ==="
    system --show | grep -E -i '^(System Name|Current Time|System ID|Product Name|Version|Build|Repository location|Metadata location)'
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
# Convert a size string to bytes.
# Accepts plain bytes like "123456" or "123,456 bytes", or IEC like "25.1G".
to_bytes() {
    local s="$1"
    # Strip commas and trailing " bytes"
    s="${s//,/}"
    s="${s% bytes}"

    # If it's already an integer, return it
    if [[ "$s" =~ ^[0-9]+$ ]]; then
        printf "%s" "$s"
        return
    fi

    # numfmt best effort
    if command -v numfmt >/dev/null 2>&1; then
        # numfmt --from=iec handles KiB/MiB/GiB/TiB and also K/M/G/T as 1024 base
        local out
        if out="$(numfmt --from=iec "$s" 2>/dev/null)"; then
            printf "%s" "$out"
            return
        fi
    fi

    # Fallback parser (IEC base 1024), accepts optional i: K/Ki, M/Mi, ...
    awk -v s="$s" '
        function mul(u) {
            if (u=="K"||u=="Ki") return 1024;
            if (u=="M"||u=="Mi") return 1024^2;
            if (u=="G"||u=="Gi") return 1024^3;
            if (u=="T"||u=="Ti") return 1024^4;
            if (u=="P"||u=="Pi") return 1024^5;
            return 1;
        }
        BEGIN {
            if (match(s, /^([0-9]+(\.[0-9]+)?)\s*([KMGTPE]?i?)/, m)) {
                val = m[1]+0; unit = m[3];
                printf "%.0f", val * mul(unit);
            } else {
                gsub(/[^0-9]/, "", s);
                if (s=="") s="0";
                print s+0;
            }
        }'
}

human_bytes() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --format="%.2f" "$1"
        return
    fi
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
            DRY_RUN=true
            shift
            ;;
        --scan-only)
            SCAN_ONLY=true
            shift
            ;;
        --checksum-verify)
            VERIFY_CHECKSUM=true
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

    if ! $SCAN_ONLY; then
        if [[ ${#args[@]} -gt 0 ]]; then
            MOUNTPOINT="${args[0]}"
        else
            read -rp "Enter the full mount path (e.g. /testmnt or /testmnt/subdir): " MOUNTPOINT
        fi

        # Require full path
        if [[ -z "$MOUNTPOINT" || "${MOUNTPOINT:0:1}" != "/" ]]; then
            echo "Error: Mountpoint must be a full path starting with '/'." >&2
            exit 1
        fi

        # Strip any trailing slash
        MOUNTPOINT="${MOUNTPOINT%/}"

        # If user included /ssd, strip it off
        if [[ "$MOUNTPOINT" =~ /ssd$ ]]; then
            MOUNTPOINT="${MOUNTPOINT%/ssd}"
        fi

        # Build export line
        NEW_LINE="export TGTSSDDIR=${MOUNTPOINT}/ssd/"

        # Create ssd dir if missing (only in live mode)
        if ! $DRY_RUN; then
            if [[ ! -d "${MOUNTPOINT}/ssd" ]]; then
                mkdir -p "${MOUNTPOINT}/ssd"
                echo "Created directory: ${MOUNTPOINT}/ssd"
            fi
        fi
        # Add a line to the summary output and log
        SUMMARY+=("✔ Using target SSD directory: ${MOUNTPOINT}/ssd/")

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

    if $DRY_RUN; then
        echo "MODE: DRY-RUN"
    elif $SCAN_ONLY; then
        echo "MODE: SCAN-ONLY"
    else
        echo "MODE: LIVE"
    fi

    echo "Dry run: $DRY_RUN"
    echo "Scan only: $SCAN_ONLY"
    echo "Verify checksum: $VERIFY_CHECKSUM"
    if ! $SCAN_ONLY; then
        echo "Mountpoint: $MOUNTPOINT"
    fi
    echo

    capture_system_info
}
plan_copy_totals() {
    local repo
    repo="$(get_repo_location)" || return 1

    local total_files=0
    shopt -s nullglob
    for d in "$repo"/*; do
        [[ -d "$d" ]] || continue
        local base="$(basename -- "$d")"
        [[ "$base" =~ ^[0-9]+$ ]] || continue
        local refdir="$d/.ocarina_hidden/refcnt"
        if [[ -d "$refdir" ]]; then
            local count
            count="$(find "$refdir" -type f 2>/dev/null | wc -l)"
            total_files=$((total_files + count))
        fi
    done
    shopt -u nullglob

    echo "$total_files"
}

# ---- Scan-only (also reused for sizing) ----
scan_refcnt_sizes() {
    local repo
    repo="$(get_repo_location)" || {
        echo "Scan aborted."
        return 1
    }

    echo "Scanning refcount data under: $repo"
    echo "Looking for integer dirs with '.ocarina_hidden/refcnt'"
    echo

    local -i found=0
    local total_bytes=0

    shopt -s nullglob
    for d in "$repo"/*; do
        [[ -d "$d" ]] || continue
        local base
        base="$(basename -- "$d")"
        [[ "$base" =~ ^[0-9]+$ ]] || continue
        ((found++))

        local refdir="$d/.ocarina_hidden/refcnt"
        local bytes=0
        if [[ -d "$refdir" ]]; then
            bytes="$(du -sb "$refdir" 2>/dev/null | awk '{print $1}')"
            bytes="${bytes:-0}"
        else
            echo "Note: Missing refcount path for $base -> $refdir"
        fi

        total_bytes=$((total_bytes + bytes))

        local hb
        hb=$(human_bytes "$bytes")
        printf "Directory %s: %s\n" "$base" "$hb"
    done
    shopt -u nullglob

    if ((found == 0)); then
        echo "No integer-named directories with refcnt found under $repo."
        SUMMARY+=("✘ Scan: 0 integer dirs found under $repo")
        return 0
    fi

    echo
    local grand_human
    grand_human=$(human_bytes "$total_bytes")
    echo "Total Refcount Size: $grand_human"
    echo

    SUMMARY+=("✔ Scan: $found integer dirs under $repo")
    SUMMARY+=("✔ Total Refcount Size: $grand_human")

    SCAN_FOUND="$found"
    SCAN_TOTAL_BYTES="$total_bytes"
    return 0
}

# ---- Free space check ----
check_free_space() {
    local target_base="$1"
    local need_bytes="$2"

    if ! command -v df >/dev/null 2>&1; then
        echo "Warning: 'df' not available, skipping free space check."
        return 0
    fi
    mkdir -p "$target_base"
    local avail
    avail="$(df -PB1 "$target_base" | awk 'NR==2{print $4}')"
    if [[ -z "$avail" ]]; then
        echo "Warning: Unable to determine free space for $target_base"
        return 0
    fi
    echo "Free space on target: $(human_bytes "$avail") | Required: $(human_bytes "$need_bytes")"
    if ((avail < need_bytes)); then
        echo "ERROR: Not enough free space on $target_base"
        return 1
    fi
    return 0
}

# ---- Rsync copy + verification (no deletion of sources) ----
rsync_base_flags() {
    # print one flag per line so process-substitution -> read -a builds a proper array
    printf '%s\n' -aHAX --numeric-ids --sparse -W --info=progress2 --human-readable
}

rsync_verify_flags() {
    # start from base
    mapfile -t base < <(rsync_base_flags)
    if $VERIFY_CHECKSUM; then
        base+=(--checksum)
    fi
    printf '%s\n' "${base[@]}"
}

copy_one_refcnt() {
    local SRC="$1" DST="$2" base="$3"
    if [[ ! -d "$SRC" ]]; then
        echo "Note: Missing $SRC (skipped)"
        SUMMARY+=("✘ Skip (missing): $SRC")
        return 0
    fi
    mkdir -p "$DST"

    local -a RSYNC_ARGS
    IFS=$'\n' read -r -d '' -a RSYNC_ARGS < <(rsync_base_flags && printf '\0')
    RSYNC_ARGS+=(--stats)

    if $DRY_RUN; then
        # add -n explicitly for dry-run
        RSYNC_ARGS+=(-n)
        echo "[DRY RUN] rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

        local out files
        out="$(rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1 || true)"
        files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
        : "${files:=0}"

        printf "Directory %s: %'d files would be copied\n" "$base" "$files"
        SUMMARY+=("Directory $base: $files files would be copied")

        DRY_COPY_FILES=$((DRY_COPY_FILES + files))
        COPIED_FILES=$((COPIED_FILES + files))
        return 0
    fi

    # LIVE RUN
    echo "[LIVE] rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

    local out files
    if out="$(rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1)"; then
        files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
        : "${files:=0}"
        printf "Directory %s: %'d files copied\n" "$base" "$files"
        SUMMARY+=("Directory $base: $files files copied")
        COPIED_FILES=$((COPIED_FILES + files))
        return 0
    else
        SUMMARY+=("✘ rsync failed: $SRC -> $DST")
        echo "$out"
        return 1
    fi
}

verify_one_refcnt() {
    local SRC="$1" DST="$2"
    local -a RSYNC_ARGS
    IFS=$'\n' read -r -d '' -a RSYNC_ARGS < <(rsync_verify_flags && printf '\0')

    local out rc files

    if $DRY_RUN; then
        # add -n explicitly for dry-run
        RSYNC_ARGS+=(-n --stats)
        echo "[DRY RUN] verify rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

        # Run rsync in dry-run mode to get stats only
        out="$(rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1 || true)"
        files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
        : "${files:=0}"

        printf "[DRY RUN] Verify %s: %'d files would be compared\n" "$SRC" "$files"
        SUMMARY+=("Would verify $SRC: $files files")
        return 0
    fi

    # LIVE RUN
    echo "[LIVE] verify rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

    set +e
    out="$(rsync -n "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1)"
    rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        echo "Verification rsync reported errors for: $SRC -> $DST"
        echo "$out"
        return 1
    fi

    if [[ -n "$out" ]]; then
        echo "Verification found differences for: $SRC -> $DST"
        echo "$out"
        return 1
    fi

    if $VERIFY_CHECKSUM; then
        echo "Verified OK (checksum): $SRC -> $DST"
        SUMMARY+=("Verified OK (checksum): $SRC -> $DST")
    else
        echo "Verified OK: $SRC -> $DST"
        SUMMARY+=("Verified OK: $SRC -> $DST")
    fi
    return 0
}

copy_all_refcnt() {
    local planned_files
    planned_files="$(plan_copy_totals)"
    echo "Planned total files to copy: $(printf "%'d" "$planned_files")"
    SUMMARY+=("Planned total files to copy: $(printf "%'d" "$planned_files")")

    local repo
    repo="$(get_repo_location)" || {
        echo "Copy aborted."
        return 1
    }

    local target_base="${NEW_LINE#export TGTSSDDIR=}"
    target_base="${target_base%/}"
    if [[ -z "$target_base" || "$target_base" == "export TGTSSDDIR=" ]]; then
        echo "Error: Target base (TGTSSDDIR) not set; aborting copy."
        return 1
    fi

    # Size planning & space check
    scan_refcnt_sizes || true
    local need="${SCAN_TOTAL_BYTES:-0}"
    echo "Planned copy target base: $target_base"
    check_free_space "$target_base" "$need" || return 1
    echo

    # Reset counters
    COPIED_FILES=0
    if $DRY_RUN; then
        DRY_COPY_BYTES=0
    fi

    shopt -s nullglob
    local processed=0
    for d in "$repo"/*; do
        [[ -d "$d" ]] || continue
        local base="$(basename -- "$d")"
        [[ "$base" =~ ^[0-9]+$ ]] || continue

        local SRC="$d/.ocarina_hidden/refcnt"
        local DST="$target_base/$base/.ocarina_hidden/refcnt"

        copy_one_refcnt "$SRC" "$DST" "$base" || return 1
        ((processed++))
    done
    shopt -u nullglob

    echo
    echo "Total files copied: $(printf "%'d" "$COPIED_FILES")"
    SUMMARY+=("Total files copied: $(printf "%'d" "$COPIED_FILES")")

    if [[ -n "$planned_files" && "$COPIED_FILES" -ne "$planned_files" ]]; then
        echo "WARNING: Planned file count ($planned_files) does not match actual copied ($COPIED_FILES)"
        SUMMARY+=("✘ File count mismatch: planned $(printf "%'d" "$planned_files") vs actual $(printf "%'d" "$COPIED_FILES")")
    else
        SUMMARY+=("✔ File count match: $(printf "%'d" "$COPIED_FILES")")
    fi

    SUMMARY+=("✔ Refcnt trees processed: $processed")

    if $DRY_RUN; then
        local human_total
        human_total="$(human_bytes "$DRY_COPY_BYTES")"
        SUMMARY+=("✔ DRY total files to copy: $(printf "%'d" "$DRY_COPY_FILES")")
        SUMMARY+=("✔ DRY total size to copy: $human_total")
    fi

    return 0
}

verify_all_refcnt() {
    local repo
    repo="$(get_repo_location)" || {
        echo "Verify aborted."
        return 1
    }

    local target_base="${NEW_LINE#export TGTSSDDIR=}"
    target_base="${target_base%/}"
    if [[ -z "$target_base" || "$target_base" == "export TGTSSDDIR=" ]]; then
        echo "Error: Target base (TGTSSDDIR) not set; aborting verify."
        return 1
    fi

    shopt -s nullglob
    local verified=0
    local total_verified_files=0
    for d in "$repo"/*; do
        [[ -d "$d" ]] || continue
        local base="$(basename -- "$d")"
        [[ "$base" =~ ^[0-9]+$ ]] || continue

        local SRC="$d/.ocarina_hidden/refcnt"
        local DST="$target_base/$base/.ocarina_hidden/refcnt"

        if $DRY_RUN; then
            # Dry-run: simulate comparison, parse stats
            local out files
            out="$(rsync -n --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1 || true)"
            files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
            : "${files:=0}"

            printf "[DRY RUN] Verify Directory %s: %'d files would be compared\n" "$base" "$files"
            SUMMARY+=("Would verify dir $base: $files files")
            total_verified_files=$((total_verified_files + files))
            ((verified++))
            continue
        fi

        # Live mode: actually compare
        local out files rc
        set +e
        out="$(rsync -n --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1)"
        rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "Verification rsync reported errors for: $SRC -> $DST"
            echo "$out"
            SUMMARY+=("✘ Verify failed: $base")
            return 1
        fi

        files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
        : "${files:=0}"

        printf "Verify Directory %s: %'d files compared OK\n" "$base" "$files"
        SUMMARY+=("Directory $base: $files files verified")
        total_verified_files=$((total_verified_files + files))
        ((verified++))
    done
    shopt -u nullglob

    echo
    if $DRY_RUN; then
        echo "Total files that would be compared: $(printf "%'d" "$total_verified_files")"
        SUMMARY+=("Total files that would be compared: $(printf "%'d" "$total_verified_files")")
    else
        echo "Total files verified: $(printf "%'d" "$total_verified_files")"
        SUMMARY+=("✔ Verify OK for $verified trees, $total_verified_files files")
    fi

    return 0
}

# ---- Edit-mode (unchanged behavior) ----
dry_run_preview() {
    # ---- Diff helper (only changes, clean wrapping, colorized for console) ----
    show_diff() {
        local file1="$1" file2="$2"
        local width="${3:-160}"

        # Detect if stdout is a terminal → enable colors
        local RED="" GREEN="" CYAN="" RESET=""
        if [[ -t 1 ]]; then
            RED=$'\033[31m'
            GREEN=$'\033[32m'
            CYAN=$'\033[36m'
            RESET=$'\033[0m'
        fi

        echo "${CYAN}=== CONFIG DIFF ($file1 vs $file2) ===${RESET}"
        diff -u "$file1" "$file2" |
            grep -E '^[+-]' |
            grep -Ev '^(\+\+\+|---)' |
            fold -w "$width" -s |
            while IFS= read -r line; do
                case "$line" in
                +*) echo "${GREEN}${line}${RESET}" ;;
                -*) echo "${RED}${line}${RESET}" ;;
                *) echo "$line" ;;
                esac
            done
        echo "${CYAN}=== END DIFF ===${RESET}"
    }

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
    ' "$CONFIG_FILE" \
        >"${CONFIG_FILE}.dryrun.tmp"
    show_diff "$CONFIG_FILE" "${CONFIG_FILE}.dryrun.tmp"
    rm -f "${CONFIG_FILE}.dryrun.tmp"
}

make_backup() {
    BACKUP_FILE="${BACKUP_DIR}/oca.cfg.refcount_script.bak_${TIMESTAMP}"
    cp -p "$CONFIG_FILE" "$BACKUP_FILE"
    echo "Backup created at: $BACKUP_FILE"
    SUMMARY+=("✔ Backup created: $BACKUP_FILE")
    echo
}

apply_changes() {
    # ---- Diff helper (only changes, clean wrapping, colorized for console) ----
    show_diff() {
        local file1="$1" file2="$2"
        local width="${3:-160}"

        # Detect if stdout is a terminal → enable colors
        local RED="" GREEN="" CYAN="" RESET=""
        if [[ -t 1 ]]; then
            RED=$'\033[31m'
            GREEN=$'\033[32m'
            CYAN=$'\033[36m'
            RESET=$'\033[0m'
        fi

        echo "${CYAN}=== CONFIG DIFF ($file1 vs $file2) ===${RESET}"
        diff -u "$file1" "$file2" |
            grep -E '^[+-]' |
            grep -Ev '^(\+\+\+|---)' |
            fold -w "$width" -s |
            while IFS= read -r line; do
                case "$line" in
                +*) echo "${GREEN}${line}${RESET}" ;;
                -*) echo "${RED}${line}${RESET}" ;;
                *) echo "$line" ;;
                esac
            done
        echo "${CYAN}=== END DIFF ===${RESET}"
    }

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
    show_diff "$BACKUP_FILE" "$CONFIG_FILE"
}

print_summary() {
    echo
    echo "=== SUMMARY ==="

    # Mode detection
    if $DRY_RUN; then
        echo "MODE: DRY-RUN"
    elif $SCAN_ONLY; then
        echo "MODE: SCAN-ONLY"
    else
        echo "MODE: LIVE"
    fi

    # Checksum verification status
    if $VERIFY_CHECKSUM; then
        SUMMARY+=("✔ Checksum verification enabled")
    else
        SUMMARY+=("✘ Checksum verification not enabled")
    fi

    for line in "${SUMMARY[@]}"; do
        echo "$line"
    done
    echo "Run complete. Log saved to: $LOG_FILE"
}
confirm_live_run() {
    echo
    echo "=== PREVIEW BEFORE LIVE RUN ==="
    echo
    # Show scan results
    scan_refcnt_sizes || true
    # Show copy plan with rsync -n stats
    copy_all_refcnt || true
    # Show config changes
    dry_run_preview
    echo

    read -rp "Proceed with LIVE run? Type 'yes' to continue, anything else will cancel: " reply
    if [[ "$reply" == "yes" ]]; then
        echo "Continuing with LIVE run..."
    else
        echo "Cancelled by user."
        # Insert at the *start* of SUMMARY array
        SUMMARY=("✘ CANCELLED at confirmation step" "${SUMMARY[@]}")
        print_summary
        exit 0
    fi
}

main() {
    parse_args "$@"
    setup_logging

    if $SCAN_ONLY; then
        echo "=== SCAN-ONLY MODE ==="
        scan_refcnt_sizes || true
        print_summary
        exit 0
    fi

    if $DRY_RUN; then
        # scan_refcnt_sizes || true
        copy_all_refcnt || true
        dry_run_preview
        print_summary
        exit 0
    fi

    # LIVE RUN: show everything first, ask user to confirm
    confirm_live_run
    # Now proceed for real
    copy_all_refcnt || {
        echo "Copy step failed. Aborting before any config changes."
        print_summary
        exit 1
    }
    verify_all_refcnt || {
        echo "Verification failed. Aborting before any config changes."
        print_summary
        exit 1
    }

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file $CONFIG_FILE not found!"
        print_summary
        exit 1
    fi

    make_backup
    apply_changes
    print_summary
}

main "$@"
