#!/bin/bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: must run as root"
    exit 1
  fi
}

get_root_disk() {
  local root_disk
  root_disk=$(lsblk -o MOUNTPOINT,PKNAME -P \
    | grep 'MOUNTPOINT="/"' \
    | grep -o 'PKNAME="[^"]*"' \
    | cut -d'"' -f2 \
    | sed 's/[0-9]*$//' \
    | head -n 1 || true)

  [ -z "${root_disk:-}" ] && return 1
  echo "$root_disk"
}

format_device() {
  local dev="$1" fstype="$2"
  case "$fstype" in
    ext4) mkfs.ext4 -F "$dev" ;;
    xfs)  mkfs.xfs  -f "$dev" ;;
    *) log "ERROR: unsupported FS_TYPE=$fstype"; return 1 ;;
  esac
}

persist_mount_uuid() {
  local dev="$1" mountpoint="$2" fstype="$3"
  local uuid
  uuid=$(blkid -s UUID -o value "$dev" || true)
  [ -z "${uuid:-}" ] && return 0
  grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $mountpoint $fstype defaults,nofail 0 2" >> /etc/fstab
}

format_and_mount_scratch_persist() {
  local dev="$1" mountpoint="$2" fstype="$3"
  mkdir -p "$mountpoint"

  if mount | grep -q " $mountpoint "; then
    log "Scratch already mounted at $mountpoint"
    return 0
  fi

  log "Formatting scratch device $dev as $fstype"
  format_device "$dev" "$fstype"

  log "Mounting $dev -> $mountpoint"
  mount "$dev" "$mountpoint"

  persist_mount_uuid "$dev" "$mountpoint" "$fstype"
  log "Scratch ready at $mountpoint"
}

mount_nfs() {
  local server="$1" export_path="$2" mountpoint="$3" opts="$4"
  mkdir -p "$mountpoint"
  mount | grep -q " $mountpoint " && { log "$mountpoint already mounted"; return 0; }
  log "Mounting NFS ${server}:${export_path} -> $mountpoint"
  mount -t nfs -o "$opts" "${server}:${export_path}" "$mountpoint"
}

AZURE_CANDIDATES=(
  "/dev/disk/azure/local/by-index/0-part1"
  "/dev/disk/azure/local/by-index/0"
  "/dev/disk/azure/resource-part1"
  "/dev/disk/azure/resource"
  "/dev/disk/cloud/azure_resource-part1"
  "/dev/disk/cloud/azure_resource"
)

get_azure_ephemeral_path() {
  local root_disk="${1:-}"

  local p
  for p in "${AZURE_CANDIDATES[@]}"; do
    if [ -b "$p" ]; then
      echo "$p"
      return 0
    fi
  done

  local mp
  for mp in /mnt /mnt/resource; do
    if mountpoint -q "$mp"; then
      local src
      src="$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null || true)"
      if [ -n "$src" ] && [ -b "$src" ]; then
        echo "$src"
        return 0
      fi
    fi
  done

  if [ -f /etc/fstab ]; then
    local fstab_src
    fstab_src="$(awk '$1 ~ /azure_resource/ {print $1; exit}' /etc/fstab 2>/dev/null || true)"
    if [ -n "$fstab_src" ] && [ -b "$fstab_src" ]; then
      echo "$fstab_src"
      return 0
    fi
  fi

  local nvme_disk
  nvme_disk="$(
    lsblk -dn -o NAME,TYPE,MOUNTPOINT 2>/dev/null \
      | awk '$2=="disk" && $3=="" {print $1}' \
      | awk '/^nvme[1-9][0-9]*n1$/' \
      | sort -V \
      | head -n 1
  )"

  if [ -n "$nvme_disk" ]; then
    if [ -n "$root_disk" ] && [ "$nvme_disk" = "$root_disk" ]; then
      :
    else
      if [ -b "/dev/${nvme_disk}p1" ]; then
        echo "/dev/${nvme_disk}p1"
      else
        echo "/dev/${nvme_disk}"
      fi
      return 0
    fi
  fi

  return 1
}

ensure_scratch_on_azure_ephemeral() {
  local scratch_mount="${1:-/mnt/scratch}"
  local fstype="${2:-ext4}"

  local root_disk
  root_disk="$(get_root_disk)" || return 1

  local eph
  eph="$(get_azure_ephemeral_path "$root_disk")" || return 1

  local eph_real
  eph_real="$(readlink -f "$eph" 2>/dev/null || echo "$eph")"

  if [[ "$eph_real" == "/dev/${root_disk}"* ]]; then
    log "ERROR: ephemeral candidate resolves to root disk ($eph_real)."
    return 1
  fi

  local existing_mp
  existing_mp="$(findmnt -n -o TARGET --source "$eph_real" 2>/dev/null || true)"
  if [ -n "$existing_mp" ]; then
    log "Ephemeral storage already mounted at $existing_mp (source=$eph_real)"
    mkdir -p "$existing_mp/scratch" "$scratch_mount"
    mountpoint -q "$scratch_mount" || mount --bind "$existing_mp/scratch" "$scratch_mount"
    return 0
  fi

  local staging="/mnt/azure-ephemeral"
  mkdir -p "$staging" "$scratch_mount"

  _partition_name() {
    local disk="$1"
    if [[ "$disk" == *"nvme"* ]]; then
      echo "${disk}p1"
    else
      echo "${disk}1"
    fi
  }

  _init_format_disk() {
    local disk="$1"
    local part
    part="$(_partition_name "$disk")"

    log "Initializing raw ephemeral disk: $disk -> $part ($fstype)"
    parted "$disk" --script mklabel gpt mkpart primary "$fstype" 0% 100%
    partprobe "$disk"
    format_device "$part" "$fstype"
    echo "$part"
  }

  if lsblk -dn -o TYPE "$eph_real" 2>/dev/null | grep -q '^disk$'; then
    local part
    part="$(_init_format_disk "$eph_real")"
    log "Mounting ephemeral partition $part -> $staging"
    mount "$part" "$staging"
  else
    if ! blkid "$eph_real" >/dev/null 2>&1; then
      log "Ephemeral partition unformatted: $eph_real -> formatting ($fstype)"
      format_device "$eph_real" "$fstype"
    else
      log "Ephemeral partition already has filesystem: $eph_real"
    fi
    log "Mounting ephemeral partition $eph_real -> $staging"
    mount "$eph_real" "$staging"
  fi

  mkdir -p "$staging/scratch"
  mountpoint -q "$scratch_mount" || mount --bind "$staging/scratch" "$scratch_mount"

  log "Scratch ready at $scratch_mount (Azure ephemeral)"
  return 0
}

list_nvme_temp_disks() {
  lsblk -dn -o NAME,TYPE,MOUNTPOINT 2>/dev/null \
    | awk '$2=="disk" && $3=="" {print $1}' \
    | awk '/^nvme[1-9][0-9]*n1$/' \
    | sort -V \
    | awk '{print "/dev/"$1}'
}

_is_safe_raid_member() {
  local dev="$1" root_disk="$2"
  local real
  real="$(readlink -f "$dev" 2>/dev/null || echo "$dev")"

  [[ "$real" == "/dev/${root_disk}"* ]] && return 1
  lsblk -dn -o TYPE "$real" 2>/dev/null | grep -q '^disk$' || return 1
  findmnt --noheadings --source "$real" >/dev/null 2>&1 && return 1

  local part_count
  part_count="$(lsblk -n -o TYPE "$real" | grep -c '^part$' || true)"
  [ "${part_count:-0}" -gt 0 ] && return 1

  return 0
}

create_or_reuse_raid0() {
  local md_dev="${1:-/dev/md0}"
  local chunk="${2:-512K}"
  shift 2 || true

  local disks=("$@");
  [ "${#disks[@]}" -lt 2 ] && { log "RAID0 requires >= 2 disks"; return 1; }

  command -v mdadm >/dev/null 2>&1 || { log "mdadm not found"; return 1; }

  if [ -b "$md_dev" ]; then
    log "Using existing RAID device: $md_dev"
    echo "$md_dev"
    return 0
  fi

  log "Creating RAID0: $md_dev with ${#disks[@]} disks, chunk=$chunk"
  mdadm --create "$md_dev" --level=0 --raid-devices="${#disks[@]}" --chunk="$chunk" "${disks[@]}"
  udevadm settle || true

  [ -b "$md_dev" ] || { log "Failed to create RAID device $md_dev"; return 1; }
  echo "$md_dev"
}

ensure_scratch_on_azure_ephemeral_with_raid0() {
  local scratch_mount="${1:-/mnt/scratch}"
  local fstype="${2:-ext4}"

  local agg="${AZURE_EPHEMERAL_AGGREGATION:-auto}"
  local md_dev="${AZURE_EPHEMERAL_MD_DEVICE:-/dev/md0}"
  local md_chunk="${AZURE_EPHEMERAL_MD_CHUNK:-512K}"
  local min_disks="${AZURE_EPHEMERAL_MIN_DISKS:-2}"
  local force_reformat="${AZURE_EPHEMERAL_FORCE_REFORMAT:-0}"

  local root_disk
  root_disk="$(get_root_disk)" || return 1

  local mp
  for mp in /mnt /mnt/resource; do
    if mountpoint -q "$mp"; then
      mkdir -p "$mp/scratch" "$scratch_mount"
      mountpoint -q "$scratch_mount" || mount --bind "$mp/scratch" "$scratch_mount"
      log "Scratch ready at $scratch_mount (bind from $mp)"
      return 0
    fi
  done

  if [ "$agg" != "none" ]; then
    mapfile -t nvme_disks < <(list_nvme_temp_disks)

    local safe_disks=()
    local d
    for d in "${nvme_disks[@]}"; do
      if _is_safe_raid_member "$d" "$root_disk"; then
        safe_disks+=("$d")
      fi
    done

    if [ "${#safe_disks[@]}" -ge "$min_disks" ]; then
      if command -v mdadm >/dev/null 2>&1; then
        if [ "$agg" = "mdadm" ] || [ "$agg" = "auto" ]; then
          local raid_dev
          raid_dev="$(create_or_reuse_raid0 "$md_dev" "$md_chunk" "${safe_disks[@]}")" || raid_dev=""

          if [ -n "$raid_dev" ]; then
            local staging="/mnt/azure-ephemeral-raid"
            mkdir -p "$staging" "$scratch_mount"

            if ! blkid "$raid_dev" >/dev/null 2>&1 || [ "$force_reformat" = "1" ]; then
              log "Formatting RAID device $raid_dev as $fstype (force=$force_reformat)"
              format_device "$raid_dev" "$fstype"
            else
              log "RAID device already has filesystem: $raid_dev"
            fi

            mount "$raid_dev" "$staging"
            mkdir -p "$staging/scratch"
            mountpoint -q "$scratch_mount" || mount --bind "$staging/scratch" "$scratch_mount"

            log "Scratch ready at $scratch_mount (RAID0=$raid_dev disks=${#safe_disks[@]})"
            return 0
          fi
        fi
      else
        [ "$agg" = "mdadm" ] && { log "mdadm missing but required"; return 1; }
      fi
    else
      [ "$agg" = "mdadm" ] && { log "Not enough NVMe temp disks for RAID0 (found ${#safe_disks[@]})"; return 1; }
    fi
  fi

  ensure_scratch_on_azure_ephemeral "$scratch_mount" "$fstype"
}

list_all_disks() {
  lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'
}

is_mounted_anywhere() {
  local dev="$1"
  lsblk -n -o MOUNTPOINT "$dev" | grep -qv '^$'
}

has_fs_sig() {
  local dev="$1"
  blkid "$dev" >/dev/null 2>&1
}

select_scratch_disk_nonroot() {
  local root_disk="$1" disk dev

  for disk in $(list_all_disks); do
    [ "$disk" = "$root_disk" ] && continue
    dev="/dev/$disk"
    is_mounted_anywhere "$dev" && continue
    if ! has_fs_sig "$dev"; then
      echo "$dev"
      return 0
    fi
  done

  for disk in $(list_all_disks); do
    [ "$disk" = "$root_disk" ] && continue
    dev="/dev/$disk"
    is_mounted_anywhere "$dev" && continue
    echo "$dev"
    return 0
  done

  return 1
}

debug_topology() {
  log "=== lsblk ==="
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
  log "=== blkid ==="
  blkid || true
  log "=== mdadm (if present) ==="
  command -v mdadm >/dev/null 2>&1 && mdadm --detail --scan || true
}
