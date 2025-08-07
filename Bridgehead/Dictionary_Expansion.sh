#!/bin/bash
# ------ General server info ------
# capture the full output once
SYS_SHOW=$(system --show)
# print the general info
echo
echo "System Information"
echo "$SYS_SHOW" | awk -F':' \
    '/^(System Name|Current Time|System ID|Version|Build)/ {
     # strip leading/trailing whitespace from the value
     gsub(/^ +| +$/,"",$2)
     printf "%s: %s\n", $1, $2
  }'

# ------ Main Data Repository discovery ------
DATA_PATH=$(system --show |
    grep Repository |
    cut -d':' -f2- |
    xargs) # trims leading/trailing whitespace

if [[ -z "$DATA_PATH" ]]; then
    echo "Error: could not determine metadata location." >&2
    exit 1
fi
echo
echo "Main data storage information"
echo
echo "Main Data location: $DATA_PATH"

# ------ Main Data Repository usage ------

# Metadata Partition usage
#    - Extract first directory level of BASE_PATH (e.g. /QSdata)
DATA_LEVEL="/$(echo "$DATA_PATH" | cut -d'/' -f2)"

#    - Try to grep that mountpoint in a full df -h
DATAPART_USAGE=$(df -h | awk -v mnt="$DATA_LEVEL" '$NF==mnt {print}')

#    - Fallback: if no match, ask df for the specific path
if [[ -z "$DATAPART_USAGE" ]]; then
    DATAPART_USAGE=$(df -h "$DATA_PATH" | tail -1)
fi

read -r DATA_DEVICE DATA_SIZE DATA_USED DATA_AVAIL DATA_USEP _ <<<"$DATAPART_USAGE"

#    - Print header + values in columns
echo "Device: $DATA_DEVICE"
echo "Data Partition Usage:"
printf "%-8s %-8s %-8s %-6s\n" "Size" "Used" "Avail" "Use%"
printf "%-8s %-8s %-8s %-6s\n" \
    "$DATA_SIZE" "$DATA_USED" "$DATA_AVAIL" "$DATA_USEP"

# ------ Metadata location dicovery ------
BASE_PATH=$(system --show |
    grep Metadata |
    cut -d':' -f2- |
    xargs) # trims leading/trailing whitespace

if [[ -z "$BASE_PATH" ]]; then
    echo "Error: could not determine metadata location." >&2
    exit 1
fi
echo
echo "Current metadata information and cleaning progress"
echo
echo "Metadata location: $BASE_PATH"

# ------ Meta-data Partition usage ------

# Metadata Partition usage
#    - Extract first directory level of BASE_PATH (e.g. /QSdata)
FIRST_LEVEL="/$(echo "$BASE_PATH" | cut -d'/' -f2)"

#    - Try to grep that mountpoint in a full df -h
PART_USAGE=$(df -h | awk -v mnt="$FIRST_LEVEL" '$NF==mnt {print}')

#    - Fallback: if no match, ask df for the specific path
if [[ -z "$PART_USAGE" ]]; then
    PART_USAGE=$(df -h "$BASE_PATH" | tail -1)
fi

read -r DEVICE SIZE USED AVAIL USEP _ <<<"$PART_USAGE"

#    - Print header + values in columns
echo "Device: $DEVICE"
echo "Metadata Partition Usage:"
printf "%-8s %-8s %-8s %-6s\n" "Size" "Used" "Avail" "Use%"
printf "%-8s %-8s %-8s %-6s\n" \
    "$SIZE" "$USED" "$AVAIL" "$USEP"

# Start of code to expand dictionary size
# Function to ask yes/no question with default 'no'

# ---------- Show current disctionary size ----------
# File whose size we’ll report
DICT_FILE="${BASE_PATH}/dict2"
if [[ ! -f "$DICT_FILE" ]]; then
    echo "Error: File '$DICT_FILE' not found." >&2
    exit 1
fi

# Get size in bytes
BYTES=$(stat -c%s "$DICT_FILE")

# Floor to nearest GiB (integer division)
FLOOR_GIB=$((BYTES / 1024 / 1024 / 1024))

# Also keep the two-decimal float for display
DICT_SIZE=$(awk "BEGIN { printf \"%.2f\", $BYTES/1024/1024/1024 }")
echo
echo "Dictionary Size: $DICT_SIZE GiB"

# Lookup table
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

# Find the largest key <= FLOOR_GIB
size_key=""
for k in $(printf '%s\n' "${!max_keys_map[@]}" | sort -n); do
    if ((FLOOR_GIB >= k)); then
        size_key=$k
    else
        break
    fi
done

if [[ -z "$size_key" ]]; then
    echo "Error: no MAX_KEYS defined for dictionary size ≤ ${FLOOR_GIB} GiB." >&2
    exit 1
fi

MAX_KEYS=${max_keys_map[$size_key]}

# Format MAX_KEYS with commas
if command -v numfmt &>/dev/null; then
    MAX_KEYS_FMT=$(numfmt --grouping "$MAX_KEYS")
else
    # fallback: ensure your locale supports thousands-sep (e.g. en_GB.UTF-8)
    MAX_KEYS_FMT=$(printf "%'d" "$MAX_KEYS")
fi

echo "Using lookup size ${size_key} GiB → MAX KEYS: $MAX_KEYS_FMT"
# ------ Number of consumed dictionary Keys ------

# Show number of consumed keys
# Pull out the total number of deduped records
# (we assume the grep line ends in the number you want)
USED_KEYS_RAW=$(ctrlrpc -p 9911 show.dedupe_stats |
    grep uhd_total_nrecs |
    awk '{print $NF}')

# Format with thousands separators into a new var
if command -v numfmt &>/dev/null; then
    USED_KEYS_FMT=$(numfmt --grouping "$USED_KEYS_RAW")
else
    USED_KEYS_FMT=$(printf "%'d" "$USED_KEYS_RAW")
fi
echo "Used Dictionary Keys: $USED_KEYS_FMT"

# Calculate Percent Used with AWK -v (no commas ever enter the math)
PERCENT_USED=$(awk -v used="$USED_KEYS_RAW" -v max="$MAX_KEYS" \
    'BEGIN {
    if (max <= 0) {
      printf "N/A"
    } else {
      printf "%.2f", (used/max)*100
    }
  }')
echo "Percent Used: $PERCENT_USED %  (using lookup size ${size_key} GiB)"


# ---------- End of showing current dictionary size ----------


# ---------- Gather Information ----------
# Function to get parameters for dictionary expansion.



confirm_action() {
    read -r -p "This action will stop all QoreStor services. Do you want to continue? [y/N] " response
    case "$response" in
    [yY][eE][sS] | [yY])
        return 0 # yes
        ;;
    *)
        echo "Operation cancelled."
        return 1 # no
        ;;
    esac
}

# Run confirmation
if confirm_action; then
    echo "Stopping QoreStor services..."
    # sudo systemctl stop ocards
    echo "faked stopping of service for script testing"

    # Add any additional logic here, e.g., next questions or steps
    echo "'ocards' service stopped."
else
    exit 1
fi
