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

### Gaming stack (Bazzite-class)
# Steam on Apple Silicon: Valve's native ARM64 client wrapped for the 4 KiB
# page process tree (aurora-steam-native), with fex-emu registered as a Steam
# compatibility tool so x86 Windows/Linux games run via Proton/FEX.
# mesa-aurora-fex-guest supplies the x86_64/i686 guest graphics stack;
# aurora-gamemode ships GameMode defaults that pin games to the P cores.
dnf5 install -y --allowerasing \
    steam \
    aurora-steam-native \
    fex-emu \
    fex-emu-steam \
    fex-emu-thunks \
    mesa-aurora-fex-guest \
    aurora-gamemode \
    gamemode \
    mangohud \
    goverlay \
    gamescope \
    vkBasalt \
    lutris \
    corectrl \
    distrobox \
    just \
    flatpak

### Bazzite package set
# Ported from ublue-os/bazzite's build spec (build_files/bazzite/*.sh), limited
# to packages with aarch64 builds. Terra (etc/yum.repos.d/terra.repo, shipped
# in system_files) carries the ublue-adjacent layer: umu-launcher, uupd,
# ScopeBuddy, bazzite-updater/portal, cardwire, dmemcg-booster, topgrade,
# starship, udev rule packs. Fedora supplies the rest.
# Not available on aarch64 and therefore skipped: bazaar/krunner-bazaar
# (Bazaar installed as a flatpak instead), steamdeck-kde-presets, greenboot,
# scx-scheds, hhd, xwiimote-ng.
dnf5 install -y --allowerasing \
    umu-launcher \
    umu-wrapper \
    uupd \
    bazzite-updater \
    bazzite-portal \
    ScopeBuddy \
    cardwire \
    cardwire-gui \
    dmemcg-booster \
    plasma-foreground-booster-dmemcg \
    ls-iommu \
    topgrade \
    starship \
    webapp-manager \
    rom-properties \
    rom-properties-kf6 \
    game-devices-udev \
    udev-joystick-blacklist-rm \
    cicpoffs \
    vulkan-low-latency-layer

dnf5 install -y --allowerasing \
    jq \
    bees \
    input-remapper \
    waydroid \
    ptyxis \
    twitter-twemoji-fonts \
    google-noto-sans-cjk-fonts \
    lato-fonts \
    fira-code-fonts \
    snapper \
    btrfs-assistant \
    btrfsmaintenance \
    cockpit-system \
    cockpit-podman \
    cockpit-storaged \
    cockpit-files \
    cockpit-networkmanager \
    tailscale \
    fish \
    btop \
    fastfetch \
    glow \
    gum \
    xdg-terminal-exec \
    linuxconsoletools \
    v4l-utils \
    ydotool \
    msedit \
    libcec \
    openrgb \
    python3-icoextract \
    lshw \
    xwininfo \
    udica \
    dbus-x11 \
    xrandr \
    evtest \
    hidapi \
    xdg-user-dirs \
    openxr \
    compsize \
    i2c-tools \
    lm_sensors \
    iio-sensor-proxy \
    stress-ng \
    lsb_release \
    kernel-tools \
    sbsigntools \
    ddcutil \
    libddcutil \
    7zip \
    lzip \
    libxcrypt-compat \
    vulkan-tools \
    tuned \
    tuned-ppd \
    ladspa-caps-plugins \
    pipewire-module-filter-chain-sofa \
    xdotool \
    wmctrl \
    yad \
    f3 \
    duf \
    gnome-disk-utility \
    oxygen-icon-theme \
    unrar \
    libvirt-daemon-kvm \
    virt-manager \
    edk2-aarch64

### Multimedia codecs
# RPM Fusion carries the full ffmpeg (Fedora's ffmpeg-free is codec-limited)
# plus the patent-encumbered gstreamer plugins.
dnf5 install -y \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
dnf5 install -y --allowerasing \
    ffmpeg \
    gstreamer1-plugins-good \
    gstreamer1-plugins-bad-free \
    gstreamer1-plugins-ugly-free \
    gstreamer1-plugin-openh264 \
    openh264

# Flathub remote for user flatpaks (Heroic, Discord, etc. — `ujust setup-flatpaks`)
flatpak remote-add --if-not-exists --system flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

### Bazzite identity
# Faithful port of upstream's image-info.sh: rewrite os-release as Bazzite and
# stamp /usr/share/ublue-os/image-info.json, which the ported bazzite-* tools
# (flatpak-manager, user-setup, ujust recipes) read at runtime.
# aurora-release stays installed for system-release/the hardware remix bits.
sed -i \
    -e 's|^NAME=.*|NAME="Bazzite"|' \
    -e 's|^PRETTY_NAME=.*|PRETTY_NAME="Bazzite 44"|' \
    -e 's|^VERSION=.*|VERSION="44 (Kinoite)"|' \
    -e 's|^ID=.*|ID=bazzite\nID_LIKE="fedora"|' \
    -e 's|^VARIANT=.*|VARIANT="Bazzite KDE"|' \
    -e 's|^VARIANT_ID=.*|VARIANT_ID=bazzite|' \
    -e 's|^DEFAULT_HOSTNAME=.*|DEFAULT_HOSTNAME=bazzite|' \
    -e 's|^LOGO=.*|LOGO=bazzite-logo|' \
    -e 's|^HOME_URL=.*|HOME_URL="https://bazzite.gg"|' \
    -e 's|^ANSI_COLOR=.*|ANSI_COLOR="0;38;2;138;43;226"|' \
    /usr/lib/os-release
grep -q '^ID_LIKE=' /usr/lib/os-release || \
    sed -i 's|^ID=bazzite|ID=bazzite\nID_LIKE="fedora"|' /usr/lib/os-release
echo "Bazzite release 44 (Forty Four)" > /etc/system-release

mkdir -p /usr/share/ublue-os
cat > /usr/share/ublue-os/image-info.json <<'EOF'
{
  "image-name": "bazzite",
  "image-flavor": "main",
  "image-vendor": "bazzite",
  "image-ref": "ostree-image-signed:docker://ghcr.io/dracinn/aurora-bazzite",
  "image-tag": "latest",
  "image-branch": "stable",
  "base-image-name": "kinoite",
  "fedora-version": "44"
}
EOF

# Default look-and-feel: dark color scheme + Bazzite convergence wallpaper for
# new users (kde-settings may already pin a LookAndFeelPackage — override it).
if [[ -f /etc/xdg/kdeglobals ]] && grep -q '^LookAndFeelPackage=' /etc/xdg/kdeglobals; then
    sed -i 's|^LookAndFeelPackage=.*|LookAndFeelPackage=org.bazzite.desktop|' /etc/xdg/kdeglobals
else
    printf '\n[KDE]\nLookAndFeelPackage=org.bazzite.desktop\n' >> /etc/xdg/kdeglobals
fi

# Upstream configure-kde: merge Bazzite's pinned-panel applets into the
# plasma layout defaults (steamdeck-kde-presets is x86-only, so the LnF
# package + pins carry the Bazzite look here).
LAYOUT=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/layout.js
if [[ -f "$LAYOUT" ]]; then
    cat /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/bazzite-pins.js >> "$LAYOUT"
fi

# Plymouth: spinner theme with the Bazzite watermark (watermark.png ships in
# system_files); KDE carries plymouth already.
if [[ -d /usr/share/plymouth/themes/spinner ]]; then
    printf '[Daemon]\nTheme=spinner\n' > /etc/plymouth/plymouthd.conf
fi

# tuned default profile (Bazzite ships throughput-performance-bazzite on
# desktops; balanced-bazzite is the laptop-friendly default for Macs).
mkdir -p /etc/tuned
echo balanced-bazzite > /etc/tuned/active_profile

# Bazzite first-boot services (user services go to the global wants dir).
systemctl enable \
    bazzite-flatpak-manager.service \
    bazzite-hardware-setup.service
systemctl enable --global \
    bazzite-user-setup.service \
    bazzite-dynamic-fixes.service

# bootc's var-tmpfiles lint resolves the owner of every file under /var via
# /etc/passwd and /etc/group; cups, samba and swtpm ship /var files owned by
# the /usr/lib statics lp, printadmin and tss, which the files nsswitch
# cannot resolve. Materialize all of them — each has a matching sysusers.d
# entry, so the sysusers lint stays satisfied.
for spec in lp:7 printadmin:984 tss:59; do
    name="${spec%%:*}" gid="${spec##*:}"
    if grep -q "^${name}:" /etc/group; then
        sed -i "s/^${name}:[^:]*:[0-9]*:/${name}:x:${gid}:/" /etc/group
    else
        echo "${name}:x:${gid}:" >> /etc/group
    fi
done
if ! grep -q "^tss:" /etc/passwd; then
    echo "tss:x:59:59:Account used for TPM access:/:/usr/sbin/nologin" >> /etc/passwd
else
    sed -i "s/^tss:[^:]*:[0-9]*:[0-9]*:/tss:x:59:59:/" /etc/passwd
fi

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
#
# Some package in the desktop/bazzite set pulls the stock Fedora kernel back
# in as a dependency; a bootc image must carry exactly one kernel, so drop it
# again before generating initramfs images.
for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 remove -y "$pkg"
    fi
done
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
