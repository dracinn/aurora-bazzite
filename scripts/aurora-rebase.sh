#!/usr/bin/bash
set -euo pipefail

_on_error() {
    local rc=$?
    echo "" >&2
    echo "ERROR: script failed at line ${BASH_LINENO[0]} (exit code ${rc})." >&2
    echo "Command: ${BASH_COMMAND}" >&2
    echo "" >&2
}
trap _on_error ERR

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# aurora-bazzite conversion: turn a running Fedora Aurora Remix (traditional
# dnf) install into an atomic system, in place, WITHOUT touching the
# m1n1 -> U-Boot -> GRUB boot chain.
#
# Adapted from ublue-os/bazzite PR #2155's just_scripts/asahi-rebase.sh,
# simplified because our target image is already published: instead of
# building bazzite-arm locally, deploying an intermediate atomic base and
# rebasing on first boot, we pull the published aurora-bazzite image into a
# fresh ostree stateroot and deploy it directly.
#
# Run on a freshly installed Fedora Aurora Remix (KDE or Minimal).
# Prerequisites: sudo dnf upgrade -y && reboot  (before running this)
#
# What this script does:
#   1. Installs ostree (dnf) if missing
#   2. Initializes an ostree stateroot on the running system's root partition
#   3. Pulls ghcr.io/dracinn/aurora-bazzite into /ostree/repo
#   4. Deploys it with root=UUID / rootflags / user4k=on kernel args
#   5. Injects /boot + /boot/efi into the deployment's fstab (Aurora keeps
#      these on separate partitions, like Asahi)
#   6. Injects a user account into the new deployment so you can log in
#   7. Regenerates GRUB config and reboots into aurora-bazzite
#
# Safe to re-run after failures: skips steps already completed.
# Force re-deploy: OSTREE_FORCE_DEPLOY=1 bash scripts/aurora-rebase.sh
# Override target image: TARGET_IMAGE=ostree-unverified-registry:... bash ...

TARGET_IMAGE="${TARGET_IMAGE:-ostree-unverified-registry:ghcr.io/dracinn/aurora-bazzite:latest}"
STATEROOT="fedora"

echo "Target image: ${TARGET_IMAGE}"

# ──────────────────────────────────────────────────────────────────────────────
# Step 0: Preflight + collect user credentials up front
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$(uname -m)" != "aarch64" ]]; then
    echo "ERROR: this conversion is only for Apple Silicon (aarch64)." >&2
    exit 1
fi

if ostree admin status --sysroot=/ &>/dev/null && \
   find /ostree/deploy/*/deploy -maxdepth 1 -name '*.0' -type d 2>/dev/null | grep -q .; then
    echo "Existing ostree deployments found."
    if [[ -z "${OSTREE_FORCE_DEPLOY:-}" ]]; then
        echo "Set OSTREE_FORCE_DEPLOY=1 to re-deploy anyway. Aborting." >&2
        exit 1
    fi
fi

echo ""
echo "The atomic deployment needs a login account. The account below is"
echo "injected into the new system (your current dnf user does NOT carry over)."
read -rp "Username for the atomic system [aurora]: " AURORA_USER
AURORA_USER="${AURORA_USER:-aurora}"
if [[ ! "${AURORA_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: invalid username '${AURORA_USER}'." >&2
    exit 1
fi
while true; do
    read -rsp "Password for ${AURORA_USER}: " AURORA_PASS
    echo ""
    read -rsp "Confirm password: " AURORA_PASS2
    echo ""
    [[ "${AURORA_PASS}" == "${AURORA_PASS2}" ]] && break
    echo "Passwords do not match, try again."
done
AURORA_PASS_HASH="$(openssl passwd -6 "${AURORA_PASS}")"
unset AURORA_PASS AURORA_PASS2

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: Install prerequisites
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Step 1: Install prerequisites ---"
for cmd in ostree openssl findmnt grub2-mkconfig; do
    command -v "${cmd}" >/dev/null 2>&1 && continue
    echo "Missing ${cmd}; installing..."
    sudo dnf install -y ostree grub2-tools-minimal openssl util-linux
    break
done

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: Initialize ostree repository + stateroot
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Step 2: Initialize ostree repository ---"
sudo mkdir -p /ostree/repo
if [[ ! -f /ostree/repo/config ]]; then
    sudo ostree init --repo=/ostree/repo --mode=bare
else
    echo "OSTree repo already initialized; skipping."
fi
sudo ostree config --repo=/ostree/repo set sysroot.bootloader none
sudo ostree config --repo=/ostree/repo set sysroot.readonly true

sudo mkdir -p /ostree/deploy
if [[ ! -d "/ostree/deploy/${STATEROOT}" ]]; then
    sudo ostree admin os-init "${STATEROOT}" --sysroot /
else
    echo "Stateroot '${STATEROOT}' already exists; skipping os-init."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: Pull the aurora-bazzite image into the stateroot repo
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Step 3: Pull ${TARGET_IMAGE} ---"
PULL_LOG="/var/tmp/aurora-bazzite-pull.log"
pull_ok=0
for attempt in 1 2 3; do
    echo "Pull attempt ${attempt}/3 (this is ~10 GB, may take a while)..."
    if sudo ostree container image pull /ostree/repo "${TARGET_IMAGE}" \
        2>&1 | tee "${PULL_LOG}"; then
        pull_ok=1
        break
    fi
    sleep 5
done
if [[ "${pull_ok}" -ne 1 ]]; then
    echo "ERROR: failed to pull ${TARGET_IMAGE} (log: ${PULL_LOG})" >&2
    exit 1
fi
echo "Pull complete."

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: Detect partition UUIDs
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Step 4: Detect partition UUIDs ---"
ROOT_UUID=$(sed -n 's/.*root=UUID=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null || true)
if [[ -z "$ROOT_UUID" ]]; then
    ROOT_UUID=$(findmnt -no UUID / 2>/dev/null || true)
fi
if [[ -z "$ROOT_UUID" ]]; then
    echo "ERROR: could not detect root UUID." >&2
    echo "  /proc/cmdline: $(cat /proc/cmdline)" >&2
    exit 1
fi

# Capture /boot and /boot/efi UUIDs from the RUNNING traditional system.
# Aurora (like Asahi) keeps /boot and /boot/efi on separate partitions; the
# bootc image's fstab only covers /. Without these entries the atomic system
# boots with /boot unmounted and bootc/rpm-ostree updates fail read-only.
BOOT_UUID=$(findmnt -no UUID /boot 2>/dev/null || true)
BOOT_FSTYPE=$(findmnt -no FSTYPE /boot 2>/dev/null || echo "ext4")
EFI_UUID=$(findmnt -no UUID /boot/efi 2>/dev/null || true)
echo "Root UUID: ${ROOT_UUID}"
echo "Boot UUID: ${BOOT_UUID:-NOT FOUND} (${BOOT_FSTYPE})"
echo "EFI UUID:  ${EFI_UUID:-NOT FOUND}"

# ──────────────────────────────────────────────────────────────────────────────
# Step 5: Deploy the aurora-bazzite image
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Step 5: Deploy aurora-bazzite ---"

REF=""
if sudo ostree rev-parse --repo=/ostree/repo "${TARGET_IMAGE}" &>/dev/null; then
    REF="${TARGET_IMAGE}"
fi
if [[ -z "${REF}" ]]; then
    mapfile -t _image_refs < <(sudo ostree refs --repo=/ostree/repo \
        | grep '^ostree/container/image/' || true)
    if [[ "${#_image_refs[@]}" -eq 1 ]]; then
        REF="${_image_refs[0]}"
    else
        echo "ERROR: could not resolve a single deployable ref:" >&2
        sudo ostree refs --repo=/ostree/repo >&2
        exit 1
    fi
fi
echo "Deploying ref: ${REF}"
TARGET_REV=$(sudo ostree rev-parse --repo=/ostree/repo "${REF}")

# Preserve rootflags (btrfs subvol) from the running system's cmdline.
EXISTING_KARGS=$(cat /proc/cmdline)
ROOTFLAGS_KARG=()
if [[ "$EXISTING_KARGS" =~ rootflags=([^[:space:]]+) ]]; then
    ROOTFLAGS_KARG=(--karg="rootflags=${BASH_REMATCH[1]}")
    echo "Preserving rootflags=${BASH_REMATCH[1]}"
fi

# user4k=on is REQUIRED: it enables per-process 4K userspace pages on the 16K
# kernel; FEX (x86 emulation) and the native ARM64 Steam client depend on it.
# `ostree admin deploy` does not read the image's /usr/lib/bootc/kargs.d, so
# the critical kargs are passed explicitly here.
DEPLOY_LOG="/var/tmp/aurora-bazzite-deploy.log"
PRE_DEPLOY_DIRS=$(find "/ostree/deploy/${STATEROOT}/deploy" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort || true)

if [[ -z "${OSTREE_FORCE_DEPLOY:-}" ]] && \
   sudo ostree admin status --sysroot=/ 2>/dev/null | grep -qF "${TARGET_REV:0:16}"; then
    echo "Revision already deployed; skipping (OSTREE_FORCE_DEPLOY=1 to force)."
else
    if ! sudo ostree admin deploy "${REF}" \
        --sysroot / \
        --os "${STATEROOT}" \
        --karg="root=UUID=${ROOT_UUID}" \
        --karg="ro" \
        --karg="user4k=on" \
        --karg="quiet" \
        --karg="loglevel=3" \
        --karg="rhgb" \
        "${ROOTFLAGS_KARG[@]}" 2>&1 | tee "${DEPLOY_LOG}"; then
        echo "ERROR: ostree admin deploy failed (log: ${DEPLOY_LOG})" >&2
        exit 1
    fi
fi

DEPLOY_DIR="$(comm -13 <(printf '%s\n' "${PRE_DEPLOY_DIRS}") \
    <(find "/ostree/deploy/${STATEROOT}/deploy" -maxdepth 1 -mindepth 1 -type d | sort) \
    | head -1 || true)"
if [[ -z "${DEPLOY_DIR}" || ! -d "${DEPLOY_DIR}" ]]; then
    DEPLOY_DIR=$(find "/ostree/deploy/${STATEROOT}/deploy" -maxdepth 1 -mindepth 1 -type d -name "${TARGET_REV}*" | head -1 || true)
fi
echo "Deployment dir: ${DEPLOY_DIR:-<unresolved>}"

# ──────────────────────────────────────────────────────────────────────────────
# Step 6: fstab + user injection
# ──────────────────────────────────────────────────────────────────────────────
if [[ -n "${DEPLOY_DIR}" && -d "${DEPLOY_DIR}" ]]; then
    FSTAB="${DEPLOY_DIR}/etc/fstab"
    sudo touch "${FSTAB}"

    if [[ -n "$BOOT_UUID" ]] && ! grep -q "UUID=${BOOT_UUID}" "${FSTAB}" 2>/dev/null; then
        echo "UUID=${BOOT_UUID}  /boot  ${BOOT_FSTYPE}  defaults  1  2" \
            | sudo tee -a "${FSTAB}" > /dev/null
        echo "Added /boot to deployment fstab."
    fi
    if [[ -n "$EFI_UUID" ]] && ! grep -q "UUID=${EFI_UUID}" "${FSTAB}" 2>/dev/null; then
        echo "UUID=${EFI_UUID}  /boot/efi  vfat  umask=0077,shortname=winnt  0  2" \
            | sudo tee -a "${FSTAB}" > /dev/null
        echo "Added /boot/efi to deployment fstab."
    fi

    (
        set +e
        sudo sed -i "s|^root:[^:]*:|root:${AURORA_PASS_HASH}:|" "${DEPLOY_DIR}/etc/shadow"
        if ! grep -q "^${AURORA_USER}:" "${DEPLOY_DIR}/etc/passwd" 2>/dev/null; then
            NEXT_UID=$(awk -F: 'BEGIN{max=999} $3>max && $3<60000{max=$3} END{print max+1}' \
                "${DEPLOY_DIR}/etc/passwd")
            printf '%s:x:%s:%s:%s:/home/%s:/bin/bash\n' \
                "${AURORA_USER}" "${NEXT_UID}" "${NEXT_UID}" "${AURORA_USER}" "${AURORA_USER}" \
                | sudo tee -a "${DEPLOY_DIR}/etc/passwd" > /dev/null
            printf '%s:x:%s:\n' "${AURORA_USER}" "${NEXT_UID}" \
                | sudo tee -a "${DEPLOY_DIR}/etc/group" > /dev/null
            printf '%s:%s:19900:0:99999:7:::\n' "${AURORA_USER}" "${AURORA_PASS_HASH}" \
                | sudo tee -a "${DEPLOY_DIR}/etc/shadow" > /dev/null

            # ostree persistent var lives at /ostree/deploy/<stateroot>/var —
            # this is what becomes /var after boot.
            STATEROOT_VAR="/ostree/deploy/${STATEROOT}/var"
            sudo mkdir -p "${STATEROOT_VAR}/home/${AURORA_USER}"
            sudo chown "${NEXT_UID}:${NEXT_UID}" "${STATEROOT_VAR}/home/${AURORA_USER}"

            if grep -q "^wheel:" "${DEPLOY_DIR}/etc/group" && \
               ! grep -qE "^wheel:.*[:,]${AURORA_USER}(,|$)" "${DEPLOY_DIR}/etc/group"; then
                sudo sed -i "/^wheel:/ s/$/,${AURORA_USER}/" "${DEPLOY_DIR}/etc/group"
                sudo sed -i 's/:,/:/' "${DEPLOY_DIR}/etc/group"
            fi
            echo "User '${AURORA_USER}' created in deployment (sudo via wheel)."
        else
            sudo sed -i "s|^${AURORA_USER}:[^:]*:|${AURORA_USER}:${AURORA_PASS_HASH}:|" \
                "${DEPLOY_DIR}/etc/shadow"
            echo "Password updated for existing user '${AURORA_USER}'."
        fi
    ) || echo "WARNING: user setup had errors — root is still unlocked for login."
else
    echo "WARNING: could not resolve deployment dir. Log in as root after reboot."
fi
unset AURORA_PASS_HASH

# ──────────────────────────────────────────────────────────────────────────────
# Step 7: Update GRUB (regenerate BLS enumeration, keep saved/next entries)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Step 7: Update GRUB ---"
sudo cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.backup 2>/dev/null || true
sudo mkdir -p /etc/default && sudo touch /etc/default/grub
grep -q '^GRUB_DEFAULT=' /etc/default/grub \
    && sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub \
    || echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub > /dev/null
grep -q '^GRUB_ENABLE_BLSCFG=' /etc/default/grub \
    && sudo sed -i 's/^GRUB_ENABLE_BLSCFG=.*/GRUB_ENABLE_BLSCFG=true/' /etc/default/grub \
    || echo 'GRUB_ENABLE_BLSCFG=true' | sudo tee -a /etc/default/grub > /dev/null
sudo grub2-editenv /boot/grub2/grubenv create >/dev/null 2>&1 || true

for grub_target in /etc/grub2-efi.cfg /boot/grub2/grub.cfg; do
    [[ -e "${grub_target}" || "${grub_target}" == "/boot/grub2/grub.cfg" ]] || continue
    sudo grub2-mkconfig -o "${grub_target}" 2>&1 | tail -5 || \
        echo "WARNING: grub2-mkconfig for ${grub_target} had errors."
done
if ! sudo grep -Eq 'saved_entry|next_entry' /boot/grub2/grub.cfg; then
    echo "ERROR: /boot/grub2/grub.cfg does not honor saved/next GRUB entries." >&2
    echo "GRUB selection would be ignored on reboot, stopping here." >&2
    exit 1
fi
echo "GRUB updated."

echo ""
echo "================================================="
echo "  Conversion complete!"
echo ""
echo "  On reboot you boot directly into aurora-bazzite."
echo "  Log in as '${AURORA_USER}' (password you just set)."
echo ""
echo "  If it fails to boot: pick your old Fedora entry in"
echo "  the GRUB menu (the original BLS entries are kept)."
echo "================================================="
echo ""
read -rp "Reboot now? (y/N): " reboot_confirm
if [[ "${reboot_confirm}" == [yY] ]]; then
    sudo systemctl reboot
fi
