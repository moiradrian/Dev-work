#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/oca/oca_test.cfg"
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

# ---- Defaults ----
STOP_TIMEOUT=60       # seconds to wait for service to stop
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
    echo
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

get_repo_location() {
	if ! command -v system &>/dev/null; then
		echo "Error: 'system' command not found; cannot determine Repository location." >&2
		return 1
	fi
	local repo
	repo="$(system --show | awk -F': ' '/^Repository location/ {print $2}' | sed 's/[[:space:]]*$//')"
	if [[ -z "${repo:-}" ]]; then
		echo "Error: Could not parse Repository location from 'system --show'." >&2
		return 1
	fi
	if [[ ! -d "$repo" ]]; then
		echo "Error: Parsed Repository location '$repo' does not exist or is not a directory." >&2
		return 1
	fi
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
	local cmd=("$@")
	"${cmd[@]}" 2>&1 | while IFS= read -r line; do
		if [[ "$line" =~ ([0-9]+)% ]]; then
			local pct="${BASH_REMATCH[1]}"
			local bar_len=$((pct / 2)) # 50 chars = 100%
			local bar=$(printf "%0.s#" $(seq 1 $bar_len))
			printf "\r[%-50s] %3d%%" "$bar" "$pct"
		fi
	done
	echo
}

debug_log() {
	if [ "$DEBUG_MODE" = "true" ]; then
		echo "[DEBUG]$*"
	fi
}

debug_printf() {
    if [ "$DEBUG_MODE" = "true" ]; then
        # First arg is format string, rest are parameters
        local fmt="$1"
        shift
        printf "[DEBUG]$fmt\n" "$@"
    fi
}

# ---- Arg parsing (phase 1 only: detect flags, save args) ----
parse_args() {
	local args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		--scan-only)
			SCAN_ONLY="true"
			shift
			;;
		--checksum-verify)
			VERIFY_CHECKSUM="true"
			shift
			;;
		--test) # hidden option
			TEST_MODE="true"
			shift
			;;
		--debug) # hidden option
			DEBUG_MODE="true"
			shift
			;;
		-h | --help)
			usage
			exit 0
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
			read -rp "Enter the full mount path (e.g. /testmnt or /testmnt/subdir): " MOUNTPOINT
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
				echo "Created directory: ${MOUNTPOINT}/ssd"
			fi
		fi

		SUMMARY+=("✔ Using target SSD directory: ${MOUNTPOINT}/ssd/")
		break
	done
}

# ---- Logging ----
setup_logging() {
	mkdir -p "$LOG_DIR"
	LOG_FILE="${LOG_DIR}/oca_edit_${TIMESTAMP}.log"
	exec > >(stdbuf -oL -eL tee -a "$LOG_FILE") 2>&1

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
	banner "Verify checksum: $VERIFY_CHECKSUM" "$GREEN"

	if [ "$DRY_RUN" = "true" ]; then
		banner "✔ Dry-run target available: $DRY_HAS_TARGET" "$GREEN"
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
		SUMMARY+=("${GREEN}✔ DRY-RUN: would stop ${service} (precheck OK)$(NC)")
		return 0
	fi

	# In live mode, we just show info and continue
	SUMMARY+=("${GREEN}✔ Precheck before stopping ${service}: sys=$sys_state, svc=$svc_state, reason=$reason$(NC)")
	return 0
}

wait_for_service_stop() {
	local service="$1"
	local timeout="${2:-$STOP_TIMEOUT}"

	local spinner='-\|/'
	local i=0

	# Initial snapshot
	local sys_state svc_state
	sys_state=$(get_system_state 2>/dev/null || echo "unknown")
	svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

	if [ "$DRY_RUN" = "true" ]; then
		echo -e "${YELLOW}[DRY RUN] Stopping '${service}' … (simulated)${NC}"
		echo "System: ${sys_state} | Service: ${svc_state}"

		local end=$((SECONDS + 5)) # 5s spinner simulation
		while ((SECONDS < end)); do
			i=$(((i + 1) % 4))
			printf "\r%s System: %s | Service: %s" "${spinner:$i:1}" "$sys_state" "$svc_state"
			sleep 0.2
		done
		printf "\r\033[2K"
		echo
		echo -e "${YELLOW}Dry Run Information:${NC}"
		echo "• Would stop service: ${service}"
		echo "• Command to run    : systemctl stop ${service}"
		echo "• Wait strategy     : poll until 'System State=Stopped' and service inactive (timeout ${timeout}s)"
		SUMMARY+=("[DRY RUN] Would stop service: $service")
		return 0
	fi

	# --- LIVE RUN ---
	local start_ts
	start_ts=$(date +%s)

	echo
	echo -e "${YELLOW}Stopping '${service}' …${NC}"
	echo "System: ${sys_state} | Service: ${svc_state}"

	while true; do
		i=$(((i + 1) % 4))
		local spin="${spinner:$i:1}"

		# Refresh states
		sys_state=$(get_system_state 2>/dev/null || echo "unknown")
		svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

		printf "\033[2A"
		if [[ "${sys_state,,}" == "stopped" ]]; then
			printf "${GREEN}Stopping '%s' %s${NC}\033[0K\n" "$service" "$spin"
			printf "System: ${GREEN}%s${NC} | Service: %s\033[0K\n" "$sys_state" "$svc_state"
			sleep 1
			printf "\r\033[0K"
			log info "Stop complete: System State='${sys_state}', service='${service}', svc_state='${svc_state}'"
			return 0
		else
			printf "${YELLOW}Stopping '%s' %s${NC}\033[0K\n" "$service" "$spin"
			printf "System: %s | Service: %s\033[0K\n" "$sys_state" "$svc_state"
		fi

		if (($(date +%s) - start_ts >= timeout)); then
			printf "\r\033[2K"
			echo -e "${RED}Timeout waiting for system to reach 'Stopped' (>${timeout}s). Last: System='${sys_state}', Service='${svc_state}'${NC}"
			log error "Stop timeout: last System State='${sys_state}', svc_state='${svc_state}'"
			return 1
		fi

		sleep 0.2
	done
}

start_services() {
	debug_log " start_services() was called" | tee -a "$LOG_FILE"

	debug_log " Entering start_services(), DRY_RUN=$DRY_RUN, DRY_SKIP_SERVICES=$DRY_SKIP_SERVICES" | tee -a "$LOG_FILE"
	set +e

	local service="ocards"
	echo -e "\n${GREEN}Starting QoreStor services (${service})${NC}"

	local reason svc_state
	reason=$(get_system_reason 2>/dev/null || echo "unknown")
	svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

	if [ "$DRY_RUN" = "true" ]; then
		echo -e "${YELLOW}[DRY RUN] Starting '${service}' … (simulated)${NC}"
		echo "Reason : ${reason}"
		echo "Service: ${svc_state}"

		# Spinner simulation for ~5s
		local spinner='-\|/'
		local i=0
		local end=$((SECONDS + 5))
		while ((SECONDS < end)); do
			i=$(((i + 1) % 4))
			printf "\r%s Reason: %s | Service: %s" "${spinner:$i:1}" "$reason" "$svc_state"
			sleep 0.2
		done
		printf "\r\033[2K"

		echo
		echo -e "${YELLOW}Dry Run Information:${NC}"
		echo "• Would start service: ${service}"
		echo "• Command to run    : systemctl start ${service}"
		echo "• Wait strategy     : poll until 'Reason=Filesystem is fully operational for I/O.' and service active (timeout ${START_TIMEOUT}s)"

		echo -e "${GREEN}✔ Dry-run start simulation complete.${NC}"
		SUMMARY+=("✔ DRY-RUN: would start ${service} (simulated)")
		return 0
	fi

	# --- LIVE RUN ---
	if [[ "$svc_state" != "active" ]]; then
		systemctl start "$service" || echo "${YELLOW}systemctl start returned non-zero, continuing wait...${NC}"
	fi

	local spinner='-\|/'
	local i=0
	local start_ts=$(date +%s)

	while true; do
		i=$(((i + 1) % 4))
		reason=$(get_system_reason 2>/dev/null || echo "unknown")
		svc_state=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")

		printf "\r${YELLOW}Starting '%s' %s${NC} | Reason: %s | Service: %s" \
			"$service" "${spinner:$i:1}" "$reason" "$svc_state"

		if [[ "$reason" == "Filesystem is fully operational for I/O." && "$svc_state" == "active" ]]; then
			printf "\n${GREEN}System is operational. Startup sequence complete.${NC}\n"
			SUMMARY+=("✔ Service started and operational: $service")
			return 0
		fi

		if (($(date +%s) - start_ts >= START_TIMEOUT)); then
			echo -e "\n${RED}Timeout waiting for system startup readiness.${NC}"
			SUMMARY+=("✘ Start timeout for $service")
			return 1
		fi

		sleep "$START_POLL_INTERVAL"
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
		local refdir="$d/.ocarina_hidden/refcnt"
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
	echo "Looking for integer dirs with '.ocarina_hidden/refcnt'"
	echo

	local -i found=0
	local total_bytes=0

	shopt -s nullglob
	for d in "$repo"/*; do
		[[ -d "$d" ]] || continue
		local base
		base="$(basename -- "$d")"
		[[ "$base" =~ ^[0-9]+$ ]] || continue
		((found++))

		local refdir="$d/.ocarina_hidden/refcnt"
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
		echo "No integer-named directories with refcnt found under $repo."
		SUMMARY+=("✘ Scan: 0 integer dirs found under $repo")
		return 0
	fi

	echo
	local grand_human
	grand_human=$(human_bytes "$total_bytes")
	echo "Total Refcount Size: $grand_human"
	echo

	SUMMARY+=("✔ Scan: $found integer dirs under $repo")
	SUMMARY+=("✔ Total Refcount Size: $grand_human")

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
	printf '%s\n' -aHAX --numeric-ids --sparse -W --human-readable
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
	IFS=$'\n' read -r -d '' -a RSYNC_ARGS < <(rsync_base_flags && printf '\0')
	RSYNC_ARGS+=(--stats --info=progress2)

	if [ "$DRY_RUN" = "true" ]; then
		RSYNC_ARGS+=(-n)
		echo "[DRY RUN] rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

		local out files
		out="$(safe_rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1 || true)"
		files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
		: "${files:=0}"

		printf "Directory %s: %'d files would be copied\n" "$base" "$files"
		SUMMARY+=("Directory $base: $files files would be copied")

		DRY_COPY_FILES=$((DRY_COPY_FILES + files))
		COPIED_FILES=$((COPIED_FILES + files))
		return 0
	fi

	# --- LIVE RUN ---
	echo "[LIVE] rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

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

		out="$(rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1 || true)"
		files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
		: "${files:=0}"

		printf "[DRY RUN] Verify %s: %'d files would be compared\n" "$SRC" "$files"
		SUMMARY+=("Would verify $SRC: $files files")
		return 0
	fi

	# --- LIVE RUN ---
	echo "[LIVE] verify rsync ${RSYNC_ARGS[*]} \"$SRC/\" \"$DST/\"" >>"$LOG_FILE"

	set +e
	out="$(rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DST/" 2>&1)"
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
		echo "✔ Verified OK (checksum): $SRC -> $DST"
		SUMMARY+=("✔ Verified OK (checksum): $SRC -> $DST")
	else
		echo "✔ Verified OK (size/time): $SRC -> $DST"
		SUMMARY+=("✔ Verified OK (size/time): $SRC -> $DST")
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

	# --- DRY-RUN without target: plan-only mode ---
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

	# Size planning & space check
	local need="${SCAN_TOTAL_BYTES:-0}"
	echo "Planned copy target base: $target_base"

	# Space check should use the mountpoint, not the /ssd subdir
	local base_mount="${MOUNTPOINT:-$target_base}"
	check_free_space "$base_mount" "$need" || return 1
	echo

	# Build list of all refcount files (relative to $repo)
	local filelist
	filelist="$(mktemp)"
	(cd "$repo" && find . -type f -path "*/.ocarina_hidden/refcnt/*") >"$filelist"

	# Rsync args
	local -a RSYNC_ARGS
	IFS=$'\n' read -r -d '' -a RSYNC_ARGS < <(rsync_base_flags && printf '\0')
	RSYNC_ARGS+=(--files-from="$filelist" --stats --info=progress2)

	if [ "$DRY_RUN" = "true" ]; then
		RSYNC_ARGS+=(-n)
		echo "[DRY RUN] rsync ${RSYNC_ARGS[*]} $repo/ $target_base/" >>"$LOG_FILE"
		rsync "${RSYNC_ARGS[@]}" "$repo/" "$target_base/" | grep -E 'Number of regular files transferred'
		echo "Total files that would be copied: $(printf "%'d" "$planned_files")"
		SUMMARY+=("Total files that would be copied: $(printf "%'d" "$planned_files")")
		rm -f "$filelist"
		return 0
	fi

	# --- LIVE RUN ---
	echo "[LIVE] rsync ${RSYNC_ARGS[*]} $repo/ $target_base/" >>"$LOG_FILE"

	if rsync "${RSYNC_ARGS[@]}" "$repo/" "$target_base/"; then
		echo
		echo "✔ Rsync completed"
		SUMMARY+=("✔ Rsync completed: $planned_files files planned")
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
		echo "Error: Target base (TGTSSDDIR) not set; aborting verify."
		return 1
	fi

	shopt -s nullglob
	local verified=0
	local total_verified_files=0
	for d in "$repo"/*; do
		[[ -d "$d" ]] || continue
		local base="$(basename -- "$d")"
		[[ "$base" =~ ^[0-9]+$ ]] || continue

		local SRC="$d/.ocarina_hidden/refcnt"
		local DST="$target_base/$base/.ocarina_hidden/refcnt"

		if [ "$DRY_RUN" = "true" ]; then
			local out files
			out="$(rsync -n --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1 || true)"
			files="$(echo "$out" | awk -F': ' '/Number of regular files transferred/ {gsub(/[^0-9]/,"",$2); print $2+0}')"
			: "${files:=0}"

			printf "[DRY RUN] Verify Directory %s: %'d files would be compared\n" "$base" "$files"
			SUMMARY+=("Would verify dir $base: $files files")
			total_verified_files=$((total_verified_files + files))
			((verified++))
			continue
		fi

		# --- LIVE RUN ---
		local out files rc
		set +e
		out="$(rsync --stats $(rsync_verify_flags) "$SRC/" "$DST/" 2>&1)"
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
		SUMMARY+=("✔ Verify OK for $verified trees, $total_verified_files files")
	fi

	return 0
}

config_preview_live() {
	echo
	banner "=== LIVE CONFIG PREVIEW ===" "$GREEN"
	echo "Would insert after 'export TGTDIR':"
	echo "  $NEW_LINE"
	SUMMARY+=("✔ Would insert (live preview): $NEW_LINE")

	if grep -q "^$REFCNT_OLD" "$CONFIG_FILE"; then
		echo
		echo "Would also change:"
		echo "  $REFCNT_OLD"
		echo "  → $REFCNT_NEW"
		SUMMARY+=("✔ Would change (live preview): $REFCNT_OLD → $REFCNT_NEW")
	else
		echo "No PLATFORM_DS_REFCNTS_ON_SSD=0 line found, no change made there."
		SUMMARY+=("✘ No PLATFORM_DS_REFCNTS_ON_SSD=0 found (live preview)")
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
		echo "[DRY RUN] No target mount available — previewing config changes with placeholder:"
		echo "  $preview_line"
		SUMMARY+=("✔ Config preview with placeholder TGTSSDDIR (target not mounted)")
	fi

	echo
	banner "=== DRY-RUN CONFIG PREVIEW ===" "$YELLOW"
	echo "[DRY RUN] Would insert after 'export TGTDIR':"
	echo "  $preview_line"
	SUMMARY+=("✔ Would insert: $preview_line")

	if grep -q "^$REFCNT_OLD" "$CONFIG_FILE"; then
		echo
		echo "[DRY RUN] Would also change:"
		echo "  $REFCNT_OLD"
		echo "  → $REFCNT_NEW"
		SUMMARY+=("✔ Would change: $REFCNT_OLD → $REFCNT_NEW")
	else
		echo "[DRY RUN] No PLATFORM_DS_REFCNTS_ON_SSD=0 line found, no change made there."
		SUMMARY+=("✘ No PLATFORM_DS_REFCNTS_ON_SSD=0 found")
	fi

	echo
	echo "[DRY RUN] Preview of changes:"
	awk -v newline="$preview_line" -v old="$REFCNT_OLD" -v new="$REFCNT_NEW" '
        BEGIN { done_insert=0 }
        /^export TGTDIR/ && !done_insert {
            print
            print newline
            done_insert=1
            next
        }
        $0 == old { print new; next }
        { print }
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

	SUMMARY+=("${GREEN} ✔ Backup created: $BACKUP_FILE$(NC)")
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
        BEGIN { done_insert=0; changed_refcnt=0 }
        /^export TGTDIR/ && !done_insert {
            print
            print newline
            done_insert=1
            next
        }
        $0 == old {
            print new
            changed_refcnt=1
            next
        }
        { print }
        END {
            if (!done_insert) print newline
            if (!changed_refcnt) print new
        }
    ' "$CONFIG_FILE" >"${CONFIG_FILE}.tmp"

	# Compare old vs new before replacing
	if cmp -s "$CONFIG_FILE" "${CONFIG_FILE}.tmp"; then
		echo "✔ Config already up-to-date. No changes made."
		SUMMARY+=("✔ Config already up-to-date (no changes required)")
		rm -f "${CONFIG_FILE}.tmp"
		return 0
	fi

	# Replace config with updated version
	mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

	echo "✔ Config updated."
	SUMMARY+=("✔ Config updated: $CONFIG_FILE")

	if grep -q "^$REFCNT_NEW" "$CONFIG_FILE"; then
		echo "✔ Updated: $REFCNT_OLD → $REFCNT_NEW"
		SUMMARY+=("✔ Updated: $REFCNT_OLD → $REFCNT_NEW")
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
		echo "✔ MODE: DRY-RUN"
	elif [ "$SCAN_ONLY" = "true" ]; then
		echo "✔ MODE: SCAN-ONLY"
	else
		echo "✔ MODE: LIVE"
	fi

	# Checksum verification status
	if [ "$VERIFY_CHECKSUM" = "true" ]; then
		echo "✔ Checksum verification enabled"
		SUMMARY+=("✔ Checksum verification enabled")
	else
		echo "✘ Checksum verification not enabled"
		SUMMARY+=("✘ Checksum verification not enabled")
	fi

	# Dry-run target availability (only relevant in dry-run)
	if [ "$DRY_RUN" = "true" ]; then
		if [ "$DRY_HAS_TARGET" = "true" ]; then
			echo "✔ Dry-run target available: true"
			SUMMARY+=("✔ Dry-run target available: true")
		else
			echo "✘ Dry-run target available: false"
			SUMMARY+=("✘ Dry-run target available: false")
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
		echo "✔ Continuing with LIVE run..."
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
