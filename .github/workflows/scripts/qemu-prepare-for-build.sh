#!/usr/bin/env bash

# Helper script to run after installing dependencies.  This brings the VM back
# up and copies over the zfs source directory.
#
# $1: architecture (x86_64 or aarch64, default x86_64)

ARCH="${1:-x86_64}"
echo "Build modules in QEMU machine"

# The domain is created with a file-backed serial console
# (--serial file,path=/tmp/vm0-serial.log in qemu-2-start.sh), so boot output
# lands directly on disk and can be dumped when the VM fails to come up (the
# wait loop itself only sees SSH timeouts).
CONSOLE_LOG="/tmp/vm0-serial.log"
# Keep the deps-step (first boot) serial log for comparison before the
# restart below truncates the main log.
sudo cp "$CONSOLE_LOG" /tmp/vm0-serial-firstboot.log 2>/dev/null || true
sudo rm -f "$CONSOLE_LOG"
sudo virsh start openzfs

.github/workflows/scripts/qemu-wait-for-vm.sh vm0 $ARCH
RV=$?

if [ $RV -ne 0 ]; then
  echo "--- VM vm0 serial console (last 100 lines) ---"
  sudo tail -100 "$CONSOLE_LOG" 2>/dev/null || echo "(no console output captured)"
  echo "--- VM vm0 interface state ---"
  sudo virsh domiflist openzfs 2>/dev/null || true
  sudo virsh domifaddr openzfs 2>/dev/null || true
  echo "--- VM vm0 domain state ---"
  sudo virsh domstate openzfs 2>/dev/null || true
  sudo virsh qemu-monitor-command openzfs --hmp info status 2>/dev/null || true
  echo "--- VM vm0 cpu stats ---"
  sudo virsh cpu-stats openzfs 2>&1 | head -30 || true
  echo "--- VM vm0 serial devices ---"
  sudo virsh dumpxml openzfs 2>/dev/null | grep -i -B1 -A3 'serial\|console' || true
  echo "--- VM vm0 screen (if any) ---"
  sudo virsh qemu-monitor-command openzfs --hmp screendump /tmp/vm0-screen.ppm 2>/dev/null || true
  sudo ls -l /tmp/vm0-screen.ppm 2>/dev/null || true
  # Inspect the guest's boot config directly on disk (BLS entries, grub.cfg,
  # installed kernels).  The VM must be stopped to mount the disk safely.
  if command -v guestfish >/dev/null 2>&1; then
    echo "--- VM vm0 disk boot config ---"
    sudo virsh destroy openzfs 2>/dev/null || true
    sudo timeout 180 guestfish --ro -a /dev/zvol/zpool/openzfs -i sh '
      echo "== /boot kernels ==";
      ls -l /boot/vmlinuz* /boot/initramfs* 2>/dev/null;
      echo "== BLS entries ==";
      cat /boot/loader/entries/*.conf 2>/dev/null;
      echo "== /etc/default/grub ==";
      cat /etc/default/grub 2>/dev/null;
      echo "== grub.cfg terminal/serial/menu ==";
      grep -n -A2 -B2 "serial\|terminal\|menuentry\|submenu\|set root" /boot/grub2/grub.cfg 2>/dev/null;
      echo "== EFI grub.cfg (original image, if present) ==";
      head -60 /boot/efi/EFI/centos/grub.cfg 2>/dev/null;
      head -60 /boot/efi/EFI/redhat/grub.cfg 2>/dev/null;
    ' 2>&1 | tail -200 || echo "(guestfish inspection failed)"
  fi
  exit $RV
fi
rsync -ar $HOME/work/zfs/zfs zfs@vm0:./
