#!/usr/bin/env bash
# monitor_reclaimed.sh — realtime reclaimed-bytes monitor for ctrlrpc cleaner_status
# Features:
#   • Hourly default refresh; +/- 5m steps (5m..2h), manual refresh (r)
#   • Per-section totals (LOCAL/CLOUD) + GRAND, cumulative & step deltas
#   • Period start (per section) + avg reclaim rate (/h)
#   • Sparklines (bytes/hour), persistent colors, width-aware (toggle on/off)
#   • High-rate alerts (threshold configurable)
#   • CSV logging of raw totals
#   • Keys: + faster, - slower, r refresh, p pause, b baseline, h help, q quit
#   • Live bottom-line countdown (color cues), header flash on refresh
#   • Toggles: c (countdown on/off), f (footer bar on/off)
#   • Compact header with status strip below title, help strip below status
#   • Heartbeat pulse on header "updated:" timestamp each refresh
#   • Mini legend under the spark lines
#   • Period line colors (avg + inst) follow newest spark color (G/R/D)

set -Eeuo pipefail

# --- Configurable knobs (via env or flags) ---

# Refresh interval controls
INTERVAL="${INTERVAL:-3600}" # default: 1 hour
INTERVAL_STEP=300            # 5 minutes
INTERVAL_MIN=300             # 5 minutes
INTERVAL_MAX=7200            # 2 hours

SOURCE_CMD="${SOURCE_CMD:-ctrlrpc -p 9911 show.cleaner_status}"
RECLAIMED_COL="${RECLAIMED_COL:-13}"
SKIP_SUMMARY_LINES="${SKIP_SUMMARY_LINES:-12}"
TS_COL="${TS_COL:-4}" # column for timestamp text

# CSV logging
CSV_MODE="${CSV_MODE:-0}"
LOG_FILE="${LOG_FILE:-}" # auto-set if --csv used without a file

# Alerts (bytes/hour). Default ~32 GiB/h
ALERT_RATE_BPH="${ALERT_RATE_BPH:-34359738368}"
ALERTS_ON="${ALERTS_ON:-1}"

# Sparklines
SPARK_ON="${SPARK_ON:-1}"                   # 1=enabled, 0=disabled (can be set by --no-spark)
SPARK_POINTS="${SPARK_POINTS:-30}"          # rolling buffer length
SPARK_WIDTH="${SPARK_WIDTH:-0}"             # 0=auto-fit to terminal; otherwise fixed width
SHOW_SPARK_LEGEND="${SHOW_SPARK_LEGEND:-1}" # show mini legend under sparks

# Follow spark color on the period line (avg + inst fields)
FOLLOW_SPARK_TEXT="${FOLLOW_SPARK_TEXT:-1}"

# Misc
DEBUG="${DEBUG:-0}"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
BASE_INIT=0
PAUSED=0
SHOW_HELP=0
STATUS_MSG=""
BASELINE_TIME="" # human-readable timestamp of last (auto or manual) baseline

# Header row mapping (0-indexed after clear):
STATUS_LINE_ROW=1  # status strip row (below title)
HELP_LINE_ROW=2    # help strip row (below status)
REFRESH_LINE_ROW=3 # refresh info row

# Live countdown (1=show, 0=hide) + position/throttle + color cues
SHOW_COUNTDOWN="${SHOW_COUNTDOWN:-1}"
COUNTDOWN_OFFSET="${COUNTDOWN_OFFSET:-2}" # 1 = very last row; 2 = one row above bottom
COUNTDOWN_THROTTLE_SEC="${COUNTDOWN_THROTTLE_SEC:-1}"
COUNTDOWN_WARN="${COUNTDOWN_WARN:-60}"  # yellow below this
COUNTDOWN_CRIT="${COUNTDOWN_CRIT:-10}"  # red below this
SHOW_FOOTER_BAR="${SHOW_FOOTER_BAR:-1}" # draw bar above countdown
UNICODE_BORDERS="${UNICODE_BORDERS:-0}" # 1=use '─', 0=ASCII '-'

# Per-group last-sample epoch for instant rate calc
LAST_EPOCH_LOCAL=0
LAST_EPOCH_CLOUD=0

# Instant-rate smoothing and sampling
EMA_NUM="${EMA_NUM:-2}"
EMA_DEN="${EMA_DEN:-5}"
MIN_SAMPLE_SECS="${MIN_SAMPLE_SECS:-60}"
MIN_VISIBLE_BPH="${MIN_VISIBLE_BPH:-1}"
INST_LOCAL_EMA=0
INST_CLOUD_EMA=0

# Spark color deadband (APPLIED TO EMA BAR HEIGHT DIFFERENCE)
COLOR_DEADBAND_PCT="${COLOR_DEADBAND_PCT:-2}"         # % of previous EMA height (rounded)
COLOR_DEADBAND_ABS_BPH="${COLOR_DEADBAND_ABS_BPH:-0}" # absolute B/h floor (0=off)

# Header flash/heartbeat
FLASH_ON_REFRESH="${FLASH_ON_REFRESH:-0}" # legacy whole-line flash (off)
FLASH_MS="${FLASH_MS:-100}"               # ms (approx)
HEARTBEAT_MS="${HEARTBEAT_MS:-120}"       # pulse duration for updated: timestamp

# --- Arg parsing ---
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
	--ts-col)
		TS_COL="${2:-4}"
		shift
		;;
	--spark-width=*) SPARK_WIDTH="${1#*=}" ;;
	--spark-points=*) SPARK_POINTS="${1#*=}" ;;
	--no-spark) SPARK_ON=0 ;;
	--debug) DEBUG=1 ;;
	-h | --help)
		cat <<EOF
Usage: $0 [options]
  --csv[=FILE]          Enable CSV logging (optional file path)
  --interval, -i SECS   Refresh interval in seconds (default ${INTERVAL})
  --col N               Column index for "reclaimed" bytes (default ${RECLAIMED_COL})
  --skip N              Lines to skip after "Cleaner summary" (default ${SKIP_SUMMARY_LINES})
  --ts-col N            Column index for per-row timestamp text (default ${TS_COL})
  --spark-width=N       Force sparkline width (0=auto-fit)
  --spark-points=N      Rolling buffer length for sparkline (default ${SPARK_POINTS})
  --no-spark            Disable sparklines
  --debug               Verbose parser debug to stderr
Keys:
  + faster (-5m)  - slower (+5m)  r refresh  p pause  b baseline  h help  c countdown  f footer  q quit
EOF
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		echo "Try '$0 --help'" >&2
		exit 1
		;;
	esac
	shift
done

# CSV filename default
if ((CSV_MODE == 1)) && [[ -z "$LOG_FILE" ]]; then
	LOG_FILE="./reclaimed_trend_$(date '+%Y%m%d_%H%M%S').csv"
fi

# Clamp initial interval
((INTERVAL < INTERVAL_MIN)) && INTERVAL="$INTERVAL_MIN"
((INTERVAL > INTERVAL_MAX)) && INTERVAL="$INTERVAL_MAX"

# --- TTY handling ---
cleanup() {
	tput sgr0 2>/dev/null || printf '\033[0m'
	clear_footer_area 2>/dev/null || true
	tput cnorm 2>/dev/null || true
	stty echo icanon time 1 min 0 2>/dev/null || stty sane 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
tput civis 2>/dev/null || true
stty -echo -icanon time 0 min 0 2>/dev/null || true # immediate keypresses

# --- Colors ---
if tput colors >/dev/null 2>&1; then
	CLR_GREEN="$(tput setaf 2)"
	CLR_RED="$(tput setaf 1)"
	CLR_YELLOW="$(tput setaf 3)"
	CLR_DIM="$(tput dim)"
	CLR_BOLD="$(tput bold)"
	CLR_REV="$(tput rev)"
	CLR_RESET="$(tput sgr0)"
else
	CLR_GREEN=""
	CLR_RED=""
	CLR_YELLOW=""
	CLR_DIM=""
	CLR_BOLD=""
	CLR_REV=""
	CLR_RESET=""
fi

# --- Helpers ---
hr() {
	local bytes="${1:-0}"
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
	local d="${1:-0}"
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
	local s="${1:-0}"
	case "$s" in '' | *[!0-9]*) s=0 ;; esac
	local h=$((10#$s / 3600)) m=$(((10#$s % 3600) / 60)) out=""
	((h > 0)) && out+="${h}h"
	((m > 0)) && out+="${out:+ }${m}m"
	[[ -z "$out" ]] && out="0m"
	printf "%s" "$out"
}

fmt_secs_long() { # H M S for countdown
	local s="${1:-0}"
	((s < 0)) && s=0
	local h=$((s / 3600)) m=$(((s % 3600) / 60)) sec=$((s % 60))
	if ((h > 0)); then
		printf "%dh %dm %ds" "$h" "$m" "$sec"
	elif ((m > 0)); then
		printf "%dm %ds" "$m" "$sec"
	else
		printf "%ds" "$sec"
	fi
}

rate_bph() {
	local bytes="${1:-0}" secs="${2:-0}"
	((secs <= 0)) && {
		echo 0
		return
	}
	echo $(((bytes * 3600) / secs))
}
rate_hr() {
	local bytes="${1:-0}" secs="${2:-0}" r
	r="$(rate_bph "$bytes" "$secs")"
	((r == 0)) && {
		printf "n/a"
		return
	}
	printf "%s/h" "$(hr "$r")"
}

# Timestamp parser (safe for leading zeros)
to_epoch() {
	local ts="$1" norm
	if [[ "$ts" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{2})/([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
		local MM="${BASH_REMATCH[1]}" DD="${BASH_REMATCH[2]}" YY="${BASH_REMATCH[3]}"
		local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}" ss="${BASH_REMATCH[6]}"
		MM=$((10#$MM))
		DD=$((10#$DD))
		hh=$((10#$hh))
		mm=$((10#$mm))
		ss=$((10#$ss))
		local YYd=$((10#$YY)) YYYY
		if ((YYd >= 70)); then YYYY=$((1900 + YYd)); else YYYY=$((2000 + YYd)); fi
		norm=$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$YYYY" "$MM" "$DD" "$hh" "$mm" "$ss")
		date -d "$norm" +%s 2>/dev/null || gdate -d "$norm" +%s 2>/dev/null || echo ""
		return
	fi
	if [[ "$ts" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4})/([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
		local MM="${BASH_REMATCH[1]}" DD="${BASH_REMATCH[2]}" YYYY="${BASH_REMATCH[3]}"
		local hh="${BASH_REMATCH[4]}" mm="${BASH_REMATCH[5]}" ss="${BASH_REMATCH[6]}"
		MM=$((10#$MM))
		DD=$((10#$DD))
		YYYY=$((10#$YYYY))
		hh=$((10#$hh))
		mm=$((10#$mm))
		ss=$((10#$ss))
		norm=$(printf "%04d-%02d-%02d %02d:%02d:%02d" "$YYYY" "$MM" "$DD" "$hh" "$mm" "$ss")
		date -d "$norm" +%s 2>/dev/null || gdate -d "$norm" +%s 2>/dev/null || echo ""
		return
	fi
	date -d "$ts" +%s 2>/dev/null || gdate -d "$ts" +%s 2>/dev/null || echo ""
}

# Sparkline with persistent colors (G=green, R=red, D=dim), min–max scaling
spark() {
	local vals_str="${1-}" toks_str="${2-}"
	[[ -z "$vals_str" ]] && {
		echo " "
		return
	}
	local vals=($vals_str) toks=($toks_str) out=""
	local n=${#vals[@]}
	((n == 0)) && {
		echo " "
		return
	}
	local min="${vals[0]}" max="${vals[0]}"
	for v in "${vals[@]}"; do
		((v < min)) && min="$v"
		((v > max)) && max="$v"
	done
	local range=$((max - min)) blocks=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
	for i in "${!vals[@]}"; do
		local v="${vals[$i]}" idx
		if ((range == 0)); then
			idx=3
		else
			idx=$((((v - min) * (${#blocks[@]} - 1)) / range))
			((idx < 0)) && idx=0
			((idx > ${#blocks[@]} - 1)) && idx=${#blocks[@]}-1
		fi
		local tok="${toks[$i]:-D}" color="$CLR_DIM"
		case "$tok" in G) color="$CLR_GREEN" ;; R) color="$CLR_RED" ;; D | *) color="$CLR_DIM" ;; esac
		out+="${color}${blocks[$idx]}${CLR_RESET}"
	done
	echo "$out"
}

# Color helper for tokens
color_for_tok() {
	case "$1" in
	G) printf "%s" "$CLR_GREEN" ;;
	R) printf "%s" "$CLR_RED" ;;
	D | *) printf "%s" "$CLR_DIM" ;;
	esac
}

# Alerts
alert_if_rate_high() {
	local label="$1" rbph="$2"
	if ((ALERTS_ON == 1 && rbph >= ALERT_RATE_BPH)); then
		printf "%s[ALERT]%s %s rate high: %s/h\n" "$CLR_RED" "$CLR_RESET" "$label" "$(hr "$rbph")"
		printf "\a"
	fi
}

# --- State ---
declare -A base=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)
declare -A prev=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)
declare -a rate_local_vals=() rate_local_colors=()
declare -a rate_cloud_vals=() rate_cloud_colors=()

# CSV header if needed
if ((CSV_MODE == 1)) && [[ -n "$LOG_FILE" && ! -s "$LOG_FILE" ]]; then
	echo "timestamp,LOCAL_bytes,CLOUD_bytes,GRAND_bytes" >>"$LOG_FILE"
fi

# --- UI helpers ---
update_refresh_line() {
	tput sc 2>/dev/null || true
	tput cup "$REFRESH_LINE_ROW" 0 2>/dev/null || true
	tput el 2>/dev/null || true
	echo "Refresh every $(fmt_secs "$INTERVAL")"
	tput rc 2>/dev/null || true
}

draw_help_line() {
	tput sc 2>/dev/null || true
	tput cup "$HELP_LINE_ROW" 0 2>/dev/null || true
	tput el 2>/dev/null || true
	if ((SHOW_HELP)); then
		echo "${CLR_DIM}Keys: + faster  - slower  r refresh  p pause  b baseline  h help  c countdown  f footer  q quit${CLR_RESET}"
	else
		echo "${CLR_DIM}Press 'h' for help${CLR_RESET}"
	fi
	tput rc 2>/dev/null || true
}

draw_status_line() {
	tput sc 2>/dev/null || true
	tput cup "$STATUS_LINE_ROW" 0 2>/dev/null || true
	tput el 2>/dev/null || true
	local badge
	if ((PAUSED)); then badge="${CLR_YELLOW}[PAUSED]${CLR_RESET}"; else badge="${CLR_GREEN}[RUNNING]${CLR_RESET}"; fi
	if [[ -n "$BASELINE_TIME" ]]; then echo -e "$badge  ${CLR_DIM}Baseline:${CLR_RESET} $BASELINE_TIME"; else echo -e "$badge"; fi
	tput rc 2>/dev/null || true
}

pulse_updated_ts() {
	local now="$(date '+%Y-%m-%d %H:%M:%S')"
	local line_norm line_pulse
	line_norm=$(printf "%sReclaimed totals%s (started: %s | updated: %s)" "$CLR_BOLD" "$CLR_RESET" "$START_TIME" "$now")
	line_pulse=$(printf "%sReclaimed totals%s (started: %s | updated: %s%s%s)" "$CLR_BOLD" "$CLR_RESET" "$START_TIME" "$CLR_YELLOW" "$now" "$CLR_RESET")
	tput sc 2>/dev/null || true
	tput cup 0 0 2>/dev/null || true
	tput el 2>/dev/null || true
	echo -n "$line_pulse"
	sleep "$(awk -v ms="$HEARTBEAT_MS" 'BEGIN{printf "%.3f", ms/1000.0}')"
	tput cup 0 0 2>/dev/null || true
	tput el 2>/dev/null || true
	echo -n "$line_norm"
	tput rc 2>/dev/null || true
}

LAST_COUNTDOWN_STR=""
LAST_COUNTDOWN_TS=0

clear_footer_area() {
	local rows cols row_bar row_count
	rows="$(tput lines 2>/dev/null || echo 24)"
	cols="$(tput cols 2>/dev/null || echo 120)"
	row_count=$((rows - COUNTDOWN_OFFSET))
	row_bar=$((row_count - 1))
	tput sc 2>/dev/null || true
	if ((row_bar >= 0)); then
		tput cup "$row_bar" 0 2>/dev/null || true
		printf "%-*s" "$cols" ""
	fi
	((row_count < 0)) && row_count=0
	tput cup "$row_count" 0 2>/dev/null || true
	printf "%-*s" "$cols" ""
	tput rc 2>/dev/null || true
}

draw_footer_bar() {
	((SHOW_FOOTER_BAR == 0)) && return 0
	local rows cols row ch
	rows="$(tput lines 2>/dev/null || echo 24)"
	cols="$(tput cols 2>/dev/null || echo 120)"
	row=$((rows - COUNTDOWN_OFFSET - 1))
	((row < 0)) && row=0
	ch='-'
	((UNICODE_BORDERS == 1)) && ch='─'
	tput sc 2>/dev/null || true
	tput cup "$row" 0 2>/dev/null || true
	printf "%*s" "$cols" "" | tr ' ' "$ch"
	tput rc 2>/dev/null || true
}

draw_countdown() {
	local rem="${1:-0}" paused="${2:-0}"
	if ((SHOW_COUNTDOWN == 0)); then
		clear_footer_area
		LAST_COUNTDOWN_STR=""
		return 0
	fi
	local now="$SECONDS"
	((now - LAST_COUNTDOWN_TS < COUNTDOWN_THROTTLE_SEC)) && return 0
	LAST_COUNTDOWN_TS="$now"
	local cols rows row prefix time_str color line
	rows="$(tput lines 2>/dev/null || echo 24)"
	cols="$(tput cols 2>/dev/null || echo 120)"
	row=$((rows - COUNTDOWN_OFFSET))
	((row < 0)) && row=0
	if ((paused)); then
		prefix="(PAUSED) Press 'p' to resume. Keys: + - r b h c f q"
		time_str=""
		color="$CLR_YELLOW"
	else
		prefix="(Press '+' / '-' / 'r' / 'p' / 'b' / 'h' / 'c' / 'f' / 'q')  Next refresh in "
		time_str="$(fmt_secs_long "$rem")"
		if ((rem <= COUNTDOWN_CRIT)); then
			color="$CLR_RED"
		elif ((rem <= COUNTDOWN_WARN)); then
			color="$CLR_YELLOW"
		else color="$CLR_GREEN"; fi
	fi
	if [[ -n "$time_str" ]]; then line="${prefix}${color}${time_str}${CLR_RESET}"; else line="${color}${prefix}${CLR_RESET}"; fi
	[[ "$line" == "$LAST_COUNTDOWN_STR" ]] && return 0
	LAST_COUNTDOWN_STR="$line"
	draw_footer_bar
	tput sc 2>/dev/null || true
	tput cup "$row" 0 2>/dev/null || true
	printf "%-*s" "$cols" "$line"
	tput rc 2>/dev/null || true
}

# --- Main loop ---
while true; do
	clear
	# Title (row 0)
	printf "%sReclaimed totals%s (started: %s | updated: %s)\n" \
		"$CLR_BOLD" "$CLR_RESET" "$START_TIME" "$(date '+%Y-%m-%d %H:%M:%S')"
	# Reserve three lines under title for: status, help, refresh
	echo
	echo
	echo
	# Draw header strips
	draw_status_line
	draw_help_line
	update_refresh_line
	# Heartbeat pulse of the updated timestamp (subtle)
	pulse_updated_ts

	# Optional CSV line
	[[ -n "$LOG_FILE" ]] && echo "Logging CSV to: ${CLR_DIM}${LOG_FILE}${CLR_RESET}"
	# Spark legend intro
	if ((SPARK_ON == 1)); then
		echo "${CLR_DIM}avg = since period start; inst = last interval${CLR_RESET}"
	fi
	echo "--------------------------------------------------------------------------------"
	# Baseline indicator (dim)
	if [[ -n "$BASELINE_TIME" ]]; then
		echo "${CLR_DIM}Baseline: $BASELINE_TIME${CLR_RESET}"
	fi
	# One-shot status message
	if [[ -n "$STATUS_MSG" ]]; then
		echo "$STATUS_MSG"
		STATUS_MSG=""
	fi

	# Run producer + parse
	mapfile -t lines < <(
		eval "$SOURCE_CMD" | awk -v RC="$RECLAIMED_COL" -v TC="$TS_COL" -v SKIPN="$SKIP_SUMMARY_LINES" -v DEBUG="$DEBUG" '
      BEGIN { IGNORECASE=1; skip=0 }
      /^[[:space:]]*Cleaner[[:space:]]+summary/ { skip = SKIPN; next }
      skip>0 { skip--; next }
      /[[:space:]]*Resource[[:space:]]+Group/ {
        split($0, parts, ":"); grp = (length(parts)>=2?parts[2]:$NF)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"", grp); gsub(/:/,"", grp)
        if (grp!="") curgrp=grp; next
      }
      {
        if (curgrp=="" || NF<RC || NF<TC) next
        ts  = $TC; raw = $RC
        if (!(curgrp in start_ts)) { if (tolower(ts) !~ /^start$/) start_ts[curgrp] = ts }
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
        if (bytes>0) { total[curgrp] += bytes; grand += bytes }
      }
      END {
        printf("LOCAL\t%d\t%s\n", (total["LOCAL"] ? total["LOCAL"] : 0), (start_ts["LOCAL"]?start_ts["LOCAL"]:""))
        printf("CLOUD\t%d\t%s\n", (total["CLOUD"] ? total["CLOUD"] : 0), (start_ts["CLOUD"]?start_ts["CLOUD"]:""))
        printf("GRAND\t%d\t\n", grand + 0)
      }
    '
	)

	# Parse into current map + period start
	declare -A curr=([LOCAL]=0 [CLOUD]=0 [GRAND]=0)
	declare -A period_start=([LOCAL]="" [CLOUD]="" [GRAND]="")
	for ln in "${lines[@]}"; do
		IFS=$'\t' read -r g v pstart <<<"$ln"
		[[ "$g" =~ ^(LOCAL|CLOUD|GRAND)$ ]] || continue
		curr[$g]="$v"
		period_start[$g]="$pstart"
	done

	# Initialize baseline
	if ((BASE_INIT == 0)); then
		base[LOCAL]="${curr[LOCAL]}"
		base[CLOUD]="${curr[CLOUD]}"
		base[GRAND]="${curr[GRAND]}"
		prev[LOCAL]="${curr[LOCAL]}"
		prev[CLOUD]="${curr[CLOUD]}"
		prev[GRAND]="${curr[GRAND]}"
		BASE_INIT=1
		BASELINE_TIME="$(date '+%Y-%m-%d %H:%M:%S') (auto)"
		draw_status_line
	fi

	# Auto re-baseline if totals dropped
	for g in LOCAL CLOUD GRAND; do
		if ((curr[$g] < base[$g])); then
			((DEBUG)) && echo "[DEBUG] Rebaseline: $g dropped (base=${base[$g]} -> curr=${curr[$g]})" >&2
			base[$g]=${curr[$g]}
			prev[$g]=${curr[$g]}
			BASELINE_TIME="$(date '+%Y-%m-%d %H:%M:%S') (auto)"
			draw_status_line
		fi
	done

	# Display sections
	now_epoch="$(date +%s)"
	term_cols="$(tput cols 2>/dev/null || echo 120)"

	for g in LOCAL CLOUD GRAND; do
		total="${curr[$g]}"
		delta_step=$((total - prev[$g]))
		delta_cum=$((total - base[$g]))
		pstart="${period_start[$g]}"

		line1=$(printf "%-6s total reclaimed: %-12s  (since monitor start: %s  %sstep: %s%s)" \
			"$g" "$(hr "$total")" "$(fmt_delta "$delta_cum")" "$CLR_DIM" "$(fmt_delta "$delta_step")" "$CLR_RESET")

		rate_text=""
		rate_int=0
		line2=""
		if [[ -n "$pstart" && "$g" != "GRAND" ]]; then
			ps_epoch="$(to_epoch "$pstart")"
			if [[ -n "$ps_epoch" ]]; then
				elapsed=$((now_epoch - ps_epoch))
				rate_text="$(rate_hr "$total" "$elapsed")"
				rate_int="$(rate_bph "$total" "$elapsed")"
			else
				elapsed=0
				rate_text="n/a"
				rate_int=0
			fi

			# Seed sparkline on very first render
			skip_inst=0
			if [[ "$g" == "LOCAL" && ${#rate_local_vals[@]} -eq 0 && "$rate_int" -ge 0 ]]; then
				rate_local_vals+=("$rate_int")
				rate_local_colors+=("D")
				LAST_EPOCH_LOCAL="$now_epoch"
				skip_inst=1
			elif [[ "$g" == "CLOUD" && ${#rate_cloud_vals[@]} -eq 0 && "$rate_int" -ge 0 ]]; then
				rate_cloud_vals+=("$rate_int")
				rate_cloud_colors+=("D")
				LAST_EPOCH_CLOUD="$now_epoch"
				skip_inst=1
			fi

			# Instantaneous per-interval rate
			step_bytes=$((total - prev[$g]))
			((step_bytes < 0)) && step_bytes=0
			if [[ "$g" == "LOCAL" ]]; then last_ep="$LAST_EPOCH_LOCAL"; else last_ep="$LAST_EPOCH_CLOUD"; fi
			if [[ -z "$last_ep" || "$last_ep" -le 0 ]]; then
				elapsed_step=$((INTERVAL > 0 ? INTERVAL : 1))
			else
				elapsed_step=$((now_epoch - last_ep))
				((elapsed_step <= 0)) && elapsed_step=1
			fi

			if ((elapsed_step < MIN_SAMPLE_SECS && step_bytes == 0)); then
				inst_bph=0
			else
				inst_bph=$(((step_bytes * 3600 + elapsed_step / 2) / elapsed_step))
				((step_bytes > 0 && inst_bph == 0)) && inst_bph=$MIN_VISIBLE_BPH
			fi
			if [[ "$g" == "LOCAL" ]]; then LAST_EPOCH_LOCAL="$now_epoch"; else LAST_EPOCH_CLOUD="$now_epoch"; fi

			# EMA smoothing -> spark value (bar height)
			if [[ "$g" == "LOCAL" ]]; then
				INST_LOCAL_EMA=$(((EMA_NUM * inst_bph + (EMA_DEN - EMA_NUM) * INST_LOCAL_EMA + EMA_DEN / 2) / EMA_DEN))
				spark_val="$INST_LOCAL_EMA"
			else
				INST_CLOUD_EMA=$(((EMA_NUM * inst_bph + (EMA_DEN - EMA_NUM) * INST_CLOUD_EMA + EMA_DEN / 2) / EMA_DEN))
				spark_val="$INST_CLOUD_EMA"
			fi

			# --- Color token by EMA bar-height change ---
			if [[ "$g" == "LOCAL" ]]; then
				if ((${#rate_local_vals[@]} > 0)); then
					prev_height="${rate_local_vals[$((${#rate_local_vals[@]} - 1))]}"
				else prev_height=-1; fi
			else
				if ((${#rate_cloud_vals[@]} > 0)); then
					prev_height="${rate_cloud_vals[$((${#rate_cloud_vals[@]} - 1))]}"
				else prev_height=-1; fi
			fi

			tok="D"
			if ((prev_height >= 0)); then
				rel_thresh=$(((prev_height * COLOR_DEADBAND_PCT + 50) / 100))
				((rel_thresh < COLOR_DEADBAND_ABS_BPH)) && rel_thresh="$COLOR_DEADBAND_ABS_BPH"
				diff=$((spark_val - prev_height))
				if ((diff > rel_thresh)); then
					tok="G"
				elif ((diff < -rel_thresh)); then
					tok="R"
				else tok="D"; fi
			fi
			
			# If we just seeded this group in this same loop, force neutral color
			# Also keep neutral if we only have the single seed point in the buffer.
			if ((skip_inst == 1)); then
				tok="D"
			else
				if [[ "$g" == "LOCAL" ]]; then
					((${#rate_local_vals[@]} <= 1)) && tok="D"
				else
					((${#rate_cloud_vals[@]} <= 1)) && tok="D"
				fi
			fi

			# Append sample (height=EMA, color=tok) + trim buffers
			if [[ "$g" == "LOCAL" ]]; then
				((skip_inst == 0)) && {
					rate_local_vals+=("$spark_val")
					rate_local_colors+=("$tok")
				}
				if ((${#rate_local_vals[@]} > SPARK_POINTS)); then
					rate_local_vals=("${rate_local_vals[@]: -$SPARK_POINTS}")
					rate_local_colors=("${rate_local_colors[@]: -$SPARK_POINTS}")
				fi
			else
				((skip_inst == 0)) && {
					rate_cloud_vals+=("$spark_val")
					rate_cloud_colors+=("$tok")
				}
				if ((${#rate_cloud_vals[@]} > SPARK_POINTS)); then
					rate_cloud_vals=("${rate_cloud_vals[@]: -$SPARK_POINTS}")
					rate_cloud_colors=("${rate_cloud_colors[@]: -$SPARK_POINTS}")
				fi
			fi

			# Build colored period line that follows spark color (if enabled)
			if ((FOLLOW_SPARK_TEXT == 1)); then
				col="$(color_for_tok "$tok")"
				line2=$(printf "  cleaner period start: %s   |   avg reclaim rate: %s%s%s   |   inst: %s%s/h%s" \
					"$pstart" \
					"$col" "$rate_text" "$CLR_RESET" \
					"$col" "$(hr "$inst_bph")" "$CLR_RESET")
			else
				line2=$(printf "  cleaner period start: %s   |   avg reclaim rate: %s   |   inst: %s/h" \
					"$pstart" "$rate_text" "$(hr "$inst_bph")")
			fi

			# Alerts: use unsmoothed instantaneous rate
			alert_if_rate_high "$g" "$inst_bph"
		fi

		# width guards + print
		if ((${#line1} > term_cols)); then echo "${line1:0:term_cols-1}…"; else echo "$line1"; fi
		if [[ -n "$line2" ]]; then
			if ((${#line2} > term_cols)); then echo "${line2:0:term_cols-1}…"; else echo "$line2"; fi
		fi

		# Sparkline (optional, width-aware)
		if ((SPARK_ON == 1)); then
			prefix_len=13 # "  rate spark: "
			if ((SPARK_WIDTH > 0)); then
				points=$SPARK_WIDTH
			else
				points=$SPARK_POINTS
				if ((term_cols > prefix_len + 2)); then
					fit=$((term_cols - prefix_len - 2))
					((fit < points)) && points=$fit
				fi
			fi
			((points < 5)) && points=5

			# render even a single seed point
			if [[ "$g" == "LOCAL" && ${#rate_local_vals[@]} -gt 0 ]]; then
				draw_vals=("${rate_local_vals[@]}")
				draw_toks=("${rate_local_colors[@]}")
				((${#draw_vals[@]} > points)) && {
					draw_vals=("${draw_vals[@]: -$points}")
					draw_toks=("${draw_toks[@]: -$points}")
				}
				echo "  rate spark: $(spark "${draw_vals[*]}" "${draw_toks[*]}")"
			fi
			if [[ "$g" == "CLOUD" && ${#rate_cloud_vals[@]} -gt 0 ]]; then
				draw_vals=("${rate_cloud_vals[@]}")
				draw_toks=("${rate_cloud_colors[@]}")
				((${#draw_vals[@]} > points)) && {
					draw_vals=("${draw_vals[@]: -$points}")
					draw_toks=("${draw_toks[@]: -$points}")
				}
				echo "  rate spark: $(spark "${draw_vals[*]}" "${draw_toks[*]}")"
			fi
		fi
	done

	# Mini legend under sparks (once)
	if ((SPARK_ON == 1 && SHOW_SPARK_LEGEND == 1)); then
		echo -e "${CLR_DIM}legend:${CLR_RESET} ${CLR_GREEN}█${CLR_RESET} up  ${CLR_RED}█${CLR_RESET} down  ${CLR_DIM}█${CLR_RESET} steady"
	fi

	# CSV log of raw totals
	if ((CSV_MODE == 1)) && [[ -n "$LOG_FILE" ]]; then
		printf "%s,%d,%d,%d\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${curr[LOCAL]}" "${curr[CLOUD]}" "${curr[GRAND]}" >>"$LOG_FILE"
	fi

	# Update prev for next loop
	prev[LOCAL]="${curr[LOCAL]}"
	prev[CLOUD]="${curr[CLOUD]}"
	prev[GRAND]="${curr[GRAND]}"

	# --- Wait loop (paused vs timed), with live countdown ---
	if ((PAUSED)); then
		while true; do
			draw_countdown 0 1
			if read -r -n1 -t 0.2 key; then
				case "$key" in
				p | P)
					PAUSED=0
					draw_status_line
					break
					;;
				[rR]) break ;;
				+)
					INTERVAL=$((INTERVAL - INTERVAL_STEP))
					((INTERVAL < INTERVAL_MIN)) && INTERVAL="$INTERVAL_MIN"
					update_refresh_line
					continue
					;;
				-)
					INTERVAL=$((INTERVAL + INTERVAL_STEP))
					((INTERVAL > INTERVAL_MAX)) && INTERVAL="$INTERVAL_MAX"
					update_refresh_line
					continue
					;;
				b | B)
					base[LOCAL]="${curr[LOCAL]}"
					base[CLOUD]="${curr[CLOUD]}"
					base[GRAND]="${curr[GRAND]}"
					prev[LOCAL]="${curr[LOCAL]}"
					prev[CLOUD]="${curr[CLOUD]}"
					prev[GRAND]="${curr[GRAND]}"
					BASELINE_TIME="$(date '+%Y-%m-%d %H:%M:%S') (manual)"
					STATUS_MSG="${CLR_GREEN}Baseline set at ${BASELINE_TIME}${CLR_RESET}"
					draw_status_line
					break
					;;
				h | H)
					SHOW_HELP=$((1 - SHOW_HELP))
					draw_help_line
					continue
					;;
				c | C)
					SHOW_COUNTDOWN=$((1 - SHOW_COUNTDOWN))
					LAST_COUNTDOWN_STR=""
					clear_footer_area
					continue
					;;
				f | F)
					SHOW_FOOTER_BAR=$((1 - SHOW_FOOTER_BAR))
					LAST_COUNTDOWN_STR=""
					clear_footer_area
					continue
					;;
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
			rem=$((end - SECONDS))
			draw_countdown "$rem" 0
			if read -r -n1 -t 0.2 key; then
				case "$key" in
				+)
					INTERVAL=$((INTERVAL - INTERVAL_STEP))
					((INTERVAL < INTERVAL_MIN)) && INTERVAL="$INTERVAL_MIN"
					end=$((SECONDS + INTERVAL))
					update_refresh_line
					continue
					;;
				-)
					INTERVAL=$((INTERVAL + INTERVAL_STEP))
					((INTERVAL > INTERVAL_MAX)) && INTERVAL="$INTERVAL_MAX"
					end=$((SECONDS + INTERVAL))
					update_refresh_line
					continue
					;;
				[rR]) break ;;
				p | P)
					PAUSED=1
					draw_status_line
					break
					;;
				b | B)
					base[LOCAL]="${curr[LOCAL]}"
					base[CLOUD]="${curr[CLOUD]}"
					base[GRAND]="${curr[GRAND]}"
					prev[LOCAL]="${curr[LOCAL]}"
					prev[CLOUD]="${curr[CLOUD]}"
					prev[GRAND]="${curr[GRAND]}"
					BASELINE_TIME="$(date '+%Y-%m-%d %H:%M:%S') (manual)"
					STATUS_MSG="${CLR_GREEN}Baseline set at ${BASELINE_TIME}${CLR_RESET}"
					draw_status_line
					break
					;;
				h | H)
					SHOW_HELP=$((1 - SHOW_HELP))
					draw_help_line
					continue
					;;
				c | C)
					SHOW_COUNTDOWN=$((1 - SHOW_COUNTDOWN))
					LAST_COUNTDOWN_STR=""
					clear_footer_area
					continue
					;;
				f | F)
					SHOW_FOOTER_BAR=$((1 - SHOW_FOOTER_BAR))
					LAST_COUNTDOWN_STR=""
					clear_footer_area
					continue
					;;
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
