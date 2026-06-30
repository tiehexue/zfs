#!/bin/bash
#
# Wait for a VM to boot up and become active.  This is used in a number of our
# scripts.
#
# $1: VM hostname or IP address
# $2: architecture (x86_64 or aarch64, default x86_64)

ARCH="${2:-x86_64}"
if [ "$ARCH" = "aarch64" ]; then
  QEMU_BIN="/usr/bin/qemu-system-aarch64"
else
  QEMU_BIN="/usr/bin/qemu-system-x86_64"
fi

MAX_WAIT=900  # 15 minutes
START_TIME=$(date +%s)

while pidof $QEMU_BIN >/dev/null; do
  ELAPSED=$(($(date +%s) - START_TIME))
  if ssh -o ConnectTimeout=5 2>/dev/null zfs@$1 "uname -a" ; then
    echo "VM $1 is ready after ${ELAPSED}s"
    exit 0
  fi
  if [ $ELAPSED -gt $MAX_WAIT ]; then
    echo "ERROR: Timed out waiting for VM $1 after ${MAX_WAIT}s"
    echo "QEMU process: $(pidof $QEMU_BIN)"
    exit 1
  fi
  sleep 5
done

echo "ERROR: QEMU process ($QEMU_BIN) is not running"
echo "Domain state:"
sudo virsh list --all 2>/dev/null || true
echo "---"
echo "Last 60 lines of libvirt log:"
sudo tail -60 /var/log/libvirt/qemu/openzfs.log 2>/dev/null || true
echo "---"
echo "Checking dmesg for OOM kills:"
sudo dmesg | grep -i 'oom\|out of memory\|killed process' | tail -20 || true
exit 1
