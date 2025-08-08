#!/bin/bash

# ---------- Constraints ----------
readonly PAGE_SIZE=11
readonly LOG_FILE="./dictionary_expansion.log"

# ------ Set up logging ------

log() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $*" >>"$LOG_FILE"
}

# ---------- Config & Globals ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SHOW_ALL_SIZES=false

# Parse CLI flags
for arg in "$@"; do
    case "$arg" in
    --show-all-sizes)
        SHOW_ALL_SIZES=true
        ;;
    esac
done

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

show_system_info() {
    echo -e "\n${GREEN}System Information${NC}"
    SYS_SHOW=$(system --show)
    echo "$SYS_SHOW" | awk -F':' '/^(System Name|Current Time|System ID|Version|Build)/ {
        gsub(/^ +| +$/, "", $2)
        printf "%s: %s\n", $1, $2
    }'
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
    log "Total Installed Memory: ${total_mem_gib} GiB"
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
        echo -e "${GREEN}Current dictionary size (${DICT_SIZE} GiB) is already at or above the maximum supported: ${max_supported_size} GiB${NC}"
        log "Current dictionary size (${DICT_SIZE} GiB) is at or above supported max (${max_supported_size} GiB)"

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
                log "WARNING: Projected usage after expanding to ${next_size} GiB would be ${next_percent_used}%"
            fi

            log "Next size ${next_size} GiB requires ${next_required_mem} GiB RAM; projected usage: ${next_percent_used}%"
        else
            echo -e "${YELLOW}You are already at the maximum configurable dictionary size available.${NC}"
            log "User is at the highest dictionary size available. No further upgrades possible."
        fi

    else
        echo -e "${GREEN}Maximum dictionary size supported based on available memory: ${max_supported_size} GiB${NC}"
        log "Max supported dictionary size based on ${total_mem_gib} GiB RAM: ${max_supported_size} GiB"
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

    log "Metadata partition available space: $AVAIL"
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

    echo "Dictionary Size: $DICT_SIZE GiB"

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
    echo "Current dictionary size: ${DICT_SIZE} GiB"

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
    avail_metadata_gib=""
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
        log "User selected ${NEW_SIZE} GiB (step-up: ${step_up})"
        # Check projected disk usage percentage
        projected_usage=$(awk -v dict="$DICT_SIZE" -v new="$NEW_SIZE" -v avail="$avail_metadata_gib" \
            'BEGIN {
        total_needed = dict + new
        usage_percent = (total_needed / avail) * 100
        printf "%.2f", usage_percent
    }')

        if (($(awk "BEGIN {print ($projected_usage >= 90)}"))); then
            echo -e "${YELLOW}⚠ WARNING: Projected disk usage will reach ${projected_usage}% of available metadata space.${NC}"
            echo "Proceed with caution — consider freeing up space before continuing."
            log "WARNING: Projected metadata usage will be ${projected_usage}%"
        else
            echo "Projected metadata usage after expansion: ${projected_usage}%"
            log "Projected usage OK: ${projected_usage}%"
        fi
        break
    done

    export NEW_SIZE step_up
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
    log "Projected percent used for ${NEW_SIZE} GiB: ${NEW_PERCENT_USED}%"
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
        log "Memory validation failed for ${NEW_SIZE} GiB — Required: ${required_mem} GiB, Available: ${total_mem_gib} GiB"
        echo "Returning to size selection..."

        # Loop back just like reselect
        collect_dict_expansion_params
        calculate_projected_usage
        validate_memory_for_size # repeat check
        return 0
    else
        echo -e "${GREEN}Memory Check Passed:${NC} Required ${required_mem} GiB, Available ${total_mem_gib} GiB"
        log "Memory validated for ${NEW_SIZE} GiB (Required: ${required_mem} GiB, Available: ${total_mem_gib} GiB)"
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
    log "Parsed available metadata space: ${avail_metadata_gib} GiB"
}


validate_metadata_space() {
compute_avail_metadata_gib
    required_space=$(awk "BEGIN { print $DICT_SIZE_RAW + $NEW_SIZE }")
    space_ok=$(awk -v avail="$avail_gib" -v required="$required_space" \
        'BEGIN { print (avail >= required) ? 1 : 0 }')

    echo "Available space: ${avail_gib} GiB"
    echo "Required space : ${required_space} GiB (dict2 + new dict-${NEW_SIZE}GiB)"

    if [[ "$space_ok" -ne 1 ]]; then
        echo -e "${RED}Error: Not enough space on the metadata partition to perform expansion.${NC}"
        echo "Please free up space or expand storage before proceeding."
        log "ERROR: Not enough metadata space. Required: ${required_space} GiB, Available: ${avail_gib} GiB"
        exit 1
    fi

    echo -e "${GREEN}Sufficient space available to proceed with expansion.${NC}"
    log "Metadata space validated: Required ${required_space} GiB, Available ${avail_gib} GiB"
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
        echo "Checked size $size GiB → space OK? $space_ok"
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
        echo -e "${GREEN}Effective maximum dictionary size: ${effective_limit} GiB${NC}"
    else
        echo -e "${RED}No dictionary expansion possible due to system constraints.${NC}"
        exit 1
    fi

    case "$reason" in
    memory) echo -e "→ ${YELLOW}Limiting factor: memory${NC}" ;;
    disk) echo -e "→ ${YELLOW}Limiting factor: disk space${NC}" ;;
    both) echo -e "→ ${RED}Limiting factor: both memory and disk${NC}" ;;
    *) echo -e "→ No limiting factor detected" ;;
    esac

    log "Max supported dict size: $effective_limit GiB (limited by $reason)"

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
    echo
    echo -e "${GREEN}Summary of Proposed Expansion:${NC}"
    echo "Current Dictionary Size : ${DICT_SIZE} GiB"
    echo "Selected New Size        : ${NEW_SIZE} GiB"
    echo "Step-up Level            : $step_up"
    echo "Page Size               : ${PAGE_SIZE}"
    echo "Projected Usage          : ${NEW_PERCENT_USED} %"

    echo
    while true; do
        read -r -p "Proceed with expansion? (yes / reselect / cancel) [cancel]: " decision
        case "$decision" in
        [yY][eE][sS] | [yY])
            log "User confirmed to proceed with expansion."
            return 0 # proceed
            ;;
        [rR][eE][sS][eE][lL][eE][cC][tT])
            log "User chose to reselect dictionary size."
            echo -e "${GREEN}Reselecting dictionary size...${NC}"
            collect_dict_expansion_params
            calculate_projected_usage
            validate_memory_for_size
            validate_metadata_space
            confirm_expansion_plan # recursive call
            return $?              # bubble up user's final answer
            ;;
        "" | [cC][aA][nN][cC][eE][lL])
            log "User cancelled the operation."
            echo "Operation cancelled by user."
            exit 1
            ;;
        *)
            echo "Invalid option. Please type 'yes', 'reselect', or 'cancel'."
            ;;
        esac
    done
}

stop_services() {
    echo "Stopping QoreStor services..."
    # sudo systemctl stop ocards
    echo "[TEST MODE] faked stopping of service"
    echo "'ocards' service stopped."
    log "QoreStor services stopped. (actual or simulated)"
}

# ---------- Main Entry Point ----------

main() {
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
    else
        exit 1
    fi

    echo -e "\nDone. System is ready for next steps."
}

main "$@"
