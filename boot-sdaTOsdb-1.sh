#!/bin/bash
set -e

echo "Detecting EFI partition on sdb..."
EFIPART=$(lsblk -o NAME,FSTYPE | grep "sdb" | grep "vfat" | awk '{print $1}')

if [ -z "$EFIPART" ]; then
    echo "ERROR: No EFI partition found on sdb."
    exit 1
fi

echo "EFI partition found: /dev/$EFIPART"

sudo mkdir -p /mnt/efisdb
sudo mount /dev/$EFIPART /mnt/efisdb

echo "Installing GRUB on /dev/sdb..."
sudo grub-install --target=x86_64-efi --efi-directory=/mnt/efisdb --bootloader-id=ubuntu-sdb --recheck
sudo update-grub

echo "Getting new boot entry..."
BOOTNUM=$(sudo efibootmgr | grep ubuntu-sdb | cut -d'*' -f1 | sed 's/Boot//')

if [ -z "$BOOTNUM" ]; then
    echo "ERROR: Boot entry for ubuntu-sdb not found."
    exit 1
fi

echo "Setting boot order to $BOOTNUM..."
sudo efibootmgr -o $BOOTNUM

echo "Done. System will now boot from sdb."