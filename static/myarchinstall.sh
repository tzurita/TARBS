#!/usr/bin/env bash
# Copyright (c) 2012 Tom Wambold
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This script will set up an Arch installation with a 300 MB /boot partition
# and an unencrypted LVM partition with swap and / inside.  It also installs
# and configures systemd as the init system (removing sysvinit).
#
# You should read through this script before running it in case you want to
# make any modifications, in particular, the variables just below, and the
# following functions:
#
#    partition_drive - Customize to change partition sizes (/boot vs LVM)
#    setup_lvm - Customize for partitions inside LVM
#    - swapsize is 1GB on the create a swapfile if more is needed.
#    install_packages - Customize packages installed in base system
#                       (desktop environment, etc.)

## CONFIGURE THESE VARIABLES
## ALSO LOOK AT THE install_packages FUNCTION TO SEE WHAT IS ACTUALLY INSTALLED

## Safer Bash Scripting ###
#set -euo pipefail #e: exits immediatly if failure, u:exit if using unset variables, o pipefail: if using pipeline, will exit where it failed since if not set, it would have still gone on to the last command even if prev command failed,
#set -x #shows the actually bash command before executing it(verbose)
#trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR #trap catches signals and execute code when they appear, on error, the echo command is called and ERR is the type error that trap catches

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")


## SETUP
setup_environment() {
    ## Required for script to function
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Sy --noconfirm archlinux-keyring
    pacman -Sy --noconfirm dialog
    timedatectl set-timezone America/New_York

    ## Select Harddrive
    # Variables
    devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
    device=$(dialog --stdout --menu "Select installation disk" 0 0 0 ${devicelist}) || exit 1
    boot_dev="$device"1
    lvm_dev="$device"2
    volgroup="rootvg"
    clear
}


setup_drive() {
    sgdisk -ogZ ${device}

    # Label and partition Disk
    sgdisk -n 0:0:+300M -t 0:ef00 -c 0:"EFI Partition" ${device}
    sgdisk -n 0:0:0 -t 0:8300 -c 0:"Root Partition" ${device}

    part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
    part_root="$(ls ${device}* | grep -E "^${device}p?2$")"

    wipefs "${part_boot}"
    wipefs "${part_root}"

    partprobe ${device}

    ##Setup LVM
    pvcreate "$lvm_dev"
    vgcreate "$volgroup" "$lvm_dev"

    # Create a 1GB swap partition
    lvcreate -C y -L1G "$volgroup" -n swap

    # Use the rest of the space for root
    lvcreate -l '+100%FREE' "$volgroup" -n root

    # Enable the new volumes
    vgchange -ay

    ## Format Filesytems
    mkfs.fat -F 32 -n EFIBOOT "$boot_dev"
    mkfs.xfs -L ROOT /dev/rootvg/root
    mkswap /dev/rootvg/swap

    ## Mount Filestems for installation
    mount /dev/rootvg/root /mnt
    mkdir /mnt/boot
    mount "$boot_dev" /mnt/boot
    swapon /dev/rootvg/swap
}

install_base() {
    echo 'Server = http://mirrors.kernel.org/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist

    pacstrap /mnt base base-devel linux linux-firmware efibootmgr lvm2 networkmanager xfsprogs
}

set_fstab() {
    genfstab -U /mnt > /mnt/etc/fstab
}

set_initcpio() {
    # Set MODULES with your video driver and HOOKS in /etc/mkinitcpio.conf
    #
    sed -i "s/^MODULES=.*/MODULES=(dm-mod)/" /etc/mkinitcpio.conf
    sed -i "s/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont $encrypt block lvm2 filesystems fsck)/" /etc/mkinitcpio.conf

    mkinitcpio -p linux
}

set_uefi_bootloader() {
    mkdir -p /boot/loader/entries
    cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=/dev/mapper/rootvg-root quiet rw
EOF

    bootctl install
}

set_hostname()
{
    hostname=$(whiptail --nocancel --inputbox "Enter hostname" 10 60 3>&1 1>&2 2>&3 3>&1)

    echo "${hostname}" > /mnt/etc/hostname
}

set_timezone()
{
    ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
    hwclock --systohc
}

set_locale() {
    echo 'LANG="en_US.UTF-8"' >> /etc/locale.conf
    echo 'LC_COLLATE="C"' >> /etc/locale.conf
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
}

get_root_password()
{
    # Prompts user for new username an password.
    password_root=$(whiptail --nocancel --passwordbox "Enter new root password" 10 60 3>&1 1>&2 2>&3 3>&1)
    password2_root=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)
    while ! [ "$pass1" = "$pass2" ]; do
        unset pass2
        password_root=$(whiptail --nocancel --passwordbox "Passwords do not match.\\n\\nEnter password again." 10 60 3>&1 1>&2 2>&3 3>&1)
        password2_root=$(whiptail --nocancel --passwordbox "Retype password." 10 60 3>&1 1>&2 2>&3 3>&1)
    done
}


setup() {
    echo 'Setting up environment'
    setup_environment
    echo 'Partition Drive'
    setup_drive
    echo 'Installing base system'
    install_base
    echo 'Setting fstab'
    set_fstab
    echo 'Set hostname'
    set_hostname
    echo 'Grab Root PW'
    get_root_password
    echo "Setting Root PW"
    echo "root:$password_root" | arch-chroot /mnt chpasswd
    echo 'Chrooting into installed system to continue setup...'
    cp $0 /mnt/setup.sh
    arch-chroot /mnt ./setup.sh chroot

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

tarbs() {
    curl -O https://raw.githubusercontent.com/tzurita/TARBS/master/static/tarbs.sh && bash tarbs.sh
}

configure() {

    echo 'Set Timezone'
    set_timezone
    echo 'Setting locale'
    set_locale
    echo 'Configuring initial ramdisk'
    set_initcpio
    echo 'Configuring bootloader'
    set_uefi_bootloader
    echo 'Setup Tarbs'
    tarbs
    rm setup.sh
}

set -ex

if [ "$1" == "chroot" ]
then
    configure
else
    setup
fi
