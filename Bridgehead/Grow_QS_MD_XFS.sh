#!/usr/bin/env bash
# File: grow_xfs_in_guest.sh
# Purpose:
#   Safely grow an XFS filesystem after you enlarged a VMware VMDK.
#   Adds rich discovery: system info, partition sizes, LVM topology, XFS metadata (incl. log location).
#
# Usage:
#   sudo ./grow_xfs_in_guest.sh -m /data
#   sudo ./grow_xfs_in_guest.sh -m / -y                 # auto-install missing deps without prompting
#   sudo ./grow_xfs_in_guest.sh -m / --no-install       # refuse to install; exit if deps missing
#   sudo ./grow_xfs_in_guest.sh -m / --report-only      # discovery only, no changes
#   sudo ./grow_xfs_in_guest.sh -m / -n                 # dry run (no changes), still prints discovery
#
# Exit codes: 0 success; non-zero on error.

set -euo pipefail

MNT=""
DRY_RUN="false"
ASSUME_YES="false"
NO_INSTALL="false"
REPORT_ONLY="false"
LOGDIR="/var/log"
PKG_MGR=""

usage() {
  cat <<EOF
Usage: $0 -m <mountpoint> [-n] [-y] [--no-install] [--report-only]
  -m  Mountpoint of the XFS filesystem to grow (e.g., / or /data)
  -n  Dry run (show what would happen)
  -y  Auto-approve package installation (non-interactive)
      --no-install   Do not install packages; exit if requirements missing
      --report-only  Discovery/report only; make no changes
Env:
  LOGDIR=${LOGDIR} (where the discovery log is written)
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "Please run as root (use sudo)."; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: $*" | tee -a "${LOGFILE}"
  else
    # shellcheck disable=SC2086
    bash -c "$*" 2>&1 | tee -a "${LOGFILE}"
  fi
}

try() {
  # non-fatal version of run
  echo "TRY: $*" | tee -a "${LOGFILE}"
  # shellcheck disable=SC2086
  bash -c "$*" 2>&1 | tee -a "${LOGFILE}" || true
}

ask_yes_no() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" == "true" ]]; then
    echo "yes"; return 0
  fi
  read -r -p "${prompt} [Y/n]: " ans || true
  ans="${ans:-Y}"
  case "${ans}" in Y|y|yes|YES) echo "yes" ;; *) echo "no" ;; esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m) MNT="$2"; shift 2 ;;
      -n) DRY_RUN="true"; shift ;;
      -y) ASSUME_YES="true"; shift ;;
      --no-install) NO_INSTALL="true"; shift ;;
      --report-only) REPORT_ONLY="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) warn "Unknown arg: $1"; usage; exit 2 ;;
    esac
  done
  [[ -n "${MNT}" ]] || { usage; exit 2; }
}

detect_pkg_mgr() {
  if have_cmd apt-get; then PKG_MGR="apt"
  elif have_cmd dnf; then   PKG_MGR="dnf"
  elif have_cmd yum; then   PKG_MGR="yum"
  elif have_cmd zypper; then PKG_MGR="zypper"
  elif have_cmd apk; then   PKG_MGR="apk"
  else PKG_MGR=""
  fi
}

compute_package_list() {
  PKGS_ALWAYS=()
  PKGS_LVM=()
  case "${PKG_MGR}" in
    apt)    PKGS_ALWAYS=(xfsprogs cloud-guest-utils parted util-linux)
            PKGS_LVM=(lvm2) ;;
    dnf|yum)PKGS_ALWAYS=(xfsprogs cloud-utils-growpart parted util-linux)
            PKGS_LVM=(lvm2) ;;
    zypper) PKGS_ALWAYS=(xfsprogs cloud-utils-growpart parted util-linux)
            PKGS_LVM=(lvm2) ;;
    apk)    PKGS_ALWAYS=(xfsprogs cloud-utils-growpart parted util-linux)
            PKGS_LVM=(lvm2) ;;
    *)      PKGS_ALWAYS=(); PKGS_LVM=() ;;
  esac
}

install_pkgs() {
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0
  case "${PKG_MGR}" in
    apt)
      run "DEBIAN_FRONTEND=noninteractive apt-get update -y"
      run "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs[*]}"
      ;;
    dnf) run "dnf install -y ${pkgs[*]}" ;;
    yum) run "yum install -y ${pkgs[*]}" ;;
    zypper)
      run "zypper --non-interactive refresh"
      run "zypper --non-interactive install --auto-agree-with-licenses ${pkgs[*]}"
      ;;
    apk)
      run "apk update"
      run "apk add ${pkgs[*]}"
      ;;
    *) die "No supported package manager found to install: ${pkgs[*]}";;
  esac
}

ensure_requirements() {
  detect_pkg_mgr
  compute_package_list

  # Minimal tools to inspect mount
  have_cmd findmnt || die "findmnt required (usually in util-linux)."
  have_cmd lsblk   || die "lsblk required (usually in util-linux)."

  local fstype src is_lvm="false"
  fstype=$(findmnt -n -o FSTYPE --target "${MNT}" || true)
  [[ "${fstype}" == "xfs" ]] || die "Mountpoint ${MNT} is not XFS (found: ${fstype:-unknown})."
  src=$(findmnt -n -o SOURCE --target "${MNT}") || die "Cannot determine block device for ${MNT}"
  [[ "${src}" =~ ^/dev/mapper/ || "${src}" =~ ^/dev/dm- ]] && is_lvm="true"

  local missing=()
  have_cmd xfs_growfs || missing+=("xfs_growfs")
  if have_cmd growpart || have_cmd parted; then :; else missing+=("growpart/parted"); fi
  if [[ "${is_lvm}" == "true" ]]; then
    have_cmd pvresize || missing+=("pvresize")
    have_cmd lvextend || missing+=("lvextend")
    have_cmd lvs      || missing+=("lvs")
    have_cmd pvs      || missing+=("pvs")
    have_cmd vgs      || missing+=("vgs")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    [[ "${NO_INSTALL}" == "true" ]] && die "Missing commands: ${missing[*]} and --no-install specified."
    [[ -z "${PKG_MGR}" ]] && die "Missing commands: ${missing[*]} but no supported package manager found."
    warn "Missing commands detected: ${missing[*]}"
    local to_install=("${PKGS_ALWAYS[@]}")
    [[ "${is_lvm}" == "true" ]] && to_install+=("${PKGS_LVM[@]}")
    if [[ "$(ask_yes_no "Install required packages via ${PKG_MGR}: ${to_install[*]}?")" == "yes" ]]; then
      install_pkgs "${to_install[@]}"
    else
      die "User declined to install missing packages."
    fi
  fi
}

# ---------- Discovery ----------
section() {
  echo; echo "==== $* ====" | tee -a "${LOGFILE}"
}

kv() { printf "%-22s : %s\n" "$1" "$2" | tee -a "${LOGFILE}"; }

parent_disk_of() {
  local dev="$1"
  lsblk -no PKNAME "${dev}" 2>/dev/null | awk '{print "/dev/"$1}'
}

collect_os_info() {
  section "System"
  kv "Timestamp" "$(date -Iseconds)"
  kv "Hostname" "$(hostname -f 2>/dev/null || hostname)"
  kv "Kernel" "$(uname -r)"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    kv "OS" "${PRETTY_NAME:-${NAME:-unknown}}"
  else
    kv "OS" "unknown"
  fi
  kv "Virtualization" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
}

collect_mount_fs_info() {
  section "Target"
  kv "Mountpoint" "${MNT}"
  kv "Source" "$(findmnt -n -o SOURCE --target "${MNT}")"
  kv "Fstype"  "$(findmnt -n -o FSTYPE  --target "${MNT}")"
  kv "Options" "$(findmnt -n -o OPTIONS --target "${MNT}")"
  echo
  df -h "${MNT}" 2>/dev/null | tee -a "${LOGFILE}" || true

  if have_cmd xfs_info; then
    echo; echo "-- xfs_info ${MNT} --" | tee -a "${LOGFILE}"
    xfs_info "${MNT}" 2>&1 | tee -a "${LOGFILE}" || true
  else
    warn "xfs_info not available; skipping detailed XFS metadata."
  fi
}

collect_block_graph() {
  section "Block Devices (lsblk)"
  lsblk -e7 -o NAME,TYPE,SIZE,ROTA,FSTYPE,MOUNTPOINT,PKNAME,MODEL,SERIAL,TRAN -p | tee -a "${LOGFILE}"
}

collect_partition_tables_for_chain() {
  local src parent
  src=$(findmnt -n -o SOURCE --target "${MNT}")
  parent="$(parent_disk_of "${src}")"
  [[ -z "${parent}" ]] && return 0

  section "Partition Table(s)"
  echo "Primary disk for ${src}: ${parent}" | tee -a "${LOGFILE}"
  if have_cmd parted; then
    echo; echo "-- parted -s ${parent} print --" | tee -a "${LOGFILE}"
    parted -s "${parent}" unit s print 2>&1 | tee -a "${LOGFILE}" || true
  elif have_cmd fdisk; then
    echo; echo "-- fdisk -l ${parent} --" | tee -a "${LOGFILE}"
    fdisk -l "${parent}" 2>&1 | tee -a "${LOGFILE}" || true
  fi

  # If src is a partition, also show siblings context
  local pk
  pk=$(lsblk -no PKNAME "${src}" 2>/dev/null || true)
  if [[ -n "${pk}" ]]; then
    section "Siblings on ${parent}"
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT -p "/dev/${pk}" | tee -a "${LOGFILE}"
  fi
}

collect_lvm_info_if_any() {
  local src is_lvm="false"
  src=$(findmnt -n -o SOURCE --target "${MNT}") || return 0
  [[ "${src}" =~ ^/dev/mapper/ || "${src}" =~ ^/dev/dm- ]] && is_lvm="true"
  [[ "${is_lvm}" != "true" ]] && return 0

  section "LVM Topology"
  if have_cmd pvs; then
    echo "-- pvs (with pe_start) --" | tee -a "${LOGFILE}"
    pvs -o pv_name,vg_name,pv_size,pv_free,pe_start --units m --separator '  ' --noheadings | sed 's/^ *//' | tee -a "${LOGFILE}"
  fi
  if have_cmd vgs; then
    echo; echo "-- vgs --" | tee -a "${LOGFILE}"
    vgs -o vg_name,vg_size,vg_free,pv_count,lv_count --units m | tee -a "${LOGFILE}"
  fi
  if have_cmd lvs; then
    echo; echo "-- lvs --" | tee -a "${LOGFILE}"
    lvs -o lv_name,vg_name,lv_size,lv_path,lv_attr --units m | tee -a "${LOGFILE}"
  fi

  # Per-PV metadata layout (maps + shows where metadata lives relative to data area start)
  if have_cmd pvdisplay; then
    echo; echo "-- pvdisplay -m (first PV in VG) --" | tee -a "${LOGFILE}"
    # Figure out VG and first PV
    local lv_path vg_name pv
    lv_path=$(readlink -f "${src}")
    vg_name=$(lvs --noheadings -o vg_name "${lv_path}" | awk '{$1=$1};1')
    pv=$(pvs --noheadings -o pv_name --select "vg_name=${vg_name}" | awk 'NR==1{print $1}')
    [[ -n "${pv}" ]] && pvdisplay -m "${pv}" 2>&1 | tee -a "${LOGFILE}" || true
  fi
}

discovery_report() {
  section "Discovery Report (START)"
  collect_os_info
  collect_mount_fs_info
  collect_block_graph
  collect_partition_tables_for_chain
  collect_lvm_info_if_any
  section "Discovery Report (END)"
}

# ---------- Partition grow helper ----------
grow_partition_if_needed() {
  local dev="$1" # e.g., /dev/sdb1 or /dev/nvme0n1p3 or /dev/sdb
  local type
  type=$(lsblk -no TYPE "${dev}")
  if [[ "${type}" == "part" ]]; then
    local partnum pkname parent
    partnum=$(lsblk -no PARTNUM "${dev}")
    pkname=$(lsblk -no PKNAME "${dev}")
    parent="/dev/${pkname}"

    log "Partitioned device: ${dev} (parent: ${parent}, partnum: ${partnum})" | tee -a "${LOGFILE}"

    if have_cmd growpart; then
      run "growpart ${parent} ${partnum}"
    else
      try "parted -s ${parent} unit s print"
      run "parted -s ${parent} resizepart ${partnum} 100%"
      if have_cmd partprobe; then
        run "partprobe ${parent}"
      fi
    fi
  else
    log "Device ${dev} is not a partition (TYPE=${type}); skipping partition grow." | tee -a "${LOGFILE}"
  fi
}

main() {
  parse_args "$@"
  need_root

  # Prepare logfile with sanitized mount in name
  local mnt_tag
  mnt_tag=$(echo "${MNT}" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g')
  mkdir -p "${LOGDIR}"
  LOGFILE="${LOGDIR}/grow_xfs_${mnt_tag}_$(date +%Y%m%dT%H%M%S).log"
  : > "${LOGFILE}"

  log "Logging discovery and actions to: ${LOGFILE}"

  # Make sure we can at least inspect the target
  ensure_requirements

  # === Pre-change discovery ===
  discovery_report

  if [[ "${REPORT_ONLY}" == "true" ]]; then
    log "--report-only specified; stopping after discovery."
    exit 0
  fi

  # Rescan SCSI (VMware VMDK size changes)
  if compgen -G "/sys/class/scsi_host/host*" >/dev/null; then
    section "SCSI Rescan"
    for host in /sys/class/scsi_host/host*; do
      run "echo '- - -' > ${host}/scan"
    done
  fi
  have_cmd udevadm && run "udevadm settle"

  local FSTYPE SRC is_lvm="false"
  FSTYPE=$(findmnt -n -o FSTYPE --target "${MNT}" || true)
  [[ "${FSTYPE}" == "xfs" ]] || die "Mountpoint ${MNT} is not XFS (found: ${FSTYPE:-unknown})."
  SRC=$(findmnt -n -o SOURCE --target "${MNT}")
  [[ "${SRC}" =~ ^/dev/mapper/ || "${SRC}" =~ ^/dev/dm- ]] && is_lvm="true"

  section "Resize Actions"
  if [[ "${is_lvm}" == "true" ]]; then
    local LV_PATH VG_NAME
    LV_PATH=$(readlink -f "${SRC}")
    log "Detected LVM LV: ${LV_PATH}" | tee -a "${LOGFILE}"
    VG_NAME=$(lvs --noheadings -o vg_name "${LV_PATH}" | awk '{$1=$1};1')
    [[ -n "${VG_NAME}" ]] || die "Could not determine VG for ${LV_PATH}"

    # Grow PV partitions and pvresize
    mapfile -t PVS < <(pvs --noheadings -o pv_name --select "vg_name=${VG_NAME}" | awk '{$1=$1};1')
    [[ "${#PVS[@]}" -gt 0 ]] || die "No PVs found for VG ${VG_NAME}"
    log "PVs in VG ${VG_NAME}: ${PVS[*]}" | tee -a "${LOGFILE}"

    for PV in "${PVS[@]}"; do
      grow_partition_if_needed "${PV}"
      run "pvresize ${PV}"
    done

    log "Extending LV to consume all free space..." | tee -a "${LOGFILE}"
    if ! run "lvextend -l +100%FREE -r ${LV_PATH}"; then
      warn "lvextend -r failed (fsadm may have balked). Retrying without -r, then xfs_growfs separately..."
      run "lvextend -l +100%FREE ${LV_PATH}"
    fi

    log "Growing XFS on ${MNT} ..." | tee -a "${LOGFILE}"
    run "xfs_growfs ${MNT}"
    log "SUCCESS: ${MNT} grown (LVM)." | tee -a "${LOGFILE}"

  else
    log "Non-LVM source detected: ${SRC}" | tee -a "${LOGFILE}"
    grow_partition_if_needed "${SRC}"

    local PARENT_KNAME PARENT
    PARENT_KNAME=$(lsblk -no PKNAME "${SRC}" 2>/dev/null || true)
    if [[ -n "${PARENT_KNAME}" ]] && have_cmd partprobe; then
      PARENT="/dev/${PARENT_KNAME}"
      run "partprobe ${PARENT}"
    fi

    log "Growing XFS on ${MNT} ..." | tee -a "${LOGFILE}"
    run "xfs_growfs ${MNT}"
    log "SUCCESS: ${MNT} grown (non-LVM)." | tee -a "${LOGFILE}"
  fi

  # === Post-change discovery ===
  section "Post-Change Discovery"
  collect_mount_fs_info
  collect_block_graph
  collect_partition_tables_for_chain
  collect_lvm_info_if_any

  log "All done. Full report: ${LOGFILE}"
}

main "$@"
