#!/bin/bash
#shellcheck shell=bash
set -euo pipefail

# Preserve the original stderr on FD 3 for debug output (so it never gets merged into stdout)
exec 3>&2

CONFIG_FILE="/etc/oca/oca.cfg"
BACKUP_DIR="/etc/oca"
LOG_DIR="/var/log/oca_edit"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DRY_RUN="false"
SCAN_ONLY="false"
VERIFY_CHECKSUM="false"
MOUNTPOINT=""
SCAN_FOUND=0
SCAN_TOTAL_BYTES=0
SCAN_MAP=""
grand_human=""
hb=""
COPIED_FILES=0

NEW_LINE=""
REFCNT_OLD="export PLATFORM_DS_REFCNTS_ON_SSD=0"
REFCNT_NEW="export PLATFORM_DS_REFCNTS_ON_SSD=1"
LOG_FILE=""
SUMMARY=()
BACKUP_FILE=""

DRY_HAS_TARGET="false" # in dry-run: did user say the target is mounted?
DRY_COPY_FILES=0
DRY_COPY_BYTES=0
DRY_SKIP_SERVICES="false"
TEST_MODE="false"
DEBUG_MODE="false"

# Layout detection (standard vs. alt)
ALT_LAYOUT="false"
R3_JOURNAL_PATH=""
REFCNT_SUBPATH=".ocarina_hidden/refcnt" # default; alt layout switches this to "refcnt"

# ---- Defaults ----
STOP_TIMEOUT=120      # seconds to wait for service to stop
START_TIMEOUT=120     # seconds to wait for service startup
START_POLL_INTERVAL=2 # seconds between state checks

# ---- Colors ----
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
NC=$'\033[0m' # reset
BLUE=$'\033[34m'
BOLD=$'\033[1m'

# ---- Functions ----
usage() {
	echo "Usage: $0 [--dry-run] [--scan-only] [--checksum-verify] [MOUNTPOINT]"
	echo
	echo "  --dry-run           Show what would happen (scan + rsync -n stats + config preview)"
	echo "  --scan-only         Only scan and sum refcount sizes (no copy, no edits)"
	echo "  --checksum-verify   Use rsync --checksum during verify step (slower, strongest check)"
	echo "  MOUNTPOINT          Target mount name for TGTSSDDIR in edit mode; prompted if omitted"
}

banner() {
	local text="$1"
	local color="${2:-$CYAN}" # default cyan if not given
	echo "${BOLD}${color}=== ${text} ===${NC}"
}

decide_dryrun_target() {
	# Only asked in DRY-RUN or TEST mode
	if [ "$DRY_RUN" != "true" ]; then
		return
	fi

	local ans
	read -rp "Is the new SSD location mounted and available now? [yes/NO]: " ans
	if [[ "${ans,,}" == "yes" ]]; then
		DRY_HAS_TARGET="true"
		DRY_SKIP_SERVICES="false" # boolean, no quotes
		debug_log " decide_dryrun_target: DRY_HAS_TARGET=true, DRY_SKIP_SERVICES=false"
		setup_mountpoint
	else
		DRY_HAS_TARGET="false"
		DRY_SKIP_SERVICES="true" # boolean, no quotes
		debug_log " decide_dryrun_target: DRY_HAS_TARGET=false, DRY_SKIP_SERVICES=true"
		echo "[DRY RUN] No target mount selected."
		echo "[DRY RUN] Will run SCAN-ONLY mode instead."
	fi
}

# ---- System Info ----
capture_system_info() {
	if ! command -v system &>/dev/null; then
		echo "Warning: 'system' command not found. Skipping system info."
		return
	fi
	banner "=== SYSTEM INFO ===" "$BLUE"
	system --show | grep -E -i '^(System Name|Current Time|System ID|Product Name|Version|Build|Repository location|Metadata location)'
	echo
}

detect_layout_once() {
	# Defensive defaults
	declare -g ALT_LAYOUT="false"
	declare -g REFCNT_SUBPATH=".ocarina_hidden/refcnt"
	declare -g R3_JOURNAL_PATH=""

	# Presence checks in CONFIG_FILE
	local has_refcnt_on_ssd has_tgt_is_r3 r3val
	has_refcnt_on_ssd=$(grep -E '^\s*export\s+PLATFORM_DS_REFCNTS_ON_SSD=1\s*$' "$CONFIG_FILE" || true)
	has_tgt_is_r3=$(grep -E '^\s*export\s+TGTSSDDIR=\$\{R3_DISK_JOURNAL_PATH\}\s*$' "$CONFIG_FILE" || true)

	if [[ -n "$has_refcnt_on_ssd" && -n "$has_tgt_is_r3" ]]; then
		# Parse R3_DISK_JOURNAL_PATH
		r3val="$(awk -F= '/^\s*export\s+R3_DISK_JOURNAL_PATH=/{sub(/\r/,"",$2); print $2}' "$CONFIG_FILE" | sed 's/^["'\'']//; s/["'\'']$//')"
		if [[ -n "$r3val" && -d "$r3val" ]]; then
			ALT_LAYOUT="true"
			REFCNT_SUBPATH="refcnt"
			R3_JOURNAL_PATH="$r3val"
		fi
	fi

	# Debug: always print what we decided
	debug_log "detect_layout_once: ALT_LAYOUT=$ALT_LAYOUT"
	debug_log "detect_layout_once: REFCNT_SUBPATH=$REFCNT_SUBPATH"
	if [[ "$ALT_LAYOUT" == "true" ]]; then
		debug_log "detect_layout_once: R3_JOURNAL_PATH=$R3_JOURNAL_PATH"
	fi
}

# ---- Detect alternate repo root from config (R3 layout) ----
detect_alt_repo_from_config() {
	# Print the R3_DISK_JOURNAL_PATH and return 0 if BOTH are true:
	#   PLATFORM_DS_REFCNTS_ON_SSD=1
	#   TGTSSDDIR=${R3_DISK_JOURNAL_PATH}  (or $R3_DISK_JOURNAL_PATH)
	# Otherwise return 1.

	local r3_path
	r3_path="$(
		awk '
      BEGIN { has_ref=0; has_tgt=0; r3="" }
      {
        line=$0
        sub(/\r$/, "", line)             # handle possible CRLF
        # Normalize
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)

        # PLATFORM_DS_REFCNTS_ON_SSD=1 (with/without export)
        if (line ~ /^(export[[:space:]]+)?PLATFORM_DS_REFCNTS_ON_SSD[[:space:]]*=[[:space:]]*1[[:space:]]*$/) {
          has_ref=1
        }

        # TGTSSDDIR=$R3_DISK_JOURNAL_PATH or ${R3_DISK_JOURNAL_PATH}
        if (line ~ /^(export[[:space:]]+)?TGTSSDDIR[[:space:]]*=[[:space:]]*\$({)?R3_DISK_JOURNAL_PATH(})?[[:space:]]*$/) {
          has_tgt=1
        }

        # Capture R3_DISK_JOURNAL_PATH (with/without export; with/without quotes)
        if (line ~ /^(export[[:space:]]+)?R3_DISK_JOURNAL_PATH[[:space:]]*=/) {
          split(line, a, "=")
          val=a[2]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
          gsub(/^"\s*|\s*"$/, "", val)    # strip double quotes
          gsub(/^'\''\s*|\s*'\''$/, "", val) # strip single quotes
          sub(/\r$/, "", val)             # CR, just in case
          r3=val
        }
      }
      END {
        if (has_ref && has_tgt && r3 != "") {
          print r3
          exit 0
        }
        exit 1
      }
    ' "$CONFIG_FILE"
	)"

	if [[ -n "$r3_path" && -d "$r3_path" ]]; then
		[ "$DEBUG_MODE" = "true" ] && echo "[DEBUG] R3 detection succeeded, R3_DISK_JOURNAL_PATH='$r3_path'"
		printf "%s" "$r3_path"
		return 0
	fi

	[ "$DEBUG_MODE" = "true" ] && echo "[DEBUG] R3 detection not satisfied (or path missing)."
	return 1
}

get_repo_location() {
	if ! command -v system &>/dev/null; then
		echo "Error: 'system' command not found; cannot determine Repository location." >&2
		return 1
	fi

	if [[ "$ALT_LAYOUT" == "true" ]]; then
		# Alt layout: the "repo root" is the R3 journal path
		if [[ -z "$R3_JOURNAL_PATH" || ! -d "$R3_JOURNAL_PATH" ]]; then
			echo "Error: ALT_LAYOUT=true but R3_JOURNAL_PATH invalid: '$R3_JOURNAL_PATH'." >&2
			return 1
		fi
		debug_log "get_repo_location: ALT repo -> $R3_JOURNAL_PATH (subpath=$REFCNT_SUBPATH)"
		printf "%s" "$R3_JOURNAL_PATH"
		return 0
	fi

	# Standard layout
	local repo
	repo="$(system --show | awk -F': ' '/^Repository location/ {print $2}' | sed 's/[[:space:]]*$//')"
	if [[ -z "${repo:-}" || ! -d "$repo" ]]; then
		echo "Error: Could not resolve valid Repository location from 'system --show'." >&2
		return 1
	fi
	debug_log "get_repo_location: standard repo -> $repo (subpath=$REFCNT_SUBPATH)"
	printf "%s" "$repo"
}

# ---- Human-readable bytes ----
# Convert a size string to bytes.
# Accepts plain bytes like "123456" or "123,456 bytes", or IEC like "25.1G".
to_bytes() {
	local s="$1"
	# Strip commas and trailing " bytes"
	s="${s//,/}"
	s="${s% bytes}"

	# If it's already an integer, return it
	if [[ "$s" =~ ^[0-9]+$ ]]; then
		printf "%s" "$s"
		return
	fi

	# numfmt best effort
	if command -v numfmt >/dev/null 2>&1; then
		# numfmt --from=iec handles KiB/MiB/GiB/TiB and also K/M/G/T as 1024 base
		local out
		if out="$(numfmt --from=iec "$s" 2>/dev/null)"; then
			printf "%s" "$out"
			return
		fi
	fi

	# Fallback parser (IEC base 1024), accepts optional i: K/Ki, M/Mi, ...
	awk -v s="$s" '
        function mul(u) {
            if (u=="K"||u=="Ki") return 1024;
            if (u=="M"||u=="Mi") return 1024^2;
            if (u=="G"||u=="Gi") return 1024^3;
            if (u=="T"||u=="Ti") return 1024^4;
            if (u=="P"||u=="Pi") return 1024^5;
            return 1;
        }
        BEGIN {
            if (match(s, /^([0-9]+(\.[0-9]+)?)\s*([KMGTPE]?i?)/, m)) {
                val = m[1]+0; unit = m[3];
                printf "%.0f", val * mul(unit);
            } else {
                gsub(/[^0-9]/, "", s);
                if (s=="") s="0";
                print s+0;
            }
        }'
}

human_bytes() {
	if command -v numfmt >/dev/null 2>&1; then
		numfmt --to=iec --suffix=B --format="%.2f" "$1"
		return
	fi
	awk -v b="$1" '
        function fmt(x, u) { printf("%.2f %sB\n", x, u); }
        BEGIN {
            v=b+0
            if (v<1024) { fmt(v, ""); exit }
            v/=1024; if (v<1024) { fmt(v,"Ki"); exit }
            v/=1024; if (v<1024) { fmt(v,"Mi"); exit }
            v/=1024; if (v<1024) { fmt(v,"Gi"); exit }
            v/=1024; fmt(v,"Ti");
        }'
}

run_with_bar() {
	# Args: the exact rsync (or other) command + flags to run
	local -a cmd=("$@")

	# Detect dry-run
	local dry=false
	for a in "${cmd[@]}"; do
		[[ "$a" == "-n" || "$a" == "--dry-run" ]] && dry=true
	done

	# Save shell strictness and relax inside this function
	local _had_errexit=0 _had_pipefail=0
	if [[ $- == *e* ]]; then
		_had_errexit=1
		set +e
	fi
	if shopt -qo pipefail; then
		_had_pipefail=1
		set +o pipefail
	fi

	if "$dry"; then
		# DRY-RUN: run once, simulate bar from stats
		local out total i pct bar_len bar
		out="$("${cmd[@]}" 2>&1 || true)"
		total="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
		: "${total:=100}"

		i=0
		while ((i <= total)); do
			pct=$((i * 100 / total))
			bar_len=$((pct / 2))
			bar=$(printf "%0.s#" $(seq 1 $bar_len))
			printf "\r[%-50s] %3d%% (simulated)" "$bar" "$pct"
			sleep 0.02
			((i += (total / 20 > 0 ? total / 20 : 1)))
		done
		printf "\r[%-50s] %3d%% (simulated)\n\n" "##################################################" 100
		printf "%s\n" "$out"

		((_had_pipefail)) && set -o pipefail
		((_had_errexit)) && set -e
		return 0
	fi

	# LIVE: write rsync output to a temp file and follow it
	local tmp
	tmp="$(mktemp)"

	# Start rsync (line-buffered) -> tmp
	stdbuf -oL -eL "${cmd[@]}" >"$tmp" 2>&1 &
	local rsync_pid=$!

	# Reader: follow tmp until *rsync* exits; show only the bar
	{
		local line pct last_pct=-1 bar_len bar
		# --pid makes tail exit when rsync exits; tr turns \r into \n so we see updates
		tail -n +1 -F "$tmp" --pid="$rsync_pid" 2>/dev/null |
			tr '\r' '\n' |
			while IFS= read -r line; do
				if [[ "$line" =~ ([0-9]{1,3})% ]]; then
					pct="${BASH_REMATCH[1]}"
					((pct < 0)) && pct=0
					((pct > 100)) && pct=100
					if ((pct != last_pct)); then
						bar_len=$((pct / 2))
						bar=$(printf "%0.s#" $(seq 1 $bar_len))
						printf "\r[%-50s] %3d%%" "$bar" "$pct"
						last_pct=$pct
					fi
				fi
			done
	} &
	local reader_pid=$!

	# Wait for rsync, then for reader (reader exits automatically via --pid)
	wait "$rsync_pid"
	local rsync_rc=$?
	wait "$reader_pid" 2>/dev/null || true

	# Freeze the bar at 100% and ensure a blank line before summary/banners
	printf "\r[%-50s] %3d%%\n\n" "##################################################" 100

	# Print rsync summary once (no % lines)
	grep -v '%' "$tmp" || true
	rm -f "$tmp"

	# Extra newline so your next banner never sticks to the bar or summary
	echo

	# Restore shell strictness
	((_had_pipefail)) && set -o pipefail
	((_had_errexit)) && set -e

	return "$rsync_rc"
}

simulate_bar() {
	while true; do
		for pct in 0 20 40 60 80 100; do
			local bar_len=$((pct / 2)) # 50 chars = 100%
			local bar=$(printf "%0.s#" $(seq 1 $bar_len))
			printf "\r[%-50s] %3d%% (simulated)" "$bar" "$pct"
			sleep 0.2
		done
	done
}

debug_log() {
	if [ "$DEBUG_MODE" = "true" ]; then
		# Write to original stderr (FD 3), bypassing any later 2>&1 logging
		echo "[DEBUG]$*" >&3
	fi
}

debug_printf() {
	if [ "$DEBUG_MODE" = "true" ]; then
		local fmt="$1"
		shift
		# Write to original stderr (FD 3), bypassing any later 2>&1 logging
		printf "[DEBUG]$fmt\n" "$@" >&3
	fi
}

# ---- Arg parsing (phase 1 only: detect flags, save args) ----
parse_args() {
	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run | --dryrun | -n)
			DRY_RUN="true"
			shift
			;;
		--scan-only | --scan)
			SCAN_ONLY="true"
			shift
			;;
		--checksum-verify | --checksum | --verify)
			VERIFY_CHECKSUM="true"
			shift
			;;
		--test)
			TEST_MODE="true"
			shift
			;;
		--debug)
			DEBUG_MODE="true"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			while [[ $# -gt 0 ]]; do
				args+=("$1")
				shift
			done
			break
			;;
		-*)
			echo "Error: Unknown option '$1'"
			usage
			exit 2
			;;
		*)
			args+=("$1")
			shift
			;;
		esac
	done
	PARSED_ARGS=("${args[@]}")
}

# ---- Mountpoint normalization (phase 2: after DRY_RUN is known) ----
setup_mountpoint() {
	if [ "$SCAN_ONLY" = "true" ]; then
		return
	fi

	while true; do
		if [[ ${#PARSED_ARGS[@]} -gt 0 && -z "$MOUNTPOINT" ]]; then
			MOUNTPOINT="${PARSED_ARGS[0]}"
		elif [[ -z "$MOUNTPOINT" ]]; then
			read -rp "Enter the full mount path (e.g. /mountpoint or /mountpoint/subdir): " MOUNTPOINT
		fi

		# Require full path
		if [[ -z "$MOUNTPOINT" || "${MOUNTPOINT:0:1}" != "/" ]]; then
			echo -e "${RED}Error: Mountpoint must be a full path starting with '/'.${NC}"
			MOUNTPOINT=""
			continue
		fi

		# Strip trailing slash
		MOUNTPOINT="${MOUNTPOINT%/}"

		# If user included /ssd, strip it off
		if [[ "$MOUNTPOINT" =~ /ssd$ ]]; then
			MOUNTPOINT="${MOUNTPOINT%/ssd}"
		fi

		# --- Validation rules ---
		if [ "$TEST_MODE" = "true" ]; then
			# In test mode, only check existence of the directory
			if [[ ! -d "$MOUNTPOINT" ]]; then
				echo -e "${RED}Error: Directory '$MOUNTPOINT' does not exist. Please re-enter.${NC}"
				MOUNTPOINT=""
				continue
			else
				echo "[TEST MODE] Directory '$MOUNTPOINT' exists (mountpoint check skipped)."
			fi
		elif [ "$DRY_RUN" = "true" ]; then
			# In dry-run, check directory existence only
			if [[ ! -d "$MOUNTPOINT" ]]; then
				echo -e "${RED}Error: Directory '$MOUNTPOINT' does not exist. Please re-enter.${NC}"
				MOUNTPOINT=""
				continue
			fi
		else
			# In live mode, enforce mountpoint check
			if ! mountpoint -q "$MOUNTPOINT"; then
				echo -e "${RED}Error: '$MOUNTPOINT' is not a mounted filesystem. Please re-enter.${NC}"
				MOUNTPOINT=""
				continue
			fi
		fi

		# Build export line
		NEW_LINE="export TGTSSDDIR=${MOUNTPOINT}/ssd/"

		# Create ssd dir only in LIVE mode
		if [ "$DRY_RUN" != "true" ]; then
			if [[ ! -d "${MOUNTPOINT}/ssd" ]]; then
				mkdir -p "${MOUNTPOINT}/ssd"
				banner "Created directory: ${MOUNTPOINT}/ssd" "$GREEN"
			fi
		fi

		SUMMARY+=("${GREEN}✔ Using target SSD directory: ${MOUNTPOINT}/ssd/${NC}")
		break
	done
}

# ---- Logging ----
setup_logging() {
	mkdir -p "$LOG_DIR"
	LOG_FILE="${LOG_DIR}/oca_edit_${TIMESTAMP}.log"

	# Log stdout and stderr to the same file, but keep them as distinct FDs
	exec 1> >(stdbuf -o0 -e0 tee -a "$LOG_FILE")
	exec 2> >(stdbuf -o0 -e0 tee -a "$LOG_FILE" >&2)

	banner "=== QoreStor Config Edit Script ===" "$CYAN"
	echo "Run timestamp: $(date)"
	echo "Config file: $CONFIG_FILE"
	echo "Backup dir: $BACKUP_DIR"
	echo "Log file: $LOG_FILE"

	if [ "$DRY_RUN" = "true" ]; then
		banner "MODE: DRY-RUN" "$YELLOW"
	elif [ "$SCAN_ONLY" = "true" ]; then
		banner "MODE: SCAN-ONLY" "$YELLOW"
	else
		banner "MODE: LIVE" "$GREEN"
	fi

	banner "Dry run: $DRY_RUN" "$YELLOW"
	banner "Scan only: $SCAN_ONLY" "$YELLOW"
	banner "Verify checksum: $VERIFY_CHECKSUM" "$YELLOW"

	if [ "$DRY_RUN" = "true" ]; then
		banner "Dry-run target available: $DRY_HAS_TARGET" "$YELLOW"
	fi

	if [ "$SCAN_ONLY" != "true" ]; then
		echo "Mountpoint: $MOUNTPOINT"
	fi

	echo
	capture_system_info
}
# ---- Service Control ----
get_system_state() {
	system --show 2>/dev/null | awk -F': ' '/^System State/ {print $2}' | sed 's/[[:space:]]*$//'
}

get_system_reason() {
	system --show 2>/dev/null | awk -F': ' '/^Reason/ {print $2}' | sed 's/[[:space:]]*$//'
}

verify_ready_to_stop() {
	local service="ocards"
	local sys_state svc_state reason
	sys_state=$(get_system_state 2>/dev/null || echo "unknown")
	svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
	reason=$(get_system_reason 2>/dev/null || echo "unknown")

	banner "=== SERVICE STOP PRECHECK ===" "$BLUE"
	echo "System State : $sys_state"
	echo "Service State: $svc_state"
	echo "Reason       : $reason"

	if [ "$DRY_RUN" = "true" ]; then
		banner "[DRY RUN] Would proceed to stop service: $service" "$YELLOW"
		SUMMARY+=("${GREEN}✔ DRY-RUN: would stop ${service} (precheck OK)${NC}")
		return 0
	fi

	# In live mode, we just show info and continue
	SUMMARY+=("${GREEN}✔ Precheck before stopping ${service}: sys=$sys_state, svc=$svc_state, reason=$reason${NC}")
	return 0
}

wait_for_service_stop() {
	local service="$1"
	local timeout="${2:-$STOP_TIMEOUT}"

	if [ "$DRY_RUN" = "true" ]; then
		echo -e "${CYAN}=== DRY-RUN: STOPPING SERVICE '$service' ===${NC}"
		echo -e "${YELLOW}[DRY RUN] Would stop service: $service${NC}"
		echo "• Command: systemctl stop $service"
		echo "• Condition: Wait until System State=Stopped"
		SUMMARY+=("[DRY RUN] Would stop service: $service")
		return 0
	fi

	echo -e "${CYAN}=== STOPPING SERVICE '$service' ===${NC}"
	if ! systemctl stop "$service" 2>/dev/null; then
		echo -e "${RED}✘ Failed to issue systemctl stop for $service${NC}"
		SUMMARY+=("✘ Failed to issue stop for $service")
		return 1
	fi

	local start_ts=$(date +%s)
	local sys_state

	# Print initial line
	sys_state=$(get_system_state 2>/dev/null || printf "unknown")
	printf "System State : %s\n" "$sys_state"

	while :; do
		sys_state=$(get_system_state 2>/dev/null || printf "unknown")

		# overwrite the line in-place
		printf "\033[1A" # move cursor up one line
		printf "System State : %s\033[K\n" "$sys_state"

		if [[ "$sys_state" == "Stopped" ]]; then
			echo -e "${GREEN}✔ Service '$service' stopped (System State=Stopped).${NC}"
			SUMMARY+=("${GREEN}✔ Service stopped: $service (System State=Stopped).${NC}")
			return 0
		fi

		if (($(date +%s) - start_ts >= timeout)); then
			echo -e "${RED}✘ Timeout waiting for '$service' to stop (> ${timeout}s). Last state: $sys_state${NC}"
			SUMMARY+=("✘ Stop timeout for $service (last state=$sys_state)")
			return 1
		fi

		sleep 1
	done
}

start_services() {
	local service="ocards"

	if [ "$DRY_RUN" = "true" ]; then
		echo -e "${CYAN}=== DRY-RUN: STARTING SERVICE '$service' ===${NC}"
		echo -e "${YELLOW}[DRY RUN] Would start service: $service${NC}"
		echo "• Command: systemctl start $service"
		echo "• Condition: Wait until System State=Operational Mode and Reason=Filesystem is fully operational for I/O."
		SUMMARY+=("[DRY RUN] Would start service: $service")
		return 0
	fi

	echo -e "${CYAN}=== STARTING SERVICE '$service' ===${NC}"
	systemctl start "$service" || {
		echo -e "${RED}✘ Failed to issue systemctl start for $service${NC}"
		SUMMARY+=("✘ Failed to issue start for $service")
		return 1
	}

	local start_ts=$(date +%s)
	local first_print=true

	while true; do
		local sys_state reason svc_state
		sys_state=$(get_system_state 2>/dev/null || echo "unknown")
		reason=$(get_system_reason 2>/dev/null || echo "unknown")
		svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

		if [ "$first_print" = true ]; then
			echo "System State : $sys_state"
			echo "Service State: $svc_state"
			echo "Reason       : $reason"
			first_print=false
		else
			# Move cursor up 3 lines and overwrite them
			printf "\033[3A"
			printf "System State : %s\033[K\n" "$sys_state"
			printf "Service State: %s\033[K\n" "$svc_state"
			printf "Reason       : %s\033[K\n" "$reason"
		fi

		if [[ "$sys_state" == "Operational Mode" && "$reason" == "Filesystem is fully operational for I/O." && "$svc_state" == "active" ]]; then
			echo -e "${GREEN}✔ Service '$service' is fully operational.${NC}"
			SUMMARY+=("${GREEN}✔ Service started and operational: $service${NC}")
			return 0
		fi

		if (($(date +%s) - start_ts >= START_TIMEOUT)); then
			echo -e "${RED}✘ Timeout waiting for '$service' to start (>${START_TIMEOUT}s). Last state: $sys_state, reason: $reason${NC}"
			SUMMARY+=("${RED}✘ Start timeout for $service (last sys=$sys_state, reason=$reason)${NC}")
			return 1
		fi

		sleep 2
	done
}

plan_copy_totals() {
	local repo
	repo="$(get_repo_location)" || return 1

	local total_files=0
	shopt -s nullglob
	for d in "$repo"/*; do
		[[ -d "$d" ]] || continue
		local base="$(basename -- "$d")"
		[[ "$base" =~ ^[0-9]+$ ]] || continue
		local refdir="$d/$REFCNT_SUBPATH"
		if [[ -d "$refdir" ]]; then
			local count
			count="$(find "$refdir" -type f 2>/dev/null | wc -l)"
			total_files=$((total_files + count))
		fi
	done
	shopt -u nullglob

	echo "$total_files"
}

safe_rsync() {
	# usage: safe_rsync <args...>
	# If DRY_RUN=true, require that -n (or --dry-run) is present in args.
	local want_dry="$DRY_RUN"
	local have_dry="false"
	for a in "$@"; do
		if [[ "$a" == "-n" || "$a" == "--dry-run" ]]; then
			have_dry="true"
			break
		fi
	done
	if [ "$want_dry" = "true" ] && [ "$have_dry" != "true" ]; then
		echo "FATAL: rsync invoked without -n in dry-run mode. Aborting." >&2
		return 99
	fi
	rsync "$@"
}

# ---- Scan-only (also reused for sizing) ----
scan_refcnt_sizes() {
	local repo
	repo="$(get_repo_location)" || {
		echo "Scan aborted."
		return 1
	}

	echo "Scanning refcount data under: $repo"
	echo "Looking for integer dirs with '$REFCNT_SUBPATH'"
	echo

	local -i found=0
	local total_bytes=0

	shopt -s nullglob
	for d in "$repo"/*; do
		[[ -d "$d" ]] || continue
		local base="$(basename -- "$d")"
		[[ "$base" =~ ^[0-9]+$ ]] || continue
		((found++))

		local refdir="$d/$REFCNT_SUBPATH"
		local bytes=0
		if [[ -d "$refdir" ]]; then
			bytes="$(du -sb "$refdir" 2>/dev/null | awk '{print $1}')"
			bytes="${bytes:-0}"
		else
			echo "Note: Missing refcount path for $base -> $refdir"
		fi

		total_bytes=$((total_bytes + bytes))
		local hb
		hb=$(human_bytes "$bytes")
		printf "Directory %s: %s\n" "$base" "$hb"
	done
	shopt -u nullglob

	if ((found == 0)); then
		echo "${RED}No integer-named directories with refcnt found under $repo.${NC}"
		SUMMARY+=("${RED}✘ Scan: 0 integer dirs found under $repo${NC}")
		return 0
	fi

	echo
	local grand_human
	grand_human=$(human_bytes "$total_bytes")
	echo "Total Refcount Size: $grand_human"
	echo

	SUMMARY+=("${GREEN}✔ Scan: $found integer dirs under $repo${NC}")
	SUMMARY+=("${GREEN}✔ Total Refcount Size: $grand_human${NC}")

	SCAN_FOUND="$found"
	SCAN_TOTAL_BYTES="$total_bytes"
	return 0
}

# ---- Free space check ----
check_free_space() {
	local target_base="$1"
	local need_bytes="$2"

	if ! command -v df >/dev/null 2>&1; then
		echo "Warning: 'df' not available, skipping free space check."
		return 0
	fi
	if [ "$DRY_RUN" != "true" ]; then
		mkdir -p "$target_base"
	fi

	local avail
	avail="$(df -PB1 "$target_base" | awk 'NR==2{print $4}')"
	if [[ -z "$avail" ]]; then
		echo "Warning: Unable to determine free space for $target_base"
		return 0
	fi
	echo "Free space on target: $(human_bytes "$avail") | Required: $(human_bytes "$need_bytes")"
	if ((avail < need_bytes)); then
		echo "ERROR: Not enough free space on $target_base"
		return 1
	fi
	return 0
}

# ---- Rsync copy + verification (no deletion of sources) ----
rsync_base_flags() {
	# Base flags: safe attributes, numeric IDs, sparse, whole-file
	printf '%s\n' -aHAX --numeric-ids --sparse -W --human-readable --dirs
}

rsync_verify_flags() {
	# start from base
	mapfile -t base < <(rsync_base_flags)
	if [ "$VERIFY_CHECKSUM" = "true" ]; then
		base+=(--checksum)
	fi
	printf '%s\n' "${base[@]}"
}

copy_one_refcnt() {
	local SRC="$1" DST="$2" base="$3"

	# --- Normalize SRC/DST to the refcnt subtree for both layouts ---
	# Expect global: REFCNT_SUBPATH (".ocarina_hidden/refcnt" or "refcnt")
	# If SRC is an integer dir (or its base) and SRC/$REFCNT_SUBPATH exists, fix SRC/DST.
	local tail="${SRC%/}"
	tail="${tail##*/}"                      # last path component of SRC
	local need_tail="${REFCNT_SUBPATH##*/}" # "refcnt"

	if [[ "$tail" != "$need_tail" && -d "$SRC/$REFCNT_SUBPATH" ]]; then
		debug_log "copy_one_refcnt: auto-appending REFCNT_SUBPATH to SRC/DST (layout fix)"
		SRC="$SRC/$REFCNT_SUBPATH"
		# Only append to DST if it doesn't already end with .../refcnt
		local dst_tail="${DST%/}"
		dst_tail="${dst_tail##*/}"
		[[ "$dst_tail" == "$need_tail" ]] || DST="$DST/$REFCNT_SUBPATH"
	fi
	# --- end normalization ---

	if [[ ! -d "$SRC" ]]; then
		echo "Note: Missing $SRC (skipped)"
		SUMMARY+=("✘ Skip (missing): $SRC")
		return 0
	fi

	# Only create destination in LIVE mode
	if [ "$DRY_RUN" != "true" ]; then
		mkdir -p "$DST"
	fi

	local -a RSYNC_ARGS
	if [ "$DRY_RUN" = "true" ]; then
		IFS=$'\n' read -r -d '' -a RSYNC_ARGS < <(rsync_base_flags && printf '\0')
		RSYNC_ARGS+=(--stats -n)

		echo "[DRY RUN] rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"
		echo "[DRY RUN] Scanning files, please wait..."
		simulate_bar &
		BAR_PID=$!

		local tmpfile
		tmpfile="$(mktemp)"
		# unsafe rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" >"$tmpfile" 2>&1 || true
		safe_rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" >"$tmpfile" 2>&1 || true

		kill "$BAR_PID" 2>/dev/null
		wait "$BAR_PID" 2>/dev/null || true
		echo

		local files
		files="$(awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}' "$tmpfile")"
		: "${files:=0}"
		rm -f "$tmpfile"

		printf "Directory %s: %'d files would be transferred\n" "$base" "$files"
		SUMMARY+=("Directory $base: $files files would be transferred")

		DRY_COPY_FILES=$((DRY_COPY_FILES + files))
		COPIED_FILES=$((COPIED_FILES + files))
		return 0
	fi

	# --- LIVE RUN ---
	mapfile -t RSYNC_ARGS < <(rsync_base_flags)
	RSYNC_ARGS+=(--stats --info=progress2)

	echo "[LIVE] rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

	local src_count
	src_count=$(find "$SRC" -type f 2>/dev/null | wc -l | awk '{print $1+0}')
	echo "[INFO] Copying $(printf "%'d" "$src_count") files from $SRC to $DST ..."

	local tmpfile
	tmpfile="$(mktemp)"
	if run_with_bar rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1 | tee "$tmpfile"; then
		local files
		files="$(awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}' "$tmpfile")"
		: "${files:=0}"
		printf "\nDirectory %s: %'d files copied\n" "$base" "$files"
		SUMMARY+=("Directory $base: $files files copied")
		COPIED_FILES=$((COPIED_FILES + files))
		rm -f "$tmpfile"
		return 0
	else
		SUMMARY+=("✘ rsync failed: $SRC -> $DST")
		cat "$tmpfile"
		rm -f "$tmpfile"
		return 1
	fi
}

verify_one_refcnt() {
	local SRC="$1" DST="$2"
	local -a RSYNC_ARGS
	IFS=$'\n' read -r -d '' -a RSYNC_ARGS < <(rsync_verify_flags && printf '\0')

	local out rc files

	if [ "$DRY_RUN" = "true" ]; then
		RSYNC_ARGS+=(-n --stats)
		echo "[DRY RUN] verify rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

		# unsafe out="$(rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1 || true)"
		out="$(safe_rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1 || true)"

		files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
		: "${files:=0}"

		printf "[DRY RUN] Verify %s: %'d files would be compared\n" "$SRC" "$files"
		SUMMARY+=("Would verify $SRC: $files files")
		return 0
	fi

	# --- LIVE RUN ---
	echo "[LIVE] verify rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

	set +e
	# unsafe out="$(rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1)"
	out="$(safe_rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1)"
	rc=$?
	set -e

	if [[ $rc -ne 0 ]]; then
		echo "✘ Verification errors: $SRC -> $DST"
		echo "$out"
		SUMMARY+=("✘ Verify failed: $SRC -> $DST")
		return 1
	fi

	if [[ -n "$out" ]]; then
		echo "✘ Differences found: $SRC -> $DST"
		echo "$out"
		SUMMARY+=("✘ Verify mismatch: $SRC -> $DST")
		return 1
	fi

	# At this point, directories match
	if [ "$VERIFY_CHECKSUM" = "true" ]; then
		banner "✔ Verified OK (checksum): $SRC -> $DST" "$GREEN"
		SUMMARY+=("${GREEN}✔ Verified OK (checksum): $SRC -> $DST${NC}")
	else
		banner "✔ Verified OK (size/time): $SRC -> $DST" "$GREEN"
		SUMMARY+=("${GREEN}✔ Verified OK (size/time): $SRC -> $DST${NC}")
	fi
	return 0
}

copy_all_refcnt() {
	local planned_files
	planned_files="$(plan_copy_totals)"
	echo "Planned total files to copy: $(printf "%'d" "$planned_files")"
	SUMMARY+=("Planned total files to copy: $(printf "%'d" "$planned_files")")

	local repo
	repo="$(get_repo_location)" || {
		echo "Copy aborted."
		return 1
	}

	# --- DRY-RUN without target ---
	if [ "$DRY_RUN" = "true" ] && [ "$DRY_HAS_TARGET" != "true" ]; then
		echo
		echo "[DRY RUN] Plan-only mode (no target)."
		echo "[DRY RUN] Space check skipped (no target available)."
		echo
		SUMMARY+=("✘ Space check skipped (no target in dry-run)")

		COPIED_FILES="$planned_files"
		echo "Total files that would be copied: $(printf "%'d" "$planned_files")"
		SUMMARY+=("Total files that would be copied: $(printf "%'d" "$planned_files")")
		return 0
	fi

	# --- LIVE or DRY-RUN with target ---
	local target_base="${NEW_LINE#export TGTSSDDIR=}"
	target_base="${target_base%/}"
	if [[ -z "$target_base" || "$target_base" == "export TGTSSDDIR=" ]]; then
		echo "Error: Target base (TGTSSDDIR) not set; aborting copy."
		return 1
	fi

	local need="${SCAN_TOTAL_BYTES:-0}"
	echo "Planned copy target base: $target_base"

	local base_mount="${MOUNTPOINT:-$target_base}"
	check_free_space "$base_mount" "$need" || return 1
	echo

	local filelist
	filelist="$(mktemp)"
	echo "[INFO] Building refcnt file list, this may take a while..."
	# Build list of all refcnt files (relative to $repo) for current layout
	(cd "$repo" && find . -type f -path "*/${REFCNT_SUBPATH}/*") >"$filelist"

	echo "[INFO] File list built: $(wc -l <"$filelist") files queued for rsync"
	echo

	local -a RSYNC_ARGS
	if [ "$DRY_RUN" = "true" ]; then
		# DRY-RUN
		IFS=$'\n' read -r -d '' -a RSYNC_ARGS < <(rsync_base_flags && printf '\0')
		RSYNC_ARGS+=(--files-from="$filelist" --stats -n)

		echo "[DRY RUN] rsync ${RSYNC_ARGS[*]} $repo/ $target_base/" >>"$LOG_FILE"
		echo "[DRY RUN] Scanning all refcnt files, please wait..."
		simulate_bar &
		BAR_PID=$!

		local tmpfile
		tmpfile="$(mktemp)"
		# unsafe rsync "${RSYNC_ARGS[@]}" "$repo/" "$target_base/" >"$tmpfile" 2>&1 || true
		safe_rsync "${RSYNC_ARGS[@]}" "$repo/" "$target_base/" >"$tmpfile" 2>&1 || true
		kill "$BAR_PID" 2>/dev/null
		wait "$BAR_PID" 2>/dev/null || true
		printf "\r[%-50s] %3d%% (simulated)\n" "##################################################" 100

		awk -F': ' '/Number of regular files transferred/ {print $0}' "$tmpfile"
		rm -f "$tmpfile"

		echo "Total files that would be tranferred: $(printf "%'d" "$planned_files")"
		SUMMARY+=("Total files that would be transferred: $(printf "%'d" "$planned_files")")
		rm -f "$filelist"
		return 0
	fi

	# --- LIVE RUN ---
	mapfile -t RSYNC_ARGS < <(rsync_base_flags)
	RSYNC_ARGS+=(--files-from="$filelist" --stats --info=progress2)

	echo "[LIVE] rsync ${RSYNC_ARGS[*]} $repo/ $target_base/" >>"$LOG_FILE"
	echo "[INFO] Copying $(printf "%'d" "$planned_files") files to $target_base ..."
	if run_with_bar rsync "${RSYNC_ARGS[@]}" "$repo/" "$target_base/"; then
		echo
		banner "✔ Rsync completed" "$GREEN"
		SUMMARY+=("${GREEN}✔ Rsync completed: $planned_files files planned${NC}")
		COPIED_FILES="$planned_files"
		rm -f "$filelist"
		return 0
	else
		echo "✘ Rsync failed"
		SUMMARY+=("✘ Rsync failed")
		rm -f "$filelist"
		return 1
	fi
}

verify_all_refcnt() {
	local repo
	repo="$(get_repo_location)" || {
		echo "Verify aborted."
		return 1
	}

	local target_base="${NEW_LINE#export TGTSSDDIR=}"
	target_base="${target_base%/}"
	if [[ -z "$target_base" || "$target_base" == "export TGTSSDDIR=" ]]; then
		banner "Error: Target base (TGTSSDDIR) not set; aborting verify." "$RED"
		return 1
	fi

	shopt -s nullglob
	local verified=0
	local total_verified_files=0
	for d in "$repo"/*; do
		[[ -d "$d" ]] || continue
		local base="$(basename -- "$d")"
		[[ "$base" =~ ^[0-9]+$ ]] || continue

		local SRC="$d/$REFCNT_SUBPATH"
		local DST="$target_base/$base/$REFCNT_SUBPATH"

		if [ "$DRY_RUN" = "true" ]; then
			local out files
			# unsafe out="$(rsync -n --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1 || true)"
			out="$(safe_rsync -n --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1 || true)"
			files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
			: "${files:=0}"

			printf "[DRY RUN] Verify Directory %s: %'d files would be compared\n" "$base" "$files"
			SUMMARY+=("Would verify dir $base: $files files")
			total_verified_files=$((total_verified_files + files))
			((verified++))
			continue
		fi

		# --- LIVE RUN ---
		# Make sure the destination refcnt path exists (even if it's empty on source)
		mkdir -p "$DST"

		local out files rc
		set +e
		# unsafe out="$(rsync --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1)"
		out="$(safe_rsync --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1)"
		rc=$?
		set -e

		if [[ $rc -ne 0 ]]; then
			echo "Verification rsync reported errors for: $SRC -> $DST"
			echo "$out"
			SUMMARY+=("✘ Verify failed: $base")
			return 1
		fi

		files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
		: "${files:=0}"

		printf "Verify Directory %s: %'d files compared OK\n" "$base" "$files"
		SUMMARY+=("Directory $base: $files files verified")
		total_verified_files=$((total_verified_files + files))
		((verified++))
	done
	shopt -u nullglob

	echo
	if [ "$DRY_RUN" = "true" ]; then
		echo "Total files that would be compared: $(printf "%'d" "$total_verified_files")"
		SUMMARY+=("Total files that would be compared: $(printf "%'d" "$total_verified_files")")
	else
		echo "Total files verified: $(printf "%'d" "$total_verified_files")"
		SUMMARY+=("${GREEN}✔ Verify OK for $verified trees, $total_verified_files files${NC}")
	fi

	return 0
}

config_preview_live() {
	echo
	banner "=== LIVE CONFIG PREVIEW ===" "$GREEN"
	echo "Would insert after 'export TGTDIR':"
	echo "  $NEW_LINE"
	SUMMARY+=("${GREEN}✔ Would insert (live preview): $NEW_LINE${NC}")

	if grep -q "^$REFCNT_OLD" "$CONFIG_FILE"; then
		echo
		echo "Would also change:"
		echo "  $REFCNT_OLD"
		echo "  → $REFCNT_NEW"
		SUMMARY+=("${GREEN}✔ Would change (live preview): $REFCNT_OLD → $REFCNT_NEW${NC}")
	else
		banner "No PLATFORM_DS_REFCNTS_ON_SSD=0 line found, no change made there." "$RED"
		SUMMARY+=("${RED}✘ No PLATFORM_DS_REFCNTS_ON_SSD=0 found (live preview)${NC}")
	fi
}

dry_run_preview() {
	# ---- Diff helper (only changes, clean wrapping, colorized for console) ----
	show_diff() {
		local file1="$1" file2="$2"
		local width="${3:-160}"

		# Detect if stdout is a terminal → enable colors
		local RED="" GREEN="" CYAN="" RESET=""
		if [[ -t 1 ]]; then
			RED=$'\033[31m'
			GREEN=$'\033[32m'
			CYAN=$'\033[36m'
			RESET=$'\033[0m'
		fi

		echo "${CYAN}=== CONFIG DIFF ($file1 vs $file2) ===${RESET}"

		# Run diff safely (don’t abort if it returns 1)
		set +e
		local diff_out
		diff_out="$(diff -u "$file1" "$file2")"
		local diff_rc=$?
		set -e

		if [[ $diff_rc -eq 2 ]]; then
			echo "${RED}Error running diff${RESET}"
			return 1
		fi

		echo "$diff_out" |
			grep -E '^[+-]' |
			grep -Ev '^(\+\+\+|---)' |
			fold -w "$width" -s |
			while IFS= read -r line; do
				case "$line" in
				+*) echo "${GREEN}${line}${RESET}" ;;
				-*) echo "${RED}${line}${RESET}" ;;
				*) echo "$line" ;;
				esac
			done
		echo "${CYAN}=== END DIFF ===${RESET}"
	}

	local preview_line="$NEW_LINE"

	if [ "$DRY_RUN" = "true" ] && [ "$DRY_HAS_TARGET" != "true" ]; then
		# substitute placeholder if no mountpoint in dry-run
		preview_line="export TGTSSDDIR=<YOUR_MOUNTPOINT>/ssd/"
		echo
		banner "[DRY RUN] No target mount available — previewing config changes with placeholder:" "$YELLOW"
		echo "  $preview_line"
		SUMMARY+=("${GREEN}✔ Config preview with placeholder TGTSSDDIR (target not mounted)${NC}")
	fi

	echo
	banner "=== DRY-RUN CONFIG PREVIEW ===" "$YELLOW"
	echo "[DRY RUN] Would replace existing 'export TGTSSDDIR=...' if present,"
	echo "          otherwise insert after 'export TGTDIR' (or append if not found):"
	echo "  $preview_line"
	SUMMARY+=("${GREEN}✔ Would ensure single TGTSSDDIR: $preview_line${NC}")

	if grep -q "^$REFCNT_OLD" "$CONFIG_FILE"; then
		echo
		echo "[DRY RUN] Would also change:"
		echo "  $REFCNT_OLD"
		echo "  → $REFCNT_NEW"
		SUMMARY+=("${GREEN}✔ Would change: $REFCNT_OLD → $REFCNT_NEW${NC}")
	else
		if grep -q "^$REFCNT_NEW" "$CONFIG_FILE"; then
			banner "[DRY RUN] PLATFORM_DS_REFCNTS_ON_SSD already set to 1 — no change." "$GREEN"
			SUMMARY+=("${GREEN}✔ PLATFORM_DS_REFCNTS_ON_SSD already 1${NC}")
		else
			banner "[DRY RUN] No PLATFORM_DS_REFCNTS_ON_SSD line found — will add the new one." "$YELLOW"
			SUMMARY+=("${GREEN}✔ Will add: $REFCNT_NEW${NC}")
		fi
	fi

	echo
	echo "[DRY RUN] Preview of changes:"
	awk -v newline="$preview_line" -v old="$REFCNT_OLD" -v new="$REFCNT_NEW" '
		BEGIN {
			done_insert = 0
			changed_refcnt = 0
			replaced_tgtsddir = 0
			saw_refcnt_new = 0
		}
		# Keep track if new refcnt line already exists
		$0 == new {
			saw_refcnt_new = 1
			print
			next
		}
		# Replace first TGTSSDDIR occurrence; drop further duplicates
		/^export[[:space:]]+TGTSSDDIR=/ {
			if (!replaced_tgtsddir) {
				print newline
				replaced_tgtsddir = 1
			}
			next
		}
		# Insert after TGTDIR if not yet inserted and no replacement happened
		/^export[[:space:]]+TGTDIR/ && !done_insert && !replaced_tgtsddir {
			print
			print newline
			done_insert = 1
			next
		}
		# Replace old refcnt toggle if present
		$0 == old {
			print new
			changed_refcnt = 1
			next
		}
		{ print }
		END {
			# Fallbacks: append missing lines if anchors absent
			if (!done_insert && !replaced_tgtsddir) print newline
			if (!changed_refcnt && !saw_refcnt_new) print new
		}
	' "$CONFIG_FILE" >"${CONFIG_FILE}.dryrun.tmp"

	show_diff "$CONFIG_FILE" "${CONFIG_FILE}.dryrun.tmp" || true
	rm -f "${CONFIG_FILE}.dryrun.tmp"

	debug_log " Exiting dry_run_preview normally"
}

make_backup() {
	BACKUP_FILE="${BACKUP_DIR}/oca.cfg.refcount_script.bak_${TIMESTAMP}"
	cp -p "$CONFIG_FILE" "$BACKUP_FILE"

	banner "=== BACKUP CREATED ===" "$GREEN"
	echo "Backup created at: $BACKUP_FILE"
	banner "======================" "$GREEN"

	SUMMARY+=("${GREEN}✔ Backup created: $BACKUP_FILE${NC}")
	echo
}

apply_changes() {
	# ---- Diff helper (only changes, clean wrapping, colorized for console) ----
	show_diff() {
		local file1="$1" file2="$2"
		local width="${3:-160}"

		local RED="" GREEN="" CYAN="" RESET=""
		if [[ -t 1 ]]; then
			RED=$'\033[31m'
			GREEN=$'\033[32m'
			CYAN=$'\033[36m'
			RESET=$'\033[0m'
		fi

		echo "${CYAN}=== CONFIG DIFF ($file1 vs $file2) ===${RESET}"

		# Run diff safely (don’t abort if it returns 1)
		set +e
		local diff_out
		diff_out="$(diff -u "$file1" "$file2")"
		local diff_rc=$?
		set -e

		if [[ $diff_rc -eq 2 ]]; then
			echo "${RED}Error running diff${RESET}"
			return 1
		fi

		echo "$diff_out" |
			grep -E '^[+-]' |
			grep -Ev '^(\+\+\+|---)' |
			fold -w "$width" -s |
			while IFS= read -r line; do
				case "$line" in
				+*) echo "${GREEN}${line}${RESET}" ;;
				-*) echo "${RED}${line}${RESET}" ;;
				*) echo "$line" ;;
				esac
			done
		echo "${CYAN}=== END DIFF ===${RESET}"
	}

	# Build a temp file with proposed changes
	awk -v newline="$NEW_LINE" -v old="$REFCNT_OLD" -v new="$REFCNT_NEW" '
		BEGIN {
			done_insert = 0
			changed_refcnt = 0
			replaced_tgtsddir = 0
			saw_refcnt_new = 0
		}
		# Track if the "new" refcnt line already exists to avoid duplicates
		$0 == new {
			saw_refcnt_new = 1
			print
			next
		}
		# Replace the first existing TGTSSDDIR=... line; drop any subsequent duplicates
		/^export[[:space:]]+TGTSSDDIR=/ {
			if (!replaced_tgtsddir) {
				print newline
				replaced_tgtsddir = 1
			}
			next
		}
		# If TGTDIR line exists and we havent inserted yet (and we didnt replace TGTSSDDIR earlier),
		# insert newline immediately after it.
		/^export[[:space:]]+TGTDIR/ && !done_insert && !replaced_tgtsddir {
			print
			print newline
			done_insert = 1
			next
		}
		# Replace the old refcnt toggle with the new one
		$0 == old {
			print new
			changed_refcnt = 1
			next
		}
		{ print }
		END {
			# If no TGTDIR anchor and no existing TGTSSDDIR was replaced, append newline at end
			if (!done_insert && !replaced_tgtsddir) print newline
			# Ensure the new refcnt line exists exactly once
			if (!changed_refcnt && !saw_refcnt_new) print new
		}
	' "$CONFIG_FILE" >"${CONFIG_FILE}.tmp"

	# Compare old vs new before replacing
	if cmp -s "$CONFIG_FILE" "${CONFIG_FILE}.tmp"; then
		banner "✔ Config already up-to-date. No changes made."
		SUMMARY+=("${GREEN}✔ Config already up-to-date (no changes required)${NC}")
		rm -f "${CONFIG_FILE}.tmp"
		return 0
	fi

	# Replace config with updated version
	mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

	banner "✔ Config updated." "$GREEN"
	SUMMARY+=("${GREEN}✔ Config updated: $CONFIG_FILE${NC}")

	if grep -q "^$REFCNT_NEW" "$CONFIG_FILE"; then
		banner "✔ Updated: $REFCNT_OLD → $REFCNT_NEW" "$GREEN"
		SUMMARY+=("${GREEN}✔ Updated: $REFCNT_OLD → $REFCNT_NEW${NC}")
	fi

	echo
	echo "Changes made (compared to backup):"
	show_diff "$BACKUP_FILE" "$CONFIG_FILE" || true
}

print_summary() {
	echo
	banner "=== RUN SUMMARY ===" "$BLUE"

	# Mode detection
	if [ "$DRY_RUN" = "true" ]; then
		banner "✔ MODE: DRY-RUN" "$YELLOW"
	elif [ "$SCAN_ONLY" = "true" ]; then
		banner "✔ MODE: SCAN-ONLY" "$BLUE"
	else
		banner "✔ MODE: LIVE" "$GREEN"
	fi

	# Checksum verification status
	if [ "$VERIFY_CHECKSUM" = "true" ]; then
		banner "✔ Checksum verification enabled" "$GREEN"
		SUMMARY+=("${GREEN}✔ Checksum verification enabled${NC}")
	else
		banner "✘ Checksum verification not enabled" "$RED"
		SUMMARY+=("${RED}✘ Checksum verification not enabled${NC}")
	fi

	# Dry-run target availability (only relevant in dry-run)
	if [ "$DRY_RUN" = "true" ]; then
		if [ "$DRY_HAS_TARGET" = "true" ]; then
			banner "✔ Dry-run target available: true" "$GREEN"
			SUMMARY+=("${GREEN}✔ Dry-run target available: true${NC}")
		else
			banner "✘ Dry-run target available: false" "$RED"
			SUMMARY+=("${RED}✘ Dry-run target available: false${NC}")
		fi
	fi

	# Print accumulated summary lines
	for line in "${SUMMARY[@]}"; do
		echo "$line"
	done

	banner "Run complete. Log saved to: $LOG_FILE" "$GREEN"
}

confirm_live_run() {
	echo
	banner "=== RUN PREVIEW: LIVE RUN ===" "$GREEN"
	echo

	banner "✔ MODE: LIVE" "$GREEN"
	if [ "$VERIFY_CHECKSUM" = "true" ]; then
		banner "✔ Checksum verification enabled" "$GREEN"
	else
		banner "✘ Checksum verification not enabled" "$RED"
	fi

	if [[ -n "$MOUNTPOINT" ]]; then
		banner "✔ Using target mountpoint: $MOUNTPOINT/ssd/" "$GREEN"
	else
		banner "✘ No mountpoint defined (unexpected)" "$RED"
	fi
	echo

	scan_refcnt_sizes || true

	# Only show planned totals (don’t rescan)
	local planned_files
	planned_files="$(plan_copy_totals)"
	echo "Planned total files to copy: $(printf "%'d" "$planned_files")"
	SUMMARY+=("Planned total files to copy (preview): $(printf "%'d" "$planned_files")")

	# Show config changes
	config_preview_live
	SUMMARY+=("${GREEN}✔ LIVE run preview complete${NC}")
	echo

	read -rp "${RED}Proceed with LIVE run? Type 'yes' to continue, anything else will cancel: ${NC}" reply
	if [[ "$reply" == "yes" ]]; then
		banner "✔ Continuing with LIVE run..." "$GREEN"
	else
		echo "✘ Cancelled by user."
		SUMMARY=("${RED}✘ CANCELLED at confirmation step" "${SUMMARY[@]}${NC}")
		print_summary
		exit 0
	fi
}

# ---- Main ----
main() {
	parse_args "$@" # phase 1: detect flags, store args
	setup_logging
	detect_layout_once

	if [ "$SCAN_ONLY" = "true" ]; then
		echo
		banner "=== RUN PREVIEW: SCAN-ONLY MODE ===" "$BLUE"
		echo
		banner "✔ MODE: SCAN-ONLY" "$GREEN"

		if [ "$VERIFY_CHECKSUM" = "true" ]; then
			banner "✔ Checksum verification enabled" "$GREEN"
		else
			banner "✘ Checksum verification not enabled" "$RED"
		fi
		echo

		scan_refcnt_sizes || true
		print_summary
		exit 0
	fi

	if [ "$DRY_RUN" = "true" ]; then
		echo
		banner "=== RUN PREVIEW: DRY-RUN MODE ===" "$YELLOW"
		echo
		banner "✔ MODE: DRY-RUN" "$YELLOW"

		if [ "$VERIFY_CHECKSUM" = "true" ]; then
			banner "✔ Checksum verification enabled" "$GREEN"
		else
			banner "✘ Checksum verification not enabled" "$RED"
		fi

		decide_dryrun_target

		if [ "$DRY_HAS_TARGET" = "true" ]; then
			banner "✔ Dry-run target available" "$GREEN"
			echo "Mountpoint: $MOUNTPOINT"
		else
			banner "✘ Dry-run target not available (plan-only mode)" "$RED"
		fi
		echo

		verify_ready_to_stop
		wait_for_service_stop "ocards"

		set +e
		debug_log " About to run copy_all_refcnt"
		copy_all_refcnt || true
		debug_log " Finished copy_all_refcnt"
		verify_all_refcnt || true
		set -e

		dry_run_preview

		# Debug output
		debug_log " DRY_SKIP_SERVICES='$DRY_SKIP_SERVICES'"
		debug_log " DRY_HAS_TARGET='$DRY_HAS_TARGET'"
		# --- BEGIN DEBUG WALL ---
		debug_log " About to test DRY_SKIP_SERVICES in main"
		debug_printf " DRY_SKIP_SERVICES raw -> '%s'\n" "$DRY_SKIP_SERVICES"
		debug_printf " DRY_HAS_TARGET raw     -> '%s'\n" "$DRY_HAS_TARGET"
		debug_printf " MOUNTPOINT raw          -> '%s'\n" "$MOUNTPOINT"
		debug_printf " NEW_LINE raw            -> '%s'\n" "$NEW_LINE"
		debug_printf " Lengths: skip=%d, has=%d, mount=%d\n" "${#DRY_SKIP_SERVICES}" "${#DRY_HAS_TARGET}" "${#MOUNTPOINT}"

		case "$DRY_SKIP_SERVICES" in
		false) debug_log " case-match: DRY_SKIP_SERVICES is exactly 'false'" ;;
		true) debug_log " case-match: DRY_SKIP_SERVICES is exactly 'true'" ;;
		*)
			debug_log " case-match: DRY_SKIP_SERVICES is something else (possibly hidden chars)"
			od -An -tx1 <<<"$DRY_SKIP_SERVICES"
			;;
		esac

		set -o errtrace
		trap 'echo "[TRACE] ERR at ${BASH_SOURCE}:${LINENO}; last cmd: $BASH_COMMAND";' ERR
		# --- END DEBUG WALL ---

		if [ "${FORCE_TEST_START_SERVICES:-}" = "1" ]; then
			debug_log " FORCE_TEST_START_SERVICES=1 -> calling start_services() even if branch says skip"
			start_services
		fi

		if [ "$DRY_SKIP_SERVICES" = "false" ]; then
			debug_log " Entering start_services branch"
			echo
			banner "[DRY RUN] Simulating service restart ..." "$YELLOW"
			start_services
			banner "[DRY RUN] Service restart simulation complete." "$GREEN"
		else
			debug_log " Entering skip-services branch"
			banner "[DRY RUN] Skipping service restart (user chose no mountpoint)." "$YELLOW"
			SUMMARY+=("${GREEN}✔ DRY-RUN: scan-only, no service restart simulated${NC}")
		fi

		print_summary
		exit 0
	fi

	# --- LIVE RUN ---
	setup_mountpoint
	confirm_live_run

	if [[ ! -f "$CONFIG_FILE" ]]; then
		banner "Error: Config file $CONFIG_FILE not found!" "$RED"
		print_summary
		exit 1
	fi

	make_backup

	# --- New service stop/start workflow ---
	verify_ready_to_stop || {
		banner "Precheck failed, aborting before stop." "$RED"
		print_summary
		exit 1
	}
	wait_for_service_stop "ocards" || {
		banner "Stop failed, aborting." "$RED"
		print_summary
		exit 1
	}

	copy_all_refcnt || {
		banner "Copy step failed. Aborting before any config changes." "$RED"
		print_summary
		exit 1
	}

	if [ "$VERIFY_CHECKSUM" = "true" ]; then
		verify_all_refcnt || {
			banner "Verification failed. Aborting before any config changes." "$RED"
			print_summary
			exit 1
		}
	fi

	apply_changes

	start_services || {
		banner "Start failed; check logs for details." "$RED"
		print_summary
		exit 1
	}

	print_summary
}

main "$@"
