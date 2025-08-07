#!/bin/bash

# ---------- Config & Globals ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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

show_system_info() {
    echo -e "\n${GREEN}System Information${NC}"
    SYS_SHOW=$(system --show)
    echo "$SYS_SHOW" | awk -F':' '/^(System Name|Current Time|System ID|Version|Build)/ {
        gsub(/^ +| +$/, "", $2)
        printf "%s: %s\n", $1, $2
    }'
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

get_dict_info() {
    echo -e "\nDictionary Info:"
    DICT_FILE="${BASE_PATH}/dict2"
    if [[ ! -f "$DICT_FILE" ]]; then
        echo "Error: File '$DICT_FILE' not found." >&2
        exit 1
    fi

    BYTES=$(stat -c%s "$DICT_FILE")
    FLOOR_GIB=$((BYTES / 1024 / 1024 / 1024))
    DICT_SIZE=$(awk "BEGIN { printf \"%.2f\", $BYTES/1024/1024/1024 }")
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

    valid_sizes=(64 128 256 384 640 1520 2176 4224)

    echo "Available dictionary sizes:"
    printf '%s ' "${valid_sizes[@]}"
    echo

    while true; do
        read -r -p "Enter the new desired dictionary size (GiB): " NEW_SIZE

        # Check if it's a valid number from the list
        if [[ ! " ${valid_sizes[@]} " =~ " ${NEW_SIZE} " ]]; then
            echo -e "${RED}Invalid selection. Choose from the listed sizes.${NC}"
            continue
        fi

        # Compare with current
        CUR_SIZE_INT=${DICT_SIZE%.*} # truncate decimals
        if ((NEW_SIZE <= CUR_SIZE_INT)); then
            echo -e "${RED}New size must be greater than current size (${DICT_SIZE} GiB).${NC}"
            continue
        fi

        # Determine step-up
        step_up=0
        for size in "${valid_sizes[@]}"; do
            if ((size > CUR_SIZE_INT && size <= NEW_SIZE)); then
                ((step_up++))
            fi
        done

        echo -e "${GREEN}Dictionary size will increase from ${CUR_SIZE_INT} to ${NEW_SIZE} GiB"
        echo "Step-up level: $step_up${NC}"
        break
    done

    # Export if needed by other functions
    export NEW_SIZE step_up
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

stop_services() {
    echo "Stopping QoreStor services..."
    # sudo systemctl stop ocards
    echo "[TEST MODE] faked stopping of service"
    echo "'ocards' service stopped."
}

# ---------- Main Entry Point ----------

main() {
    show_system_info
    get_main_data_path
    get_storage_usage
    get_metadata_path
    get_dict_info
    get_dedupe_stats
    collect_dict_expansion_params

    echo

    if confirm_action; then
        stop_services
    else
        exit 1
    fi

    echo -e "\nDone. System is ready for next steps."
}

main "$@"
