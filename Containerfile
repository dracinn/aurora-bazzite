# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
#
# Universal Blue images (bazzite, aurora, bluefin) are x86_64-only, so this
# port reproduces Bazzite's build spec on Fedora's multiarch bootc base
# instead of rebasing. aarch64 is the only supported architecture: the
# Aurora Silicon hardware stack layered on in build_files/build.sh targets
# Apple Silicon Macs.
FROM quay.io/fedora/fedora-bootc:44
## Other possible base images include:
# FROM quay.io/fedora/fedora-bootc:45           # Fedora 45 (Aurora testing channel exists)
# FROM quay.io/centos-bootc/centos-bootc:stream10
#
# ... and so on, here are more base images
# Fedora base images: https://gitlab.com/fedora/bootc/base-images
# Aurora RPM repository (Fedora 44 aarch64): https://aurorasilicon.org/fedora-aurora/44/testing/aarch64/

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
