#!/usr/bin/env bash

# QoreStor Laundry Monitor / Tools
# Modes:
#   Monitor (default): event-driven inotify monitor with counts & colors
#   --low-cpu       : monitor mode, but throttled redraw + periodic rescan
#   --list          : one-shot list of laundry dirs and file counts
#   --count         : one-shot count of laundry dirs
#
# Laundry layout:
#   /QSdata/ocaroot/<int>/.ocarina_hidden/laundry/<int>/<files>
#
# BASE is auto-detected from /etc/oca/oca.cfg (TGTDIR=<path>)
# Default BASE will be /QSdata/ocaroot only if config is absent/broken.


########################################
# Detect BASE from /etc/oca/oca.cfg
########################################

CFG_FILE="/etc/oca/oca.cfg"

detect_base() {
	local value=""

	# Ensure cfg file exists
	if [[ -f "$CFG_FILE" ]]; then
		# Extract TGTDIR=<path>
		value=$(grep -E '^TGTDIR=' "$CFG_FILE" 2>/dev/null | head -n1 | cut -d= -f2-)
	fi

	# Validate
	if [[ -n "$value" && -d "$value" ]]; then
		BASE="$value"
	else
		echo "Warning: Could not determine TGTDIR from $CFG_FILE" >&2
		echo "Using default BASE: $BASE" >&2
	fi
}

# Default BASE if config missing/corrupt
BASE="/QSdata/ocaroot"

# Run detection
detect_base

LOG_FILE="/var/log/qorestor_laundry_monitor.log"
ERR_LOG="/var/log/qorestor_laundry_monitor.err"

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

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$(dirname "$ERR_LOG")" 2>/dev/null || true

# Colors
color_reset=$(tput sgr0 2>/dev/null || echo "")
color_green=$(tput setaf 2 2>/dev/null || echo "")
color_red=$(tput setaf 1 2>/dev/null || echo "")
color_yellow=$(tput setaf 3 2>/dev/null || echo "")
color_magenta=$(tput setaf 5 2>/dev/null || echo "")
color_bold=$(tput bold 2>/dev/null || echo "")

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
Usage: $(basename "$0") [--low-cpu] [--list | --count]

Modes:
  (no options)   Monitor mode: event-driven inotify monitor with live display.
  --low-cpu      Monitor mode with reduced CPU usage:
                   - redraw limited to every N seconds
                   - periodic full refresh of all counts
  --list         One-shot list of all laundry directories and their file counts.
  --count        One-shot count of laundry directory paths.

Notes:
  --list and --count are mutually exclusive and non-monitoring (they exit after output).
  --low-cpu is only valid in monitor mode.
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

if $LOW_CPU; then
	REDUCED_CPU=true
	REFRESH_INTERVAL=3       # redraw at most every 3 seconds
	FULL_REFRESH_INTERVAL=60 # rescan counts every 60 seconds
fi

########################################
# Common helpers
########################################

# Find all laundry directories:
#   /QSdata/ocaroot/<int>/.ocarina_hidden/laundry/<int>
scan_laundry_dirs() {
	find "$BASE" \
		-regextype posix-extended \
		-type d \
		-regex "$BASE/[0-9]+/\\.ocarina_hidden/laundry/[0-9]+" \
		2>/dev/null | sort
}

# Initialize counts map from existing files (monitor mode)
init_counts_from_files() {
	counts=()
	prev_counts=()

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local count dir
		read -r count dir <<<"$line"
		[[ -z "$dir" ]] && continue
		counts["$dir"]=$count
		prev_counts["$dir"]=$count
	done < <(
		find "$BASE" \
			-regextype posix-extended \
			-type f \
			-regex "$BASE/[0-9]+/\\.ocarina_hidden/laundry/[0-9]+/[^/]+" \
			-printf '%h\n' 2>/dev/null |
			sort |
			uniq -c
	)
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
			line_color="${color_bold}${color_red}"
		else
			if ((cur > prev)); then
				line_color=$color_green
			elif ((cur < prev)); then
				line_color=$color_red
			else
				line_color=$color_reset
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

# Update count for a directory (+1 or -1) and log
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

	printf '%s dir="%s" op="%s" reason="%s" count=%d\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$dir" "$op" "$reason" "$cur" >>"$LOG_FILE"
}

########################################
# --list mode: one-shot list of dirs + counts
########################################
if [[ "$MODE" == "list" ]]; then
	counts=()
	prev_counts=()

	while IFS= read -r dir; do
		[[ -z "$dir" ]] && continue
		# Non-recursive count of files in each laundry dir
		local c
		c=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
		counts["$dir"]=$c
		prev_counts["$dir"]=$c
	done < <(scan_laundry_dirs)

	# Reuse monitor renderer (it already prints in the desired format)
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
# Monitor mode (default, with optional --low-cpu)
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
	# Watch only the laundry roots: /QSdata/ocaroot/<int>/.ocarina_hidden/laundry
	WATCH_PATHS=("$BASE"/*/.ocarina_hidden/laundry)

	if ((${#WATCH_PATHS[@]} == 0)); then
		echo "$(date '+%Y-%m-%d %H:%M:%S') no laundry roots found under $BASE; sleeping 10s" >>"$ERR_LOG"
		sleep 10
		continue
	fi

	# inotify loop (auto-restarted if inotifywait exits)
	while read -r watched_dir filename events; do
		fullpath="${watched_dir%/}/$filename"

		# Match only:
		#   /QSdata/ocaroot/<int>/.ocarina_hidden/laundry/<int>/<file>
		if [[ "$fullpath" =~ ^$BASE/[0-9]+/\.ocarina_hidden/laundry/[0-9]+/[^/]+$ ]]; then
			parent_dir="${fullpath%/*}"

			local_op=""
			if [[ "$events" == *CREATE* || "$events" == *MOVED_TO* ]]; then
				local_op="+1"
			elif [[ "$events" == *DELETE* || "$events" == *MOVED_FROM* ]]; then
				local_op="-1"
			else
				continue
			fi

			update_count "$parent_dir" "$local_op" "$events"

			now=$(date +%s)

			# Periodic full refresh to catch new/removed dirs (only if configured)
			if ((FULL_REFRESH_INTERVAL > 0)) && ((now - last_full_refresh >= FULL_REFRESH_INTERVAL)); then
				init_counts_from_files
				render_monitor
				last_full_refresh=$now
				last_render=$now
				continue
			fi

			if $REDUCED_CPU; then
				if ((now - last_render >= REFRESH_INTERVAL)); then
					render_monitor
					last_render=$now
				fi
			else
				render_monitor
				last_render=$now
			fi
		fi
	done < <(
		inotifywait -m -r \
			-e create -e delete -e moved_to -e moved_from \
			--format '%w %f %e' \
			"${WATCH_PATHS[@]}" 2>>"$ERR_LOG"
	)

	echo "$(date '+%Y-%m-%d %H:%M:%S') inotifywait exited, restarting in 5 seconds" >>"$LOG_FILE"
	sleep 5
done
