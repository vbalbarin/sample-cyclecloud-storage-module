#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/storage-lib.sh"

SCRATCH="${SCRATCH_MOUNTPOINT:-/mnt/scratch}"
CHECK_RAID="${CHECK_RAID:-auto}"   # auto|require|skip
CHECK_IO="${CHECK_IO:-1}"          # 1=attempt fio lite test, 0=skip

fail() { echo "[FAIL] $*"; exit 1; }
pass() { echo "[PASS] $*"; }

echo "=== STORAGE END-TO-END VALIDATION ==="

echo "Scratch mountpoint: $SCRATCH"
mountpoint -q "$SCRATCH" || fail "Scratch mountpoint not mounted: $SCRATCH"
pass "Scratch mount exists"

DEVICE="$(findmnt -n -o SOURCE --target "$SCRATCH" 2>/dev/null || true)"
[ -n "$DEVICE" ] || fail "Unable to determine backing device for $SCRATCH"
echo "Backing device: $DEVICE"
pass "Backing device identified"

TEST_FILE="$SCRATCH/.e2e_test_$$"
TEST_DATA="sample-cc-storage-test-$(date +%s)"

echo "$TEST_DATA" > "$TEST_FILE" || fail "Write failed"
sync
READ_BACK="$(cat "$TEST_FILE" || true)"
[ "$READ_BACK" = "$TEST_DATA" ] || fail "Read verification failed"
rm -f "$TEST_FILE"
pass "Write + sync + read verification passed"

if [ "$CHECK_RAID" != "skip" ]; then
  if [[ "$DEVICE" == /dev/md* ]]; then
    echo "RAID device detected: $DEVICE"
    if command -v mdadm >/dev/null 2>&1; then
      mdadm --detail "$DEVICE" >/dev/null 2>&1 || fail "mdadm cannot inspect $DEVICE"
      RAID_DISKS="$(mdadm --detail "$DEVICE" | awk '/Raid Devices/ {print $4; exit}' || echo 0)"
      [ "${RAID_DISKS:-0}" -ge 2 ] || fail "RAID device has fewer than 2 disks"
      pass "RAID validation passed"
    else
      echo "mdadm not installed; skipping detailed RAID validation"
    fi
  else
    [ "$CHECK_RAID" = "require" ] && fail "RAID required but scratch is not on /dev/md*"
    echo "Scratch is not on RAID (ok for single-disk cases): $DEVICE"
  fi
fi

if [ "$CHECK_IO" = "1" ]; then
  if command -v fio >/dev/null 2>&1; then
    echo "Running lightweight fio test (5s, 64M randwrite 4k)"
    fio --name=sample-cc-e2e --directory="$SCRATCH" --size=64M --rw=randwrite --bs=4k \
        --numjobs=1 --time_based --runtime=5 --group_reporting >/tmp/ohia_fio.out 2>&1 \
      || fail "fio sanity test failed"
    pass "fio sanity test passed"
  else
    echo "fio not installed; skipping I/O test"
  fi
fi

echo "=== ALL STORAGE E2E VALIDATIONS PASSED ==="
