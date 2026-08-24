# Native aarch64 (or x86+qemu) image builder: losetup, arch-chroot, mksquashfs.
# Used for BOARD=ayn-thor / cm5 mkimage.sh and verify-image.sh.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        arch-install-scripts libarchive-tools dosfstools parted file curl \
        util-linux fdisk e2fsprogs git xz-utils zstd squashfs-tools mtools \
        python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
