#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/storage-lib.sh"

RUN="${RUN:-0}"
FS_TYPE="${FS_TYPE:-ext4}"

export AZURE_EPHEMERAL_AGGREGATION="${AZURE_EPHEMERAL_AGGREGATION:-auto}"
export AZURE_EPHEMERAL_MD_DEVICE="${AZURE_EPHEMERAL_MD_DEVICE:-/dev/md0}"
export AZURE_EPHEMERAL_MD_CHUNK="${AZURE_EPHEMERAL_MD_CHUNK:-512K}"
export AZURE_EPHEMERAL_MIN_DISKS="${AZURE_EPHEMERAL_MIN_DISKS:-2}"
export AZURE_EPHEMERAL_FORCE_REFORMAT="${AZURE_EPHEMERAL_FORCE_REFORMAT:-0}"

echo "=== lsblk ==="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE

echo "=== root disk ==="
ROOT_DISK="$(get_root_disk || true)"
echo "root_disk=$ROOT_DISK"

echo "=== azure ephemeral path (best effort) ==="
echo "eph_path=$(get_azure_ephemeral_path "$ROOT_DISK" || echo '<none>')"

echo "=== NVMe temp disk candidates ==="
list_nvme_temp_disks || true

echo "=== config ==="
echo "AZURE_EPHEMERAL_AGGREGATION=$AZURE_EPHEMERAL_AGGREGATION"
echo "AZURE_EPHEMERAL_MD_DEVICE=$AZURE_EPHEMERAL_MD_DEVICE"
echo "AZURE_EPHEMERAL_MD_CHUNK=$AZURE_EPHEMERAL_MD_CHUNK"
echo "AZURE_EPHEMERAL_MIN_DISKS=$AZURE_EPHEMERAL_MIN_DISKS"
echo "AZURE_EPHEMERAL_FORCE_REFORMAT=$AZURE_EPHEMERAL_FORCE_REFORMAT"
echo "FS_TYPE=$FS_TYPE"

if [ "$RUN" -ne 1 ]; then
  echo "DRY RUN complete. Set RUN=1 to execute scratch setup."
  exit 0
fi

echo "=== executing ensure_scratch_on_azure_ephemeral_with_raid0 ==="
ensure_scratch_on_azure_ephemeral_with_raid0 "/mnt/scratch" "$FS_TYPE"

echo "=== mounts (scratch/raid) ==="
mount | grep -E '/mnt/scratch|/mnt/azure-ephemeral|/mnt/azure-ephemeral-raid|/dev/md' || true

ls -la /mnt/scratch || true
