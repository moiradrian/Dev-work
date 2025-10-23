#!/usr/bin/env bash
# monitor_reclaimed.sh — realtime reclaimed-bytes monitor for ctrlrpc cleaner_status
# Adds:
#   • Sparklines for rate (bytes/hour)
#   • Alerts on high rate
#   • Keys: h help, p pause, b baseline, r/space refresh, +/- interval, q quit
#   • Width-safe two-line output per section

set -Eeuo pipefail

# --- Configurable knobs (via env or flags) ---

# Refresh interval controls (default hourly; +/- steps of 5 min; clamp 5m..2h)
INTERVAL="${INTERVAL:-3600}" # 1 hour
INTERVAL_STEP=300            # 5 minutes
INTERVAL_MIN=300             # 5 minutes
INTERVAL_MAX=7200            # 2 hours

SOURCE_CMD="ctrlrpc -p 9911 show.cleaner_status"
RECLAIMED_COL=13
SKIP_SUMMARY_LINES=12
LOG_FILE="" # CSV file path (auto-set if --csv)
DEBUG=0
CSV_MODE="${CSV_MODE:-0}"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
BASE_INIT=0
TS_COL="${TS_COL:-4}" # column holding timestamp text

# Alerts (bytes/hour). Default ~32 GiB/h
ALERT_RATE_BPH="${ALERT_RATE_BPH:-34359738368}"
ALERTS_ON="${ALERTS_ON:-1}"

# Sparklines: number of samples to retain
SPARK_POINTS="${SPARK_POINTS:-30}"

# State flags
PAUSED=0
SHOW_HELP=0

# --- Parse args ---
while [[ $# -gt 0 ]]; do
	case "$1" in
	--csv) CSV_MODE=1 ;;
	--csv=*)
		CSV_MODE=1
		LOG_FILE="${1#*=}"
		;;
	--interval | -i)
		INTERVAL="${2:-3600}"
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
	--debug) DEBUG=1 ;;
	-h | --help)
		echo "Usage: $0 [--csv[=FILE]] [--interval SECS] [--col N] [--skip N] [--debug]"
		echo "Keys: + faster (-5m), - slower (+5m), r/space refresh, p pause, b baseline, h help, q quit"
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

# Clamp initial interval
((INTERVAL < INTERVAL_MIN)) && INTERVAL="$INTERVAL_MIN"
((INTERVAL > INTERVAL_MAX)) && INTERVAL="$INTERVAL_MAX"

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

# --- Human-readable helpers ---
hr() { # prefers numfmt if available
	local bytes="$1"
	if command -v numfmt >/dev/null 2>&1; then
		numfmt --to=iec --suffix=B "$bytes"
	else
		local units=(B KiB MiB GiB TiB PiB) i=0 val="$bytes"
		while ((val >= 1024 && i < ${#units[@]} - 1)); do
			val=$(((val + 512) / 1024))
			((i++))
		done
		if ((i == 0)); then printf "%d %s" "$val" "${units[i]}"; else
			awk -v n="$bytes" -v p="$i" 'BEGIN{split("B KiB MiB GiB TiB PiB",u," ");for(i=1;i<p;i++)n/=1024;printf("%.2f %s",n,u[p+1])}'
		fi
	fi
}

fmt_delta() {
	local d="$1"
	if ((d > 0)); then
		printf "%s+%s%s" "$CLR_GREEN" "$(hr "$d")" "$CLR_RESET"
	elif ((d < 0)); then
		local ad=$((-d))
		printf "%s-%s%s" "$CLR_RED" "$(hr "$ad")" "$CLR_RESET"
	else
		printf "%s+0 B%s" "$CLR_DIM" "$CLR_RESET"
	fi
}

fmt_secs() {
	local s="${1:-0}" # default to 0 if missing
	# coerce to integer safely (avoid octal and nounset issues)
	case "$s" in
	'' | *[!0-9]*) s=0 ;;
	esac
	local h=$((10#$s / 3600))
	local m=$(((10#$s % 3600) / 60))
	local out=""
	((h > 0)) && out+="${h}h"
	((m > 0)) && out+="${out:+ }${m}m"
	[[ -z "$out" ]] && out="0m"
	printf "%s" "$out"
}

# Bytes/hour as integer
rate_bph() {
	local bytes="$1" secs="$2"
	((secs <= 0)) && {
		echo 0
		return
	}
	echo $(((bytes * 3600) / secs))
}

# Pretty rate
rate_hr() {
	local bytes="$1" secs="$2" r
	r="$(rate_bph "$bytes" "$secs")"
	((r == 0)) && {
		printf "n/a"
		return
	}
	printf "%s/h" "$(hr "$r")"
}

# Timestamp parser:
#  - MM/DD/YY/HH:MM:SS   (assumes 20YY for YY<70)
#  - MM/DD/YYYY/HH:MM:SS
to_epoch() {
	local ts="$1" norm
	if [[ "$ts" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{2})/([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
		local MM="${BASH_REMATCH[1]}" DD="${BASH_REMATCH[2]}" YY="${BASH_REMATCH[3]}"
		local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}" ss="${BASH_REMATCH[6]}" YYYY
		if ((10#$YY >= 70)); then YYYY=$((1900 + 10#$YY)); else YYYY=$((2000 + 10#$YY)); fi
		norm=$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$YYYY" "$MM" "$DD" "$hh" "$mm" "$ss")
		date -d "$norm" +%s 2>/dev/null || gdate -d "$norm" +%s 2>/dev/null || echo ""
		return
	fi
	if [[ "$ts" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4})/([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
		local MM="${BASH_REMATCH[1]}" DD="${BASH_REMATCH[2]}" YYYY="${BASH_REMATCH[3]}"
		local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}" ss="${BASH_REMATCH[6]}"
		norm=$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$YYYY" "$MM" "$DD" "$hh" "$mm" "$ss")
		date -d "$norm" +%s 2>/dev/null || gdate -d "$norm" +%s 2>/dev/null || echo ""
		return
	fi
	date -d "$ts" +%s 2>/dev/null || gdate -d "$ts" +%s 2>/dev/null || echo ""
}

# Sparkline from integer list (bytes/hour)
spark() {
	[[ -z "${1-}" ]] && {
		echo " "
		return
	}
	local vals=($1) max=0 out=""
	for v in "${vals[@]}"; do ((v > max)) && max=$v; done
	((max == 0)) && {
		echo " "
		return
	}
	local blocks=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
	for v in "${vals[@]}"; do
		local idx=$((v * (${#blocks[@]} - 1) / max))
		((idx < 0)) && idx=0
		((idx > ${#blocks[@]} - 1)) && idx=${#blocks[@]}-1
		out+="${blocks[$idx]}"
	done
	echo "$out"
}

alert_if_rate_high() {
	local label="$1" rate_bph="$2"
	if ((ALERTS_ON == 1 && rate_bph >= ALERT_RATE_BPH)); then
		printf "%s[ALERT]%s %s rate high: %s/h\n" "$CLR_RED" "$CLR_RESET" "$label" "$(hr "$rate_bph")"
		printf "\a"
	fi
}

# Store totals
declare -A base=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)
declare -A prev=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)

# Sparkline buffers
declare -a rate_local=()
declare -a rate_cloud=()

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
	echo "Controls: '+' faster (-5m), '-' slower (+5m), 'r'/space refresh, 'p' pause, 'b' baseline, 'h' help, 'q' quit"
	echo "Refresh every $(fmt_secs "$INTERVAL")"
	if [[ -n "$LOG_FILE" ]]; then
		echo "Logging CSV to: ${CLR_DIM}${LOG_FILE}${CLR_RESET}"
	fi
	echo "--------------------------------------------------------------------------------"
	if ((SHOW_HELP)); then
		echo "${CLR_BOLD}Keys:${CLR_RESET} + faster  - slower  r/space refresh  p pause  b baseline  h help  q quit"
		echo "Alerts when rate ≥ $(hr "$ALERT_RATE_BPH")/h  |  Sparkline window: ${SPARK_POINTS} samples"
		echo "--------------------------------------------------------------------------------"
	fi

	# shellcheck disable=SC2086
	mapfile -t lines < <(eval "$SOURCE_CMD" | awk -v RC="$RECLAIMED_COL" -v TC="$TS_COL" -v SKIPN="$SKIP_SUMMARY_LINES" -v DEBUG="$DEBUG" '
    BEGIN { IGNORECASE=1; skip=0 }
    /^[[:space:]]*Cleaner[[:space:]]+summary/ { skip = SKIPN; next }
    skip>0 { skip--; next }
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

      # first non-header timestamp per group
      if (!(curgrp in start_ts)) {
        if (tolower(ts) !~ /^start$/) start_ts[curgrp] = ts
      }

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
		IFS=$'\t' read -r g v pstart <<<"$ln"
		[[ "$g" =~ ^(LOCAL|CLOUD|GRAND)$ ]] || continue
		curr[$g]="$v"
		period_start[$g]="$pstart"
	done

	# Initialize baseline on first loop
	if ((BASE_INIT == 0)); then
		base[LOCAL]="${curr[LOCAL]}"
		base[CLOUD]="${curr[CLOUD]}"
		base[GRAND]="${curr[GRAND]}"
		prev[LOCAL]="${curr[LOCAL]}"
		prev[CLOUD]="${curr[CLOUD]}"
		prev[GRAND]="${curr[GRAND]}"
		BASE_INIT=1
	fi

	# Auto re-baseline if totals dropped below baseline (window shrink/reset)
	for g in LOCAL CLOUD GRAND; do
		if ((curr[$g] < base[$g])); then
			((DEBUG)) && echo "[DEBUG] Rebaseline: $g dropped (base=${base[$g]} -> curr=${curr[$g]})" >&2
			base[$g]=${curr[$g]}
			prev[$g]=${curr[$g]}
		fi
	done

	# Display (two lines per section) + spark + alerts
	now_epoch="$(date +%s)"
	term_cols="$(tput cols 2>/dev/null || echo 120)"

	for g in LOCAL CLOUD GRAND; do
		total="${curr[$g]}"
		delta_step=$((total - prev[$g]))
		delta_cum=$((total - base[$g]))
		pstart="${period_start[$g]}"

		line1=$(printf "%-6s total reclaimed: %-12s  (since monitor start: %s  %sstep: %s%s)" \
			"$g" "$(hr "$total")" "$(fmt_delta "$delta_cum")" "$CLR_DIM" "$(fmt_delta "$delta_step")" "$CLR_RESET")

		if [[ -n "$pstart" && "$g" != "GRAND" ]]; then
			ps_epoch="$(to_epoch "$pstart")"
			if [[ -n "$ps_epoch" ]]; then
				elapsed=$((now_epoch - ps_epoch))
				rate_text="$(rate_hr "$total" "$elapsed")"
				rate_int="$(rate_bph "$total" "$elapsed")" # integer bytes/hour for spark + alerts
			else
				elapsed=0
				rate_text="n/a"
				rate_int=0
			fi
			line2=$(printf "  cleaner period start: %s   |   avg reclaim rate: %s" "$pstart" "$rate_text")

			# Update spark buffers
			if [[ "$g" == "LOCAL" ]]; then
				rate_local+=("$rate_int")
				((${#rate_local[@]} > SPARK_POINTS)) && rate_local=("${rate_local[@]: -$SPARK_POINTS}")
			elif [[ "$g" == "CLOUD" ]]; then
				rate_cloud+=("$rate_int")
				((${#rate_cloud[@]} > SPARK_POINTS)) && rate_cloud=("${rate_cloud[@]: -$SPARK_POINTS}")
			fi

			# Alert if high
			alert_if_rate_high "$g" "$rate_int"
		else
			line2=""
		fi

		# Width guard + print
		if ((${#line1} > term_cols)); then echo "${line1:0:term_cols-1}…"; else echo "$line1"; fi
		if [[ -n "$line2" ]]; then
			if ((${#line2} > term_cols)); then echo "${line2:0:term_cols-1}…"; else echo "$line2"; fi
		fi

		# Print sparkline if we have enough points
		if [[ "$g" == "LOCAL" && ${#rate_local[@]} -gt 1 ]]; then
			echo "  rate spark: $(spark "${rate_local[*]}")"
		fi
		if [[ "$g" == "CLOUD" && ${#rate_cloud[@]} -gt 1 ]]; then
			echo "  rate spark: $(spark "${rate_cloud[*]}")"
		fi
	done

	# CSV log of raw totals (unchanged by baseline)
	if [[ -n "$LOG_FILE" ]]; then
		printf "%s,%d,%d,%d\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${curr[LOCAL]}" "${curr[CLOUD]}" "${curr[GRAND]}" >>"$LOG_FILE"
	fi

	# Update prev for next loop
	prev[LOCAL]="${curr[LOCAL]}"
	prev[CLOUD]="${curr[CLOUD]}"
	prev[GRAND]="${curr[GRAND]}"

	echo
	if ((PAUSED)); then
		echo "(PAUSED) Press 'p' to resume. Keys: + - r/space b h q"
	else
		echo "(Press '+' / '-' / 'r' / space / 'p' / 'b' / 'h' / 'q')  Next refresh in $(fmt_secs "$INTERVAL")"
	fi

	# Wait loop: timed or paused with key handling
	if ((PAUSED)); then
		while true; do
			if read -r -n1 -t 0.1 key; then
				case "$key" in
				p | P)
					PAUSED=0
					break
					;;
				[rR] | " ") break ;; # manual refresh
				+)
					INTERVAL=$((INTERVAL - INTERVAL_STEP))
					((INTERVAL < INTERVAL_MIN)) && INTERVAL="$INTERVAL_MIN"
					break
					;;
				-)
					INTERVAL=$((INTERVAL + INTERVAL_STEP))
					((INTERVAL > INTERVAL_MAX)) && INTERVAL="$INTERVAL_MAX"
					break
					;;
				b | B)
					base[LOCAL]="${curr[LOCAL]}"
					base[CLOUD]="${curr[CLOUD]}"
					base[GRAND]="${curr[GRAND]}"
					prev[LOCAL]="${curr[LOCAL]}"
					prev[CLOUD]="${curr[CLOUD]}"
					prev[GRAND]="${curr[GRAND]}"
					;;
				h | H) SHOW_HELP=$((1 - SHOW_HELP)) ;;
				q | Q)
					echo
					echo "Exiting."
					exit 0
					;;
				esac
			fi
		done
	else
		end=$((SECONDS + INTERVAL))
		while ((SECONDS < end)); do
			if read -r -n1 -t 0.1 key; then
				case "$key" in
				+)
					INTERVAL=$((INTERVAL - INTERVAL_STEP))
					((INTERVAL < INTERVAL_MIN)) && INTERVAL="$INTERVAL_MIN"
					break
					;;
				-)
					INTERVAL=$((INTERVAL + INTERVAL_STEP))
					((INTERVAL > INTERVAL_MAX)) && INTERVAL="$INTERVAL_MAX"
					break
					;;
				[rR] | " ") break ;;
				p | P)
					PAUSED=1
					break
					;;
				b | B)
					base[LOCAL]="${curr[LOCAL]}"
					base[CLOUD]="${curr[CLOUD]}"
					base[GRAND]="${curr[GRAND]}"
					prev[LOCAL]="${curr[LOCAL]}"
					prev[CLOUD]="${curr[CLOUD]}"
					prev[GRAND]="${curr[GRAND]}"
					;;
				h | H) SHOW_HELP=$((1 - SHOW_HELP)) ;;
				q | Q)
					echo
					echo "Exiting."
					exit 0
					;;
				esac
			fi
		done
	fi
done
