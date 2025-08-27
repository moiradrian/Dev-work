#!/usr/bin/env bash
# File: grow_xfs_in_guest.sh
# Adds: pre-copy safety when target mount is on a partition.
# - Copies metadata dir to a safe "main storage" mount if there is space.
# - If not enough space, prompts to continue unsafely or exit (or use --unsafe-continue).
# - Then does non-destructive grow with growpart/parted, LVM ops if needed, and xfs_growfs.

set -euo pipefail

# ------------------ Globals / Defaults ------------------
MNT="${MNT:-}"
BASE_PATH="${BASE_PATH:-}"
METADATA_CMD="${METADATA_CMD:-system --show}"

DRY_RUN="false"
ASSUME_YES="false"
NO_INSTALL="false"
REPORT_ONLY="false"
LOGDIR="${LOGDIR:-/var/log}"
PKG_MGR=""
LOGFILE=""

# === PRE-COPY toggles/params ===
PRECOPY="auto"                  # auto|always|never
MAIN_STORE=""                   # mount or path where the backup copy will live
UNSAFE_CONTINUE="false"
CLEANUP_PRECOPY="false"
QUIESCE_CMD=""
UNQUIESCE_CMD=""
PRECOPY_DIR=""

# Colors
GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"

# ---------- Helpers (wrapping & pretty help) ----------
get_term_width(){ local w="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"; [[ "$w" =~ ^[0-9]+$ ]] || w=80; echo "$w"; }
wrap_text(){ local t="$1" i="${2:-0}" w bw; w=$(get_term_width); bw=$((w - i)); ((bw<30))&&bw=30; echo -e "$t"|fold -s -w "$bw"|sed "2,999s/^/$(printf '%*s' "$i")/"; }
color_wrap_text(){ wrap_text "$1" "${2:-0}"; }
print_opt(){ local opt="$1" desc="$2"; printf "  %-20b " "$opt"; color_wrap_text "$desc" 22; }
cmdline(){ local out; printf -v out '%q ' "$@"; echo "${out% }"; }

show_help() {
  echo -e "${GREEN}Usage:${NC} $0 [options]\n"
  echo -e "${GREEN}Options:${NC}"
  print_opt "-m, --mount <path>"           "Mountpoint to grow (if omitted, discovered from app metadata)."
  print_opt "    --metadata-cmd <cmd>"     "Command printing a line 'Metadata: /path' (default: 'system --show')."
  print_opt "-y, --yes"                    "Auto-approve package installs."
  print_opt "-n, --dry-run"                "Simulate actions; no changes."
  print_opt "    --no-install"             "Do not install missing packages."
  print_opt "    --report-only"            "Discovery only; no changes."
  print_opt "    --logdir <dir>"           "Log directory (default: ${LOGDIR})."
  echo
  echo -e "${GREEN}Pre-copy safety (when backing device is a partition):${NC}"
  print_opt "    --precopy auto|always|never" "Control pre-copy behavior (default: auto = only when mount device TYPE=part)."
  print_opt "    --main-store <path>"       "Target directory or mount to hold the backup copy."
  print_opt "    --unsafe-continue"         "If not enough space for backup, proceed without pre-copy (no prompt)."
  print_opt "    --cleanup-precopy"         "Remove the backup copy after a successful grow."
  print_opt "    --quiesce <cmd>"           "Run command before copying (e.g., stop app)."
  print_opt "    --unquiesce <cmd>"         "Run command after copying (e.g., start app)."
  echo
  echo -e "${GREEN}Examples:${NC}"
  echo "  $0 --report-only"
  echo "  $0 --yes --precopy auto"
  echo "  $0 --mount /data --main-store /var/backups --quiesce 'systemctl stop app' --unquiesce 'systemctl start app'"
  exit 0
}

# ---------- Core plumbing ----------
die(){ echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
log(){ echo "[+] $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*" >&2; }
need_root(){ [[ "$EUID" -eq 0 ]] || die "Please run as root."; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

run(){ if [[ "$DRY_RUN" == "true" ]]; then echo "DRY-RUN: $*" | tee -a "$LOGFILE"; else bash -c "$*" 2>&1 | tee -a "$LOGFILE"; fi; }
try(){ echo "TRY: $*" | tee -a "$LOGFILE"; bash -c "$*" 2>&1 | tee -a "$LOGFILE" || true; }
ask_yes_no(){ local p="$1"; [[ "$ASSUME_YES" == "true" ]] && { echo yes; return; }; read -r -p "$p [Y/n]: " a || true; a="${a:-Y}"; case "$a" in Y|y|yes|YES) echo yes;;*) echo no;; esac; }

# ---------- Args ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--mount)       MNT="$2"; shift 2 ;;
      --metadata-cmd)   METADATA_CMD="$2"; shift 2 ;;
      -y|--yes)         ASSUME_YES="true"; shift ;;
      -n|--dry-run)     DRY_RUN="true"; shift ;;
      --no-install)     NO_INSTALL="true"; shift ;;
      --report-only)    REPORT_ONLY="true"; shift ;;
      --logdir)         LOGDIR="$2"; shift 2 ;;
      # PRE-COPY:
      --precopy)        PRECOPY="$2"; shift 2 ;;
      --main-store)     MAIN_STORE="$2"; shift 2 ;;
      --unsafe-continue)UNSAFE_CONTINUE="true"; shift ;;
      --cleanup-precopy)CLEANUP_PRECOPY="true"; shift ;;
      --quiesce)        QUIESCE_CMD="$2"; shift 2 ;;
      --unquiesce)      UNQUIESCE_CMD="$2"; shift 2 ;;
      -h|--help)        show_help ;;
      *) warn "Unknown arg: $1"; echo; show_help ;;
    esac
  done
}

# ---------- App-aware discovery ----------
get_metadata_path() {
  local out=""
  [[ "$METADATA_CMD" == "system --show" && ! $(have_cmd system; echo $?) -eq 0 ]] && return 1
  out=$(eval ${METADATA_CMD} 2>/dev/null | grep -m1 'Metadata' | cut -d':' -f2- | xargs || true)
  [[ -n "$out" ]] || return 1
  echo "$out"
}
discover_target_from_metadata() {
  [[ -z "$BASE_PATH" ]] && BASE_PATH=$(get_metadata_path || true)
  [[ -z "$BASE_PATH" ]] && die "Could not determine metadata location via '${METADATA_CMD}'. Provide --mount."
  echo -e "\nMetadata location: ${BASE_PATH}" | tee -a "$LOGFILE"
  if [[ -z "$MNT" ]]; then
    MNT=$(findmnt -n -o TARGET --target "$BASE_PATH" 2>/dev/null || true)
    if [[ -z "$MNT" ]]; then
      local FIRST_LEVEL="/$(echo "$BASE_PATH" | cut -d'/' -f2)"
      if [[ -n "$FIRST_LEVEL" ]] && mountpoint -q "$FIRST_LEVEL"; then MNT="$FIRST_LEVEL"; fi
    fi
    [[ -z "$MNT" ]] && MNT=$(df -P "$BASE_PATH" 2>/dev/null | awk 'NR==2{print $6}')
    [[ -n "$MNT" ]] || die "Unable to map metadata path '$BASE_PATH' to a mountpoint. Provide --mount."
  fi
  echo "Target mountpoint: ${MNT}" | tee -a "$LOGFILE"
}

# ---------- Discovery / Reporting ----------
section(){ echo; echo "==== $* ====" | tee -a "$LOGFILE"; }
kv(){ printf "%-22s : %s\n" "$1" "$2" | tee -a "$LOGFILE"; }
parent_disk_of(){ lsblk -no PKNAME "$1" 2>/dev/null | awk '{print "/dev/"$1}'; }

collect_os_info(){ section "System"; kv Timestamp "$(date -Iseconds)"; kv Hostname "$(hostname -f 2>/dev/null || hostname)"; kv Kernel "$(uname -r)"; if [[ -r /etc/os-release ]]; then . /etc/os-release; kv OS "${PRETTY_NAME:-$NAME}"; else kv OS unknown; fi; kv Virtualization "$(systemd-detect-virt 2>/dev/null || echo unknown)"; }
get_metadata_usage(){
  echo -e "\n${GREEN}Checking Metadata Partition Usage${NC}"
  local mntc PART_USAGE; mntc=$(findmnt -n -o TARGET --target "$BASE_PATH" 2>/dev/null || echo ""); [[ -z "$mntc" ]] && mntc="/$(echo "$BASE_PATH" | cut -d'/' -f2)"
  PART_USAGE=$(df -h | awk -v mnt="$mntc" '$NF==mnt {print}'); [[ -z "$PART_USAGE" ]] && PART_USAGE=$(df -h "$BASE_PATH" 2>/dev/null | tail -1)
  [[ -z "$PART_USAGE" ]] && { echo -e "${RED}Error: Unable to determine usage for: ${BASE_PATH}${NC}"; echo "DEBUG: df empty" | tee -a "$LOGFILE"; return 1; }
  local OLDIFS="$IFS"; IFS=$' \t'; read -r DEVICE SIZE USED AVAIL USEP MOUNTED <<<"$PART_USAGE"; IFS="$OLDIFS"
  echo "Device: $DEVICE"; echo "Metadata Partition Usage:"; printf "%-8s %-8s %-8s %-6s\n" "Size" "Used" "Avail" "Use%"; printf "%-8s %-8s %-8s %-6s\n" "$SIZE" "$USED" "$AVAIL" "$USEP"; echo "Mount: $MOUNTED"; echo | tee -a "$LOGFILE"
}
collect_mount_fs_info(){ section "Target"; kv "Metadata path" "$BASE_PATH"; kv "Mountpoint" "$(findmnt -n -o TARGET --target "$MNT" 2>/dev/null || echo "$MNT")"; kv "Source" "$(findmnt -n -o SOURCE --target "$MNT")"; kv "Fstype" "$(findmnt -n -o FSTYPE --target "$MNT")"; kv "Options" "$(findmnt -n -o OPTIONS --target "$MNT")"; echo; df -h "$MNT" 2>/dev/null | tee -a "$LOGFILE" || true; if have_cmd xfs_info; then echo; echo "-- xfs_info $MNT --" | tee -a "$LOGFILE"; xfs_info "$MNT" 2>&1 | tee -a "$LOGFILE" || true; fi; get_metadata_usage || true; }
collect_block_graph(){ section "Block Devices (lsblk)"; lsblk -e7 -o NAME,TYPE,SIZE,ROTA,FSTYPE,MOUNTPOINT,PKNAME,MODEL,SERIAL,TRAN -p | tee -a "$LOGFILE"; }
collect_partition_tables_for_chain(){ local src parent; src=$(findmnt -n -o SOURCE --target "$MNT"); parent="$(parent_disk_of "$src")"; [[ -z "$parent" ]] && return 0; section "Partition Table"; echo "Primary disk for $src: $parent" | tee -a "$LOGFILE"; if have_cmd parted; then echo; echo "-- parted -s $parent unit s print --" | tee -a "$LOGFILE"; parted -s "$parent" unit s print 2>&1 | tee -a "$LOGFILE" || true; elif have_cmd fdisk; then echo; echo "-- fdisk -l $parent --" | tee -a "$LOGFILE"; fdisk -l "$parent" 2>&1 | tee -a "$LOGFILE" || true; fi; }
collect_lvm_info_if_any(){ local src=$(findmnt -n -o SOURCE --target "$MNT" || true); [[ "$src" =~ ^/dev/mapper/ || "$src" =~ ^/dev/dm- ]] || return 0; section "LVM Topology"; have_cmd pvs && { echo "-- pvs (pe_start) --" | tee -a "$LOGFILE"; pvs -o pv_name,vg_name,pv_size,pv_free,pe_start --units m --separator '  ' --noheadings | sed 's/^ *//' | tee -a "$LOGFILE"; }; have_cmd vgs && { echo; echo "-- vgs --" | tee -a "$LOGFILE"; vgs -o vg_name,vg_size,vg_free,pv_count,lv_count --units m | tee -a "$LOGFILE"; }; have_cmd lvs && { echo; echo "-- lvs --" | tee -a "$LOGFILE"; lvs -o lv_name,vg_name,lv_size,lv_path,lv_attr --units m | tee -a "$LOGFILE"; }; }

discovery_report(){ section "Discovery Report (START)"; collect_os_info; collect_mount_fs_info; collect_block_graph; collect_partition_tables_for_chain; collect_lvm_info_if_any; section "Discovery Report (END)"; }

# ---------- Dependencies ----------
detect_pkg_mgr(){ if have_cmd apt-get; then PKG_MGR=apt; elif have_cmd dnf; then PKG_MGR=dnf; elif have_cmd yum; then PKG_MGR=yum; elif have_cmd zypper; then PKG_MGR=zypper; elif have_cmd apk; then PKG_MGR=apk; else PKG_MGR=""; fi; }
compute_package_list(){ case "$PKG_MGR" in apt) PKGS_ALWAYS=(xfsprogs cloud-guest-utils parted util-linux); PKGS_LVM=(lvm2) ;; dnf|yum) PKGS_ALWAYS=(xfsprogs cloud-utils-growpart parted util-linux); PKGS_LVM=(lvm2) ;; zypper|apk) PKGS_ALWAYS=(xfsprogs cloud-utils-growpart parted util-linux); PKGS_LVM=(lvm2) ;; *) PKGS_ALWAYS=(); PKGS_LVM=() ;; esac; }
install_pkgs(){ local pkgs=("$@"); [[ ${#pkgs[@]} -eq 0 ]] && return 0; case "$PKG_MGR" in apt) run "DEBIAN_FRONTEND=noninteractive apt-get update -y"; run "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs[*]}";; dnf) run "dnf install -y ${pkgs[*]}";; yum) run "yum install -y ${pkgs[*]}";; zypper) run "zypper --non-interactive refresh"; run "zypper --non-interactive install --auto-agree-with-licenses ${pkgs[*]}";; apk) run "apk update"; run "apk add ${pkgs[*]}";; *) die "No supported package manager to install: ${pkgs[*]}";; esac; }
ensure_requirements(){
  detect_pkg_mgr; compute_package_list
  have_cmd findmnt || die "findmnt required (util-linux)."
  have_cmd lsblk   || die "lsblk required (util-linux)."
  local fstype src is_lvm="false"
  fstype=$(findmnt -n -o FSTYPE --target "$MNT" || true)
  [[ "$fstype" == "xfs" ]] || die "Mountpoint $MNT is not XFS (found: ${fstype:-unknown})."
  src=$(findmnt -n -o SOURCE --target "$MNT") || die "Cannot determine block device for $MNT"
  [[ "$src" =~ ^/dev/mapper/ || "$src" =~ ^/dev/dm- ]] && is_lvm="true"
  local missing=()
  have_cmd xfs_growfs || missing+=("xfs_growfs")
  if have_cmd growpart || have_cmd parted; then :; else missing+=("growpart/parted"); fi
  if [[ "$is_lvm" == "true" ]]; then
    have_cmd pvresize || missing+=("pvresize"); have_cmd lvextend || missing+=("lvextend")
    have_cmd lvs || missing+=("lvs"); have_cmd pvs || missing+=("pvs"); have_cmd vgs || missing+=("vgs")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    [[ "$NO_INSTALL" == "true" ]] && die "Missing: ${missing[*]} and --no-install specified."
    [[ -z "$PKG_MGR" ]] && die "Missing: ${missing[*]} but no supported package manager found."
    warn "Missing commands: ${missing[*]}"
    local to_install=("${PKGS_ALWAYS[@]}"); [[ "$is_lvm" == "true" ]] && to_install+=("${PKGS_LVM[@]}")
    if [[ "$(ask_yes_no "Install required packages via $PKG_MGR: ${to_install[*]}?")" == "yes" ]]; then install_pkgs "${to_install[@]}"; else die "User declined to install missing packages."; fi
  fi
}

# ---------- PRE-COPY: choose main storage & copy ----------
bytes_du(){ du -sb "$1" 2>/dev/null | awk '{print $1}'; }
bytes_df_avail(){ df -B1 -P "$1" | awk 'NR==2{print $4}'; }
mount_of(){ findmnt -n -o TARGET --target "$1"; }

is_partition_device(){ local dev="$1"; [[ "$(lsblk -no TYPE "$dev")" == "part" ]]; }

pick_main_store(){
  # If user supplied, return that; else pick largest-available non-pseudo FS not equal to $MNT.
  if [[ -n "$MAIN_STORE" ]]; then echo "$MAIN_STORE"; return 0; fi
  # Prefer GNU findmnt if it can give bytes:
  if have_cmd findmnt; then
    # TARGET,FSTYPE,AVAIL; filter pseudo FS and current mount
    findmnt -rn -o TARGET,FSTYPE,AVAIL | awk -v tgt="$MNT" '
      $1!=tgt && $2 !~ /^(tmpfs|devtmpfs|proc|sysfs|cgroup|mqueue|overlay|squashfs|debugfs|tracefs|pstore|autofs|ramfs|zfs|bpf|fuse)/ {
        print $0
      }' | awk '
      function suffix(v){ # normalize AVAIL like 12G/345M/… if units present
        if (v ~ /[A-Za-z]$/) {
          u=substr(v,length(v),1); gsub(/[A-Za-z]/,"",v);
          if (u=="K") v*=1024; else if (u=="M") v*=1024^2; else if (u=="G") v*=1024^3; else if (u=="T") v*=1024^4;
        }
        return v
      }
      {bytes=suffix($3); if (bytes>max){max=bytes; pick=$1}}
      END{if(pick!="") print pick}'
  else
    # Fallback to df -PT (Type column present)
    df -B1 -PT | awk -v tgt="$MNT" 'NR>1 && $7!=tgt && $2 !~ /^(tmpfs|devtmpfs|proc|sysfs|cgroup|mqueue|overlay|squashfs|debugfs|tracefs|pstore|autofs|ramfs|zfs|bpf|fuse)/ {print $7,$4}' |
      sort -k2,2n | tail -1 | awk '{print $1}'
  fi
}

ensure_precopy_if_needed(){
  # Only trigger when: PRECOPY=always, or PRECOPY=auto AND backing device TYPE=part
  local src devtype
  src=$(findmnt -n -o SOURCE --target "$MNT")
  devtype=$(lsblk -no TYPE "$src" 2>/dev/null || echo "")
  if [[ "$PRECOPY" == "never" ]]; then
    log "Pre-copy disabled (--precopy=never)."
    return 0
  fi
  if [[ "$PRECOPY" == "auto" && "$devtype" != "part" ]]; then
    log "Pre-copy not required (backing device type: ${devtype:-unknown})."
    return 0
  fi

  section "Pre-copy Safety"
  kv "Reason" "Backing device is a partition; preparing backup copy before resize."
  kv "Metadata path" "$BASE_PATH"

  local src_mount dst_mount need_bytes avail_bytes
  src_mount=$(mount_of "$BASE_PATH")
  need_bytes=$(bytes_du "$BASE_PATH"); [[ -z "$need_bytes" || "$need_bytes" -eq 0 ]] && need_bytes=1

  dst_mount=$(pick_main_store)
  [[ -z "$dst_mount" ]] && die "Could not determine a main storage mount. Specify --main-store <path>."
  kv "Chosen main storage" "$dst_mount"

  avail_bytes=$(bytes_df_avail "$dst_mount")
  local headroom=$(( (need_bytes*11)/10 ))   # +10% headroom
  kv "Needed (with headroom)" "$headroom bytes"
  kv "Available" "$avail_bytes bytes"

  if (( avail_bytes < headroom )); then
    warn "Not enough space to pre-copy."
    if [[ "$UNSAFE_CONTINUE" == "true" ]]; then
      warn "Proceeding UNSAFELY without backup due to --unsafe-continue."
      return 0
    fi
    if [[ "$(ask_yes_no "Proceed UNSAFELY without backup?")" == "yes" ]]; then
      warn "User accepted UNSAFE continue."
      return 0
    else
      die "Aborting; insufficient space for safe pre-copy."
    fi
  fi

  # Optional quiesce
  if [[ -n "$QUIESCE_CMD" ]]; then
    log "Quiescing: $(cmdline $QUIESCE_CMD)"
    run "$QUIESCE_CMD" || warn "Quiesce command returned non-zero."
  fi

  # Make a destination directory
  local ts; ts="$(date +%Y%m%dT%H%M%S)"
  PRECOPY_DIR="${dst_mount%/}/.metadata-precopy-${ts}"
  run "mkdir -p $(printf %q "$PRECOPY_DIR")"

  log "Copying metadata to $PRECOPY_DIR (rsync -aHAX --numeric-ids)"
  run "rsync -aHAX --numeric-ids --info=progress2 --delete-after $(printf %q "$BASE_PATH")/ $(printf %q "$PRECOPY_DIR")/"

  # Post-copy unquiesce
  if [[ -n "$UNQUIESCE_CMD" ]]; then
    log "Unquiescing: $(cmdline $UNQUIESCE_CMD)"
    run "$UNQUIESCE_CMD" || warn "Unquiesce command returned non-zero."
  fi

  # Light verification pass (find changed files since copy)
  try "rsync -aHAX --numeric-ids --dry-run --delete-after $(printf %q "$BASE_PATH")/ $(printf %q "$PRECOPY_DIR")/ | tail -n +1"

  kv "Backup location" "$PRECOPY_DIR"
  log "Pre-copy complete."
}

cleanup_precopy_if_requested(){
  [[ -n "$PRECOPY_DIR" && "$CLEANUP_PRECOPY" == "true" ]] || return 0
  log "Cleaning up backup at $PRECOPY_DIR"
  run "rm -rf -- $(printf %q "$PRECOPY_DIR")"
}

# ---------- Grow helpers ----------
grow_partition_if_needed(){
  local dev="$1" type; type=$(lsblk -no TYPE "$dev")
  if [[ "$type" == "part" ]]; then
    local partnum pkname parent
    partnum=$(lsblk -no PARTNUM "$dev")
    pkname=$(lsblk -no PKNAME "$dev")
    parent="/dev/${pkname}"
    log "Partitioned device: $dev (parent: $parent, partnum: $partnum)" | tee -a "$LOGFILE"
    if have_cmd growpart; then
      run "growpart $parent $partnum"
    else
      try "parted -s $parent unit s print"
      run "parted -s $parent resizepart $partnum 100%"
      have_cmd partprobe && run "partprobe $parent"
    fi
  else
    log "Device $dev is not a partition (TYPE=$type); skipping partition grow." | tee -a "$LOGFILE"
  fi
}

# ---------- Main ----------
main(){
  parse_args "$@"; need_root
  local tag="auto"; [[ -n "$MNT" ]] && tag=$(echo "$MNT" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g')
  mkdir -p "$LOGDIR"; LOGFILE="${LOGDIR}/grow_xfs_${tag}_$(date +%Y%m%dT%H%M%S).log"; : > "$LOGFILE"
  log "Logging to: $LOGFILE"

  # Discover target if needed
  if [[ -z "$MNT" ]]; then
    discover_target_from_metadata
  else
    BASE_PATH="${BASE_PATH:-$(get_metadata_path || echo "")}"
    [[ -n "$BASE_PATH" ]] && echo -e "\nMetadata location: $BASE_PATH" | tee -a "$LOGFILE"
    echo "Target mountpoint: $MNT" | tee -a "$LOGFILE"
  fi

  # Ensure tools
  ensure_requirements

  # Pre-change discovery
  discovery_report
  [[ "$REPORT_ONLY" == "true" ]] && { log "--report-only specified; stopping after discovery."; exit 0; }

  # === PRE-COPY (if partition) ===
  ensure_precopy_if_needed

  # Rescan for new VMDK size (safe anytime)
  if compgen -G "/sys/class/scsi_host/host*" >/dev/null; then
    section "SCSI Rescan"; for host in /sys/class/scsi_host/host*; do run "echo '- - -' > ${host}/scan"; done
  fi
  have_cmd udevadm && run "udevadm settle"

  # Determine layout
  local FSTYPE SRC is_lvm="false"
  FSTYPE=$(findmnt -n -o FSTYPE --target "$MNT" || true)
  [[ "$FSTYPE" == "xfs" ]] || die "Mountpoint $MNT is not XFS (found: ${FSTYPE:-unknown})."
  SRC=$(findmnt -n -o SOURCE --target "$MNT")
  [[ "$SRC" =~ ^/dev/mapper/ || "$SRC" =~ ^/dev/dm- ]] && is_lvm="true"

  section "Resize Actions"
  if [[ "$is_lvm" == "true" ]]; then
    local LV_PATH VG_NAME
    LV_PATH=$(readlink -f "$SRC"); log "Detected LVM LV: $LV_PATH" | tee -a "$LOGFILE"
    VG_NAME=$(lvs --noheadings -o vg_name "$LV_PATH" | awk '{$1=$1};1'); [[ -n "$VG_NAME" ]] || die "Could not determine VG for $LV_PATH"
    mapfile -t PVS < <(pvs --noheadings -o pv_name --select "vg_name=${VG_NAME}" | awk '{$1=$1};1')
    [[ ${#PVS[@]} -gt 0 ]] || die "No PVs found for VG $VG_NAME"
    log "PVs in VG $VG_NAME: ${PVS[*]}" | tee -a "$LOGFILE"
    for PV in "${PVS[@]}"; do
      grow_partition_if_needed "$PV"
      run "pvresize $PV"
    done
    log "Extending LV to use all free space..." | tee -a "$LOGFILE"
    if ! run "lvextend -l +100%FREE -r $LV_PATH"; then
      warn "lvextend -r failed, retrying without -r then xfs_growfs..."
      run "lvextend -l +100%FREE $LV_PATH"
    fi
    log "Growing XFS on $MNT ..." | tee -a "$LOGFILE"; run "xfs_growfs $MNT"
    log "SUCCESS: $MNT grown (LVM)." | tee -a "$LOGFILE"
  else
    log "Non-LVM source detected: $SRC" | tee -a "$LOGFILE"
    grow_partition_if_needed "$SRC"
    local PARENT_KNAME PARENT; PARENT_KNAME=$(lsblk -no PKNAME "$SRC" 2>/dev/null || true)
    if [[ -n "$PARENT_KNAME" ]] && have_cmd partprobe; then PARENT="/dev/${PARENT_KNAME}"; run "partprobe $PARENT"; fi
    log "Growing XFS on $MNT ..." | tee -a "$LOGFILE"; run "xfs_growfs $MNT"
    log "SUCCESS: $MNT grown (non-LVM)." | tee -a "$LOGFILE"
  fi

  # Optional cleanup of backup
  cleanup_precopy_if_requested

  # Post-change discovery
  section "Post-Change Discovery"; collect_mount_fs_info; collect_block_graph; collect_partition_tables_for_chain; collect_lvm_info_if_any
  log "All done. Full report: $LOGFILE"
}

main "$@"
