#!/usr/bin/env bash
#
# arch-install.sh
# Copyright (C) 2018 zuritat <tzurita@gmail.com>
#
# Distributed under terms of the MIT license.
#



# This script will set up an Arch installation with a 250 MB /boot partition
# and an encrypted LVM partition with swap and / inside.  It also installs
# and configures systemd as the init system (removing sysvinit).
#
# You should read through this script before running it in case you want to
# make any modifications, in particular, the variables just below, and the
# following functions:
#
#    partition_drive - Customize to change partition sizes (/boot vs LVM)
#    setup_lvm - Customize for partitions inside LVM
#    install_packages - Customize packages installed in base system
#                       (desktop environment, etc.)
#    install_aur_packages - More packages after packer (AUR helper) is
#                           installed

## CONFIGURE THESE VARIABLES
## ALSO LOOK AT THE install_packages FUNCTION TO SEE WHAT IS ACTUALLY INSTALLED

# Drive to install to.
#DRIVE='/dev/sda'
DRIVE='/dev/nvme0n1'

# Hostname of the installed machine.
HOSTNAME='borg-x1.dsolutionz.com'

# Root password (leave blank to be prompted).
ROOT_PASSWORD='linux123'

# Main user to create (by default, added to wheel group, and others).
USER_NAME=''

# The main user's password (leave blank to be prompted).
USER_PASSWORD=''

# System timezone.
TIMEZONE='America/New_York'

# Have /tmp on a tmpfs or not.  Leave blank to disable.
# Only leave this blank on systems with very little RAM.
TMP_ON_TMPFS='TRUE'

KEYMAP='us'
# KEYMAP='dvorak'

# Choose your video driver
# For Intel
# VIDEO_DRIVER="i915"
# For nVidia
#VIDEO_DRIVER="nouveau"
# For ATI
#VIDEO_DRIVER="radeon"
# For generic stuff
VIDEO_DRIVER="vesa"

# Wireless device, leave blank to not use wireless and use DHCP instead.
WIRELESS_DEVICE=""
# For tc4200's
#WIRELESS_DEVICE="eth1"

setup() {
    local boot_dev="$DRIVE"p1
    local lvm_dev="$DRIVE"p2

    echo 'Creating partitions'
    partition_drive "$DRIVE"
    local lvm_part="$lvm_dev"

    echo 'Setting up LVM'
    setup_lvm "$lvm_part" root_vg

    echo 'Formatting filesystems'
    format_filesystems "$boot_dev"

    echo 'Mounting filesystems'
    mount_filesystems "$boot_dev"

    echo 'Speed up mirrorlist'
    fast_mirrors

    echo 'Installing base system'
    install_base

    echo 'Setting fstab'
    set_fstab "$TMP_ON_TMPFS" "$boot_dev"

    echo 'Chrooting into installed system to continue setup...'
    cp $0 /mnt/setup.sh
    arch-chroot /mnt /bin/bash ./setup.sh chroot

    if [ -f /mnt/setup.sh ]
    then
        echo 'ERROR: Something failed inside the chroot, not unmounting filesystems so you can investigate.'
        echo 'Make sure you unmount everything before you try to run this script again.'
    else
        echo 'Unmounting filesystems'
        unmount_filesystems
        echo 'Done! Reboot system.'
    fi
}

configure() {
    local boot_dev="$DRIVE"1
    local lvm_dev="$DRIVE"2

    echo 'Setting hostname'
    set_hostname "$HOSTNAME"

    echo 'Setting timezone'
    set_timezone "$TIMEZONE"

    echo 'Setting locale'
    set_locale

    echo 'Setting console keymap'
    set_keymap

    echo 'Setting hosts file'
    set_hosts "$HOSTNAME"

    #echo 'Setting fstab'
    #set_fstab "$TMP_ON_TMPFS" "$boot_dev"

    echo 'Configuring initial ramdisk'
    set_initcpio

    echo 'Setting initial daemons'
    set_daemons "$TMP_ON_TMPFS"

    echo 'Configuring bootloader'
    set_systemd_boot "$lvm_dev"

    echo 'Configuring chrony'
    set_chrony

    echo 'Configuring sudo'
    TARBS_setup

    rm /setup.sh
}

partition_drive() {
    local dev="$1"; shift

    # 250 MB /boot partition, everything else under LVM
    parted -s "$dev" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 300MiB \
        mkpart primary xfs 300MiB 100% \
        set 1 boot on \
        set 2 LVM on
}

setup_lvm() {
    local partition="$1"; shift
    local volgroup="$1"; shift

    pvcreate "$partition"
    vgcreate "$volgroup" "$partition"

    # Create a 1GB swap partition
    lvcreate -C y -L1G "$volgroup" -n swap

    # Use the rest of the space for root
    lvcreate -l '+100%FREE' "$volgroup" -n root

    # Enable the new volumes
    vgchange -ay
}

format_filesystems() {
    local boot_dev="$1"; shift

    # mkfs.xfs -f -L boot "$boot_dev"
    mkfs.vfat -F32 "$boot_dev"
    mkfs.xfs -L root /dev/root_vg/root
    mkswap /dev/root_vg/swap
}

mount_filesystems() {
    local boot_dev="$1"; shift

    mount /dev/root_vg/root /mnt
    mkdir -p /mnt/boot
    mount "$boot_dev" /mnt/boot
    swapon /dev/root_vg/swap
}

fast_mirrors() {
    grep -A1 "United States" /etc/pacman.d/mirrorlist | grep -v "\-\-" > /etc/pacman.d/mirrorlist.tmp
    mv /etc/pacman.d/mirrorlist.tmp /etc/pacman.d/mirrorlist
}

install_base() {
    echo 'Server = http://mirrors.kernel.org/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist

    pacstrap /mnt base base-devel linux linux-headers linux-firmware lvm2 xfsprogs efibootmgr networkmanager
}

unmount_filesystems() {
    umount /mnt/boot
    umount /mnt
    swapoff /dev/root_vg/swap
    vgchange -an
}


set_hostname() {
    local hostname="$1"; shift

    echo "$hostname" > /etc/hostname
}

set_timezone() {
    local timezone="$1"; shift

    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
}

set_locale() {
    echo 'LANG="en_US.UTF-8"' >> /etc/locale.conf
    echo 'LC_COLLATE="C"' >> /etc/locale.conf
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
}

set_keymap() {
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
}

set_hosts() {
    local hostname="$1"; shift

    cat > /etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost $hostname
::1       localhost.localdomain localhost $hostname
EOF
}

set_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
}


set_initcpio() {
    local encrypt=""
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        encrypt="encrypt"
    fi


    # Set MODULES with your video driver
    sed -i "s/^MODULES=.*/MODULES=(dm-mod)/" /etc/mkinitcpio.conf
    sed -i 's/\(^HOOKS=.*block\).*\(filesystems.*\)/\1 lvm2 \2/' /etc/mkinitcpio.conf
    mkinitcpio -p linux
}

set_daemons() {
    local tmp_on_tmpfs="$1"; shift

    systemctl enable NetworkManager.service

    if [ -z "$tmp_on_tmpfs" ]
    then
        systemctl mask tmp.mount
    fi
}

set_systemd_boot() {
    bootctl --path=/boot/ install
    cat > /boot/loader/entries/arch.conf <<EOF
title	Arch Linux
linux	/vmlinuz-linux
initrd	/initramfs-linux.img
options	root=/dev/mapper/root_vg-root quiet rw
EOF

    echo "timeout 3" >> /boot/loader/loader.conf
}


set_chrony() {
    cat > /etc/chrony.conf <<EOF
server 0.us.pool.ntp.org iburst
server 1.us.pool.ntp.org iburst
server 2.us.pool.ntp.org iburst
server 3.us.pool.ntp.org iburst
driftfile /etc/chrony.drift
makestep 1 3
rtconutc
rtcsync
EOF
}


TARBS_setup(){
    curl -LO raw.githubusercontent.com/tzurita/TARBS/master/tarbs.sh && bash tarbs.sh
}

set -ex

if [ "$1" == "chroot" ]
then
    configure
else
    setup
fi
