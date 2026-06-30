#!/usr/bin/env bash

# Helper script to run after installing dependencies.  This brings the VM back
# up and copies over the zfs source directory.
#
# $1: architecture (x86_64 or aarch64, default x86_64)

ARCH="${1:-x86_64}"
echo "Build modules in QEMU machine"
sudo virsh start openzfs
.github/workflows/scripts/qemu-wait-for-vm.sh vm0 $ARCH
rsync -ar $HOME/work/zfs/zfs zfs@vm0:./
