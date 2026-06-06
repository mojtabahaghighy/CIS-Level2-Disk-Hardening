#!/bin/bash
set -e

echo "=============================================="
echo " Smart Boot Fixer (Switch Boot from sda → sdb)"
echo " Autodetect UEFI/BIOS, auto-create EFI, auto-GRUB"
echo "=============================================="

### Detect boot mode
if [ -d /sys/firmware/efi ]; then
    MODE="UEFI"
else
    MODE="BIOS"
fi

echo ">>> Boot mode detected: $MODE"
sleep 1


###################################################
### -------- UEFI MODE WITH AUTO EFI FIX ---------
###################################################
if [ "$MODE" = "UEFI" ]; then
    echo ">>> Checking for existing EFI partition on sdb..."

    EFI=$(lsblk -o NAME,FSTYPE | grep "^sdb" | grep "vfat" | awk '{print $1}')

    if [ -z "$EFI" ]; then
        echo ">>> No EFI partition found on sdb."
        echo ">>> Creating new EFI partition (512MB) at END of disk..."

        END=$(sudo parted /dev/sdb unit GB print | grep "Disk /dev/sdb:" | awk '{print $3}' | sed 's/GB//')
        START=$(echo "$END - 0.6" | bc)   # 600MB from end

        echo ">>> Creating EFI partition from ${START}GB to ${END}GB..."
        sudo parted /dev/sdb --script mkpart EFI fat32 ${START}GB ${END}GB
        sudo parted /dev/sdb --script set 3 esp on

        EFI="sdb3"

        echo ">>> Formatting EFI partition..."
        sudo mkfs.vfat -F32 /dev/$EFI
    else
        echo ">>> Found EFI: /dev/$EFI"
    fi

    echo ">>> Mounting EFI partition..."
    sudo mkdir -p /mnt/efi_sdb
    sudo mount /dev/$EFI /mnt/efi_sdb

    echo ">>> Installing GRUB on sdb (UEFI)..."
    sudo grub-install \
        --target=x86_64-efi \
        --efi-directory=/mnt/efi_sdb \
        --bootloader-id=ubuntu-sdb \
        --recheck

    echo ">>> Running update-grub..."
    sudo update-grub

    echo ">>> Detecting new UEFI boot entry..."
    BOOTNUM=$(sudo efibootmgr | grep "ubuntu-sdb" | cut -d"*" -f1 | sed 's/Boot//')

    if [ -z "$BOOTNUM" ]; then
        echo "!!! ERROR: Cannot find new boot entry."
        exit 1
    fi

    echo ">>> Setting BootOrder = Boot$BOOTNUM"
    sudo efibootmgr -o $BOOTNUM

    echo "=============================================="
    echo " SUCCESS: System will now boot from sdb (UEFI)"
    echo "=============================================="
    exit 0
fi


###################################################
### -------- BIOS MODE (Legacy Boot) -------------
###################################################
if [ "$MODE" = "BIOS" ]; then
    echo ">>> BIOS mode detected. Installing GRUB to /dev/sdb MBR..."
    sudo grub-install /dev/sdb
    sudo update-grub

    echo ">>> Done. You may still need to change VM boot priority manually."
    exit 0
fi
