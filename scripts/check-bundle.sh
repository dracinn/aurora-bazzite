#!/bin/bash
# SPDX-License-Identifier: MIT
# Run the upstream basics check against a finalized installer bundle.
# Runs inside a privileged container on an aarch64 Linux host (the podman
# machine VM). Usage:
#   check-bundle.sh BUNDLE_DIR PROFILE
set -euo pipefail
bundle=$(realpath "$1")
profile=${2:?profile required (minimal|kde|gnome)}
here=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
loop=
cleanup() {
  local status=$?
  trap - EXIT
  mountpoint -q "$scratch/root" 2>/dev/null && umount -R "$scratch/root"
  [[ -z $loop ]] || losetup -d "$loop" 2>/dev/null || true
  rm -rf "$scratch"
  exit "$status"
}
trap cleanup EXIT

[[ -f $bundle/image.json && -f $bundle/root.img ]] || { echo 'not a finalized bundle' >&2; exit 2; }
mkdir -p "$scratch/root"
# root.img is a bare btrfs filesystem image, not a partitioned disk.
loop=$(losetup --find --show "$bundle/root.img")
mount -o subvol=root "$loop" "$scratch/root" || mount "$loop" "$scratch/root"
for deployment in "$scratch/root"/ostree/deploy/*/deploy/*.0; do
  [[ -d $deployment ]] || continue
  mount --bind "$deployment" "$scratch/root"
  break
done
read -r boot_uuid < <(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["boot_uuid"])' "$bundle/image.json")
python3 "$here/../installer/check-basics.py" \
  --profile "$profile" --root "$scratch/root" \
  --esp "$bundle/esp" \
  --boot-image "$bundle/boot.img" --boot-uuid "$boot_uuid" \
  --grub-flavor fedora --flatpak-gl
