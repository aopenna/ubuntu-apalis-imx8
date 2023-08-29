#!/bin/bash

echo ""
echo "#######################"
echo "##  build-image.sh   ##"
echo "#######################"
echo ""

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

function cleanup_loopdev {
    sync --file-system
    sync

    if [ -b "${loop}" ]; then
        umount "${loop}"* 2> /dev/null || true
        losetup -d "${loop}" 2> /dev/null || true
    fi
}
trap cleanup_loopdev EXIT

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p images build && cd build

for rootfs in *.rootfs.tar.xz; do
    if [ ! -e "${rootfs}" ]; then
        echo "Error: could not find any rootfs tarfile, please run build-rootfs.sh"
        exit 1
    fi

    # Create an empty disk image
    img="../images/$(basename "${rootfs}" .rootfs.tar.xz).img"
    size="$(xz --robot -l "${rootfs}" | tail -n +3 | awk '{print int($5/1048576 + 1)}')"
    truncate -s "$(( size + 2048 + 512 ))M" "${img}"

    # Create loop device for disk image
    loop="$(losetup -f)"
    losetup "${loop}" "${img}"
    disk="${loop}"

    # Ensure disk is not mounted
    mount_point=/tmp/mnt
    umount "${disk}"* 2> /dev/null || true
    umount ${mount_point}/* 2> /dev/null || true
    mkdir -p ${mount_point}

    # Setup partition table
    dd if=/dev/zero of="${disk}" count=4096 bs=512
    parted --script "${disk}" \
    mklabel msdos \
    mkpart primary fat32 0% 512MiB \
    mkpart primary ext4 512MiB 100%

    set +e

    # Create partitions
    (
    echo t
    echo 1
    echo ef
    echo t
    echo 2
    echo 83
    echo a
    echo 1
    echo w
    ) | fdisk "${disk}"

    set -eE

    partprobe "${disk}"

    sleep 2

    # Generate random uuid for bootfs
    boot_uuid=$(uuidgen | head -c8)

    # Generate random uuid for rootfs
    root_uuid=$(uuidgen)

    # Create filesystems on partitions
    partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"
    mkfs.vfat -i "${boot_uuid}" -F32 -n boot "${disk}${partition_char}1"
    dd if=/dev/zero of="${disk}${partition_char}2" bs=1KB count=10 > /dev/null
    mkfs.ext4 -U "${root_uuid}" -L root "${disk}${partition_char}2"

    # Mount partitions
    mkdir -p ${mount_point}/{boot,root} 
    mount "${disk}${partition_char}1" ${mount_point}/boot
    mount "${disk}${partition_char}2" ${mount_point}/root

    # Copy the rootfs to root partition
    echo -e "Decompressing $(basename "${rootfs}")\n"
    tar -xpJf "${rootfs}" -C ${mount_point}/root

    # Create fstab entries
    mkdir -p ${mount_point}/root/boot/firmware
    boot_uuid="${boot_uuid:0:4}-${boot_uuid:4:4}"
    echo "# <file system>      <mount point>  <type>  <options>   <dump>  <fsck>" > ${mount_point}/root/etc/fstab
    echo "UUID=${boot_uuid^^}  /boot/firmware vfat    defaults    0       2" >> ${mount_point}/root/etc/fstab
    echo "UUID=${root_uuid,,}  /              ext4    defaults    0       1" >> ${mount_point}/root/etc/fstab
    echo "/swapfile            none           swap    sw          0       0" >> ${mount_point}/root/etc/fstab

    # Extract grub arm64-efi to host system 
    if [ ! -d "/usr/lib/grub/arm64-efi" ]; then
        rm -f /usr/lib/grub/arm64-efi
        ln -s ${mount_point}/root/usr/lib/grub/arm64-efi /usr/lib/grub/arm64-efi
    fi

    # Install grub 
    mkdir -p ${mount_point}/boot/boot/boot
    mkdir -p ${mount_point}/boot/boot/grub
    grub-install --target=arm64-efi --efi-directory=${mount_point}/boot --boot-directory=${mount_point}/boot/boot --removable --recheck

    # Remove grub arm64-efi if extracted
    if [ -L "/usr/lib/grub/arm64-efi" ]; then
        rm -f /usr/lib/grub/arm64-efi
    fi

    # Grub config
    cat > ${mount_point}/boot/boot/grub/grub.cfg << EOF
insmod gzio
set background_color=black
set default=0
set timeout=10

GRUB_RECORDFAIL_TIMEOUT=

menuentry 'Boot' {
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    linux /boot/vmlinuz root=UUID=${root_uuid} console=ttyLP1,115200 console=tty1 pci=nomsi rootfstype=ext4 rootwait rw
    initrd /boot/initrd.img
}
EOF

    # Uboot script
    cat > ${mount_point}/boot/boot.cmd << EOF
# Copyright 2020 Toradex
#
# Toradex boot script.
#
# Allows to change boot and rootfs devices independently.
# Supports:
# - boot device type: boot_devtype := {mmc, usb, tftp, dhcp}
# - boot device num (for mmc, usb types): boot_devnum := {0 .. MAX_DEV_NUM}
# - boot partition (for mmc, usb types): boot_part := {1 .. MAX_PART_NUM}
# - root device type: root_devtype := {mmc, usb, nfs-dhcp, nfs-static}
# - root device num (for mmc, usb types): root_devnum := {0 .. MAX_DEV_NUM}
# - root partition (for mmc, usb types): root_part := {1 .. MAX_PART_NUM}
#
# Defaults:
#    root_devtype = boot_devtype = devtype
#    root_devnum = boot_devnum = devnum
#    boot_part = distro_bootpart
#    root_part = 2
#
# Common variables used in tftp/dhcp modes:
# - Static/dynamic IP mode: ip_dyn := {yes, no}
# - Static IP-address of TFTP/NFS server: serverip := {legal IPv4 address}
# - Static IP-address of the module: ipaddr := {legal IPv4 address}
# - Root-path on NFS-server: rootpath := {legal path, exported by an NFS-server}
#
# Common flags:
# - Skip loading overlays: skip_fdt_overlays := {1, 0}
#   1 - skip, any other value (or undefined variable) - don't skip.
#   This variable is adopted from the TorizonCore and shouldn't be
#   renamed separately.

if test ${devtype} = "ubi"; then
    echo "This script is not meant to distro boot from raw NAND flash."
    exit
fi

test -n ${m4boot} || env set m4boot ';'
test -n ${fdtfile} || env set fdtfile ${fdt_file}
test -n ${boot_part} || env set boot_part ${distro_bootpart}
test -n ${root_part} || env set root_part 2
test -n ${boot_devnum} || env set boot_devnum ${devnum}
test -n ${root_devnum} || env set root_devnum ${devnum}
test -n ${kernel_vmlinuz_image} || env set kernel_vmlinuz_image vmlinuz
test -n ${kernel_initrd_image} || env set kernel_initrd_image initrd.img
#test -n ${kernel_image} || env set kernel_image Image.gz
test -n ${kernel_image} || env set kernel_image vmlinuz
test -n ${boot_devtype} || env set boot_devtype ${devtype}
test -n ${overlays_file} || env set overlays_file "overlays.txt"
test -n ${overlays_prefix} || env set overlays_prefix "overlays/"

test ${boot_devtype} = "mmc" && env set load_cmd 'load ${boot_devtype} ${boot_devnum}:${boot_part}'
test ${boot_devtype} = "usb" && env set load_cmd 'load ${boot_devtype} ${boot_devnum}:${boot_part}'
test ${boot_devtype} = "tftp" && env set load_cmd 'tftp'
test ${boot_devtype} = "dhcp" && env set load_cmd 'dhcp'

# Set Root source type properly.
# devtype tftp => nfs-static
# devtype ghcp => nfs-dhcp
if test "${root_devtype}" = ""; then
    if test ${devtype} = "tftp"; then
        env set root_devtype "nfs-static"
    else
        if test ${devtype} = "dhcp"; then
            env set root_devtype "nfs-dhcp"
        else
            env set root_devtype ${devtype}
        fi
    fi
fi

if test -n ${setup}; then
    run setup
else
    env set setupargs console=tty1 console=${console},${baudrate} consoleblank=0
fi

if test ${kernel_image} = "fitImage"; then
    env set kernel_addr_load ${ramdisk_addr_r}
    env set bootcmd_unzip ';'
else
    if test -n ${kernel_comp_addr_r}; then
        # use booti automatic decompression
        env set kernel_addr_load ${loadaddr}
        env set bootcmd_unzip ';'
    else
        if test ${kernel_image} = "Image.gz"; then
            env set kernel_addr_load ${loadaddr}
            env set bootcmd_unzip 'unzip ${kernel_addr_load} ${kernel_addr_r} '
        elseif test ${kernel_image} = "vmlinuz"; then
            env set kernel_addr_load ${loadaddr}
            env set bootcmd_unzip 'unzip ${kernel_addr_load} ${kernel_addr_r} && ${load_cmd} \\${kernel_addr_load} \\${kernel_initrd_image}'
        else 
            env set kernel_addr_load ${kernel_addr_r}
            env set bootcmd_unzip ';'
        fi
    fi
fi

# Set dynamic commands
env set set_bootcmd_kernel 'env set bootcmd_kernel "${load_cmd} \\${kernel_addr_load} \\${kernel_image}"'
env set set_load_overlays_file 'env set load_overlays_file "${load_cmd} \\${loadaddr} \\${overlays_file} && env import -t \\${loadaddr} \\${filesize}"'
if test ${kernel_image} = "fitImage"
then
    env set fdt_high
    env set fdt_resize true
    env set set_bootcmd_dtb 'env set bootcmd_dtb "true"'
    env set set_apply_overlays 'env set apply_overlays "for overlay_file in \"\\${fdt_overlays}\"; do env set fitconf_fdt_overlays \"\\"\\${fitconf_fdt_overlays}#conf-\\${overlay_file}\\"\"; env set overlay_file; done; true"'
    env set bootcmd_boot 'echo "Bootargs: \${bootargs}" && bootm ${kernel_addr_load}#conf-freescale_\${fdtfile}\${fitconf_fdt_overlays}'
else
    env set fdt_resize 'fdt addr ${fdt_addr_r} && fdt resize 0x20000'
    env set set_bootcmd_dtb 'env set bootcmd_dtb "echo Loading DeviceTree: \\${fdtfile}; ${load_cmd} \\${fdt_addr_r} \\${fdtfile}"'
    env set set_apply_overlays 'env set apply_overlays "for overlay_file in \\${fdt_overlays}; do echo Applying Overlay: \\${overlay_file} && ${load_cmd} \\${loadaddr} \\${overlays_prefix}\\${overlay_file} && fdt apply \\${loadaddr}; env set overlay_file; done; true"'
    env set bootcmd_boot 'echo "Bootargs: \${bootargs}" && booti ${kernel_addr_r} - ${fdt_addr_r}'
fi

# Set static commands
if test ${root_devtype} = "nfs-dhcp"; then
    env set rootfsargs_set 'env set rootfsargs "root=/dev/nfs ip=dhcp"'
else
    if test ${root_devtype} = "nfs-static"; then
        env set rootfsargs_set 'env set rootfsargs "root=/dev/nfs nfsroot=${serverip}:/${rootpath}"'
    else
        env set uuid_set 'part uuid ${root_devtype} ${root_devnum}:${root_part} uuid'
        env set rootfsargs_set 'run uuid_set && env set rootfsargs root=PARTUUID=${uuid} ro rootwait'
    fi
fi

env set bootcmd_args 'run rootfsargs_set && env set bootargs ${defargs} ${rootfsargs} ${setupargs} ${vidargs} ${tdxargs}'
if test ${skip_fdt_overlays} != 1; then
    env set bootcmd_overlays 'run load_overlays_file && run fdt_resize && run apply_overlays'
else
    env set bootcmd_overlays true
fi
env set bootcmd_prepare 'run set_bootcmd_kernel; run set_bootcmd_dtb; run set_load_overlays_file; run set_apply_overlays'
env set bootcmd_run 'run m4boot; run bootcmd_dtb && run bootcmd_overlays && run bootcmd_args && run bootcmd_kernel && run bootcmd_unzip && run bootcmd_boot; echo "Booting from ${devtype} failed!" && false'

run bootcmd_prepare
run bootcmd_run
EOF
    mkimage -A arm64 -O linux -T script -C none -n "Boot Script" -d ${mount_point}/boot/boot.cmd ${mount_point}/boot/boot.scr

    # Copy device tree blobs
    cp linux-toradex/arch/arm64/boot/dts/freescale/imx8qm-apalis-*.dtb ${mount_point}/boot
    cp linux-toradex/arch/arm64/boot/dts/freescale/imx8qp-apalis-*.dtb ${mount_point}/boot

    # Copy device tree overlays
    mkdir -p ${mount_point}/boot/overlays
    cp device-tree-overlays/overlays/apalis-*.dtbo ${mount_point}/boot/overlays

    # Copy hdmi firmware
    cp firmware-imx-8.17/firmware/hdmi/cadence/dpfw.bin ${mount_point}/boot
    cp firmware-imx-8.17/firmware/hdmi/cadence/hdmitxfw.bin ${mount_point}/boot

    sync --file-system
    sync

    # Umount partitions
    umount "${disk}${partition_char}1"
    umount "${disk}${partition_char}2"

    # Remove loop device
    losetup -d "${loop}"

    echo -e "\nCompressing $(basename "${img}.xz")\n"
    xz -9 --extreme --force --keep --quiet --threads=0 "${img}"
    rm -f "${img}"
done
echo "Finished build-image.sh"
