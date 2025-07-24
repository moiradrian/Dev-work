#!/usr/bin/env bash
# Base directory for Meta-data
BASE_PATH="/QSdata/qs_metadata"

# ------ Ref Count Logs ------

# Directory to count ref count logs
# Check that the directory exists
DIR="$BASE_PATH/0/refcnt_log"
if [[ ! -d "$DIR" ]]; then
  echo "Error: Directory '$DIR' not found." >&2
  exit 1
fi
# Count of refcount logs showing cleaner progress - 0 is completed.
# Count only regular files
COUNT=$(find "$DIR" -maxdepth 1 -type f | wc -l)
echo "ref count logs: $COUNT"

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

echo "Dictionary Size: $DICT_SIZE GiB"

# ------ Number of consumed dictionary Keys ------

# Show number of consumed keys
# Pull out the total number of deduped records
# (we assume the grep line ends in the number you want)
USED_KEYS=$(ctrlrpc -p 9911 show.dedupe_stats \
            | grep uhd_total_nrecs \
            | awk '{print $NF}')

echo "Used Dictionary Keys: $USED_KEYS"

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
  if (( CEIL_SIZE <= k )); then
    size_key=$k
    break
  fi
done

if [[ -z "$size_key" ]]; then
  echo "Error: no MAX_KEYS defined for dictionary size ≥ ${CEIL_SIZE} GiB." >&2
  exit 1
fi

MAX_KEYS=${max_keys_map[$size_key]}

# Calculate and show percent used
PERCENT_USED=$(awk "BEGIN { printf \"%.2f\", ($USED_KEYS/$MAX_KEYS)*100 }")
echo "Percent Used: $PERCENT_USED %  (using lookup size ${size_key} GiB)"

# ------ Cleaner Stats ------

# Cleaner stats
# Header for output
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
 