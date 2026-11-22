# aurora-bazzite

<p align="center"><img src="https://raw.githubusercontent.com/ublue-os/bazzite/main/press_kit/Bazzite_Color.svg" width="160" alt="Bazzite"></p>

A template for building your own custom [bootc](https://github.com/bootc-dev/bootc) image for **Apple Silicon**, modeled on [ublue-os/image-template](https://github.com/ublue-os/image-template) and built on the [Aurora Silicon](https://github.com/aurora-silicon) hardware stack.

The image is `linux/arm64` only. It starts from `quay.io/fedora/fedora-bootc:44`, replaces the kernel with `kernel-aurora`, and layers on Aurora's Apple Silicon packages (Mesa, firmware, audio, speaker protection, touch/camera stack) from the signed [Aurora RPM repository](https://aurorasilicon.org/fedora-aurora/44/testing/aarch64/). Universal Blue's own base images (Bazzite, Bluefin, Aurora) are x86_64-only, so they cannot be used here — hence Fedora's multiarch bootc base.

# Community

- [Aurora Silicon Discord](https://discord.com/invite/DXmsSSc5aY) — Apple Silicon hardware stack, installer, kernel
- [bootc discussion forums](https://github.com/bootc-dev/bootc/discussions) — bootc image and rebase questions
- [Universal Blue Forums](https://universal-blue.discourse.group/) — the template this is based on

# How to Use

## Step 0: Prerequisites

- A Github account
- macOS on Apple Silicon (or any aarch64 Linux host). On macOS install:

  ```bash
  brew install podman just jq cosign
  podman machine init --rootful --cpus 4 --memory 8192 --disk-size 60
  podman machine start
  ```

  `just` creates/starts a rootful podman machine automatically if you skip
  the `machine init` step. A rootful machine is required for the disk-image
  recipes. The repository should live under your `$HOME` so the podman
  machine can see it.

- A Github Actions runner is not needed on your side — the included
  workflow builds on GitHub's native arm64 runners (`ubuntu-26.04-arm`).

## Step 1: Preparing the Template

### Step 1a: Copying the Template

Select `Use this Template` on this page. You can set the name and description of your repository to whatever you would like, but all other settings should be left untouched.

Once you have finished copying the template, you need to enable the Github Actions workflows for your new repository.
To enable the workflows, go to the `Actions` tab of the new repository and click the button to enable workflows.

### Step 1b: Cloning the New Repository

[GitHub Documentation](https://docs.github.com/en/repositories/creating-and-managing-repositories/cloning-a-repository)

Once you have the repository on your local drive, proceed to the next step.

## Step 2: Initial Setup

### Step 2a: Creating a Cosign Key

Container signing is important for end-user security. By default the image builds *will fail* on the signing step if you skip this.

With the [cosign CLI tool](https://edu.chainguard.dev/open-source/sigstore/cosign/how-to-install-cosign/) installed, run inside your repo folder:

```bash
COSIGN_PASSWORD="" cosign generate-key-pair
```

The signing key will be used in GitHub Actions and will not work if it is password protected.

> [!WARNING]
> Be careful to *never* accidentally commit `cosign.key` into your git repo. If this key goes out to the public, the security of your repository is compromised.

Next, add the key to GitHub secrets:

<details>
    <summary>Using the Github Web Interface (preferred)</summary>

Go to your repository settings, under `Secrets and Variables` -> `Actions`, add a new secret named `SIGNING_SECRET`, then paste the contents of `cosign.key` into the secret and save it (the `.key` file, not the `.pub` file).
</details>
<details>
<summary>Using the Github CLI</summary>

```bash
gh secret set SIGNING_SECRET < cosign.key
```
</details>

### Step 2b: Choosing Your Base Image

The default base is `quay.io/fedora/fedora-bootc:44`, which is the release the Aurora RPM repository targets (`44/testing/aarch64`). If you switch to `fedora-bootc:45`, also switch the repo file in `system_files/etc/yum.repos.d/aurora.repo` to the matching `45/testing/aarch64` channel — the Aurora repository uses `$releasever`, so it follows automatically as long as a channel exists for that release.

You may **not** use `ghcr.io/ublue-os/*` images as a base: they publish x86_64 manifests only.

### Step 2c: Changing Names

Change the `IMAGE_NAME` and `REPO_ORGANIZATION` variable inside `image-template.env`.

To commit and push all the files changed and added in step 2 into your Github repository:
```bash
git add Containerfile image-template.env cosign.pub
git commit -m "Initial Setup"
git push
```
Once pushed, go look at the Actions tab on your Github repository's page. The green checkmark should be showing on the top commit, which means your new image is ready!

## Step 3: Switch to Your Image

### Disk images for the installer path

```bash
just build          # podman build, linux/arm64 OCI image
just build-raw      # raw disk image via bootc-image-builder, in output/image/disk.raw
just build-qcow2    # same pipeline, qcow2 output
```

`build-raw` produces `output/image/disk.raw` with the standard layout (ESP +
ext4 `/boot` + btrfs root) — the same partition layout the installer's
filesystem bundle expects.

```bash
just bundle                 # → output/bundle/: image.json, boot.img, root.img,
                            #   esp/, stage2.json (default profile fedora-minimal)
just bundle "" "" fedora-kde   # choose the installer's profile name
just payload                # → output/payload/: <profile>-<date>.zip,
                            #   installer-data-<profile>.json, delivery.json
```

`payload` clones `aurora-installer` into `.aurora-installer/` (build-time
tooling only), builds the native Recovery app template via SwiftPM with an
ad-hoc signature, and runs `assemble-distribution-payload.py`, which
digest-validates the bundle — every required board Stage 2, the Mach-O
Stage 1, image checksums, and the Recovery app's Info.plist markers and
inventory — before writing the zip. `AURORA_RECOVERY_TESTS=` can be set to
re-enable the Recovery test fixtures, which crash on newer macOS.

`bundle` runs `installer/finalize-image` (vendored from
[aurora-silicon/aurora-platform](https://github.com/aurora-silicon/aurora-platform),
MIT) inside the podman machine: it builds the combined Stage 2 via
`update-m1n1`, stages it on the ESP, seals firstboot state, hardens GRUB,
rebuilds the initramfs with the `aurora-root` dracut module, and splits the
disk into the bundle the installer consumes.

### Bare metal: use the Aurora installer

> [!IMPORTANT]
> The installer does not consume a raw disk or ISO directly. Each OS build
> reaches it as a **payload**: `assemble-distribution-payload.py` (in
> [aurora-silicon/aurora-installer](https://github.com/aurora-silicon/aurora-installer))
> combines this filesystem bundle with a native Recovery app into the
> profile zip + `installer-data` metadata + `delivery.json`, which
> `aurora-distributions` then publishes as a signed catalog entry (payload
> split into 1 GiB parts, everything bound by SHA-256 digests).
> `bundle`'s `profile` argument must be one of the installer's known
> profiles (`fedora-kde`, `fedora-gnome`, `fedora-minimal`) — pick whichever
> matches the desktop you ship; a custom profile name requires forking the
> payload schema.
>
> On real hardware the Mac boots m1n1/Aura → U-Boot → GRUB; the ESP files
> the bundle carries (`m1n1/boot.bin`, `m1n1/boot-<board>.bin`,
> `aurora/stage1.{bin,macho}`) are what make that work. The image itself
> ships `update-m1n1`, `uboot-aurora` and `aura` so the bootchain stays
> maintained after install.

### Rebasing an existing system

From an aarch64 system already running a bootc image, you can rebase:

```bash
sudo bootc switch ghcr.io/<username>/<image_name>
```

On an existing Aurora/Asahi Fedora install this is **experimental**: this
image ships `kernel-aurora`, `update-m1n1` and `uboot-aurora`, but the
switch has not been qualified the way the installer path is. Keep a working
deployment to roll back to (`bootc rollback`).

# Repository Contents

## Containerfile

The [Containerfile](./Containerfile) defines the base image and calls `build.sh`. Works like a regular podman Containerfile; see the [Podman Documentation](https://docs.podman.io/en/latest/Introduction.html).

## build.sh

[build.sh](./build_files/build.sh) is where the Apple Silicon customization happens:

1. Copies `system_files/` into the image — the Aurora repo file, its RPM signing key, and bootc kernel arguments (`user4k=on` + Aurora's quiet boot set).
2. Removes the stock Fedora kernel and installs `kernel-aurora` (16K pages, `aurora-userpages` for per-process 4K).
3. Installs the hardware stack from the [Aurora repository](https://aurorasilicon.org/fedora-aurora/44/testing/aarch64/): `aurora-platform`, `aurora-firmware`, `avd-fw`, `mesa-aurora-*`, audio (`alsa-ucm-conf-aurora`, `aurora-audio`, `speakerguardd-v2`, `speakersafetyd-aurora-profiles`), `aurora-sep`, camera/keyboard, `update-m1n1`/`uboot-aurora`.
4. Installs the Aurora release identity (`aurora-release`, `aurora-repos`, `aurora-logos`) — remove that block for a plain Fedora identity.
5. Regenerates the initramfs if the kernel transaction did not produce one, then `bootc container lint` validates the image.

Add your own packages/services at the marked spot in the file.

## build.yml

The [build.yml](./.github/workflows/build.yml) workflow builds the image on a native arm64 runner (`ubuntu-26.04-arm`), rechunks it, pushes to GHCR and signs it with cosign.

## The Aurora RPM repository

`system_files/etc/yum.repos.d/` ships Aurora's repo file and override verbatim from `aurora-silicon/fedora-aurora` (`aurora-repos` package). The public signing key is at `system_files/etc/pki/rpm-gpg/RPM-GPG-KEY-aurora`; its fingerprint `D6C974933C41AACE00AE3C4591B639B8C6A77AC1` is independently recorded in [keys/fingerprint.txt](https://github.com/aurora-silicon/fedora-aurora/blob/main/keys/fingerprint.txt). The repository has `priority=1`, so packages Aurora replaces (upower, libfprint, NetworkManager, pipewire, mutter, kwin, fex-emu, steam) come from Aurora's forks when installed.

# Building Disk Images

[build-disk.yml](./.github/workflows/build-disk.yml) runs `bootc-image-builder` on the arm64 runner and produces `qcow2` and `raw` disk images for the installer path. No ISO is built: on Apple Silicon the install goes through the native Aurora installer, not Anaconda.

Disk images upload to a job artifact, or to S3 via rclone with these repository secrets: `S3_PROVIDER`, `S3_BUCKET_NAME`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION`, `S3_ENDPOINT`. See [rclone's provider list](https://rclone.org/s3/).

# Artifacthub

`artifacthub-repo.yml` indexes your image on [artifacthub.io](https://artifacthub.io). Fill in your repository ID and owners.

# Justfile Documentation

The `Justfile` builds and manages the container image and VM disk images, and is also used inside Github Actions. On macOS, podman commands run inside `podman machine`; recipes that need the rootful store (`build-qcow2`, `ostree-rechunk`, …) transparently `podman save | podman machine ssh sudo podman load` and run inside the machine.

## Required Utilities

Container build (macOS: `brew install podman just jq`):
- [just](https://just.systems/man/en/introduction.html)
- [podman](https://docs.podman.io/en/latest) (+ a rootful `podman machine` for disk images)
- [jq](https://jqlang.org)

Linting:
- shfmt
- shellcheck

## Environment Variables

Sourced from `image-template.env`:

- `IMAGE_NAME`: image name (default: "aurora-bazzite")
- `DEFAULT_TAG`: image tag (default: "latest")
- `BIB_IMAGE`: Bootc Image Builder image (default: "quay.io/centos-bootc/bootc-image-builder:latest")

## Building The Image

### `just build`

```bash
just build $target_image $tag
```

Always passes `--platform linux/arm64`. On Apple Silicon podman machines this is native; on x86 Linux, podman falls back to `qemu-user-static`.

### Rechunking

Rechunks layers for better delta/resumable updates:

- `just ostree-rechunk` — [rpm-ostree](https://coreos.github.io/rpm-ostree/build-chunked-oci/) (on macOS runs inside the podman machine)
- `just rechunk` — [chunkah](https://github.com/coreos/chunkah)

### Switching to the locally built image for testing

The image must be in the root-owned containers-storage to rebase. On Linux, `sudo just build` skips the transfer; on macOS, copy it over:

```bash
podman save localhost/aurora-bazzite:latest | podman machine ssh sudo podman load
```

On a Linux host running bootc:

```bash
sudo podman image list --filter=label=containers.bootc=1
sudo bootc switch --transport containers-storage localhost/aurora-bazzite:latest
```

See [man bootc switch](https://bootc.dev/bootc/man/bootc-switch.8.html).

## Building Disk Images

Available types: `qcow2`, `raw`.

### `just build-raw` / `just build-qcow2` (alias `just build-disk`)

Runs bootc-image-builder inside the rootful podman machine on macOS (or
rootful podman on Linux) and leaves the result in `output/<type>/`.
`rebuild-*` variants rebuild the container image first. `raw` is the
artifact the Aurora installer consumes.

## File Management

- `just check` / `just fix` — Justfile syntax
- `just clean` — remove build artifacts
- `just lint` — shellcheck all scripts
- `just format` — shfmt all scripts

## References

- [aurora-silicon/fedora-aurora](https://github.com/aurora-silicon/fedora-aurora) — RPM specs, signing keys, KIWI image producer, repo feed
- [aurora-silicon/aurora-installer](https://github.com/aurora-silicon/aurora-installer) — native macOS installer app
- [aurora-silicon](https://github.com/aurora-silicon) — kernel (`linux`), bootloader (`aura`), Mesa, NixOS/ALARM variants
- [ublue-os/image-template](https://github.com/ublue-os/image-template) — the upstream template this mirrors
- [bootc](https://github.com/bootc-dev/bootc) — image-based OS tooling
