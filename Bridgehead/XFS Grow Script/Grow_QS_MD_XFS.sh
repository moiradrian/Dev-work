#!/usr/bin/env bash
# File: grow_xfs_in_guest.sh
#
# Safely grow an XFS filesystem after enlarging a VMware VMDK.
# - Auto-discovers target mount from app metadata (via `system --show`) or accepts --mount
# - Pre-copy safety if the backing device is a partition (optional)
# - Per-device rescan via /sys/class/block/<disk>/device/rescan (NVMe-aware)
# - Handles LVM and non-LVM, grows partition/PV/LV and finally xfs_growfs
# - Dry-run mode where probes execute but mutations are skipped

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
PRECOPY="auto" # auto|always|never
MAIN_STORE=""  # mount or path to hold the backup copy
UNSAFE_CONTINUE="false"
CLEANUP_PRECOPY="false"
QUIESCE_CMD=""
UNQUIESCE_CMD=""
PRECOPY_DIR=""

# Colors
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

# ---------- Helpers (wrapping & pretty help) ----------
get_term_width() {
    local w="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    [[ "$w" =~ ^[0-9]+$ ]] || w=80
    echo "$w"
}
wrap_text() {
    local t="$1" i="${2:-0}" w bw
    w=$(get_term_width)
    bw=$((w - i))
    ((bw < 30)) && bw=30
    echo -e "$t" | fold -s -w "$bw" | sed "2,999s/^/$(printf '%*s' "$i")/"
}
color_wrap_text() { wrap_text "$1" "${2:-0}"; }
print_opt() {
    local opt="$1" desc="$2"
    printf "  %-20b " "$opt"
    color_wrap_text "$desc" 22
}
cmdline() {
    local out
    printf -v out '%q ' "$@"
    echo "${out% }"
}

# --- Execution wrappers ---
probe() {
    # Always run (read-only / informational commands)
    # shellcheck disable=SC2086
    bash -c "$*" 2>&1 | tee -a "${LOGFILE}" || true
}
run_mut() {
    # Only run when NOT in dry-run (mutating commands)
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "DRY-RUN (skip): $*" | tee -a "${LOGFILE}"
    else
        # shellcheck disable=SC2086
        bash -c "$*" 2>&1 | tee -a "${LOGFILE}"
    fi
}

# ---------- Portable device helpers (no lsblk PARTNUM needed) ----------
_resolve_kpath() {
    local p="$1" r=""
    if command -v readlink >/dev/null 2>&1; then r=$(readlink -f -- "$p" 2>/dev/null || true); fi
    if [ -z "$r" ] && command -v realpath >/dev/null 2>&1; then r=$(realpath -- "$p" 2>/dev/null || true); fi
    [ -n "$r" ] || r="$p"
    printf '%s\n' "$r"
}
_get_kname() { basename "$(_resolve_kpath "$1")" | sed 's:^/dev/::'; }

_get_partnum() {
    local k
    k="$(_get_kname "$1")"
    if [ -r "/sys/class/block/$k/partition" ]; then
        cat "/sys/class/block/$k/partition"
        return
    fi
    echo "$k" | sed -E 's/^.*[^0-9]([0-9]+)$/\1/'
}

_get_parent_kname() {
    # Parent disk kernel name for a partition (sysfs first, then fallbacks)
    local k
    k="$(_get_kname "$1")"

    local sys
    sys="/sys/class/block/$k"

    if [ -L "$sys" ]; then
        local parent
        parent="$(basename "$(dirname "$(readlink -f "$sys")")")"
        if [ -e "/sys/class/block/$parent/device" ]; then
            printf '%s\n' "$parent"
            return
        fi
    fi

    # Try lsblk PKNAME if supported
    if lsblk -dn -o PKNAME "/dev/$k" >/dev/null 2>&1; then
        lsblk -dn -o PKNAME "/dev/$k"
        return
    fi

    # String fallbacks for common naming schemes
    case "$k" in
    nvme*n[0-9]*) echo "${k%%p[0-9]*}" ;;
    mmcblk*[0-9]p*) echo "${k%%p[0-9]*}" ;;
    *[0-9]) echo "${k%%[0-9]*}" ;;
    *) echo "$k" ;;
    esac
}

# Return unique list of base disks (sdX, nvme0n1, vdX, …) beneath a node (partition, dm/LVM/mpath, etc.)
_underlying_base_disks() {
    local node="$1" kname type pk d base
    kname=$(basename "$(_resolve_kpath "$node")")
    type=$(lsblk -dn -o TYPE "/dev/$kname" 2>/dev/null || echo "")
    if [[ "$type" == "part" ]]; then
        pk="$(_get_parent_kname "/dev/$kname")"
        [[ -n "$pk" ]] && echo "$pk" && return 0
    fi
    if [[ "$type" == "disk" || -e "/sys/class/block/$kname/device/rescan" ]]; then
        echo "$kname"
        return 0
    fi
    if [[ -d "/sys/class/block/$kname/slaves" ]]; then
        for d in /sys/class/block/"$kname"/slaves/*; do
            [[ -e "$d" ]] || continue
            base="$(basename "$d")"
            if [[ "$(lsblk -dn -o TYPE "/dev/$base")" == "part" ]]; then
                echo "$(_get_parent_kname "/dev/$base")"
            else
                echo "$base"
            fi
        done | awk 'NF' | sort -u
        return 0
    fi
    pk=$(lsblk -dn -o PKNAME "/dev/$kname" 2>/dev/null || true)
    [[ -n "$pk" ]] && echo "$pk" || echo "$kname"
}

# Per-disk rescan via sysfs (NVMe-aware)
_rescan_one_base_disk() {
    local disk
    disk="${1#/dev/}" # strip /dev/ if present

    local sysdev
    sysdev="/sys/class/block/$disk"

    local rescan
    rescan="$sysdev/device/rescan"

    if [[ -w "$rescan" ]]; then
        run_mut "echo 1 > $(printf %q "$rescan")"
        return 0
    fi

    # NVMe controller rescan (namespaces), e.g. disk "nvme0n1" -> ctrl "nvme0"
    if [[ "$disk" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        local ctrl
        ctrl="${disk%%n*}"

        local ctrl_path
        ctrl_path="/sys/class/nvme/$ctrl/rescan"

        if [[ -w "$ctrl_path" ]]; then
            run_mut "echo 1 > $(printf %q "$ctrl_path")"
            return 0
        fi
    fi

    warn "No writable rescan node for /dev/$disk (checked $rescan)."
    return 1
}

# Compute base disks to rescan for a mount (all PV parents if LVM)
_base_disks_for_mount() {
    local mnt="$1" src is_lvm="false"
    src=$(findmnt -n -o SOURCE --target "$mnt")
    [[ "$src" =~ ^/dev/mapper/ || "$src" =~ ^/dev/dm- ]] && is_lvm="true"
    if [[ "$is_lvm" == "true" ]]; then
        local lv_path vg pvs pv
        lv_path=$(readlink -f "$src")
        vg=$(lvs --noheadings -o vg_name "$lv_path" | awk '{$1=$1};1')
        mapfile -t pvs < <(pvs --noheadings -o pv_name --select "vg_name=$vg" | awk '{$1=$1};1')
        for pv in "${pvs[@]}"; do _underlying_base_disks "$pv"; done | sort -u
    else
        _underlying_base_disks "$src" | sort -u
    fi
}

# Fallback: wide SCSI-host scan (only if per-disk fails)
_fallback_host_scan() {
    if compgen -G "/sys/class/scsi_host/host*" >/dev/null; then
        section "Fallback SCSI host scan"
        for host in /sys/class/scsi_host/host*; do
            run_mut "echo '- - -' > ${host}/scan"
        done
    else
        warn "No /sys/class/scsi_host/* found for fallback host scan."
    fi
}

# ---------- Parted print warning filter ----------
_filter_parted_tail_warn() {
    # Strip the benign GPT unused-tail prompt from parted print output
    sed -E \
        -e '/^Warning: Not all of the space available to .* appears to be used/d' \
        -e '/^Fix the GPT to use all of the space/d' \
        -e '/^\?$/d'
}

# ----------- Help ----------
show_help() {
    echo -e "${GREEN}Usage:${NC} $0 [options]\n"
    echo -e "${GREEN}Options:${NC}"
    print_opt "-m, --mount <path>" "Mountpoint to grow (if omitted, discovered from app metadata)."
    print_opt "    --metadata-cmd <cmd>" "Command printing a line 'Metadata: /path' (default: 'system --show')."
    print_opt "-y, --yes" "Auto-approve package installs."
    print_opt "-n, --dry-run" "Probes run; mutating steps are skipped."
    print_opt "    --no-install" "Do not install missing packages."
    print_opt "    --report-only" "Discovery only; no changes."
    print_opt "    --logdir <dir>" "Log directory (default: ${LOGDIR})."
    echo
    echo -e "${GREEN}Pre-copy safety (when backing device is a partition):${NC}"
    print_opt "    --precopy auto|always|never" "Control pre-copy behavior (default: auto)."
    print_opt "    --main-store <path>" "Directory or mount for the backup copy."
    print_opt "    --unsafe-continue" "Proceed without backup if not enough space (no prompt)."
    print_opt "    --cleanup-precopy" "Remove backup after successful grow."
    print_opt "    --quiesce <cmd>" "Command before copy (pause app)."
    print_opt "    --unquiesce <cmd>" "Command after copy (resume app)."
    echo
    echo -e "${GREEN}Examples:${NC}"
    echo "  $0 --report-only"
    echo "  $0 --dry-run --yes"
    echo "  $0 --mount /data --main-store /var/backups --quiesce 'systemctl stop app' --unquiesce 'systemctl start app'"
    exit 0
}

# ---------- Core plumbing ----------
die() {
    echo -e "${RED}ERROR:${NC} $*" >&2
    exit 1
}
log() { echo "[+] $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
need_root() { [[ "$EUID" -eq 0 ]] || die "Please run as root."; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

ask_yes_no() {
    local p="$1"
    [[ "$ASSUME_YES" == "true" ]] && {
        echo yes
        return
    }
    read -r -p "$p [Y/n]: " a || true
    a="${a:-Y}"
    case "$a" in Y | y | yes | YES) echo yes ;; *) echo no ;; esac
}

# ---------- Args ----------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -m | --mount)
            MNT="$2"
            shift 2
            ;;
        --metadata-cmd)
            METADATA_CMD="$2"
            shift 2
            ;;
        -y | --yes)
            ASSUME_YES="true"
            shift
            ;;
        -n | --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --no-install)
            NO_INSTALL="true"
            shift
            ;;
        --report-only)
            REPORT_ONLY="true"
            shift
            ;;
        --logdir)
            LOGDIR="$2"
            shift 2
            ;;
        --precopy)
            PRECOPY="$2"
            shift 2
            ;;
        --main-store)
            MAIN_STORE="$2"
            shift 2
            ;;
        --unsafe-continue)
            UNSAFE_CONTINUE="true"
            shift
            ;;
        --cleanup-precopy)
            CLEANUP_PRECOPY="true"
            shift
            ;;
        --quiesce)
            QUIESCE_CMD="$2"
            shift 2
            ;;
        --unquiesce)
            UNQUIESCE_CMD="$2"
            shift 2
            ;;
        -h | --help) show_help ;;
        *)
            warn "Unknown arg: $1"
            echo
            show_help
            ;;
        esac
    done
}

# ---------- App-aware discovery ----------
get_metadata_path() {
    local out=""
    [[ "$METADATA_CMD" == "system --show" && ! $(
        have_cmd system
        echo $?
    ) -eq 0 ]] && return 1
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
section() {
    echo
    echo "==== $* ====" | tee -a "$LOGFILE"
}
kv() { printf "%-22s : %s\n" "$1" "$2" | tee -a "$LOGFILE"; }

collect_os_info() {
    section "System"
    kv Timestamp "$(date -Iseconds)"
    kv Hostname "$(hostname -f 2>/dev/null || hostname)"
    kv Kernel "$(uname -r)"
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        kv OS "${PRETTY_NAME:-$NAME}"
    else kv OS unknown; fi
    kv Virtualization "$(systemd-detect-virt 2>/dev/null || echo unknown)"
}
get_metadata_usage() {
    echo -e "\n${GREEN}Checking Metadata Partition Usage${NC}"
    local mntc PART_USAGE
    mntc=$(findmnt -n -o TARGET --target "$BASE_PATH" 2>/dev/null || echo "")
    [[ -z "$mntc" ]] && mntc="/$(echo "$BASE_PATH" | cut -d'/' -f2)"
    PART_USAGE=$(df -h | awk -v mnt="$mntc" '$NF==mnt {print}')
    [[ -z "$PART_USAGE" ]] && PART_USAGE=$(df -h "$BASE_PATH" 2>/dev/null | tail -1)
    [[ -z "$PART_USAGE" ]] && {
        echo -e "${RED}Error: Unable to determine usage for: ${BASE_PATH}${NC}"
        echo "DEBUG: df empty" | tee -a "$LOGFILE"
        return 1
    }
    local OLDIFS="$IFS"
    IFS=$' \t'
    read -r DEVICE SIZE USED AVAIL USEP MOUNTED <<<"$PART_USAGE"
    IFS="$OLDIFS"
    echo "Device: $DEVICE"
    echo "Metadata Partition Usage:"
    printf "%-8s %-8s %-8s %-6s\n" "Size" "Used" "Avail" "Use%"
    printf "%-8s %-8s %-8s %-6s\n" "$SIZE" "$USED" "$AVAIL" "$USEP"
    echo "Mount: $MOUNTED"
    echo | tee -a "$LOGFILE"
}
collect_mount_fs_info() {
    section "Target"
    kv "Metadata path" "$BASE_PATH"
    kv "Mountpoint" "$(findmnt -n -o TARGET --target "$MNT" 2>/dev/null || echo "$MNT")"
    kv "Source" "$(findmnt -n -o SOURCE --target "$MNT")"
    kv "Fstype" "$(findmnt -n -o FSTYPE --target "$MNT")"
    kv "Options" "$(findmnt -n -o OPTIONS --target "$MNT")"
    echo
    probe "df -h $(printf %q "$MNT")"
    if have_cmd xfs_info; then
        echo
        echo "-- xfs_info $MNT --" | tee -a "$LOGFILE"
        probe "xfs_info $(printf %q "$MNT")"
    fi
    get_metadata_usage || true
}
collect_block_graph() {
    section "Block Devices (lsblk)"
    probe "lsblk -e7 -o NAME,TYPE,SIZE,ROTA,FSTYPE,MOUNTPOINT,PKNAME,MODEL,SERIAL,TRAN -p"
}

collect_partition_tables_for_chain() {
    local src parent_k parent
    src=$(findmnt -n -o SOURCE --target "$MNT")
    parent_k="$(_get_parent_kname "$src")"
    [[ -z "$parent_k" ]] && return 0
    parent="/dev/${parent_k}"
    section "Partition Table"
    echo "Primary disk for $src: $parent" | tee -a "$LOGFILE"
    if have_cmd parted; then
        echo
        echo "-- parted -s $parent unit s print --" | tee -a "$LOGFILE"
        # Direct call so our filter function is available; don't use probe here
        parted -s "$parent" unit s print 2>&1 | _filter_parted_tail_warn | tee -a "$LOGFILE" || true
    elif have_cmd fdisk; then
        echo
        echo "-- fdisk -l $parent --" | tee -a "$LOGFILE"
        probe "fdisk -l $(printf %q "$parent")"
    fi
}
collect_lvm_info_if_any() {
    local src=$(findmnt -n -o SOURCE --target "$MNT" || true)
    [[ "$src" =~ ^/dev/mapper/ || "$src" =~ ^/dev/dm- ]] || return 0
    section "LVM Topology"
    have_cmd pvs && {
        echo "-- pvs (pe_start) --" | tee -a "$LOGFILE"
        probe "pvs -o pv_name,vg_name,pv_size,pv_free,pe_start --units m --separator '  ' --noheadings | sed 's/^ *//'"
    }
    have_cmd vgs && {
        echo
        echo "-- vgs --" | tee -a "$LOGFILE"
        probe "vgs -o vg_name,vg_size,vg_free,pv_count,lv_count --units m"
    }
    have_cmd lvs && {
        echo
        echo "-- lvs --" | tee -a "$LOGFILE"
        probe "lvs -o lv_name,vg_name,lv_size,lv_path,lv_attr --units m"
    }
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

# ---------- Dependencies ----------
detect_pkg_mgr() { if have_cmd apt-get; then PKG_MGR=apt; elif have_cmd dnf; then PKG_MGR=dnf; elif have_cmd yum; then PKG_MGR=yum; elif have_cmd zypper; then PKG_MGR=zypper; elif have_cmd apk; then PKG_MGR=apk; else PKG_MGR=""; fi; }
compute_package_list() { case "$PKG_MGR" in
    apt)
        PKGS_ALWAYS=(xfsprogs cloud-guest-utils parted util-linux)
        PKGS_LVM=(lvm2)
        ;;
    dnf | yum)
        PKGS_ALWAYS=(xfsprogs cloud-utils-growpart parted util-linux)
        PKGS_LVM=(lvm2)
        ;;
    zypper | apk)
        PKGS_ALWAYS=(xfsprogs cloud-utils-growpart parted util-linux)
        PKGS_LVM=(lvm2)
        ;;
    *)
        PKGS_ALWAYS=()
        PKGS_LVM=()
        ;;
    esac }
install_pkgs() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    case "$PKG_MGR" in
    apt)
        run_mut "DEBIAN_FRONTEND=noninteractive apt-get update -y"
        run_mut "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs[*]}"
        ;;
    dnf) run_mut "dnf install -y ${pkgs[*]}" ;;
    yum) run_mut "yum install -y ${pkgs[*]}" ;;
    zypper)
        run_mut "zypper --non-interactive refresh"
        run_mut "zypper --non-interactive install --auto-agree-with-licenses ${pkgs[*]}"
        ;;
    apk)
        run_mut "apk update"
        run_mut "apk add ${pkgs[*]}"
        ;;
    *) die "No supported package manager to install: ${pkgs[*]}" ;;
    esac
}
ensure_requirements() {
    detect_pkg_mgr
    compute_package_list
    have_cmd findmnt || die "findmnt required (util-linux)."
    have_cmd lsblk || die "lsblk required (util-linux)."
    local fstype src is_lvm="false"
    fstype=$(findmnt -n -o FSTYPE --target "$MNT" || true)
    [[ "$fstype" == "xfs" ]] || die "Mountpoint $MNT is not XFS (found: ${fstype:-unknown})."
    src=$(findmnt -n -o SOURCE --target "$MNT") || die "Cannot determine block device for $MNT"
    [[ "$src" =~ ^/dev/mapper/ || "$src" =~ ^/dev/dm- ]] && is_lvm="true"
    local missing=()
    have_cmd xfs_growfs || missing+=("xfs_growfs")
    if have_cmd growpart || have_cmd parted; then :; else missing+=("growpart/parted"); fi
    if [[ "$is_lvm" == "true" ]]; then
        have_cmd pvresize || missing+=("pvresize")
        have_cmd lvextend || missing+=("lvextend")
        have_cmd lvs || missing+=("lvs")
        have_cmd pvs || missing+=("pvs")
        have_cmd vgs || missing+=("vgs")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        [[ "$NO_INSTALL" == "true" ]] && die "Missing: ${missing[*]} and --no-install specified."
        [[ -z "$PKG_MGR" ]] && die "Missing: ${missing[*]} but no supported package manager found."
        warn "Missing commands: ${missing[*]}"
        local to_install=("${PKGS_ALWAYS[@]}")
        [[ "$is_lvm" == "true" ]] && to_install+=("${PKGS_LVM[@]}")
        if [[ "$(ask_yes_no "Install required packages via $PKG_MGR: ${to_install[*]}?")" == "yes" ]]; then install_pkgs "${to_install[@]}"; else die "User declined to install missing packages."; fi
    fi
}

# ---------- PRE-COPY: choose main storage & copy ----------
bytes_du() { du -sb "$1" 2>/dev/null | awk '{print $1}'; }
bytes_df_avail() { df -B1 -P "$1" | awk 'NR==2{print $4}'; }
mount_of() { findmnt -n -o TARGET --target "$1"; }

pick_main_store() {
    if [[ -n "$MAIN_STORE" ]]; then
        echo "$MAIN_STORE"
        return 0
    fi
    if have_cmd findmnt; then
        findmnt -rn -o TARGET,FSTYPE,AVAIL | awk -v tgt="$MNT" '
      $1!=tgt && $2 !~ /^(tmpfs|devtmpfs|proc|sysfs|cgroup|mqueue|overlay|squashfs|debugfs|tracefs|pstore|autofs|ramfs|zfs|bpf|fuse)/ { print $0 }' |
            awk '
      function suffix(v){ if (v ~ /[A-Za-z]$/){ u=substr(v,length(v),1); gsub(/[A-Za-z]/,"",v);
        if (u=="K") v*=1024; else if (u=="M") v*=1024^2; else if (u=="G") v*=1024^3; else if (u=="T") v*=1024^4; } return v }
      {bytes=suffix($3); if (bytes>max){max=bytes; pick=$1}} END{if(pick!="") print pick}'
    else
        df -B1 -PT | awk -v tgt="$MNT" 'NR>1 && $7!=tgt && $2 !~ /^(tmpfs|devtmpfs|proc|sysfs|cgroup|mqueue|overlay|squashfs|debugfs|tracefs|pstore|autofs|ramfs|zfs|bpf|fuse)/ {print $7,$4}' |
            sort -k2,2n | tail -1 | awk '{print $1}'
    fi
}

ensure_precopy_if_needed() {
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

    local dst_mount need_bytes avail_bytes
    need_bytes=$(bytes_du "$BASE_PATH")
    [[ -z "$need_bytes" || "$need_bytes" -eq 0 ]] && need_bytes=1
    dst_mount=$(pick_main_store)
    [[ -z "$dst_mount" ]] && die "Could not determine a main storage mount. Specify --main-store <path>."
    kv "Chosen main storage" "$dst_mount"
    avail_bytes=$(bytes_df_avail "$dst_mount")
    local headroom=$(((need_bytes * 11) / 10)) # +10% headroom
    kv "Needed (with headroom)" "$headroom bytes"
    kv "Available" "$avail_bytes bytes"

    if ((avail_bytes < headroom)); then
        warn "Not enough space to pre-copy."
        if [[ "$UNSAFE_CONTINUE" == "true" ]]; then
            warn "Proceeding UNSAFELY without backup due to --unsafe-continue."
            return 0
        fi
        if [[ "$(ask_yes_no "Proceed UNSAFELY without backup?")" == "yes" ]]; then
            warn "User accepted UNSAFE continue."
            return 0
        else die "Aborting; insufficient space for safe pre-copy."; fi
    fi

    # Optional quiesce
    if [[ -n "$QUIESCE_CMD" ]]; then
        log "Quiescing: $(cmdline $QUIESCE_CMD)"
        run_mut "$QUIESCE_CMD" || warn "Quiesce command returned non-zero."
    fi

    # Make destination and copy
    local ts
    ts="$(date +%Y%m%dT%H%M%S)"
    PRECOPY_DIR="${dst_mount%/}/.metadata-precopy-${ts}"
    run_mut "mkdir -p $(printf %q "$PRECOPY_DIR")"
    log "Copying metadata to $PRECOPY_DIR (rsync -aHAX --numeric-ids)"
    run_mut "rsync -aHAX --numeric-ids --info=progress2 --delete-after $(printf %q "$BASE_PATH")/ $(printf %q "$PRECOPY_DIR")/"

    # Unquiesce after copy
    if [[ -n "$UNQUIESCE_CMD" ]]; then
        log "Unquiescing: $(cmdline $UNQUIESCE_CMD)"
        run_mut "$UNQUIESCE_CMD" || warn "Unquiesce command returned non-zero."
    fi

    # Light verification (probe)
    probe "rsync -aHAX --numeric-ids --dry-run --delete-after $(printf %q "$BASE_PATH")/ $(printf %q "$PRECOPY_DIR")/ | tail -n +1"

    kv "Backup location" "$PRECOPY_DIR"
    log "Pre-copy complete."
}
cleanup_precopy_if_requested() {
    [[ -n "$PRECOPY_DIR" && "$CLEANUP_PRECOPY" == "true" ]] || return 0
    log "Cleaning up backup at $PRECOPY_DIR"
    run_mut "rm -rf -- $(printf %q "$PRECOPY_DIR")"
}

# ---------- Grow helpers ----------
grow_partition_if_needed() {
    local dev type partnum parent_k parent
    dev="$1" # e.g., /dev/sdb1 or /dev/nvme0n1p3 or /dev/sdb

    # Determine whether it's a partition (old util-linux compatible)
    type=$(lsblk -no TYPE "$dev" 2>/dev/null || echo "")

    if [[ "$type" == "part" ]]; then
        partnum="$(_get_partnum "$dev")"
        parent_k="$(_get_parent_kname "$dev")"
        parent="/dev/${parent_k}"

        log "Partitioned device: ${dev} (parent: ${parent}, partnum: ${partnum})" | tee -a "${LOGFILE}"

        if have_cmd growpart; then
            run_mut "growpart ${parent} ${partnum}"
        else
            # print-only probe (filter the benign GPT tail warning)
            echo
            echo "-- parted -s ${parent} unit s print --" | tee -a "$LOGFILE"
            parted -s "${parent}" unit s print 2>&1 | _filter_parted_tail_warn | tee -a "${LOGFILE}" || true

            run_mut "parted -s ${parent} resizepart ${partnum} 100%"
            have_cmd partprobe && run_mut "partprobe ${parent}"
        fi
    else
        log "Device ${dev} is not a partition (TYPE=${type:-unknown}); skipping partition grow." | tee -a "${LOGFILE}"
    fi
}

# ---------- Main ----------
main() {
    parse_args "$@"
    need_root
    local tag="auto"
    [[ -n "$MNT" ]] && tag=$(echo "$MNT" | sed 's#[/ ]#_#g; s#[^A-Za-z0-9_.-]#_#g')
    mkdir -p "$LOGDIR"
    LOGFILE="${LOGDIR}/grow_xfs_${tag}_$(date +%Y%m%dT%H%M%S).log"
    : >"$LOGFILE"
    log "Logging to: $LOGFILE"

    if [[ -z "$MNT" ]]; then
        discover_target_from_metadata
    else
        BASE_PATH="${BASE_PATH:-$(get_metadata_path || echo "")}"
        [[ -n "$BASE_PATH" ]] && echo -e "\nMetadata location: $BASE_PATH" | tee -a "$LOGFILE"
        echo "Target mountpoint: $MNT" | tee -a "$LOGFILE"
    fi

    # Dry-run banner
    if [[ "${DRY_RUN}" == "true" ]]; then
        section "Dry-run mode"
        echo "• Probes WILL run (discovery, prints, simulations)" | tee -a "${LOGFILE}"
        echo "• Mutations WILL NOT run (device rescans, growpart/resize, pvresize/lvextend, xfs_growfs, copies, installs)" | tee -a "${LOGFILE}"
    fi

    ensure_requirements
    discovery_report
    [[ "$REPORT_ONLY" == "true" ]] && {
        log "--report-only specified; stopping after discovery."
        exit 0
    }

    # === PRE-COPY (if partition) ===
    ensure_precopy_if_needed

    # ----------- Device rescan -----------
    section "Device rescan (per-disk)"
    mapfile -t __DISKS < <(_base_disks_for_mount "$MNT")
    if [[ "${#__DISKS[@]}" -eq 0 ]]; then
        warn "Could not determine base disks for $MNT; attempting fallback host scan."
        _fallback_host_scan
    else
        printf "Disks to rescan: %s\n" "${__DISKS[*]}" | tee -a "$LOGFILE"
        local any_ok="false"
        for d in "${__DISKS[@]}"; do
            if _rescan_one_base_disk "$d"; then any_ok="true"; fi
        done
        if [[ "$any_ok" != "true" ]]; then
            warn "Per-disk rescan nodes not available; attempting fallback host scan."
            _fallback_host_scan
        fi
    fi
    have_cmd udevadm && probe "udevadm settle"

    # ----------- Grow -----------
    section "Resize Actions"
    SRC=$(findmnt -n -o SOURCE --target "$MNT")
    if [[ "$SRC" =~ ^/dev/mapper/ || "$SRC" =~ ^/dev/dm- ]]; then
        # LVM path
        LV_PATH=$(readlink -f "$SRC")
        VG_NAME=$(lvs --noheadings -o vg_name "$LV_PATH" | awk '{$1=$1};1')
        mapfile -t PVS < <(pvs --noheadings -o pv_name --select "vg_name=${VG_NAME}" | awk '{$1=$1};1')
        for PV in "${PVS[@]}"; do
            grow_partition_if_needed "$PV"
            run_mut "pvresize $PV"
        done
        if ! run_mut "lvextend -l +100%FREE -r $LV_PATH"; then
            warn "lvextend -r failed; retrying without -r then xfs_growfs..."
            run_mut "lvextend -l +100%FREE $LV_PATH"
        fi
        run_mut "xfs_growfs $MNT"
    else
        # Non-LVM path
        grow_partition_if_needed "$SRC"
        PARENT_KNAME="$(_get_parent_kname "$SRC")"
        if have_cmd partprobe && [[ -n "$PARENT_KNAME" ]]; then run_mut "partprobe /dev/${PARENT_KNAME}"; fi
        run_mut "xfs_growfs $MNT"
    fi

    # Optional cleanup of backup
    cleanup_precopy_if_requested

    # Post-change discovery
    section "Post-Change Discovery"
    collect_mount_fs_info
    collect_block_graph
    collect_partition_tables_for_chain
    collect_lvm_info_if_any
    log "All done. Full report: $LOGFILE"
}

main "$@"
