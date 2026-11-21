#!/bin/bash
# SPDX-License-Identifier: MIT
# Seal a bootc-image-builder raw disk into an Aurora installer filesystem
# bundle (image.json + boot.img + root.img + esp/ + stage2.json).
#
# Runs inside a privileged container on an aarch64 Linux host (the podman
# machine VM). Usage:
#   make-installer-bundle.sh DISK_RAW PROFILE OUTPUT_DIR
# PROFILE is one of the installer's known profiles: fedora-kde, fedora-gnome,
# or fedora-minimal.
set -euo pipefail
disk=$(realpath "$1")
profile=${2:?installation profile required (fedora-kde|fedora-gnome|fedora-minimal)}
output=$(realpath -m "$3")
here=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
loop=
saved_policy=
cleanup() {
  local status=$?
  trap - EXIT
  if mountpoint -q "$work/esp-mnt" 2>/dev/null; then umount "$work/esp-mnt"; fi
  [[ -z $loop ]] || losetup -d "$loop" 2>/dev/null || true
  [[ -z $saved_policy ]] || load_policy -i "$saved_policy" 2>/dev/null || true
  rm -rf "$work" ${saved_policy:+"$saved_policy"}
  exit "$status"
}
trap cleanup EXIT

# finalize-image seals the rootfs with Fedora targeted SELinux contexts; a
# builder kernel enforcing a foreign policy rejects them. Load the image's
# own policy for the duration, then restore the builder's.
policy_bin=$(for p in /etc/selinux/targeted/policy/policy.*; do echo "$p"; done | sort -V | tail -n 1)
if [[ -n $policy_bin ]]; then
  mountpoint -q /sys/fs/selinux 2>/dev/null || mount -t selinuxfs selinuxfs /sys/fs/selinux 2>/dev/null || true
  if [[ -w /sys/fs/selinux/load ]]; then
    saved_policy=$(mktemp)
    cat /sys/fs/selinux/policy > "$saved_policy" 2>/dev/null || saved_policy=
    if [[ -n $saved_policy ]]; then
      load_policy -i "$policy_bin" 2>/dev/null || saved_policy=
    fi
  fi
fi

# Combined Stage 2 (m1n1 + U-Boot + every board DTB). With no live device
# tree, update-m1n1 keeps every retained kernel's trees — exactly the
# combined boot.bin the payload assembler splits per board.
TARGET="$work/boot.bin" update-m1n1
[[ -s $work/boot.bin ]] || { echo 'update-m1n1 produced no Stage 2' >&2; exit 1; }

# Stage it on the raw disk's ESP. finalize-image asserts its presence and
# prepare-stage2.py then derives boot-<board>.bin + stage2.json from it.
sector_size=512
[[ $(dd if="$disk" bs=1 skip=4096 count=8 status=none 2>/dev/null || true) == 'EFI PART' ]] && sector_size=4096
loop=$(losetup --find --show --partscan --sector-size "$sector_size" "$disk")
udevadm settle 2>/dev/null || true
mkdir -p "$work/esp-mnt"
mount "${loop}p1" "$work/esp-mnt"
install -Dm644 "$work/boot.bin" "$work/esp-mnt/m1n1/boot.bin"
sync
umount "$work/esp-mnt"
losetup -d "$loop"
loop=

# Seal the disk into the installer bundle: ESP copy + aurora/stage1.{bin,macho},
# per-board Stage 2 split + stage2.json, boot.img/root.img dd'd out, image.json.
"$here/../installer/finalize-image" "$disk" "$profile" "$output"

# This image ships aura's monitor-free marker, so boards that boot a Mach-O
# Stage 1 also need the CTXR-window Stage 2 copies chainloaded on entry.
python3 "$here/../installer/prepare-ctxr-stage2.py" "$output/esp/m1n1"
