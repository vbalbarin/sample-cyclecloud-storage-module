#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/storage-lib.sh"

CONFIG_FILE="/etc/cyclecloud/storage.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

: "${STORAGE_SCRATCH_MODE:=auto}"          # auto|none
: "${SCRATCH_MOUNTPOINT:=/mnt/scratch}"
: "${FS_TYPE:=ext4}"                       # ext4|xfs
: "${SCRATCH_REQUIRED:=false}"             # true|false

: "${STORAGE_SHARED_MODE:=none}"           # none|nfs|anf
: "${SHARED_MOUNTPOINT:=/shared}"
: "${NFS_SERVER:=}"
: "${NFS_EXPORT:=}"
: "${NFS_MOUNT_OPTS:=defaults,_netdev,nofail}"

: "${STORAGE_DEBUG:=false}"                # true|false

require_root
[ "$STORAGE_DEBUG" = "true" ] && debug_topology

log "Storage setup starting (scratch=$STORAGE_SCRATCH_MODE shared=$STORAGE_SHARED_MODE fs=$FS_TYPE)"

# Scratch
if [ "$STORAGE_SCRATCH_MODE" = "none" ]; then
  log "Scratch disabled"
else
  if ! mountpoint -q "$SCRATCH_MOUNTPOINT"; then
    if ! ensure_scratch_on_azure_ephemeral_with_raid0 "$SCRATCH_MOUNTPOINT" "$FS_TYPE"; then
      log "Ephemeral scratch not available; falling back to non-root disk selection"
      ROOT_DISK="$(get_root_disk)" || { log "ERROR: cannot determine root disk"; exit 1; }
      if DEV="$(select_scratch_disk_nonroot "$ROOT_DISK")"; then
        format_and_mount_scratch_persist "$DEV" "$SCRATCH_MOUNTPOINT" "$FS_TYPE"
      else
        log "No fallback scratch disk found"
      fi
    fi
  fi

  if [ "$SCRATCH_REQUIRED" = "true" ] && ! mountpoint -q "$SCRATCH_MOUNTPOINT"; then
    log "ERROR: SCRATCH_REQUIRED=true but $SCRATCH_MOUNTPOINT is not mounted"
    exit 2
  fi
fi

# Shared
case "$STORAGE_SHARED_MODE" in
  none)
    log "Shared storage disabled"
    ;;
  nfs|anf)
    if [ -z "$NFS_SERVER" ] || [ -z "$NFS_EXPORT" ]; then
      log "ERROR: STORAGE_SHARED_MODE=$STORAGE_SHARED_MODE requires NFS_SERVER and NFS_EXPORT"
      exit 3
    fi
    mount_nfs "$NFS_SERVER" "$NFS_EXPORT" "$SHARED_MOUNTPOINT" "$NFS_MOUNT_OPTS"
    ;;
  *)
    log "ERROR: unsupported STORAGE_SHARED_MODE=$STORAGE_SHARED_MODE"
    exit 3
    ;;
esac

log "Storage setup complete"
