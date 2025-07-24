#!/usr/bin/env bash

# ------ Get mode variable for cleaner info ------

MODE="$1"

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

# ------ Dictionary Size ------
# File whose size we’ll report
DICT_FILE="${BASE_PATH}/dict2"
# Check if dict2 file exisits
if [[ ! -f "$DICT_FILE" ]]; then
    echo "Error: File '$DICT_FILE' not found." >&2
    exit 1
fi
# Get size in bytes, convert to GiB with two decimals
BYTES=$(stat -c%s "$DICT_FILE")
DICT_SIZE=$(awk "BEGIN { printf \"%.2f\", $BYTES/1024/1024/1024 }")

echo
echo "Dictionary Size: $DICT_SIZE GiB"

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

# ------ Compute the current dictionary percentage used ------

# Lookup table: map DICT_SIZE (GiB) → MAX_KEYS
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

# Round dict size to match keys in our table
# First, compute the ceiling of DICT_SIZE as an integer
CEIL_SIZE=$(awk "BEGIN { if ($DICT_SIZE == int($DICT_SIZE)) printf \"%d\", $DICT_SIZE; else printf \"%d\", int($DICT_SIZE)+1 }")

# Then find the smallest lookup key >= CEIL_SIZE
size_key=""
for k in $(printf '%s\n' "${!max_keys_map[@]}" | sort -n); do
    if ((CEIL_SIZE <= k)); then
        size_key=$k
        break
    fi
done

if [[ -z "$size_key" ]]; then
    echo "Error: no MAX_KEYS defined for dictionary size ≥ ${CEIL_SIZE} GiB." >&2
    exit 1
fi

MAX_KEYS=${max_keys_map[$size_key]}

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

# ------ Cleaner Stats & Ref count logs ------

# Directory to count ref count logs
# Check that the directory exists
DIR="$BASE_PATH/0/refcnt_log"
if [[ ! -d "$DIR" ]]; then
    echo "Error: Directory '$DIR' not found." >&2
    exit 1
fi
# Count of refcount logs showing cleaner progress - 0 is completed.
# Count only regular files
COUNT=$(find "$DIR" -type f ! -name '.timestamp*' | wc -l)
echo
echo "ref-count logs: $COUNT"

# Cleaner stats
# Header for output
echo
echo "Storage Group Cleaning Phases:"
echo "SGID            pl      nl      zl      cl"
echo "------------------------------------------"

# Find all numeric sgid directories and process them
find "$BASE_PATH" -maxdepth 1 -type d -not -path "$BASE_PATH" -name '[0-9]*' | while read -r sgid_dir; do
    sgid=$(basename "$sgid_dir")
    # Verify sgid is numeric
    if [[ "$sgid" =~ ^[0-9]+$ ]]; then
        refcnt_log="$sgid_dir/refcnt_log"

        # Initialize counts
        pl_count=0
        nl_count=0
        zl_count=0
        cl_count=0

        # Check if refcnt_log exists
        if [ -d "$refcnt_log" ]; then
            # Count files in each subdirectory
            [ -d "$refcnt_log/pl" ] && pl_count=$(find "$refcnt_log/pl" -maxdepth 1 -type f | wc -l)
            [ -d "$refcnt_log/nl" ] && nl_count=$(find "$refcnt_log/nl" -maxdepth 1 -type f | wc -l)
            [ -d "$refcnt_log/zl" ] && zl_count=$(find "$refcnt_log/zl" -maxdepth 1 -type f | wc -l)
            [ -d "$refcnt_log/cl" ] && cl_count=$(find "$refcnt_log/cl" -maxdepth 1 -type f | wc -l)
        fi

        # Print row with fixed-width formatting for watch compatibility
        printf "%-15s %-7s %-7s %-7s %-7s\n" "$sgid" "$pl_count" "$nl_count" "$zl_count" "$cl_count"
    fi
done

# only fetch & filter if MODE is set to one of the two
if [[ "$MODE" == "--local" || "$MODE" == "--cloud" ]]; then

    # grab the full cleaner_adminstats once
    CLEANER_STATS=$(ctrlrpc -p 9911 show.cleaner_adminstats)

    # filter based on MODE
    if [[ "$MODE" == "local" ]]; then
        # print everything up to (but not including) the "Cloud cleaner:" line
        echo
        echo "$CLEANER_STATS" | awk '/^Cloud cleaner:/ { exit } { print }'
    else
        # print from the "Cloud cleaner:" line through the end
        echo
        echo "$CLEANER_STATS" | awk '/^Cloud cleaner:/ { in_cloud=1 } in_cloud'
    fi
elif [[ -n "$MODE" ]]; then
    # user passed something invalid
    echo "Error: Invalid mode '$MODE'. Use 'local' or 'cloud'." >&2
    exit 1
fi
