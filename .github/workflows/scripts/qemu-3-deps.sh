######################################################################
# 3) Wait for VM to boot from previous step and launch dependencies
#    script on it.
#
# qemu-3-deps.sh [--poweroff] OS_NAME [ARCH] [FEDORA_VERSION]
#
# --poweroff: Power off the VM after installing dependencies
# OS_NAME: OS name (like 'fedora41')
# ARCH: architecture (x86_64 or aarch64, default x86_64)
# FEDORA_VERSION: (optional) Experimental Fedora kernel version, like "6.14" to
#     install instead of Fedora defaults.
######################################################################

# Consume --poweroff if present
POWEROFF=""
if [ "${1:-}" = "--poweroff" ]; then
  POWEROFF="--poweroff"
  shift
fi
OS="${1:-}"
ARCH="${2:-x86_64}"
# Shift past OS and ARCH so "$@" contains only the optional FEDORA_VERSION
shift 2 2>/dev/null || true

if [ "$ARCH" = "aarch64" ]; then
  QEMU_BIN="/usr/bin/qemu-system-aarch64"
else
  QEMU_BIN="/usr/bin/qemu-system-x86_64"
fi

.github/workflows/scripts/qemu-wait-for-vm.sh vm0 $ARCH

# SPECIAL CASE:
#
# If the user passed in an experimental kernel version to test on Fedora,
# we need to update the kernel version in zfs's META file to allow the
# build to happen.  We update our local copy of META here, since we know
# it will be rsync'd up in the next step.
#
# Look to see if the last argument looks like a kernel version.
ver="${@: -1}"
if [[ $ver =~ ^[0-9]+\.[0-9]+ ]] ; then
  # We got a kernel version, update META to say we support it so we
  # can test against it.
  sed -i -E 's/Linux-Maximum: .+/Linux-Maximum: '$ver'/g' META
fi

scp .github/workflows/scripts/qemu-3-deps-vm.sh zfs@vm0:qemu-3-deps-vm.sh
PID=$(pidof $QEMU_BIN || true)
ssh zfs@vm0 '$HOME/qemu-3-deps-vm.sh' $POWEROFF "$OS" "$@"
# wait for poweroff to succeed (if we have a valid PID)
if [ -n "$PID" ]; then
  tail --pid=$PID -f /dev/null
fi
sleep 5 # avoid this: "error: Domain is already active"
rm -f $HOME/.ssh/known_hosts
