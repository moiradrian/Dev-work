#!/usr/bin/env bash
# monitor_reclaimed.sh — realtime reclaimed-bytes monitor for ctrlrpc cleaner_status
# Features:
#   1) Colorized delta tracking per group
#   2) CSV trend logging (timestamp, LOCAL, CLOUD, GRAND)
#   3) Interactive interval control: + to speed up, - to slow down, q to quit

set -Eeuo pipefail

# --- Configurable knobs (via env or flags) ---

# Refresh interval controls
INTERVAL="${INTERVAL:-3600}" # default: 1 hour
INTERVAL_STEP=300            # 5 minutes
INTERVAL_MIN=300             # 5 minutes
INTERVAL_MAX=7200            # 2 hours

SOURCE_CMD="ctrlrpc -p 9911 show.cleaner_status" # base command
RECLAIMED_COL=13                                 # fixed column for reclaimed bytes
SKIP_SUMMARY_LINES=12                            # lines to skip after "Cleaner summary"
LOG_FILE=""                                      # CSV log file (auto if --csv)
DEBUG=0
CSV_MODE="${CSV_MODE:-0}"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
BASE_INIT=0
TS_COL="${TS_COL:-4}" # column index that holds the date/time per row

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

# Return human-readable /h (bytes per hour)
rate_hr() {
	local bytes="$1" secs="$2"
	if ((secs <= 0)); then
		printf "n/a"
		return
	fi
	# Integer math: bytes_per_hour = bytes * 3600 / secs
	local r=$(((bytes * 3600) / secs))
	printf "%s/h" "$(hr "$r")"
}

fmt_secs() {
	local s="$1"
	local h=$((s / 3600))
	local m=$(((s % 3600) / 60))
	local out=""
	((h > 0)) && out+="${h}h"
	((m > 0)) && out+="${out:+ }${m}m"
	((h == 0 && m == 0)) && out="0m"
	printf "%s" "$out"
}

# Parse a timestamp to epoch seconds; supports:
#  - MM/DD/YY/HH:MM:SS   e.g. 10/22/25/06:05:20  (assumes 20YY for YY<70)
#  - MM/DD/YYYY/HH:MM:SS e.g. 10/22/2025/06:05:20
to_epoch() {
	local ts="$1" norm
	# MM/DD/YY/HH:MM:SS
	if [[ "$ts" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{2})/([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
		local MM="${BASH_REMATCH[1]}" DD="${BASH_REMATCH[2]}" YY="${BASH_REMATCH[3]}"
		local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}" ss="${BASH_REMATCH[6]}"
		# pick century: 00–69 => 2000s, 70–99 => 1900s (adjust if you prefer)
		local YYYY
		if ((10#$YY >= 70)); then YYYY=$((1900 + 10#$YY)); else YYYY=$((2000 + 10#$YY)); fi
		norm=$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$YYYY" "$MM" "$DD" "$hh" "$mm" "$ss")
		date -d "$norm" +%s 2>/dev/null || gdate -d "$norm" +%s 2>/dev/null || echo ""
		return
	fi
	# MM/DD/YYYY/HH:MM:SS
	if [[ "$ts" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4})/([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
		local MM="${BASH_REMATCH[1]}" DD="${BASH_REMATCH[2]}" YYYY="${BASH_REMATCH[3]}"
		local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}" ss="${BASH_REMATCH[6]}"
		norm=$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$YYYY" "$MM" "$DD" "$hh" "$mm" "$ss")
		date -d "$norm" +%s 2>/dev/null || gdate -d "$norm" +%s 2>/dev/null || echo ""
		return
	fi
	# Fallback: let date/gdate try the original string
	date -d "$ts" +%s 2>/dev/null || gdate -d "$ts" +%s 2>/dev/null || echo ""
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
	# echo "Source: ${SOURCE_CMD}   |  Column: ${RECLAIMED_COL}   |  Skip summary lines: ${SKIP_SUMMARY_LINES}"
	echo "Controls: '+' faster (-5m), '-' slower (+5m), 'q' quit   |   Refresh every $(fmt_secs "$INTERVAL")"
	echo "--------------------------------------------------------------------------------"
	if [[ -n "$LOG_FILE" ]]; then
		echo "Logging CSV to: ${CLR_DIM}${LOG_FILE}${CLR_RESET}"
		echo "--------------------------------------------------------------------------------"
	fi

	# Run producer and parse bytes per group (raw integers). Output TSV: GROUP<TAB>BYTES, one per line.
	# We intentionally do not format in awk; keep raw numbers so we can compute deltas & log easily.
	# shellcheck disable=SC2086
	mapfile -t lines < <(eval "$SOURCE_CMD" | awk -v RC="$RECLAIMED_COL" -v TC="$TS_COL" -v SKIPN="$SKIP_SUMMARY_LINES" -v DEBUG="$DEBUG" '
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
			if (curgrp=="" || NF<RC || NF<TC) next

			ts  = $TC
			raw = $RC

			# Record the first *non-header* timestamp we see for this group.
			# (Column 4 header is literally "start"; skip that.)
			if (!(curgrp in start_ts)) {
			if (tolower(ts) !~ /^start$/) start_ts[curgrp] = ts
			}

			# ignore header echoes in reclaimed column
			if (tolower(raw) ~ /^reclaimed(\(bytes\))?$/) next

			gsub(/,/, "", raw)

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
			printf("LOCAL\t%d\t%s\n", (total["LOCAL"] ? total["LOCAL"] : 0), (start_ts["LOCAL"]?start_ts["LOCAL"]:""))
			printf("CLOUD\t%d\t%s\n", (total["CLOUD"] ? total["CLOUD"] : 0), (start_ts["CLOUD"]?start_ts["CLOUD"]:""))
			printf("GRAND\t%d\t\n", grand + 0)
		}
		')

	# Parse into current map + period start
	declare -A curr=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)
	declare -A period_start=([LOCAL]="" [CLOUD]="" [GRAND]="")

	for ln in "${lines[@]}"; do
		# split TSV into 3 parts
		IFS=$'\t' read -r g v pstart <<<"$ln"
		[[ "$g" =~ ^(LOCAL|CLOUD|GRAND)$ ]] || continue
		curr[$g]="$v"
		period_start[$g]="$pstart"
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
	# Auto re-baseline if totals dropped below baseline (window shrink, reset)
	for g in LOCAL CLOUD GRAND; do
		if ((curr[$g] < base[$g])); then
			((DEBUG)) && echo "[DEBUG] Rebaseline: $g dropped (base=${base[$g]} -> curr=${curr[$g]})" >&2
			base[$g]=${curr[$g]}
			# Also sync prev so the next step delta doesn't show a huge negative blip
			prev[$g]=${curr[$g]}
		fi
	done

	# Compute deltas and display (two lines per section to avoid wide overflow)
	now_epoch="$(date +%s)"
	term_cols="$(tput cols 2>/dev/null || echo 120)"

	for g in LOCAL CLOUD GRAND; do
		total="${curr[$g]}"
		delta_step=$((total - prev[$g])) # change since last tick
		delta_cum=$((total - base[$g]))  # change since monitor start
		pstart="${period_start[$g]}"

		# First line: total + cumulative delta (+ step delta dim)
		line1=$(printf "%-6s total reclaimed: %-12s  (since monitor start: %s  %sstep: %s%s)" \
			"$g" "$(hr "$total")" \
			"$(fmt_delta "$delta_cum")" \
			"$CLR_DIM" "$(fmt_delta "$delta_step")" "$CLR_RESET")

		# Second line: period start + rate (LOCAL/CLOUD only)
		if [[ -n "$pstart" && "$g" != "GRAND" ]]; then
			# compute elapsed seconds and rate
			ps_epoch="$(to_epoch "$pstart")"
			if [[ -n "$ps_epoch" ]]; then
				elapsed=$((now_epoch - ps_epoch))
				rate="$(rate_hr "$total" "$elapsed")"
			else
				elapsed=0
				rate="n/a"
			fi
			line2=$(printf "  cleaner period start: %s   |   avg reclaim rate: %s" "$pstart" "$rate")
		else
			line2=""
		fi

		# print with simple width guard (truncate with … if needed)
		if ((${#line1} > term_cols)); then
			echo "${line1:0:term_cols-1}…"
		else
			echo "$line1"
		fi
		if [[ -n "$line2" ]]; then
			if ((${#line2} > term_cols)); then
				echo "${line2:0:term_cols-1}…"
			else
				echo "$line2"
			fi
		fi
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
	echo "(Press '+' / '-' / 'r' / 'q')  Next refresh in $(fmt_secs "$INTERVAL")"

	# Sleep with key polling for INTERVAL seconds
	end=$((SECONDS + INTERVAL))
	while ((SECONDS < end)); do
		if read -r -n1 -t 0.1 key; then
			case "$key" in
			+) # faster (decrease interval)
				INTERVAL=$((INTERVAL - INTERVAL_STEP))
				((INTERVAL < INTERVAL_MIN)) && INTERVAL="$INTERVAL_MIN"
				break
				;;
			-) # slower (increase interval)
				INTERVAL=$((INTERVAL + INTERVAL_STEP))
				((INTERVAL > INTERVAL_MAX)) && INTERVAL="$INTERVAL_MAX"
				break
				;;
			[rR] | " ") # manual refresh (space or 'r')
				break      # just break out of the wait loop early
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
