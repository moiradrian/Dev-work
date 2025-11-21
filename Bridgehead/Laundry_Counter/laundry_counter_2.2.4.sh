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
FULL_REFRESH_INTERVAL=0 # 0 = disabled (only used in low-cpu mode)

# Ensure we're in bash (associative arrays)
if [ -z "${BASH_VERSION:-}" ]; then
	echo "This script must be run with bash, e.g.: bash $0" >&2
	exit 1
fi

shopt -s nullglob

declare -A counts
declare -A prev_counts

# Colors
color_reset=$(tput sgr0 2>/dev/null || echo "")
color_green=$(tput setaf 2 2>/dev/null || echo "")
color_red=$(tput setaf 1 2>/dev/null || echo "")
color_yellow=$(tput setaf 3 2>/dev/null || echo "")
color_magenta=$(tput setaf 5 2>/dev/null || echo "")
color_bold=$(tput bold 2>/dev/null || echo "")

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

# Render monitor-style display using current counts[]
render_monitor() {
	clear
	echo "QoreStor Laundry File Monitor (inotify-driven)"
	echo "Base: $BASE"
	echo "Updated: $(date)"
	echo "--------------------------------------"

	local grand_total=0

	if ((${#counts[@]} == 0)); then
		echo "(no matching laundry directories yet)"
		echo "--------------------------------------"
		echo "Grand Total Files: 0"
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
			# Threshold exceeded: bold red
			line_color="${color_bold}${color_red}"
		else
			#  - static  -> white/default
			#  - decrease -> green
			#  - increase -> red
			if ((cur < prev)); then
				line_color=$color_green # count went down
			elif ((cur > prev)); then
				line_color=$color_red # count went up
			else
				line_color=$color_reset # unchanged
			fi
		fi

		printf "%s%-60s %10d%s\n" "$line_color" "$dir" "$cur" "$color_reset"

		grand_total=$((grand_total + cur))
		prev_counts["$dir"]=$cur
	done

	echo "--------------------------------------"
	if ((TOTAL_THRESHOLD > 0 && grand_total >= TOTAL_THRESHOLD)); then
		echo -e "${color_bold}${color_magenta}Grand Total Files: $grand_total (THRESHOLD EXCEEDED)${color_reset}"
	else
		echo "Grand Total Files: $grand_total"
	fi
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
}
trap 'cleanup; exit 0' INT TERM

init_counts_from_files
render_monitor

last_render=$(date +%s)
last_full_refresh=$(date +%s)

while true; do
	# Watch only the laundry roots: <BASE>/<int>/.ocarina_hidden/laundry
	WATCH_PATHS=("$BASE"/*/.ocarina_hidden/laundry)

	if ((${#WATCH_PATHS[@]} == 0)); then
		echo "$(date '+%Y-%m-%d %H:%M:%S') no laundry roots found under $BASE; sleeping 10s" >>"$ERR_LOG"
		sleep 10
		continue
	fi

	mapfile -t sorted_watch_paths < <(printf '%s\n' "${WATCH_PATHS[@]}" | sort)
	watch_snapshot=$(printf '%s|' "${sorted_watch_paths[@]}")

	# inotify loop (auto-restarted if inotifywait exits)
	while read -r watched_dir filename events; do
		# DEBUG (optional): uncomment to see every raw event
		# echo "$(date '+%Y-%m-%d %H:%M:%S') DEBUG w='$watched_dir' f='$filename' e='$events'" >>"$ERR_LOG"

		# We care about file-level events only (skip weird empty filename cases)
		if [[ -z "$filename" ]]; then
			continue
		fi

		# Ignore directory events so we don't pollute the display with subdirs
		if [[ "$events" == *ISDIR* ]]; then
			continue
		fi

		# Normalize parent_dir (remove trailing slash)
		parent_dir="${watched_dir%/}"

		full_path="$parent_dir/$filename"

		# Skip directory creations even if ISDIR flag is missing
		if [[ -d "$full_path" ]]; then
			continue
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

		now=$(date +%s)

		# Periodic full refresh to catch new/removed dirs (only if configured)
		if ((FULL_REFRESH_INTERVAL > 0)) && ((now - last_full_refresh >= FULL_REFRESH_INTERVAL)); then
			init_counts_from_files
			render_monitor
			last_full_refresh=$now
			last_render=$now
			continue
		fi

		# Redraw logic
		if $REDUCED_CPU; then
			if ((now - last_render >= REFRESH_INTERVAL)); then
				render_monitor
				last_render=$now
			fi
		else
			render_monitor
			last_render=$now
		fi

		mapfile -t current_sorted_watch_paths < <(printf '%s\n' "$BASE"/*/.ocarina_hidden/laundry | sort)
		current_snapshot=$(printf '%s|' "${current_sorted_watch_paths[@]}")
		if [[ "$current_snapshot" != "$watch_snapshot" ]]; then
			watch_snapshot="$current_snapshot"
			break
		fi

	done < <(
		inotifywait -m -r \
			-e create -e delete -e moved_to -e moved_from \
			--format '%w %f %e %T' --timefmt '%s' \
			"${WATCH_PATHS[@]}" 2>>"$ERR_LOG"
	)

	if $LOGGING; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') inotifywait exited, restarting in 5 seconds" >>"$LOG_FILE"
	fi
	sleep 5
done
