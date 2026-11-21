#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
#
# This installs:
#   - /etc/yum.repos.d/aurora.repo + aurora-override.repo
#     (the Aurora Silicon RPM repository, testing channel)
#   - /etc/pki/rpm-gpg/RPM-GPG-KEY-aurora
#     (repo signing key; fingerprint D6C974933C41AACE00AE3C4591B639B8C6A77AC1,
#      recorded in aurora-silicon/fedora-aurora keys/fingerprint.txt)
#   - /usr/lib/bootc/kargs.d/10-aurora.toml
#     (kernel arguments applied by bootc: user4k=on + Aurora's quiet boot set)
cp -avf "/ctx/system_files"/. /

### Apple Silicon kernel

# kernel-aurora provides installonlypkg(kernel), so it installs alongside the
# stock Fedora kernel rather than replacing it. A bootc image should carry
# exactly one kernel, so remove the Fedora kernel packages first.
for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 remove -y "$pkg"
    fi
done

dnf5 install -y \
    kernel-aurora \
    kernel-aurora-modules-extra

### Aurora Silicon hardware stack
# Package names verified against the live repository:
# https://aurorasilicon.org/fedora-aurora/44/testing/aarch64/repodata/
dnf5 install -y \
    aurora-platform \
    aurora-firmware \
    aurora-wifi-firmware \
    avd-fw \
    libva-v4l2-request-avd \
    mesa-aurora-dri-drivers \
    mesa-aurora-vulkan-drivers \
    aurora-flatpak-gl \
    alsa-ucm-conf-aurora \
    aurora-audio \
    speakerguardd-v2 \
    speakerguardd-v2-selinux \
    speakersafetyd-aurora-profiles \
    aurora-sep \
    aurora-userpages \
    aurora-kbd-light \
    aurora-camera-denoise \
    update-m1n1 \
    uboot-aurora \
    upower \
    aurora-diag

### Aurora release identity and update channel (optional)
# These make the image an Aurora remix rather than a plain Fedora one:
# aurora-release supplies system-release/os-release, aurora-repos keeps the
# RPM repository configured for updates, aurora-logos supplies branding.
# Remove this block if you want to keep the stock Fedora identity.
dnf5 install -y --allowerasing \
    aurora-release \
    aurora-logos \
    aurora-repos \
    aurora-remix-scripts

### Install additional packages

# Packages can be installed from any enabled yum repo on the image.
# The Aurora repository has priority=1, so packages it replaces
# (upower, libfprint, NetworkManager, pipewire, mutter, kwin, ...)
# come from Aurora's fork when requested here.
#
# List of Fedora packages: https://packages.fedoraproject.org/

# this installs a package from fedora repos
dnf5 install -y tmux

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

### Initramfs fallback
# kernel-aurora normally builds its initramfs via kernel-install during the
# package transaction. If a module directory ends up without one, generate it
# so `bootc container lint` passes.
for module_dir in /usr/lib/modules/*/; do
    kver="$(basename "${module_dir}")"
    if [[ -f "${module_dir}/vmlinuz" && ! -f "${module_dir}/initramfs.img" ]]; then
        DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible \
            -f "${module_dir}/initramfs.img"
        chmod 0600 "${module_dir}/initramfs.img"
    fi
done

### Enable a System Unit File
# Aurora's packages ship their own systemd presets (e.g.
# 90-aurora-peripherals.preset); bootc applies presets on deployment.
# Enable anything extra you need here.
systemctl enable podman.socket

### Clean up
dnf5 clean all
