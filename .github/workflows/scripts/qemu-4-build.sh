#!/usr/bin/env bash

######################################################################
# 4) configure and build openzfs modules
#
# Usage: qemu-4-build.sh [--patch-level N] [--custom-branch B] \
#           [--repo] [--release] [--dkms] [--tarball] <OS> <ARCH>
#
# OS:   OS name (like 'ubuntu26')
# ARCH: architecture (x86_64 or aarch64, default x86_64)
######################################################################

# Parse arguments to separate build-vm args from the trailing OS and ARCH.
# All arguments except the last two are forwarded to qemu-4-build-vm.sh.
BUILD_ARGS=()
while [ $# -gt 2 ]; do
  BUILD_ARGS+=("$1")
  shift
done
OS="${1:-}"
ARCH="${2:-x86_64}"

echo "Build modules in QEMU machine"

# Bring our VM back up and copy over ZFS source
.github/workflows/scripts/qemu-prepare-for-build.sh $ARCH

ssh zfs@vm0 '$HOME/zfs/.github/workflows/scripts/qemu-4-build-vm.sh' "${BUILD_ARGS[@]}" "$OS"
