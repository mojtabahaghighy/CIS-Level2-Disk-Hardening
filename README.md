# CIS-Level2-Disk-Hardening

# CIS Level 2 Disk Hardening – Automated Partitioning & LVM Migration

**Zero‑downtime, fully automated solution to apply CIS Level 2 partitioning to a dual‑disk Ubuntu 22.04 system, with boot switching entirely from within the OS (no BIOS access).**

This repository contains the exact scripts I used to solve a real production challenge:
- Two disks: /dev/sda (200 GB, root /) and /dev/sdb (2 TB, mounted as /mnt/data)
- Need to repartition /dev/sda with CIS Level 2 layout (separate /boot, /home, /var, /var/log, /var/log/audit, /tmp)
- Need to configure LVM on /dev/sdb and mount as /mnt/data
- No BIOS access – boot order must be changed from within the OS

---

## Files

| File | Description |
|------|-------------|
| Repartitioning.sh | Main script – 3 phases + rollback (auto‑detects UEFI/BIOS, installs prerequisites, formats with nodiscard, generates fstab with CIS mount options) |
| boot-sdaTOsdb.sh | Boot switcher – changes boot disk from sda → sdb (UEFI: auto‑creates EFI partition, installs GRUB, updates efibootmgr; BIOS: installs GRUB to MBR) |
| boot-sdaTOsdb-1.sh | Lightweight version (assumes EFI partition already exists) |

---

## Partition Layout Created on /dev/sda (CIS Level 2)

| Partition | Size (GB) | Mount Point | Special Options in fstab |
|-----------|-----------|-------------|--------------------------|
| sda1      | 512MiB (UEFI) or 1MiB (BIOS) | /boot/efi (UEFI) or none | – |
| sda2      | 1 | /boot | defaults,noatime |
| sda3      | 20 | / | defaults,noatime |
| sda4      | 20 | /home | defaults,noatime |
| sda5      | 10 | /tmp | defaults,nosuid,nodev,noexec,noatime |
| sda6      | 30 | /var | defaults,noatime |
| sda7      | 10 | /var/log | defaults,noatime |
| sda8      | 5 | /var/log/audit | defaults,noatime |
| Total     | ~96 GB | (remaining space on sda unused) | – |

> All sizes are configurable inside the script (PART_SIZES array).  
> Formatting uses mkfs.ext4 -E nodiscard for speed.

### LVM on /dev/sdb (Phase 3)
- /dev/sdb1 as LVM PV → VG vg_data → LV lv_data (100% free space)
- Mounted at /mnt/data with defaults 0 2 in /etc/fstab

---

## Usage

### Prerequisites
- Ubuntu 22.04 (the script is written for Ubuntu, but can be adapted)
- Two disks: sda (current root) and sdb (to be used as temporary root and later LVM)
- Root access

### Step‑by‑Step

1. **Clone the repository**
   git clone https://github.com/mojtaba-haghighy/CIS-Level2-Disk-Hardening.git
   cd CIS-Level2-Disk-Hardening
   chmod +x *.sh

2. **Run Phase 1 (copy system to sdb and make it bootable)**
   sudo ./Repartitioning.sh
   After completion, reboot and ensure the system boots from sdb (the script tries to change boot order automatically; if not, use BIOS boot menu once).

3. **Run Phase 2 (repartition sda, restore data, generate fstab, install GRUB)**
   sudo ./Repartitioning.sh --phase2
   Reboot again – now boot from sda (hardened).

4. **Run Phase 3 (create LVM on sdb for /mnt/data)**
   sudo ./Repartitioning.sh --phase3
   This will wipe sdb, create a LVM volume, mount it, and add to fstab.

5. **Optional – rollback to original partition table**
   sudo ./Repartitioning.sh --rollback
   (Restores sda to its original state using backup files saved in /root)

### Boot Switcher (standalone)
If you ever need to change the boot disk manually:
sudo ./boot-sdaTOsdb.sh   # switches boot from sda → sdb (auto‑detects UEFI/BIOS)

---

## Key Automation Features

- Auto‑detects firmware (UEFI vs BIOS) and handles boot partitions accordingly.
- Installs prerequisites (rsync, gdisk, parted, lvm2, grub, etc.) automatically.
- Saves original partition table and UUID before making changes – allows full rollback.
- Generates /etc/fstab with correct UUIDs and CIS‑compliant mount options (noexec,nosuid,nodev on /tmp).
- Uses nodiscard during formatting for faster execution.
- Logs everything to /root/cis_repartition.log.

---

## Important Notes

- Test in a virtual machine first – this script repartitions disks and can cause data loss if misused.
- The script assumes Ubuntu 22.04 with apt package manager. For other distros, adjust the package installation commands.
- NDA‑compliant – no proprietary information, hostnames, IPs, or real data are exposed. All commands are generic.

---

## License

MIT – free to use, modify, and distribute.

## Contact

LinkedIn: mojtaba-haghighy
GitHub: mojtaba-haghighy

If you use this in production or have improvements, I’d love to hear about it!
