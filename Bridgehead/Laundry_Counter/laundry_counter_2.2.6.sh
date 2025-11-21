#!/usr/bin/env bash

# QoreStor Laundry Monitor / Tools
#
# Modes:
#   Monitor (default): event-driven inotify monitor with counts & colors
#   --low-cpu       : monitor mode, throttled redraw + periodic rescan
#   --list          : one-shot list of laundry dirs and file counts
#   --count         : one-shot count of laundry dirs
#
# Options:
#   --logging-on    : enable per-event logging to LOG_FILE
#
# Laundry layout (relative to TGTDIR / BASE):
#   <BASE>/<int>/.ocarina_hidden/laundry/<int>/<files>
#
# BASE is auto-detected from /etc/oca/oca.cfg (TGTDIR=<path>).
# If detection fails, it falls back to /QSdata/ocaroot.

########################################
# Detect BASE from /etc/oca/oca.cfg
########################################

CFG_FILE="/etc/oca/oca.cfg"

detect_base() {
	local value=""

	# Default BASE if config missing/corrupt
	BASE="/QSdata/ocaroot"

	if [[ -f "$CFG_FILE" ]]; then
		# Accept either:
		#   TGTDIR=/path
		#   export TGTDIR=/path
		value=$(grep -E '(^|\s)TGTDIR=' "$CFG_FILE" 2>/dev/null | head -n1 | sed 's/.*TGTDIR=//')
	fi

	if [[ -n "$value" && -d "$value" ]]; then
		BASE="$value"
	else
		echo "Warning: Could not determine valid TGTDIR from $CFG_FILE" >&2
		echo "Using default BASE: $BASE" >&2
	fi
}

detect_base # sets BASE

LOG_FILE_DEFAULT="/var/log/qorestor_laundry_monitor.log"
ERR_LOG_DEFAULT="/var/log/qorestor_laundry_monitor.err"
FALLBACK_LOG_DIR="${TMPDIR:-/tmp}/qorestor_laundry_monitor"

# Logging of per-event updates (to LOG_FILE)
LOGGING=false

# Thresholds (used in monitor mode)
DIR_THRESHOLD=1000    # per-dir threshold (0 = off)
TOTAL_THRESHOLD=10000 # global threshold (0 = off)

# Monitor behaviour (defaults, may be overridden by --low-cpu)
REDUCED_CPU=false
REFRESH_INTERVAL=1      # seconds between redraws when REDUCED_CPU=true
FULL_REFRESH_INTERVAL=5 # seconds between full rescan to reconcile counts
RENDER_THROTTLE_MS=0    # minimum milliseconds between renders (0 = every event)

# Ensure we're in bash (associative arrays)
if [ -z "${BASH_VERSION:-}" ]; then
	echo "This script must be run with bash, e.g.: bash $0" >&2
	exit 1
fi

shopt -s nullglob

declare -A counts
declare -A prev_counts
declare -a rendered_lines
last_render_ms=0
ALT_SCREEN=false
SPINNER_PID=0

# Colors
color_reset=$(tput sgr0 2>/dev/null || echo "")
color_green=$(tput setaf 2 2>/dev/null || echo "")
color_red=$(tput setaf 1 2>/dev/null || echo "")
color_yellow=$(tput setaf 3 2>/dev/null || echo "")
color_magenta=$(tput setaf 5 2>/dev/null || echo "")
color_bold=$(tput bold 2>/dev/null || echo "")

move_cursor() {
	printf '\033[%d;%dH' "$1" "$2"
}

clear_to_eol() {
	printf '\033[K'
}

enter_alt_screen() {
	if tput smcup 2>/dev/null; then
		ALT_SCREEN=true
	else
		ALT_SCREEN=false
		printf '\033[2J'
		move_cursor 1 1
	fi
}

exit_alt_screen() {
	if $ALT_SCREEN; then
		tput rmcup 2>/dev/null || true
	else
		move_cursor $((${#rendered_lines[@]} + 2)) 1
		clear_to_eol
	fi
}

start_spinner() {
	local msg="$1"
	{
		local chars='|/-\'
		local i=0
		while true; do
			local c=${chars:i%${#chars}:1}
			printf "\r%s %s" "$msg" "$c"
			i=$(((i + 1) % ${#chars}))
			sleep 0.1
		done
	} &
	SPINNER_PID=$!
}

stop_spinner() {
	if ((SPINNER_PID > 0)); then
		kill "$SPINNER_PID" 2>/dev/null || true
		wait "$SPINNER_PID" 2>/dev/null || true
		SPINNER_PID=0
		printf "\r\033[K"
	fi
}

choose_log_path() {
	local target="$1" fallback_dir="$2" label="$3"
	local fallback_file="$fallback_dir/$(basename "$target")"
	local dir
	dir=$(dirname "$target")

	if mkdir -p "$dir" 2>/dev/null && touch "$target" 2>/dev/null; then
		echo "$target"
		return
	fi

	mkdir -p "$fallback_dir" 2>/dev/null || true
	if touch "$fallback_file" 2>/dev/null; then
		echo "Warning: $label not writable ($target); using $fallback_file" >&2
		echo "$fallback_file"
	else
		echo "Warning: $label not writable ($target); logging disabled for $label" >&2
		echo "/dev/null"
	fi
}

LOG_FILE=$(choose_log_path "$LOG_FILE_DEFAULT" "$FALLBACK_LOG_DIR" "LOG_FILE")
ERR_LOG=$(choose_log_path "$ERR_LOG_DEFAULT" "$FALLBACK_LOG_DIR" "ERR_LOG")

########################################
# Argument parsing
########################################

MODE="monitor" # monitor | list | count
LOW_CPU=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	--low-cpu)
		LOW_CPU=true
		shift
		;;
	--logging-on)
		LOGGING=true
		shift
		;;
	--list)
		if [[ "$MODE" != "monitor" ]]; then
			echo "Error: --list cannot be used with --count or other modes." >&2
			exit 1
		fi
		MODE="list"
		shift
		;;
	--count)
		if [[ "$MODE" != "monitor" ]]; then
			echo "Error: --count cannot be used with --list or other modes." >&2
			exit 1
		fi
		MODE="count"
		shift
		;;
	--help | -h)
		cat <<EOF
Usage: $(basename "$0") [--low-cpu] [--logging-on] [--list | --count]

Modes:
  (no options)   Monitor mode: event-driven inotify monitor with live display.
  --low-cpu      Monitor mode with reduced CPU usage:
                   - redraw limited to every N seconds
                   - periodic full refresh of all counts
  --logging-on   Enable per-event logging to: $LOG_FILE
  --list         One-shot list of all laundry directories and their file counts.
  --count        One-shot count of laundry directory paths.

Notes:
  --list and --count are mutually exclusive and non-monitoring (they exit after output).
  --low-cpu and --logging-on are only valid in monitor mode.
  Monitor mode performs a full rescan every $FULL_REFRESH_INTERVAL seconds to reconcile counts.
BASE (root) is taken from TGTDIR in $CFG_FILE; default is $BASE if TGTDIR is invalid/missing.
EOF
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		echo "Try: $(basename "$0") --help" >&2
		exit 1
		;;
	esac
done

if $LOW_CPU && [[ "$MODE" != "monitor" ]]; then
	echo "Error: --low-cpu is only valid in monitor mode." >&2
	exit 1
fi

if $LOGGING && [[ "$MODE" != "monitor" ]]; then
	echo "Error: --logging-on is only useful in monitor mode." >&2
	exit 1
fi

if $LOGGING && [[ "$LOG_FILE" == "/dev/null" ]]; then
	echo "Warning: logging requested but log path is not writable; disabling logging." >&2
	LOGGING=false
fi

if $LOW_CPU; then
	REDUCED_CPU=true
	REFRESH_INTERVAL=3       # redraw at most every 3 seconds
	FULL_REFRESH_INTERVAL=60 # rescan counts every 60 seconds
	RENDER_THROTTLE_MS=$((REFRESH_INTERVAL * 1000))
fi

########################################
# Common helpers
########################################

scan_laundry_dirs() {
	find "$BASE" \
		-type d \
		-path "$BASE/*/.ocarina_hidden/laundry/*" \
		2>/dev/null | sort
}

bucket_dir_for() {
	local path="$1"

	# Strip BASE/ prefix; if unchanged, not under BASE
	local rel="${path#"$BASE"/}"
	if [[ "$rel" == "$path" ]]; then
		return
	fi

	# Split first four components: tenant/.ocarina_hidden/laundry/bucket/...
	local tenant hidden laundry bucket rest
	IFS='/' read -r tenant hidden laundry bucket rest <<<"$rel"

	if [[ "$tenant" =~ ^[0-9]+$ && "$hidden" == ".ocarina_hidden" && "$laundry" == "laundry" && "$bucket" =~ ^[0-9]+$ ]]; then
		echo "$BASE/$tenant/.ocarina_hidden/laundry/$bucket"
	fi
}

is_bucket_dir() {
	local path="$1"
	[[ "$(bucket_dir_for "$path")" == "$path" ]]
}

prune_to_buckets() {
	for k in "${!counts[@]}"; do
		if ! is_bucket_dir "$k"; then
			unset 'counts[$k]'
			unset 'prev_counts[$k]'
		fi
	done
}

# Initialize counts map from existing directories and files (monitor mode)
init_counts_from_files() {
	counts=()
	prev_counts=()

	# 1. Start with all laundry dirs, default count 0
	while IFS= read -r dir; do
		[[ -z "$dir" ]] && continue
		counts["$dir"]=0
		prev_counts["$dir"]=0
	done < <(scan_laundry_dirs)

	# 2. Overlay actual file counts grouped by bucket dir
	while IFS= read -r file_path; do
		[[ -z "$file_path" ]] && continue
		local bucket
		bucket=$(bucket_dir_for "$file_path")
		[[ -z "$bucket" ]] && continue
		local val=${counts["$bucket"]}
		[[ -z "$val" ]] && val=0
		val=$((val + 1))
		counts["$bucket"]=$val
		prev_counts["$bucket"]=$val
	done < <(
		find "$BASE" \
			-type f \
			-path "$BASE/*/.ocarina_hidden/laundry/*/*" \
			-print 2>/dev/null
	)

	prune_to_buckets
}

now_ms() {
	printf '%s\n' "$(($(date +%s%N) / 1000000))"
}

render_lines() {
	local new_lines=("$@")
	local new_len=${#new_lines[@]}
	local old_len=${#rendered_lines[@]}
	local i

	for ((i = 0; i < new_len; i++)); do
		if [[ "${rendered_lines[i]}" != "${new_lines[i]}" ]]; then
			move_cursor $((i + 1)) 1
			printf "%s" "${new_lines[i]}"
			clear_to_eol
		fi
	done

	if ((old_len > new_len)); then
		for ((i = new_len; i < old_len; i++)); do
			move_cursor $((i + 1)) 1
			clear_to_eol
		done
	fi

	rendered_lines=("${new_lines[@]}")
	move_cursor $((new_len + 1)) 1
}

# Render monitor-style display using current counts[]
render_monitor() {
	local -a new_lines=()
	new_lines+=("QoreStor Laundry File Monitor (inotify-driven)")
	new_lines+=("Base: $BASE")
	new_lines+=("Updated: $(date)")
	new_lines+=("--------------------------------------")

	local grand_total=0

	if ((${#counts[@]} == 0)); then
		new_lines+=("(no matching laundry directories yet)")
		new_lines+=("--------------------------------------")
		new_lines+=("Grand Total Files: 0")
		render_lines "${new_lines[@]}"
		return
	fi

	mapfile -t dirs < <(printf '%s\n' "${!counts[@]}" | sort)

	for dir in "${dirs[@]}"; do
		[[ -z "$dir" ]] && continue

		local cur=${counts["$dir"]}
		local prev=${prev_counts["$dir"]}
		[[ -z "$prev" ]] && prev=$cur

		local line_color="$color_reset"

		if ((DIR_THRESHOLD > 0 && cur >= DIR_THRESHOLD)); then
			line_color="${color_bold}${color_red}"
		else
			if ((cur < prev)); then
				line_color=$color_green
			elif ((cur > prev)); then
				line_color=$color_red
			else
				line_color=$color_reset
			fi
		fi

		new_lines+=("$(printf "%s%-60s %10d%s" "$line_color" "$dir" "$cur" "$color_reset")")

		grand_total=$((grand_total + cur))
		prev_counts["$dir"]=$cur
	done

	new_lines+=("--------------------------------------")
	if ((TOTAL_THRESHOLD > 0 && grand_total >= TOTAL_THRESHOLD)); then
		new_lines+=("$(printf "%s%s%s" "${color_bold}${color_magenta}" "Grand Total Files: $grand_total (THRESHOLD EXCEEDED)" "$color_reset")")
	else
		new_lines+=("Grand Total Files: $grand_total")
	fi

	render_lines "${new_lines[@]}"
}

# Update count for a directory (+1 or -1) and optional log
update_count() {
	local dir="$1"
	local op="$2"     # +1 or -1
	local reason="$3" # CREATE/DELETE/etc.

	[[ -z "$dir" ]] && return

	local cur=${counts["$dir"]}
	[[ -z "$cur" ]] && cur=0

	if [[ "$op" == "+1" ]]; then
		cur=$((cur + 1))
	else
		cur=$((cur - 1))
		((cur < 0)) && cur=0
	fi

	counts["$dir"]=$cur

	if $LOGGING; then
		printf '%s dir="%s" op="%s" reason="%s" count=%d\n' \
			"$(date '+%Y-%m-%d %H:%M:%S')" "$dir" "$op" "$reason" "$cur" >>"$LOG_FILE"
	fi
}

########################################
# --list mode: one-shot list of dirs + counts
########################################
if [[ "$MODE" == "list" ]]; then
	counts=()
	prev_counts=()

	while IFS= read -r dir; do
		[[ -z "$dir" ]] && continue
		c=$(find "$dir" -type f 2>/dev/null | wc -l)
		counts["$dir"]=$c
		prev_counts["$dir"]=$c
	done < <(scan_laundry_dirs)

	prune_to_buckets

	render_monitor
	exit 0
fi

########################################
# --count mode: one-shot count of laundry dirs
########################################
if [[ "$MODE" == "count" ]]; then
	mapfile -t dirs < <(scan_laundry_dirs)
	echo "Laundry directory paths found: ${#dirs[@]}"
	exit 0
fi

########################################
# Monitor mode (default, with optional --low-cpu / --logging-on)
########################################

cleanup() {
	echo
	echo "Exiting qorestor_laundry_monitor."
	stop_spinner
	exit_alt_screen
}
trap 'cleanup; exit 0' INT TERM

start_spinner "Starting..."
enter_alt_screen
init_counts_from_files
render_monitor
stop_spinner

last_render_ms=$(now_ms)
last_full_refresh=$(date +%s)

while true; do
	# Watch only the laundry roots: <BASE>/<int>/.ocarina_hidden/laundry
	WATCH_PATHS=("$BASE"/*/.ocarina_hidden/laundry)

	if ((${#WATCH_PATHS[@]} == 0)); then
		echo "$(date '+%Y-%m-%d %H:%M:%S') no laundry roots found under $BASE; sleeping 10s" >>"$ERR_LOG"
		sleep 10
		continue
	fi

	# inotify loop (auto-restarted if inotifywait exits)
	restart_pending=false
	while read -r f1 f2 f3 f4; do
		# Handle either 3-field (w f e) or 4-field (optional timestamp + w f e)
		if [[ "$f1" == /* ]]; then
			watched_dir="$f1"
			filename="$f2"
			events="$f3"
		else
			# assume leading timestamp
			watched_dir="$f2"
			filename="$f3"
			events="$f4"
		fi
		# DEBUG: raw inotify events with timestamps (enabled when RAW_DEBUG=1)
		if [[ "${RAW_DEBUG:-0}" == "1" ]]; then
			echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') RAW w='$watched_dir' f='$filename' e='$events'" >>"$ERR_LOG"
		fi

		# We care about file-level events only (skip weird empty filename cases)
		if [[ -z "$filename" ]]; then
			continue
		fi

		# Normalize parent_dir (remove trailing slash)
		parent_dir="${watched_dir%/}"

		full_path="$parent_dir/$filename"

		# If kernel overflowed the event queue, resync counts immediately
		if [[ "$events" == *Q_OVERFLOW* ]]; then
			init_counts_from_files
			render_monitor
			last_full_refresh=$now
			last_render_ms=$(now_ms)
			continue
		fi

		# Directory events: trigger watcher restart to include new subtree
		if [[ "$events" == *ISDIR* ]]; then
			restart_pending=true
			break
		fi

		bucket_dir=$(bucket_dir_for "$full_path")
		[[ -z "$bucket_dir" ]] && continue

		# Decide whether this is +1 or -1 based on the event list
		op=""
		if [[ "$events" == *CREATE* || "$events" == *MOVED_TO* ]]; then
			op="+1"
		elif [[ "$events" == *DELETE* || "$events" == *MOVED_FROM* ]]; then
			op="-1"
		else
			# We asked inotify for create/delete/move events only,
			# but if something else sneaks in, ignore it.
			continue
		fi

		# Update count and optional log
		update_count "$bucket_dir" "$op" "$events"
		prune_to_buckets

		current_ms=$(now_ms)
		now=$((current_ms / 1000))

		# Periodic full refresh to catch new/removed dirs (only if configured)
		if ((FULL_REFRESH_INTERVAL > 0)) && ((now - last_full_refresh >= FULL_REFRESH_INTERVAL)); then
			init_counts_from_files
			render_monitor
			last_full_refresh=$now
			last_render_ms=$current_ms
			continue
		fi

		elapsed=$((current_ms - last_render_ms))
		if ((RENDER_THROTTLE_MS > 0 && elapsed < RENDER_THROTTLE_MS)); then
			remaining=$((RENDER_THROTTLE_MS - elapsed))
			sleep "$(printf '0.%03d' "$remaining")"
			current_ms=$(now_ms)
		fi

		render_monitor
		last_render_ms=$current_ms

	done < <(
		inotifywait -m -r \
			-e create -e delete -e moved_to -e moved_from \
			--format '%w %f %e' \
			"${WATCH_PATHS[@]}" 2>>"$ERR_LOG"
	)

	if $LOGGING; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') inotifywait exited, restarting in 5 seconds" >>"$LOG_FILE"
	fi
	if $restart_pending; then
		sleep 0
	else
		sleep 5
	fi
done
