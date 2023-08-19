#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Build the imx boot container and U-Boot
time ./scripts/build-imx-boot.sh

# Build the Linux kernel and Device Tree Blobs
time ./scripts/build-kernel.sh

# Build the root file system
time ./scripts/build-rootfs.sh

# Build the Ubuntu preinstalled images
time ./scripts/build-image.sh