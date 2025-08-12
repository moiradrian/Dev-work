#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

trap 'echo -e "${RED}A fatal error occurred. See log for details.${NC}"; exit 1' ERR

# ---------- Constraints ----------
readonly PAGE_SIZE=11
readonly STOP_TIMEOUT=120 # seconds to wait for 'ocards' to fully stop

# Start-up controls
START_TIMEOUT_DEFAULT=180 # seconds to wait for services to start
START_POLL_INTERVAL_DEFAULT=0.4

# Tunables (overridden by flags)
START_TIMEOUT="$START_TIMEOUT_DEFAULT"
START_POLL_INTERVAL="$START_POLL_INTERVAL_DEFAULT"

# ------ Set up logging ------
RUN_TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
readonly LOG_FILE="./dictionary_expansion_${RUN_TIMESTAMP}.log"

log() {
    local level="${1^^}" # First arg is level: INFO/WARN/ERROR
    shift
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local caller
    caller=$(caller 0 | awk '{print $2}') # name of calling function
    echo "[$timestamp] [$level] [$caller] $*" >>"$LOG_FILE"
}

# ---------- Config & Globals ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------- Helpers ----------
get_term_width() {
    # Prefer $COLUMNS, then tput, fallback to 80
    local w="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    echo "$w"
}

# Wraps $1 to (terminal_width - indent), indenting continuation lines by $2 spaces
wrap_text() {
    local text="$1" indent="$2"
    local width
    width=$(get_term_width)
    local bodywidth=$((width - indent))
    # Ensure sane minimum
    ((bodywidth < 30)) && bodywidth=30
    echo "$text" | fold -s -w "$bodywidth" | sed "2,999s/^/$(printf '%*s' "$indent")/"
}

# Prints an option row like: "  --flag           Description that wraps…"
print_opt() {
    local opt="$1" desc="$2"
    local indent_after_opt=22 # aligns wrapped description
    printf "  %-20s " "$opt"
    wrap_text "$desc" "$indent_after_opt"
}

show_help() {
    echo -e "${GREEN}Usage:${NC} $0 [options]\n"

    echo -e "${GREEN}Options:${NC}"
    print_opt "--help" "Show this help message and exit."
    print_opt "--dry-run" "Run in simulation mode. No changes will be made. Prompts still appear; actions are only logged."
    print_opt "--show-all-sizes" "Display all possible dictionary sizes regardless of current memory/disk limits."
    print_opt "--fast-start" "Reduce service restart timeout and increase polling frequency for quicker testing."

    echo -e "\n${GREEN}Behaviour:${NC}"
    wrap_text "• ${YELLOW}--dry-run${NC}: Prints planned actions and skips changes, including service stop/start and file renames." 2
    wrap_text "• ${YELLOW}--fast-start${NC}: Uses smaller ${GREEN}START_TIMEOUT${NC} and faster ${GREEN}START_POLL_INTERVAL${NC}." 2
    wrap_text "• ${YELLOW}--show-all-sizes${NC}: Lists sizes without filtering by memory/disk; actual selection still validated." 2

    echo -e "\n${GREEN}Interactive confirmations:${NC}"
    wrap_text "After stopping services: type ${GREEN}expand${NC}/${GREEN}e${NC} to extend, ${GREEN}skip${NC}/${GREEN}s${NC} (default) to skip, or ${RED}cancel${NC}/${RED}c${NC} to exit with services stopped." 2
    wrap_text "Before restarting services: type ${GREEN}yes${NC}/${GREEN}y${NC} (default) to start, or ${RED}cancel${NC}/${RED}c${NC} to exit with services stopped." 2

    echo -e "\n${GREEN}Examples:${NC}"
    echo "  $0 --dry-run"
    echo "  $0 --show-all-sizes"
    echo "  $0 --dry-run --fast-start"
    echo
    exit 0
}
# ---------- Parse Arguments ----------
SHOW_ALL_SIZES=false
DRY_RUN=false
FAST_START=false

for arg in "$@"; do
    case "$arg" in
    --help) show_help ;; # exits 0
    --dry-run) DRY_RUN=true ;;
    --show-all-sizes) SHOW_ALL_SIZES=true ;;
    --fast-start)
        FAST_START=true
        # set your faster tunables here if not already done elsewhere
        START_TIMEOUT=60
        START_POLL_INTERVAL=0.15
        ;;
    *)
        echo -e "${YELLOW}Unknown option: ${arg}${NC}"
        echo "Try: $0 --help"
        exit 2
        ;;
    esac
done

if $FAST_START; then
    START_TIMEOUT=60         # tighter timeout
    START_POLL_INTERVAL=0.15 # faster spinner/refresh
    log info "FAST-START enabled (timeout=${START_TIMEOUT}s, poll=${START_POLL_INTERVAL}s)"
fi

declare DATA_PATH BASE_PATH DATA_LEVEL FIRST_LEVEL
declare DATA_DEVICE DATA_SIZE DATA_USED DATA_AVAIL DATA_USEP
declare DEVICE SIZE USED AVAIL USEP
declare DICT_FILE DICT_SIZE MAX_KEYS MAX_KEYS_FMT size_key
declare USED_KEYS_RAW USED_KEYS_FMT PERCENT_USED

declare -A max_keys_map=(
    ["64"]=2863355222
    ["128"]=5726710444
    ["256"]=11453420886
    ["384"]=22906841772
    ["640"]=45813683542
    ["1520"]=91627367084
    ["2176"]=183254734166
    ["4224"]=366509468332
)

# ---------- Functions ----------

get_system_state() {
    system --show | awk -F':' '
        /^System State/ {
            gsub(/^ +| +$/, "", $2);
            print $2
        }'
}

show_progress_bar() {
    local GREEN='\033[0;32m'
    local NC='\033[0m'

    local total_steps=20
    local delay=0.15
    local bar=""
    local percent=0

    for ((i = 1; i <= total_steps; i++)); do
        sleep "$delay"
        bar+="#"
        percent=$((i * 100 / total_steps))
        printf "\r[%-20s] %3d%%" "$bar" "$percent"
    done

    # Final green "100%" safely printed using correct arguments
    printf "\r[%-20s] %b%3d%%%b" "$bar" "$GREEN" 100 "$NC"

    sleep 1

    # Clear the line cleanly
    printf "\r\033[2K"
}

wait_for_service_stop() {
    local service="$1"
    local timeout="${2:-$STOP_TIMEOUT}"
    local start ts state
    local spinner='-\|/'

    printf "Waiting for '%s' to stop " "$service"
    start=$(date +%s)
    local i=0

    # Poll until inactive/failed/unknown or timeout
    while true; do
        state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
        case "$state" in
        inactive | failed | unknown | deactivating)
            break
            ;;
        esac

        # spin
        i=$(((i + 1) % 4))
        printf "\rWaiting for '%s' to stop %s" "$service" "${spinner:$i:1}"
        sleep 0.2

        ts=$(date +%s)
        if ((ts - start >= timeout)); then
            printf "\r\033[2K"
            echo -e "${RED}Timeout waiting for '${service}' to stop (>${timeout}s).${NC}"
            return 1
        fi
    done

    printf "\r\033[2K"
    echo -e "${GREEN}'${service}' is stopped (${state}).${NC}"
    return 0
}

format_gib() {
    local raw="$1"
    # Trim trailing .00 if present
    if [[ "$raw" =~ ^([0-9]+)\.00$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        # If decimal part exists, keep it (e.g., 64.25)
        echo "$raw"
    fi
}

show_system_info() {
    echo -e "\n${GREEN}System Information${NC}"
    SYS_SHOW=$(system --show)
    echo "$SYS_SHOW" | awk -F':' '/^(System Name|Current Time|System ID|Version|Build)/ {
        gsub(/^ +| +$/, "", $2)
        printf "%s: %s\n", $1, $2
    }'
    log info "System Info collected."
}

get_total_memory() {
    echo -e "\n${GREEN}System Memory Info${NC}"

    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [[ -z "$mem_kb" ]]; then
        echo "Error: Unable to determine system memory." >&2
        exit 1
    fi

    total_mem_gib=$(awk -v kb="$mem_kb" 'BEGIN { print int((kb / 1024 / 1024) + 0.999) }')
    echo "Total Installed Memory: ${total_mem_gib} GiB"

    export total_mem_gib
    log info "Total Installed Memory: ${total_mem_gib} GiB"
}

show_max_supported_dict_size() {
    echo -e "\n${GREEN}Evaluating Maximum Supported Dictionary Size Based on Memory${NC}"
    show_progress_bar
    declare -A min_mem_required=(
        [64]=8
        [128]=16
        [256]=32
        [384]=38
        [640]=42
        [1520]=64
        [2176]=128
        [4224]=192
    )

    valid_sizes=(64 128 256 384 640 1520 2176 4224)

    # Determine max size supported by available memory
    max_supported_size=""
    for size in "${valid_sizes[@]}"; do
        required=${min_mem_required[$size]}
        if ((total_mem_gib >= required)); then
            max_supported_size=$size
        fi
    done

    if [[ -z "$max_supported_size" ]]; then
        echo -e "${RED}Warning: No dictionary size is supported with current memory (${total_mem_gib} GiB).${NC}"
        log "No dictionary size supported for system with ${total_mem_gib} GiB RAM"
        exit 1
    fi

    CUR_SIZE_INT=${DICT_SIZE%.*}

    if ((CUR_SIZE_INT >= max_supported_size)); then
        echo -e "${GREEN}Current dictionary size ($(format_gib "$DICT_SIZE_RAW") GiB) is already at or above the maximum supported: $(format_gib "$max_supported_size") GiB${NC}"
        log "Current dictionary size ($(format_gib "$DICT_SIZE_RAW") GiB) is at or above supported max $(format_gib "$max_supported_size") GiB"

        # Determine the next size in the list
        next_index=-1
        for i in "${!valid_sizes[@]}"; do
            if ((valid_sizes[i] > CUR_SIZE_INT)); then
                next_index=$i
                break
            fi
        done

        if ((next_index != -1)); then
            next_size=${valid_sizes[$next_index]}
            next_required_mem=${min_mem_required[$next_size]}
            next_max_keys=${max_keys_map[$next_size]}

            # Calculate projected % usage
            next_percent_used=$(awk -v used="$USED_KEYS_RAW" -v max="$next_max_keys" \
                'BEGIN { printf "%.2f", (max > 0 ? used / max * 100 : 0) }')

            echo -e "\n${YELLOW}To expand to the next size (${next_size} GiB):${NC}"
            echo "• Required memory: ${next_required_mem} GiB"
            echo "• Projected usage: ${next_percent_used} %"

            if (($(awk 'BEGIN {exit ARGV[1] > 85 ? 0 : 1}' "$next_percent_used"))); then
                echo -e "${RED}⚠️  Warning: Projected usage after expansion would still be over 85%.${NC}"
                echo -e "  This expansion may not provide significant headroom."
                log warn "WARNING: Projected usage after expanding to ${next_size} GiB would be ${next_percent_used}%"
            fi

            log info "Next size ${next_size} GiB requires ${next_required_mem} GiB RAM; projected usage: ${next_percent_used}%"
        else
            echo -e "${YELLOW}You are already at the maximum configurable dictionary size available.${NC}"
            log info "User is at the highest dictionary size available. No further upgrades possible."
        fi

    else
        echo -e "${GREEN}Maximum dictionary size supported based on available memory: ${max_supported_size} GiB${NC}"
        log info "Max supported dictionary size based on ${total_mem_gib} GiB RAM: ${max_supported_size} GiB"
    fi
}

get_main_data_path() {
    DATA_PATH=$(system --show | grep Repository | cut -d':' -f2- | xargs)
    if [[ -z "$DATA_PATH" ]]; then
        echo "Error: could not determine main data location." >&2
        exit 1
    fi
    DATA_LEVEL="/$(echo "$DATA_PATH" | cut -d'/' -f2)"
    echo -e "\nMain Data location: $DATA_PATH"
}

get_storage_usage() {
    echo -e "\nMain Data Storage Usage:"
    DATAPART_USAGE=$(df -h | awk -v mnt="$DATA_LEVEL" '$NF==mnt {print}')
    [[ -z "$DATAPART_USAGE" ]] && DATAPART_USAGE=$(df -h "$DATA_PATH" | tail -1)
    read -r DATA_DEVICE DATA_SIZE DATA_USED DATA_AVAIL DATA_USEP _ <<<"$DATAPART_USAGE"
    printf "Device: %s\n" "$DATA_DEVICE"
    printf "%-8s %-8s %-8s %-6s\n" "Size" "Used" "Avail" "Use%"
    printf "%-8s %-8s %-8s %-6s\n" "$DATA_SIZE" "$DATA_USED" "$DATA_AVAIL" "$DATA_USEP"
}

get_metadata_path() {
    BASE_PATH=$(system --show | grep Metadata | cut -d':' -f2- | xargs)
    if [[ -z "$BASE_PATH" ]]; then
        echo "Error: could not determine metadata location." >&2
        exit 1
    fi
    FIRST_LEVEL="/$(echo "$BASE_PATH" | cut -d'/' -f2)"
    echo -e "\nMetadata location: $BASE_PATH"
}

get_metadata_usage() {
    echo -e "\n${GREEN}Checking Metadata Partition Usage${NC}"

    # Get the mount point or use path directly
    FIRST_LEVEL="/$(echo "$BASE_PATH" | cut -d'/' -f2)"
    PART_USAGE=$(df -h | awk -v mnt="$FIRST_LEVEL" '$NF==mnt {print}')

    # Fallback if mountpoint doesn't match
    if [[ -z "$PART_USAGE" ]]; then
        PART_USAGE=$(df -h "$BASE_PATH" | tail -1)
    fi

    if [[ -z "$PART_USAGE" ]]; then
        echo -e "${RED}Error: Unable to determine metadata partition usage for: $BASE_PATH${NC}"
        log "ERROR: df returned empty for $BASE_PATH"
        exit 1
    fi

    read -r DEVICE SIZE USED AVAIL USEP _ <<<"$PART_USAGE"

    if [[ -z "$AVAIL" ]]; then
        echo -e "${RED}Error: Could not extract available space from metadata partition.${NC}"
        echo "Debug: PART_USAGE='$PART_USAGE'"
        exit 1
    fi

    echo "Device: $DEVICE"
    echo "Metadata Partition Usage:"
    printf "%-8s %-8s %-8s %-6s\n" "Size" "Used" "Avail" "Use%"
    printf "%-8s %-8s %-8s %-6s\n" "$SIZE" "$USED" "$AVAIL" "$USEP"

    log info "Metadata partition available space: $AVAIL"
}

get_dict_info() {
    echo -e "\nDictionary Info:"
    DICT_FILE="${BASE_PATH}/dict2"
    if [[ ! -f "$DICT_FILE" ]]; then
        echo "Error: File '$DICT_FILE' not found." >&2
        exit 1
    fi

    BYTES=$(stat -c%s "$DICT_FILE")
    FLOOR_GIB=$((BYTES / 1024 / 1024 / 1024))
    DICT_SIZE_RAW=$(awk "BEGIN { printf \"%.2f\", $BYTES/1024/1024/1024 }")
    DICT_SIZE="${DICT_SIZE_RAW} GiB"

    echo "Dictionary Size: $(format_gib "$DICT_SIZE_RAW") GiB"

    for k in $(printf '%s\n' "${!max_keys_map[@]}" | sort -n); do
        if ((FLOOR_GIB >= k)); then size_key=$k; else break; fi
    done

    if [[ -z "$size_key" ]]; then
        echo "Error: No MAX_KEYS defined for ${FLOOR_GIB} GiB." >&2
        exit 1
    fi

    MAX_KEYS=${max_keys_map[$size_key]}
    if command -v numfmt &>/dev/null; then
        MAX_KEYS_FMT=$(numfmt --grouping "$MAX_KEYS")
    else
        MAX_KEYS_FMT=$(printf "%'d" "$MAX_KEYS")
    fi

    echo "Using lookup size ${size_key} GiB → MAX KEYS: $MAX_KEYS_FMT"
}

get_dedupe_stats() {
    echo -e "\nUsed Dictionary Keys:"
    USED_KEYS_RAW=$(ctrlrpc -p 9911 show.dedupe_stats | grep uhd_total_nrecs | awk '{print $NF}')
    if command -v numfmt &>/dev/null; then
        USED_KEYS_FMT=$(numfmt --grouping "$USED_KEYS_RAW")
    else
        USED_KEYS_FMT=$(printf "%'d" "$USED_KEYS_RAW")
    fi
    echo "Used Dictionary Keys: $USED_KEYS_FMT"

    PERCENT_USED=$(awk -v used="$USED_KEYS_RAW" -v max="$MAX_KEYS" \
        'BEGIN { if (max <= 0) { print "N/A" } else { printf "%.2f", (used/max)*100 } }')
    echo "Percent Used: $PERCENT_USED %  (lookup size ${size_key} GiB)"
}

collect_dict_expansion_params() {
    echo -e "\n${GREEN}Dictionary Expansion Options${NC}"
    echo "Current dictionary size: $(format_gib "$DICT_SIZE_RAW") GiB"

    declare -A min_mem_required=(
        [64]=8
        [128]=16
        [256]=32
        [384]=38
        [640]=42
        [1520]=64
        [2176]=128
        [4224]=192
    )

    all_sizes=(64 128 256 384 640 1520 2176 4224)
    CUR_SIZE_INT=${DICT_SIZE%.*}

    # Recalculate available space in GiB for filtering
    compute_avail_metadata_gib

    # Build valid sizes
    valid_sizes=()
    for size in "${all_sizes[@]}"; do
        mem_ok=$((total_mem_gib >= min_mem_required[$size]))
        space_ok=$(awk -v avail="$avail_metadata_gib" -v required="$DICT_SIZE_RAW" -v new="$size" \
            'BEGIN { print (avail >= (required + new)) ? 1 : 0 }')

        if ((size > CUR_SIZE_INT && mem_ok && space_ok)); then
            valid_sizes+=("$size")
        fi
    done

    if [[ ${#valid_sizes[@]} -eq 0 ]]; then
        echo -e "${RED}No larger dictionary sizes are supported with current memory and metadata space.${NC}"
        log "No valid expansion sizes available with ${total_mem_gib} GiB RAM and ${avail_metadata_gib} GiB disk"
        exit 1
    fi

    echo "Available dictionary sizes you can upgrade to:"
    printf '%s ' "${valid_sizes[@]}"
    echo

    while true; do
        read -r -p "Enter the new desired dictionary size (GiB): " NEW_SIZE

        if [[ ! " ${valid_sizes[*]} " =~ " ${NEW_SIZE} " ]]; then
            echo -e "${RED}Invalid selection. Choose from the listed sizes only.${NC}"
            continue
        fi

        # Step-up calculation
        step_up=0
        for size in "${all_sizes[@]}"; do
            if ((size > CUR_SIZE_INT && size <= NEW_SIZE)); then
                ((step_up++))
            fi
        done

        echo -e "${GREEN}Dictionary size will increase from ${CUR_SIZE_INT} to ${NEW_SIZE} GiB${NC}"
        echo "Step-up level: $step_up"
        log info "User selected ${NEW_SIZE} GiB (step-up: ${step_up})"
        # Check projected disk usage percentage
        calculate_projected_metadata_usage

        if (($(awk "BEGIN {print ($projected_usage >= 90)}"))); then
            echo -e "${YELLOW}⚠ WARNING: Projected disk usage will reach ${projected_usage}% of available metadata space.${NC}"
            echo "Proceed with caution — consider freeing up space before continuing."
            log warn "WARNING: Projected metadata usage will be ${projected_usage}%"
        else
            echo "Projected metadata usage after expansion: ${projected_usage}%"
            log info "Projected usage OK: ${projected_usage}%"
        fi
        break
    done

    export NEW_SIZE step_up
}
calculate_projected_metadata_usage() {
    echo -e "\n${GREEN}Calculating Projected Metadata Disk Usage After Expansion${NC}"

    if [[ -z "$DICT_SIZE_RAW" || -z "$NEW_SIZE" || -z "$avail_metadata_gib" ]]; then
        echo -e "${RED}Error: Missing required variables to calculate projected usage.${NC}"
        return 1
    fi

    projected_usage=$(awk -v dict="$DICT_SIZE_RAW" -v new="$NEW_SIZE" -v avail="$avail_metadata_gib" \
        'BEGIN {
            total_needed = dict + new
            usage_percent = (total_needed / avail) * 100
            printf "%.2f", usage_percent
        }')

    echo "Projected Metadata Disk Usage: ${projected_usage}%"
    log info "Projected metadata usage after expansion: ${projected_usage}%"

    if (($(awk "BEGIN { print (${projected_usage} >= 90) ? 1 : 0 }"))); then
        echo -e "${YELLOW}⚠ Warning: Metadata disk usage will reach ${projected_usage}%. Consider freeing up space.${NC}"
        log warn "WARNING: Projected metadata usage over 90%"
    fi

    export projected_usage
}

calculate_projected_usage() {
    echo -e "\n${GREEN}Projected Dictionary Usage After Expansion${NC}"

    NEW_MAX_KEYS=${max_keys_map[$NEW_SIZE]}
    if [[ -z "$NEW_MAX_KEYS" ]]; then
        echo -e "${RED}Error: No MAX_KEYS found for size ${NEW_SIZE} GiB${NC}" >&2
        exit 1
    fi

    if command -v numfmt &>/dev/null; then
        NEW_MAX_KEYS_FMT=$(numfmt --grouping "$NEW_MAX_KEYS")
    else
        NEW_MAX_KEYS_FMT=$(printf "%'d" "$NEW_MAX_KEYS")
    fi

    # Calculate new % used
    NEW_PERCENT_USED=$(awk -v used="$USED_KEYS_RAW" -v max="$NEW_MAX_KEYS" \
        'BEGIN {
            if (max <= 0) {
                print "N/A"
            } else {
                printf "%.2f", (used/max)*100
            }
        }')

    echo "New MAX KEYS: $NEW_MAX_KEYS_FMT"
    echo "Projected Percent Used: $NEW_PERCENT_USED %  (based on ${NEW_SIZE} GiB)"
    log info "Projected percent used for ${NEW_SIZE} GiB: ${NEW_PERCENT_USED}%"
}

validate_memory_for_size() {
    echo -e "\n${GREEN}Validating Memory Requirements for ${NEW_SIZE} GiB Dictionary${NC}"

    # Define memory requirements
    declare -A min_mem_required=(
        [64]=8
        [128]=16
        [256]=32
        [384]=38
        [640]=42
        [1520]=64
        [2176]=128
        [4224]=192
    )

    required_mem=${min_mem_required[$NEW_SIZE]}

    if ((total_mem_gib < required_mem)); then
        echo -e "${RED}Insufficient memory for selected dictionary size.${NC}"
        echo "Required: ${required_mem} GiB, Available: ${total_mem_gib} GiB"
        log error "Memory validation failed for ${NEW_SIZE} GiB — Required: ${required_mem} GiB, Available: ${total_mem_gib} GiB"
        echo "Returning to size selection..."

        # Loop back just like reselect
        collect_dict_expansion_params
        calculate_projected_usage
        validate_memory_for_size # repeat check
        return 0
    else
        echo -e "${GREEN}Memory Check Passed:${NC} Required ${required_mem} GiB, Available ${total_mem_gib} GiB"
        log info "Memory validated for ${NEW_SIZE} GiB (Required: ${required_mem} GiB, Available: ${total_mem_gib} GiB)"
    fi
}

compute_avail_metadata_gib() {
    if [[ "$AVAIL" =~ ^([0-9.]+)([KMGTP])$ ]]; then
        size_val="${BASH_REMATCH[1]}"
        size_unit="${BASH_REMATCH[2]}"
        case "$size_unit" in
        K) avail_metadata_gib=$(awk "BEGIN { print $size_val / 1024 / 1024 }") ;;
        M) avail_metadata_gib=$(awk "BEGIN { print $size_val / 1024 }") ;;
        G) avail_metadata_gib="$size_val" ;;
        T) avail_metadata_gib=$(awk "BEGIN { print $size_val * 1024 }") ;;
        P) avail_metadata_gib=$(awk "BEGIN { print $size_val * 1024 * 1024 }") ;;
        *)
            echo "Unknown size unit: $size_unit" >&2
            exit 1
            ;;
        esac
    else
        echo "Error: Could not parse available space '$AVAIL'" >&2
        exit 1
    fi

    export avail_metadata_gib
    log info "Parsed available metadata space: ${avail_metadata_gib} GiB"
}

validate_metadata_space() {
    echo -e "\n${GREEN}Validating Metadata Partition Space for Expansion${NC}"
    show_progress_bar
    compute_avail_metadata_gib

    required_space=$(awk "BEGIN { print $DICT_SIZE_RAW + $NEW_SIZE }")
    space_ok=$(awk -v avail="$avail_metadata_gib" -v required="$required_space" \
        'BEGIN { print (avail >= required) ? 1 : 0 }')

    echo "Available space: ${avail_metadata_gib} GiB"
    echo "Required space : ${required_space} GiB (dict2 + new dict-${NEW_SIZE}GiB)"

    if [[ "$space_ok" -ne 1 ]]; then
        echo -e "${RED}Error: Not enough space on the metadata partition to perform expansion.${NC}"
        echo "Please free up space or expand storage before proceeding."
        log error "ERROR: Not enough metadata space. Required: ${required_space} GiB, Available: ${avail_metadata_gib} GiB"
        exit 1
    fi

    echo -e "${GREEN}Sufficient space available to proceed with expansion.${NC}"
    log info "Metadata space validated: Required ${required_space} GiB, Available ${avail_metadata_gib} GiB"
}

evaluate_max_supported_size() {
    echo -e "\n${GREEN}Evaluating Maximum Supported Dictionary Size Based on System Resources${NC}"
    show_progress_bar

    declare -A min_mem_required=(
        [64]=8
        [128]=16
        [256]=32
        [384]=38
        [640]=42
        [1520]=64
        [2176]=128
        [4224]=192
    )

    all_sizes=(64 128 256 384 640 1520 2176 4224)
    CUR_SIZE_INT=${DICT_SIZE%.*}

    mem_limit=""
    disk_limit=""

    # 1. Memory-based filtering
    for size in "${all_sizes[@]}"; do
        if ((total_mem_gib >= min_mem_required[$size])); then
            mem_limit=$size
        else
            break
        fi
    done

    # 2. Disk-based filtering
    disk_limit=""
    for size in "${all_sizes[@]}"; do
        space_ok=$(awk -v avail="$avail_metadata_gib" -v current="$DICT_SIZE_RAW" -v new="$size" \
            'BEGIN { print (avail >= (current + new)) ? 1 : 0 }')
        if [[ "$space_ok" -eq 1 ]]; then
            disk_limit=$size
        fi
    done

    # 3. Determine effective max
    if [[ -z "$mem_limit" && -z "$disk_limit" ]]; then
        effective_limit="N/A"
        reason="both"
    elif [[ -z "$mem_limit" ]]; then
        effective_limit="$disk_limit"
        reason="memory"
    elif [[ -z "$disk_limit" ]]; then
        effective_limit="$mem_limit"
        reason="disk"
    else
        # Both exist, so pick the more limiting one
        if ((mem_limit < disk_limit)); then
            effective_limit=$mem_limit
            reason="memory"
        elif ((disk_limit < mem_limit)); then
            effective_limit=$disk_limit
            reason="disk"
        else
            effective_limit=$mem_limit # same value
            reason="neither"
        fi
    fi

    echo -e "\nMaximum dictionary size supported based on memory     : ${mem_limit:-N/A} GiB"
    echo "Maximum dictionary size supported based on disk space : ${disk_limit:-N/A} GiB"

    if [[ "$effective_limit" != "N/A" ]]; then
        echo -e "${GREEN}Effective maximum dictionary size: $(format_gib "$effective_limit") GiB${NC}"
    else
        echo -e "${RED}No dictionary expansion possible due to system constraints.${NC}"
        exit 1
    fi

    case "$reason" in
    memory)
        echo -e "→ ${YELLOW}Limiting factor: memory${NC}"
        log warn "Limiting factor: memory (Max Memory allows size of: ${mem_limit} GiB, Max disk space allows size of: ${disk_limit:-N/A} GiB)"
        ;;
    disk)
        echo -e "→ ${YELLOW}Limiting factor: disk space${NC}"
        log warn "Limiting factor: disk space (Max Memory allows size of: ${mem_limit:-N/A} GiB, Max disk space allows size of: ${disk_limit} GiB)"
        ;;
    both)
        echo -e "→ ${RED}Limiting factor: both memory and disk${NC}"
        log error "Limiting factor: both memory and disk (Max mem size: ${mem_limit:-N/A} GiB, Max disk size: ${disk_limit:-N/A} GiB)"
        ;;
    *)
        echo -e "→ No limiting factor detected"
        log info "No limiting factor detected (Max mem size: ${mem_limit:-N/A} GiB, Max disk size: ${disk_limit:-N/A} GiB)"
        ;;
    esac

    log info "Max supported dict size: $effective_limit GiB (limited by $reason)"

    export effective_limit
}

confirm_action() {
    read -r -p "This action will stop all QoreStor services. Do you want to continue? [y/N] " response
    case "$response" in
    [yY][eE][sS] | [yY]) return 0 ;;
    *)
        echo "Operation cancelled."
        return 1
        ;;
    esac
}

confirm_expansion_plan() {
    # Apply color to projected usage
    if (($(awk "BEGIN { print ($projected_usage >= 90) ? 1 : 0 }"))); then
        usage_color="$RED"
    elif (($(awk "BEGIN { print ($projected_usage >= 70) ? 1 : 0 }"))); then
        usage_color="$YELLOW"
    else
        usage_color="$GREEN"
    fi
    # Optional disk cleanup recommendation
    if [[ "$usage_color" == "$RED" || "$usage_color" == "$YELLOW" ]]; then
        disk_cleanup_hint="→ Consider removing 'dict2.old' to free space once QoreStor is operational."
        log warn "Disk cleanup hint: $disk_cleanup_hint"
    else
        disk_cleanup_hint=""
    fi

    echo
    echo -e "${GREEN}Summary of Proposed Expansion:${NC}"
    echo "Current Dictionary Size : $(format_gib "$DICT_SIZE_RAW") GiB"
    echo "Selected New Size        : ${NEW_SIZE} GiB"
    echo "Step-up Level            : $step_up"
    echo "Page Size               : ${PAGE_SIZE}"
    echo "Projected New Dictionary Usage          : ${NEW_PERCENT_USED} %"
    echo -e "Projected Metadata Disk Usage : ${usage_color}${projected_usage} %${NC}"
    [[ -n "$disk_cleanup_hint" ]] && echo -e "${YELLOW}${disk_cleanup_hint}${NC}"

    echo
    while true; do
        read -r -p "Proceed with expansion? (yes / reselect / cancel) [c]: " decision
        case "${decision,,}" in
        y | yes)
            log info "User confirmed to proceed with expansion."
            return 0
            ;;
        r | reselect)
            log info "User chose to reselect dictionary size."
            echo -e "${GREEN}Reselecting dictionary size...${NC}"
            collect_dict_expansion_params
            calculate_projected_usage
            validate_memory_for_size
            validate_metadata_space
            confirm_expansion_plan
            return $? # bubble result
            ;;
        "" | c | cancel)
            log info "User cancelled the operation."
            echo "Operation cancelled by user."
            exit 1
            ;;
        *)
            echo "Invalid option. Please type 'yes' (y), 'reselect' (r), or 'cancel' (c)."
            ;;
        esac
    done
}

stop_services() {
    local service="ocards"
    echo -e "\n${GREEN}Stopping QoreStor services (${service})${NC}"

    # Current state (safe to query in dry-run)
    local cur_state
    cur_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

    if $DRY_RUN; then
        echo -e "${YELLOW}Dry Run Information:${NC}"
        echo "• Current state     : ${cur_state}"
        echo "• Command to run    : systemctl stop ${service}"
        echo "• Wait strategy     : poll 'systemctl is-active' for up to ${STOP_TIMEOUT}s with spinner"
        log info "Dry Run Information: state=${cur_state}, cmd='systemctl stop ${service}', wait=${STOP_TIMEOUT}s"
        echo -e "${GREEN}Dry run complete. No changes made.${NC}"
        return 0
    fi

    # If already stopped, don't bother
    if [[ "$cur_state" == "inactive" || "$cur_state" == "failed" || "$cur_state" == "unknown" ]]; then
        echo -e "${YELLOW}Service '${service}' is already ${cur_state}. Skipping stop.${NC}"
        log info "Service ${service} already ${cur_state}; skip stop"
        return 0
    fi

    # Attempt stop
    if ! systemctl stop "$service"; then
        echo -e "${YELLOW}systemctl stop returned non-zero; will still wait for state to change...${NC}"
        log warn "systemctl stop ${service} returned non-zero; proceeding to wait"
    else
        log info "Issued 'systemctl stop ${service}'"
    fi

    # Wait with spinner
    if wait_for_service_stop "$service" "$STOP_TIMEOUT"; then
        log info "Service ${service} stopped within timeout"
        return 0
    else
        local final_state
        final_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
        echo -e "${RED}Service '${service}' stop timeout. Final state: ${final_state}${NC}"
        log error "Service ${service} stop timeout; final_state=${final_state}"
        return 1
    fi
}

extend_dictionary() {
    echo -e "\n${GREEN}Extending Dictionary${NC}"

    # Preconditions
    if [[ -z "$DICT_FILE" || -z "$BASE_PATH" || -z "$NEW_SIZE" || -z "$step_up" ]]; then
        echo -e "${RED}Error: Missing required variables (DICT_FILE/BASE_PATH/NEW_SIZE/step_up).${NC}"
        exit 1
    fi

    # Build destination and backup paths
    local ts dest_path backup backup_rot cmd
    ts=$(date "+%Y%m%d_%H%M%S")
    dest_path="${BASE_PATH}/dict-${ts}"
    backup="${BASE_PATH}/dict2.old"
    [[ -e "$backup" ]] && backup_rot="${backup}.${ts}"

    # Compose command array
    cmd=(uhd_extend -p "$DICT_FILE" -s "$step_up" -k "$PAGE_SIZE" -d "$dest_path")

    if $DRY_RUN; then
        echo -e "\n${YELLOW}Dry Run Information:${NC}"
        echo "• Dictionary file present : $([[ -e "$DICT_FILE" ]] && echo yes || echo no)"
        echo "• Current file            : $DICT_FILE"
        if [[ -n "$backup_rot" ]]; then
            echo "• Backup target (rotate)  : $backup -> $backup_rot"
        else
            echo "• Backup target           : $backup"
        fi
        echo "• New file to be created  : $dest_path"
        echo "• Activation rename       : ${dest_path} -> ${DICT_FILE}"
        echo "• Command to run          : ${cmd[*]}"

        log info "Dry Run Information:"
        log info "Dictionary file present: $([[ -e "$DICT_FILE" ]] && echo yes || echo no)"
        log info "Current file: $DICT_FILE"
        if [[ -n "$backup_rot" ]]; then
            log info "Backup target (rotate): $backup -> $backup_rot"
        else
            log info "Backup target: $backup"
        fi
        log info "New file to be created: $dest_path"
        log info "Activation rename: ${dest_path} -> ${DICT_FILE}"
        log info "Command to run: ${cmd[*]}"

        echo -e "${GREEN}Dry run complete. No changes made.${NC}"
        return 0
    fi

    # ---- Real execution path ----
    echo "Running: ${cmd[*]}"
    log info "Invoking uhd_extend: ${cmd[*]}"

    if ! "${cmd[@]}"; then
        echo -e "${RED}uhd_extend failed. Aborting.${NC}"
        log error "uhd_extend failed for source=$DICT_FILE dest=$dest_path step_up=$step_up page_shift=$PAGE_SIZE"
        exit 1
    fi

    if [[ ! -s "$dest_path" ]]; then
        echo -e "${RED}Error: Destination dictionary not created or empty: ${dest_path}${NC}"
        log error "Destination dictionary missing/empty at ${dest_path}"
        exit 1
    fi
    log info "uhd_extend completed. New dictionary at ${dest_path}"

    # Rotate existing backup if present
    if [[ -e "$backup" ]]; then
        echo "Existing ${backup} found; rotating to ${backup_rot}"
        log info "Rotating existing backup: ${backup} -> ${backup_rot}"
        mv -f "$backup" "$backup_rot" || {
            echo -e "${RED}Failed to rotate old backup${NC}"
            log error "Failed to rotate ${backup}"
            exit 1
        }
    fi

    echo "Backing up current dict2 -> dict2.old"
    log info "Renaming ${DICT_FILE} -> ${backup}"
    mv -f "$DICT_FILE" "$backup" || {
        echo -e "${RED}Failed to backup dict2${NC}"
        log error "mv ${DICT_FILE} ${backup} failed"
        exit 1
    }

    echo "Activating new dictionary -> dict2"
    log info "Renaming ${dest_path} -> ${DICT_FILE}"
    if ! mv -f "$dest_path" "$DICT_FILE"; then
        echo -e "${RED}Activation failed; attempting rollback...${NC}"
        log error "Activation mv failed; rolling back"
        mv -f "$backup" "$DICT_FILE" 2>/dev/null
        exit 1
    fi

    echo -e "${GREEN}Dictionary expansion swap complete.${NC}"
    log info "Dictionary swap complete: active=${DICT_FILE}, backup=${backup}"
}

start_services() {
    local service="ocards"
    echo -e "\n${GREEN}Starting QoreStor services (${service})${NC}"

    # Gather initial states (safe in dry-run)
    local sys_state svc_state
    sys_state=$(get_system_state 2>/dev/null || echo "unknown")
    svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

    if $DRY_RUN; then
        echo -e "${YELLOW}Dry Run Information:${NC}"
        echo "• Current System State : ${sys_state}"
        echo "• Service State        : ${svc_state}"
        echo "• Command to run       : systemctl start ${service}"
        echo -e "• ${YELLOW}Wait strategy        : poll 'system --show' for 'System State: operational mode' and 'systemctl is-active' to be active, with spinner (timeout ${START_TIMEOUT}s)${NC}"
        log info "Dry Run Information: start state sys='${sys_state}', svc='${svc_state}', cmd='systemctl start ${service}', wait=${START_TIMEOUT}s"
        echo -e "${GREEN}Dry run complete. No changes made.${NC}"
        return 0
    fi

    # Real run wait strategy output & log
    echo -e "• ${YELLOW}Wait strategy        : poll 'system --show' for 'System State: operational mode' and 'systemctl is-active' to be active, with spinner (timeout ${START_TIMEOUT}s)${NC}"
    log info "Wait strategy: poll 'system --show' for 'System State: operational mode' and 'systemctl is-active' to be active, timeout=${START_TIMEOUT}s, poll_interval=${START_POLL_INTERVAL}s"

    # If already active, still wait for operational mode (after upgrades it may be starting up)
    if [[ "$svc_state" != "active" ]]; then
        if ! systemctl start "$service"; then
            echo -e "${YELLOW}systemctl start returned non-zero; will still wait for states to stabilize...${NC}"
            log warn "systemctl start ${service} returned non-zero; proceeding to wait"
        else
            log info "Issued 'systemctl start ${service}'"
        fi
    else
        log info "Service ${service} already active; waiting for operational mode"
    fi

    # Spinner + dual-line live status
    local spinner='-\|/'
    local i=0
    local start_ts now
    start_ts=$(date +%s)

    # Initial yellow display
    echo -e "${YELLOW}Starting '${service}' …${NC}"
    echo "System: ${sys_state} | Service: ${svc_state}"

    while true; do
        i=$(((i + 1) % 4))
        local spin="${spinner:$i:1}"
        sys_state=$(get_system_state 2>/dev/null || echo "unknown")
        svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

        printf "\033[2A" # move cursor up two lines
        if [[ "${sys_state,,}" == "operational mode" ]]; then
            printf "${GREEN}Starting '%s' %s${NC}\033[0K\n" "$service" "$spin"
            printf "System: ${GREEN}%s${NC} | Service: %s\033[0K\n" "$sys_state" "$svc_state"
            sleep 3
            printf "\r\033[0K"
            echo -e "${GREEN}System is operational. Startup sequence complete.${NC}"
            log info "System operational; service=${service}, svc_state=${svc_state}"
            return 0
        else
            printf "${YELLOW}Starting '%s' %s${NC}\033[0K\n" "$service" "$spin"
            printf "System: %s | Service: %s\033[0K\n" "$sys_state" "$svc_state"
        fi

        now=$(date +%s)
        if ((now - start_ts >= START_TIMEOUT)); then
            printf "\r\033[2K"
            echo -e "${RED}Timeout waiting for operational mode (>${START_TIMEOUT}s). Last state: System='${sys_state}', Service='${svc_state}'${NC}"
            log error "Start timeout; sys_state='${sys_state}', svc_state='${svc_state}'"
            return 1
        fi

        sleep "$START_POLL_INTERVAL"
    done
}

confirm_expand_action() {
    local prompt_prefix=""
    $DRY_RUN && prompt_prefix="[DRY-RUN] "

    while true; do
        read -r -p "${prompt_prefix}Proceed with dictionary expansion? (cancel / skip / expand) [skip]: " choice
        choice="${choice,,}" # lowercase for comparison
        case "$choice" in
        "" | "s" | "skip")
            log info "User chose to skip dictionary expansion"
            return 1 # skip
            ;;
        "e" | "expand")
            log info "User chose to expand dictionary"
            return 0 # proceed to expand
            ;;
        "c" | "cancel")
            log info "User cancelled after service stop"
            echo -e "${RED}Operation cancelled by user. Services remain stopped.${NC}"
            exit 1
            ;;
        *)
            echo -e "${YELLOW}Invalid choice. Please type 'cancel', 'skip', or 'expand'.${NC}"
            ;;
        esac
    done
}

confirm_start_services() {
    local prompt_prefix=""
    $DRY_RUN && prompt_prefix="[DRY-RUN] "

    while true; do
        read -r -p "${prompt_prefix}Are you ready to restart services? (cancel / yes) [yes]: " choice
        choice="${choice,,}" # lowercase for comparison
        case "$choice" in
        "" | "y" | "yes")
            log info "User confirmed restart of services"
            return 0 # proceed to start services
            ;;
        "c" | "cancel")
            log info "User cancelled before service restart"
            echo -e "${RED}Operation cancelled by user. Services remain stopped.${NC}"
            exit 1
            ;;
        *)
            echo -e "${YELLOW}Invalid choice. Please type 'cancel' or 'yes'.${NC}"
            ;;
        esac
    done
}

# ---------- Main Entry Point ----------

main() {
    # Show dry-run notice early
    $DRY_RUN && echo -e "${YELLOW}Running in DRY-RUN mode. No changes will be made.${NC}"
    $DRY_RUN && log "DRY-RUN mode enabled"
    $FAST_START && echo -e "${YELLOW}FAST-START: timeout=${START_TIMEOUT}s, poll=${START_POLL_INTERVAL}s${NC}"

    show_system_info
    get_total_memory
    get_main_data_path
    get_storage_usage
    get_metadata_path
    get_metadata_usage
    compute_avail_metadata_gib
    get_dict_info
    # show_max_supported_dict_size
    get_dedupe_stats
    evaluate_max_supported_size
    collect_dict_expansion_params
    calculate_projected_usage
    validate_memory_for_size
    validate_metadata_space
    confirm_expansion_plan

    echo

    if confirm_action; then
        stop_services

        # expand or skip confirmation
        if confirm_expand_action; then
            extend_dictionary
        else
            log info "User chose to skip dictionary expansion"
            echo -e "\n${YELLOW}Skipping dictionary expansion as per user request.${NC}"
        fi

        if confirm_start_services; then
            start_services
        fi
    else
        exit 1
    fi

    echo -e "\nDone. System is ready for next steps."
}

main "$@"
