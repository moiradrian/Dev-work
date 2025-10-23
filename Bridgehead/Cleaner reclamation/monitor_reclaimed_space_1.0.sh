#!/usr/bin/env bash
# monitor_reclaimed.sh — realtime reclaimed-bytes monitor for ctrlrpc cleaner_status
# Features:
#   1) Colorized delta tracking per group
#   2) CSV trend logging (timestamp, LOCAL, CLOUD, GRAND)
#   3) Interactive interval control: + to speed up, - to slow down, q to quit

set -Eeuo pipefail

# --- Configurable knobs (via env or flags) ---
INTERVAL=10                                      # default refresh interval
SOURCE_CMD="ctrlrpc -p 9911 show.cleaner_status" # base command
RECLAIMED_COL=13                                 # fixed column for reclaimed bytes
SKIP_SUMMARY_LINES=12                            # lines to skip after "Cleaner summary"
LOG_FILE=""                                      # CSV log file (auto if --csv)
DEBUG=0
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
BASE_INIT=0

# Baseline totals captured at first successful parse
declare -A base=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)

# --- Parse args ---
while [[ $# -gt 0 ]]; do
	case "$1" in
	--csv)
		CSV_MODE=1
		;;
	--csv=*)
		CSV_MODE=1
		LOG_FILE="${1#*=}"
		;;
	--interval | -i)
		INTERVAL="${2:-10}"
		shift
		;;
	--col | --column)
		RECLAIMED_COL="${2:-13}"
		shift
		;;
	--skip)
		SKIP_SUMMARY_LINES="${2:-12}"
		shift
		;;
	--debug)
		DEBUG=1
		;;
	-h | --help)
		echo "Usage: $0 [--csv[=FILE]] [--interval SECS] [--col N] [--skip N] [--debug]"
		echo
		echo "Examples:"
		echo "  $0 --csv                         # write CSV to ./reclaimed_trend_TIMESTAMP.csv"
		echo "  $0 --csv=/var/log/reclaimed.csv  # specify exact log file"
		echo "  $0 --interval 5 --debug          # 5s refresh with debug output"
		exit 0
		;;
	*)
		echo "Unknown option: $1"
		echo "Try '$0 --help'"
		exit 1
		;;
	esac
	shift
done

# Default CSV filename if --csv used with no name
if ((CSV_MODE == 1)) && [[ -z "$LOG_FILE" ]]; then
	LOG_FILE="./reclaimed_trend_$(date '+%Y%m%d_%H%M%S').csv"
fi

# --- TTY handling ---
cleanup() {
	tput cnorm || true
	stty echo -icanon time 1 min 0 2>/dev/null || true
}
trap cleanup EXIT INT TERM
tput civis
stty -echo -icanon time 0 min 0 2>/dev/null || true # immediate keypresses

# --- Colors ---
if tput colors >/dev/null 2>&1; then
	CLR_GREEN="$(tput setaf 2)"
	CLR_RED="$(tput setaf 1)"
	CLR_DIM="$(tput dim)"
	CLR_BOLD="$(tput bold)"
	CLR_RESET="$(tput sgr0)"
else
	CLR_GREEN=""
	CLR_RED=""
	CLR_DIM=""
	CLR_BOLD=""
	CLR_RESET=""
fi

# --- Human-readable helper (prefers numfmt if present) ---
hr() {
	local bytes="$1"
	if command -v numfmt >/dev/null 2>&1; then
		numfmt --to=iec --suffix=B "$bytes"
	else
		# fallback IEC
		local units=(B KiB MiB GiB TiB PiB)
		local i=0
		local val="$bytes"
		while ((val >= 1024 && i < ${#units[@]} - 1)); do
			val=$(((val + 512) / 1024))
			((i++))
		done
		if ((i == 0)); then
			printf "%d %s" "$val" "${units[i]}"
		else
			# show two decimals for non-bytes
			awk -v n="$bytes" -v p="$i" 'BEGIN{
        split("B KiB MiB GiB TiB PiB",u," ");
        for(i=1;i<p;i++) n/=1024;
        printf("%.2f %s", n, u[p+1]);
      }'
		fi
	fi
}

# --- Delta formatter ---
fmt_delta() {
	local d="$1"
	if ((d > 0)); then
		printf "%s+%s%s" "$CLR_GREEN" "$(hr "$d")" "$CLR_RESET"
	elif ((d < 0)); then
		# show negative deltas in red
		local ad=$((-d))
		printf "%s-%s%s" "$CLR_RED" "$(hr "$ad")" "$CLR_RESET"
	else
		printf "%s+0 B%s" "$CLR_DIM" "$CLR_RESET"
	fi
}

# Store previous totals
declare -A prev=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)

# Ensure CSV has header if logging
init_log() {
	[[ -z "$LOG_FILE" ]] && return 0
	if [[ ! -s "$LOG_FILE" ]]; then
		echo "timestamp,LOCAL_bytes,CLOUD_bytes,GRAND_bytes" >>"$LOG_FILE"
	fi
}

init_log

# --- Main loop ---
while true; do
	clear
	printf "%sReclaimed totals%s (started: %s | updated: %s)\n" \
		"$CLR_BOLD" "$CLR_RESET" "$START_TIME" "$(date '+%Y-%m-%d %H:%M:%S')"
	echo "Source: ${SOURCE_CMD}   |  Column: ${RECLAIMED_COL}   |  Skip summary lines: ${SKIP_SUMMARY_LINES}"
	echo "Controls: '+' faster, '-' slower, 'q' quit   |   Refresh every ${INTERVAL}s"
	echo "--------------------------------------------------------------------------------"
	if [[ -n "$LOG_FILE" ]]; then
		echo "Logging CSV to: ${CLR_DIM}${LOG_FILE}${CLR_RESET}"
		echo "--------------------------------------------------------------------------------"
	fi

	# Run producer and parse bytes per group (raw integers). Output TSV: GROUP<TAB>BYTES, one per line.
	# We intentionally do not format in awk; keep raw numbers so we can compute deltas & log easily.
	# shellcheck disable=SC2086
	mapfile -t lines < <(eval "$SOURCE_CMD" | awk -v RC="$RECLAIMED_COL" -v SKIPN="$SKIP_SUMMARY_LINES" -v DEBUG="$DEBUG" '
    BEGIN { IGNORECASE=1; skip=0 }

    # Ignore "Cleaner summary" blocks
    /^[[:space:]]*Cleaner[[:space:]]+summary/ { skip = SKIPN; next }
    skip>0 { skip--; next }

    # Groups: "Resource Group : LOCAL :" or variants
    /[[:space:]]*Resource[[:space:]]+Group/ {
      split($0, parts, ":")
      grp = (length(parts)>=2?parts[2]:$NF)
      gsub(/^[[:space:]]+|[[:space:]]+$/,"", grp); gsub(/:/,"", grp)
      if (grp!="") curgrp=grp
      next
    }

    {
      # Guard against short lines
      if (NF<RC || curgrp=="") next

      raw = $RC
      # ignore header echoes
      if (tolower(raw) ~ /^reclaimed(\(bytes\))?$/) next

      gsub(/,/, "", raw)

      # Prefer pure integer bytes at field start
      bytes = 0
      if (match(raw, /^[[:space:]]*([0-9]+)/, m)) {
        bytes = m[1] + 0
      } else if (match(raw, /([0-9]+(\.[0-9]+)?)\s*([KMGTP]i?B?)/i, u)) {
        val=u[1]+0.0; unit=toupper(u[3]); f=1
        if (unit ~ /^KI?B?$/) f=1024
        else if (unit ~ /^MI?B?$/) f=1024^2
        else if (unit ~ /^GI?B?$/) f=1024^3
        else if (unit ~ /^TI?B?$/) f=1024^4
        else if (unit ~ /^PI?B?$/) f=1024^5
        bytes = int(val*f + 0.5)
      }

      if (bytes>0) {
        total[curgrp] += bytes
        grand += bytes
      }
    }

    END {
      # Always print all known groups
      printf("LOCAL\t%d\n", (total["LOCAL"] ? total["LOCAL"] : 0))
      printf("CLOUD\t%d\n", (total["CLOUD"] ? total["CLOUD"] : 0))
      printf("GRAND\t%d\n", grand + 0)
    }
  ')

	# Parse into current map
	declare -A curr=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)
	for ln in "${lines[@]}"; do
		g="${ln%%$'\t'*}"
		v="${ln#*$'\t'}"
		[[ "$g" =~ ^(LOCAL|CLOUD|GRAND)$ ]] || continue
		curr[$g]="$v"
	done

	# Initialize baseline totals on first loop
	if ((BASE_INIT == 0)); then
		base[LOCAL]="${curr[LOCAL]}"
		base[CLOUD]="${curr[CLOUD]}"
		base[GRAND]="${curr[GRAND]}"
		prev[LOCAL]="${curr[LOCAL]}"
		prev[CLOUD]="${curr[CLOUD]}"
		prev[GRAND]="${curr[GRAND]}"
		BASE_INIT=1
	fi

	# Compute deltas and display
	for g in LOCAL CLOUD GRAND; do
		total="${curr[$g]}"
		delta_step=$((total - prev[$g])) # change since last refresh
		delta_cum=$((total - base[$g]))  # change since monitor started

		# main: cumulative delta since start; side: per-interval delta in dim text
		printf "%-6s total reclaimed: %-12s  (since start: %s  %sstep: %s%s)\n" \
			"$g" "$(hr "$total")" \
			"$(fmt_delta "$delta_cum")" \
			"$CLR_DIM" "$(fmt_delta "$delta_step")" "$CLR_RESET"
	done

	# Log to CSV if requested
	if [[ -n "$LOG_FILE" ]]; then
		printf "%s,%d,%d,%d\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${curr[LOCAL]}" "${curr[CLOUD]}" "${curr[GRAND]}" >>"$LOG_FILE"
	fi

	# Set prev for next loop
	prev[LOCAL]="${curr[LOCAL]}"
	prev[CLOUD]="${curr[CLOUD]}"
	prev[GRAND]="${curr[GRAND]}"

	echo
	echo "(Press '+' / '-' / 'q')  Next refresh in ${INTERVAL}s"

	# Sleep with key polling for INTERVAL seconds
	end=$((SECONDS + INTERVAL))
	while ((SECONDS < end)); do
		# Read a single key without blocking
		if read -r -n1 -t 0.1 key; then
			case "$key" in
			+)
				((INTERVAL > 1)) && INTERVAL=$((INTERVAL - 1))
				break
				;;
			-)
				INTERVAL=$((INTERVAL + 1))
				break
				;;
			q | Q)
				echo
				echo "Exiting."
				exit 0
				;;
			esac
		fi
	done
done
