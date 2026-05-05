# Sample CycleCloud Storage Module

This project provides sample code for storage abstraction for Azure CycleCloud HPC clusters.

Before using this in production, users should validate its functioning.

Portions of this code were generated with the assistance of Copilot.

The CycleCloud project files are incomplete.

The scripts provide a suggestion of how to account for the availability/non-availability of NVMe temporary disks across Azure SKUs.

For builders of custom images, it is recommended that they create universal images that contain the necessary NVMe drivers.

## Goals
- Provide stable mountpoints: `/mnt/scratch` (node-local scratch) and `/shared` (cluster shared FS).
- Prefer Azure **ephemeral (temp/resource) storage** for scratch when available.
- Support v6 NVMe temp disks that can appear **raw/unformatted** after allocation/deallocation.
- Optional **RAID-0 aggregation** (mdadm) when multiple NVMe temp disks exist.
- Never touch the OS/root disk.
- Remain compatible with cloud-init / waagent behavior by avoiding persistent fstab entries for ephemeral scratch.

## Key Paths
- Library: `specs/execute/cluster-init/scripts/lib/storage-lib.sh`
- Entrypoint: `specs/execute/cluster-init/scripts/00_storage_setup.sh`
- Compatibility wrapper: `specs/execute/cluster-init/scripts/nvme-check.sh`
- Tests: `specs/execute/cluster-init/scripts/tests/`

## Configuration
Default config is installed to `/etc/cyclecloud/storage.conf`.

### Scratch controls
- `STORAGE_SCRATCH_MODE`: `auto` (default) | `none`
- `SCRATCH_MOUNTPOINT`: default `/mnt/scratch`
- `FS_TYPE`: `ext4` (default) | `xfs`
- `SCRATCH_REQUIRED`: `true` | `false` (default false)

### Ephemeral aggregation (RAID-0) controls
- `AZURE_EPHEMERAL_AGGREGATION`: `auto` (default) | `mdadm` | `none`
- `AZURE_EPHEMERAL_MIN_DISKS`: default `2`
- `AZURE_EPHEMERAL_MD_DEVICE`: default `/dev/md0`
- `AZURE_EPHEMERAL_MD_CHUNK`: default `512K`
- `AZURE_EPHEMERAL_FORCE_REFORMAT`: default `0`

### Shared storage controls
- `STORAGE_SHARED_MODE`: `none` (default) | `nfs` | `anf`
- `SHARED_MOUNTPOINT`: default `/shared`
- `NFS_SERVER`, `NFS_EXPORT`, `NFS_MOUNT_OPTS`

## Usage
### Run manually on a node
```bash
sudo /mnt/cluster-init/sample-cc-storage-module/execute/scripts/00_storage_setup.sh
```

## Tests
### RAID0-focused test (dry run)
```bash
cd /mnt/cluster-init/sample-cc-storage-module/execute/scripts/tests
sudo ./test_ephemeral_raid0.sh
```

### RAID0-focused test (execute)
```bash
cd /mnt/cluster-init/sample-cc-storage-module/execute/scripts/tests
sudo RUN=1 ./test_ephemeral_raid0.sh
```

### End-to-end storage validation (mount + write + optional RAID verification)
```bash
cd /mnt/cluster-init/sample-cc-storage-module/execute/scripts/tests
sudo ./test_storage_end_to_end.sh
```

To require RAID for HPC partitions:
```bash
export CHECK_RAID=require
sudo ./test_storage_end_to_end.sh
```

---
