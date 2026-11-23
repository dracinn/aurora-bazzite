#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
#
# This installs:
#   - /etc/yum.repos.d/aurora.repo
#     (the Aurora Silicon RPM repository, testing channel, with the
#      aurora-override.repo options merged in)
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

# kernel-aurora's %posttrans runs `kernel-install add`, and the
# 05-rpmostree.install hook calls dracut before depmod has produced
# modules.dep, failing the whole transaction in a container. Mask just
# that hook for the duration of the install (/etc/kernel/install.d takes
# precedence over /usr/lib/kernel/install.d); the initramfs loop further
# down generates the initramfs correctly, and the mask is removed before
# the image is committed so deployed systems keep the hook.
mkdir -p /etc/kernel/install.d
ln -s /dev/null /etc/kernel/install.d/05-rpmostree.install

dnf5 install -y \
    kernel-aurora \
    kernel-aurora-modules-extra

rm -f /etc/kernel/install.d/05-rpmostree.install
rmdir /etc/kernel/install.d 2>/dev/null || true

### Aurora Silicon hardware stack
# Package names verified against the live repository:
# https://aurorasilicon.org/fedora-aurora/44/testing/aarch64/repodata/
# --allowerasing lets Aurora's forks replace stock Fedora packages that
# conflict (e.g. mesa, upower).
dnf5 install -y --allowerasing \
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

### KDE Plasma desktop (Bazzite-class)
# Fedora's KDE environment group pulls kwin/mutter from the Aurora repo
# (priority=1 forks patched for the Apple GPU) and presets plasmalogin as
# the display manager. plasma-setup is Fedora's first-boot wizard;
# aurora-remix-scripts retires its autologin after the installer-created
# account signs in once.
dnf5 install -y --allowerasing \
    @kde-desktop-environment \
    plasma-setup
systemctl set-default graphical.target

# bootc's var-tmpfiles lint resolves the owner of every file under /var via
# /etc/group; cups (/var/spool/cups) and samba (/var/lib/samba/drivers) ship
# files owned by the /usr/lib/group statics lp and printadmin, which the
# files nsswitch cannot resolve. Materialize both into /etc/group — each has
# a matching sysusers.d entry, so the sysusers lint stays satisfied.
for spec in lp:7 printadmin:984; do
    name="${spec%%:*}" gid="${spec##*:}"
    if grep -q "^${name}:" /etc/group; then
        sed -i "s/^${name}:[^:]*:[0-9]*:/${name}:x:${gid}:/" /etc/group
    else
        echo "${name}:x:${gid}:" >> /etc/group
    fi
done

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

### Initramfs
# The kernel's initramfs was skipped during the transaction (see the
# 05-rpmostree.install mask above), so generate it here with the ostree
# module bootc needs. depmod runs first to be safe.
for module_dir in /usr/lib/modules/*/; do
    kver="$(basename "${module_dir}")"
    if [[ -f "${module_dir}/vmlinuz" && ! -f "${module_dir}/initramfs.img" ]]; then
        depmod -a "${kver}"
        DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible \
            --add ostree -f "${module_dir}/initramfs.img"
        chmod 0600 "${module_dir}/initramfs.img"
    fi
done

### authselect vendor profile
# aurora-sep ships /usr/share/authselect/vendor/local populated but without its
# .aurora-sep marker, so authselect-vendor-local refuses to touch it and the
# unguarded default system-auth template survives — with-fingerprint would then
# offer Touch ID to login/su/su-l. Remove the stale dir and let the script
# rebuild the guarded vendor profile.
rm -rf /usr/share/authselect/vendor/local
/usr/libexec/aurora/authselect-vendor-local

### Enable a System Unit File
# Aurora's packages ship their own systemd presets (e.g.
# 90-aurora-peripherals.preset); bootc applies presets on deployment.
# Enable anything extra you need here.
systemctl enable podman.socket

### Clean up
dnf5 clean all
