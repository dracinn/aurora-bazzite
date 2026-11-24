# aurora-bazzite

<p align="center"><img src="https://raw.githubusercontent.com/ublue-os/bazzite/main/press_kit/Bazzite_Color.svg" width="160" alt="Bazzite"></p>

[Bazzite](https://bazzite.gg) — the Universal Blue gaming OS — ported to **Apple Silicon**, built on Fedora 44 aarch64 and the [Aurora Silicon](https://github.com/aurora-silicon) hardware stack, delivered through the notarized Aurora Installer for macOS.

Bazzite upstream (`ublue-os/bazzite`) and the ublue COPRs publish **x86_64 only**, so this is not a rebase: the build reproduces Bazzite's own spec — its os-release identity, `image-info.json`, `ujust` recipes, `bazzite-*` services and scripts, tuned profiles, branding, and flatpak seeding — on Fedora's multiarch bootc base, with the Terra repository (which does build aarch64) supplying the ublue-adjacent packages.

## What's in the image

### Aurora Silicon hardware layer (required to boot/function)

- `kernel-aurora` (16 KiB pages) + `aurora-userpages` for per-process 4 KiB, with bootc kargs
- `aurora-platform`, `aurora-firmware`, `aurora-wifi-firmware`, `avd-fw`
- `mesa-aurora-dri-drivers` / `mesa-aurora-vulkan-drivers` (Apple GPU), `aurora-flatpak-gl`
- Audio: `alsa-ucm-conf-aurora`, `aurora-audio`, `speakerguardd-v2`, `speakersafetyd-aurora-profiles`
- `aurora-sep` (Touch ID sudo via authselect vendor profile), camera/keyboard, `upower` fork
- Bootchain: `update-m1n1`, `uboot-aurora` — m1n1/Aura → U-Boot → GRUB stays maintained after install
- Aurora repo at `priority=1` — its patched forks (kwin, mutter, pipewire, NetworkManager, fex-emu, steam) win when requested

### Bazzite layer (faithful port, files vendored from upstream)

- Identity: `NAME="Bazzite"` os-release, `VARIANT_ID=bazzite`, purple `ANSI_COLOR`, `bazzite-logo` icons, `/usr/share/ublue-os/image-info.json`
- `ujust` → real Bazzite recipes (`/usr/share/ublue-os/just/*.just` + kinoite's `90-bazzite-de.just`)
- `bazzite-steam`/`bazzite-steam-bpm`/`bazzite-steam-firstrun` wrappers, `bazzite-rollback-helper`
- First-boot services: `bazzite-flatpak-manager`, `bazzite-hardware-setup`, `bazzite-user-setup`, `bazzite-dynamic-fixes` — plus their libexecs, polkit actions, MOTD, fastfetch config, bling
- Bazzite wallpapers (`convergence`, `giants`, `penguins`, …), `org.bazzite.desktop` look-and-feel, panel pins (`bazzite-pins.js`), plymouth spinner watermark
- Flatpak list seeded by the manager (Firefox, KDE apps, DistroShelf, Gear Lever, Flatseal, Warehouse, ProtonUp-Qt, MangoHud/vkBasalt/OBSVkCapture layers, OBS plugins, Bazaar)

### Gaming stack

- `steam` — Valve's native ARM64 client + `aurora-steam-native` (4 KiB-page wrapper)
- `fex-emu` + `fex-emu-steam` + `fex-emu-thunks` — FEX registered as a Steam compatibility tool; x86 games via Proton/FEX, `mesa-aurora-fex-guest` gives guests real GPU acceleration
- `fex-emu-rootfs-fedora`, `aurora-gamemode` (pins games to P-cores), `gamemode`
- `mangohud`, `goverlay`, `gamescope`, `vkBasalt`, `lutris`, `corectrl`, `distrobox`

### Bazzite package set (aarch64-available subset)

- From **Terra**: `umu-launcher`, `umu-wrapper`, `uupd`, `bazzite-updater`, `bazzite-portal`, `ScopeBuddy`, `cardwire`, `dmemcg-booster` + `plasma-foreground-booster-dmemcg`, `ls-iommu`, `topgrade`, `starship`, `webapp-manager`, `rom-properties`, `game-devices-udev`, `udev-joystick-blacklist-rm`, `cicpoffs`, `vulkan-low-latency-layer`
- From **Fedora**: `bees`, `input-remapper`, `waydroid`, `ptyxis`, `snapper` + `btrfs-assistant` + `btrfsmaintenance`, cockpit suite, `tailscale`, `fish`, `btop`, `fastfetch`, `ydotool`, `msedit`, `openrgb`, `tuned` + `tuned-ppd` (default profile `balanced-bazzite`), libvirt/qemu/virt-manager + `edk2-aarch64`, fonts, and the usual Bazzite CLI tooling
- RPM Fusion ffmpeg (full codecs) + Flathub remote

### Skipped (no aarch64 builds exist)

`bazaar`/`krunner-bazaar` RPMs (Bazaar installs as a flatpak instead), `steamdeck-kde-presets`, `greenboot`, `scx-scheds`, `hhd`, `xwiimote-ng`, `ublue-os-just` (base justfile vendored instead), all Steam Deck firmware/dock packages.

# Community

- [Aurora Silicon Discord](https://discord.com/invite/DXmsSSc5aY) — Apple Silicon hardware stack, installer, kernel
- [Bazzite / Universal Blue Forums](https://universal-blue.discourse.group/) — upstream distribution this ports
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions) — image and rebase questions

# Building

Prerequisites (macOS on Apple Silicon, or aarch64 Linux):

```bash
brew install podman just jq cosign
```

`just` creates/starts a rootful podman machine automatically; a rootful machine is required for the disk-image recipes.

```bash
just build          # podman build, linux/arm64 OCI image + bootc container lint
just build-raw      # raw disk image via bootc-image-builder → output/image/disk.raw
```

## Installing on a Mac (Aurora Installer path)

The installer consumes a **payload**, not a raw disk:

```bash
just bundle "" "" fedora-kde   # → output/bundle/ (profile name must be an installer profile)
just payload                   # → output/payload/: <profile>-<date>.zip,
                               #   installer-data-<profile>.json, delivery.json
```

`bundle` runs `installer/finalize-image` (vendored from
[aurora-silicon/aurora-platform](https://github.com/aurora-silicon/aurora-platform), MIT) inside the
podman machine: combined Stage 2 via `update-m1n1`, staged on the ESP, sealed
firstboot state, hardened GRUB, initramfs rebuilt with the `aurora-root` dracut
module, then the disk is split into the installer's bundle format.

`payload` clones `aurora-installer` into `.aurora-installer/` (build-time
tooling only), builds the Recovery app template via SwiftPM, and runs
`assemble-distribution-payload.py`, which digest-validates the bundle before
writing the zip. `aurora-distributions` then publishes it as a signed catalog
entry bound by SHA-256 digests. `AURORA_RECOVERY_TESTS=` re-enables the
Recovery test fixtures.

The profile must be one of the installer's known profiles (`fedora-kde`,
`fedora-gnome`, `fedora-minimal`) — a custom name requires forking the payload
schema.

## Rebasing an existing system

```bash
sudo bootc switch ghcr.io/dracinn/aurora-bazzite:latest
sudo systemctl reboot
```

On an existing Aurora/Asahi Fedora install this is **experimental**: the image
ships `kernel-aurora`, `update-m1n1` and `uboot-aurora`, but the switch path
has not been qualified the way the installer path is. Keep a working
deployment to roll back to (`bootc rollback`). On a system installed via the
Aurora Installer, `sudo bootc upgrade` tracks `latest`.

# Repository Contents

## Containerfile

[Containerfile](./Containerfile) builds `linux/arm64` from
`quay.io/fedora/fedora-bootc:44` — the release the Aurora `44/testing/aarch64`
repo channel targets (`aurora.repo` uses `$releasever`). Runs
`build_files/build.sh`, then `bootc container lint`.

## build_files/build.sh

[build.sh](./build_files/build.sh), in order:

1. Copies `system_files/` into the image — Aurora + Terra repo files and signing keys, bootc kargs, and the vendored Bazzite tree (see below)
2. Removes the stock Fedora kernel, installs `kernel-aurora` (masking the `05-rpmostree.install` dracut hook for the transaction)
3. Installs the Aurora hardware stack (`--allowerasing` so its forks replace stock mesa/upower/…)
4. `aurora-release`/`aurora-repos`/`aurora-logos`/`aurora-remix-scripts` — supplies `system-release` and keeps the hardware repo configured
5. KDE Plasma (`@kde-desktop-environment` + `plasma-setup` first-boot wizard, `plasmalogin`)
6. Gaming stack (steam/FEX/mangohud/gamescope/lutris/…)
7. Bazzite package set from Terra + Fedora
8. RPM Fusion codecs + Flathub remote
9. Bazzite identity: os-release rewrite, `image-info.json`, `org.bazzite.desktop` LnF, panel pins, plymouth, `balanced-bazzite` tuned profile, service enables
10. Re-removes the stock kernel (a package-set dep pulls it back), regenerates initramfs with the `ostree` dracut module
11. Materializes the `lp`/`printadmin` static groups into `/etc/group` so the bootc var-tmpfiles lint can resolve `/var` ownership
12. Rebuilds the authselect vendor profile for Touch ID

## system_files/

| Path | Source / purpose |
|---|---|
| `etc/yum.repos.d/aurora.repo`, `etc/pki/rpm-gpg/RPM-GPG-KEY-aurora` | Aurora repo + key (fingerprint `D6C974933C41AACE00AE3C4591B639B8C6A77AC1`, recorded upstream in `fedora-aurora/keys/fingerprint.txt`) |
| `etc/yum.repos.d/terra.repo`, `etc/pki/rpm-gpg/RPM-GPG-KEY-terra` | Terra 44 repo + key (`AE09157A4DE88B497EA1D5D300CDAB43DE226D6F`) |
| `usr/lib/bootc/kargs.d/10-aurora.toml` | `user4k=on` + Aurora quiet-boot kargs |
| `usr/bin/{ujust,bazzite-steam*,bazzite-rollback-helper}` | Bazzite wrappers; `ujust` execs `just --justfile /usr/share/ublue-os/justfile` |
| `usr/libexec/{bazzite-*,hwsupport,ublue-motd,uupd-update,waydroid-*}` | Bazzite first-boot/helper scripts |
| `usr/lib/systemd/{system,user}/bazzite-*.service` | flatpak-manager, hardware-setup, user-setup, dynamic-fixes |
| `usr/lib/tuned/profiles/*-bazzite` | `balanced`/`powersave`/`throughput-performance` (+ `-battery`) tuned profiles |
| `usr/share/ublue-os/` | justfile + `just/*.just` recipes, `bazzite/` assets (fastfetch config, MOTD, firefox-config, flatpak list, eol list), homebrew Brewfiles |
| `usr/share/wallpapers/` | Bazzite wallpaper set |
| `usr/share/plasma/lookandfeel/org.bazzite.desktop` | BreezeDark + convergence wallpaper for new users |
| `usr/share/plasma/shells/.../updates/bazzite-pins.js` | pinned-taskbar applets, appended to `layout.js` at build |
| `usr/share/icons/hicolor/**` | `bazzite-logo`/`bazzite-logo-icon`/distributor-logo |
| `usr/share/plymouth/themes/spinner/watermark.png` | boot-splash watermark |
| `etc/skel/.config/autostart/` | `steam.desktop` (`bazzite-steam -silent`), `bazzite-portal.desktop` |
| `etc/xdg/autostart/bazzite-announcement.desktop` | Bazzite welcome/news |
| `etc/profile.d/bazzite-neofetch.sh`, `usr/share/{bazzite-cli,fish}` | shell bling |

## Workflows

- [build.yml](./.github/workflows/build.yml) — builds on a native arm64 runner (`ubuntu-26.04-arm`), rechunks, pushes to GHCR, cosign-signs. Requires the `SIGNING_SECRET` repository secret (`cosign.key`).
- [build-disk.yml](./.github/workflows/build-disk.yml) — `bootc-image-builder` disk images (qcow2/raw) for the installer path; optional S3 upload via rclone secrets.

## Installer tooling

`installer/` — vendored pieces of the Aurora installer pipeline (`finalize-image`, `harden-grub.py`); `scripts/` — bundle/payload assembly and qualification (`make-installer-bundle.sh`, `assemble-payload.sh`, `check-bundle.sh`); `disk_config/` — bootc-image-builder customizations.

## artifacthub-repo.yml

Optional [artifacthub.io](https://artifacthub.io) indexing — fill in your repository ID and owners.

# Acknowledgements

- [ublue-os/bazzite](https://github.com/ublue-os/bazzite) — the distribution and spec this image ports (`system_files` vendored under their license)
- [Aurora Silicon](https://github.com/aurora-silicon) — kernel, hardware enablement, installer, signing infrastructure
- [ublue-os/image-template](https://github.com/ublue-os/image-template) — repository skeleton, Justfile, and CI workflows
- [Fyra Labs / Terra](https://terra.fyralabs.com) — the ublue-adjacent packages built for aarch64
