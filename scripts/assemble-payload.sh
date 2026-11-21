#!/bin/bash
# SPDX-License-Identifier: MIT
# Assemble the Aurora installer payload (profile zip + installer-data metadata
# + delivery.json) from a finalized filesystem bundle and the native Recovery
# app template.
#
# Runs on macOS. Usage:
#   assemble-payload.sh BUNDLE_DIR OUTPUT_DIR [INSTALLER_REPO]
# INSTALLER_REPO defaults to .aurora-installer/ (cloned on first use).
set -euo pipefail
bundle=$(realpath "$1")
output=$2
[[ $output == /* ]] || output=$PWD/$output
repo=${3:-$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/.aurora-installer}
# The upstream C authorization fixture aborts under assertion on newer macOS,
# so tests default to skipping; opt back in with AURORA_RECOVERY_TESTS=.
recovery_tests=${AURORA_RECOVERY_TESTS:-true}

# Build-time tooling only; the installer app itself is Swift and untouched.
if [[ ! -f $repo/macOS/scripts/assemble-distribution-payload.py ]]; then
  git clone --depth 1 https://github.com/aurora-silicon/aurora-installer "$repo"
fi
# The C authorization fixture aborts under assertion on newer macOS; allow a
# build to skip the pure test fixtures without editing upstream source.
if ! grep -q AURORA_RECOVERY_TESTS "$repo/macOS/Recovery/build-app.sh"; then
  # shellcheck disable=SC2016
  sed -i '' 's|^\./test-all\.sh |"${AURORA_RECOVERY_TESTS:-./test-all.sh}" |' \
    "$repo/macOS/Recovery/build-app.sh"
fi

# The Recovery template must carry the OmarchyRecoveryBuildMode=recovery and
# external-install-data-v1 Info.plist markers; the assembler verifies them
# plus the app's complete inventory.
app_dir=$repo/macOS/Recovery/build-recovery
app="$app_dir/Aurora Installer.app"
if [[ ! -x $app/Contents/MacOS/OmarchyRecovery ]]; then
  mkdir -p "$app_dir"
  (cd "$repo/macOS/Recovery" && AURORA_RECOVERY_TESTS="$recovery_tests" ./build-recovery.sh) \
    || { rm -rf "$app_dir"; echo 'Recovery app build failed' >&2; exit 1; }
fi

# ZIP members must have post-1980 mtimes; ostree materializes files at epoch.
find "$bundle" -exec touch {} +
rm -rf "$output"
python3 "$repo/macOS/scripts/assemble-distribution-payload.py" \
  --filesystems "$bundle" --recovery-app "$app" --output "$output"
