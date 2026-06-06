#!/bin/bash
# =============================================================================
# Script: CIS Level 1 Repartitioning for Ubuntu 22.04 (Online Method)
# Description: Repartition /dev/sda to meet CIS Level 1 requirements using
#              /dev/sdb as temporary boot disk. Auto-detects BIOS/UEFI.
# Three phases:
#   1. Copy system to sdb and make it bootable (with appropriate boot partition).
#   2. Repartition sda (with appropriate boot partition) and restore data.
#   3. Setup LVM on sdb for /mnt/data.
# Author: Assistant
# Version: 3.1 (added nodiscard to mkfs for speed)
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

LOG_FILE="/root/cis_repartition.log"
BACKUP_DIR="/mnt/temp_root"           # mount point for sdb in phase 1
NEW_ROOT="/mnt/new_root"               # mount point for new sda in phase 2
SDA_DISK="/dev/sda"
SDB_DISK="/dev/sdb"
PARTITION_BACKUP="/root/sda_partition_backup.sfdisk"
UUID_BACKUP="/root/sda_uuid_backup.txt"
ORIGINAL_FSTAB="/root/original_fstab.txt"

# Default partition sizes (in GB) - modifiable
declare -A PART_SIZES=(
    [boot]=1
    [root]=20
    [home]=20
    [tmp]=10
    [var]=30
    [var_log]=10
    [var_log_audit]=5
)

# Partition mount points in order (without ESP/bios_boot)
PART_MOUNTS=(
    "boot:/boot"
    "root:/"
    "home:/home"
    "tmp:/tmp"
    "var:/var"
    "var_log:/var/log"
    "var_log_audit:/var/log/audit"
)

# ---------------------------- Functions ---------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}
:
error() {
    log "ERROR: $*" >&2
}

die() {
    error "$*"
    exit 1
}
:
confirm() {
    local prompt="$1"
    local response
    read -p "$prompt (y/n): " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Detect firmware type (BIOS or UEFI)
detect_firmware() {
    if [ -d /sys/firmware/efi ]; then
        echo "UEFI"
    else
        echo "BIOS"
    fi
}

# Save original partition table and UUIDs
save_original_state() {
    log "Saving original partition table of $SDA_DISK to $PARTITION_BACKUP"
    sfdisk -d "$SDA_DISK" > "$PARTITION_BACKUP" || die "Failed to save partition table"

    log "Saving original UUID of $SDA_DISK"1
    blkid -s UUID -o value "$SDA_DISK"1 > "$UUID_BACKUP" || die "Failed to save UUID"

    # Save current fstab
    cp /etc/fstab "$ORIGINAL_FSTAB" 2>/dev/null || true
    log "Original fstab saved to $ORIGINAL_FSTAB"
}

# Rollback original partition table on sda (must be run from sdb or live)
rollback_sda() {
    log "================== ROLLBACK SDA =================="
    if [ ! -f "$PARTITION_BACKUP" ]; then
        error "Partition backup not found. Cannot rollback."
        return 1
    fi
    if confirm "This will restore original partition table on $SDA_DISK and erase all changes. Continue?"; then
        # Unmount any sda partitions
        umount -R ${SDA_DISK}* 2>/dev/null || true
        # Restore partition table
        sfdisk "$SDA_DISK" < "$PARTITION_BACKUP" || die "Failed to restore partition table"
        partprobe "$SDA_DISK"
        sleep 2
        # Recreate filesystem on sda1 with original UUID
        if [ -f "$UUID_BACKUP" ]; then
            local old_uuid=$(cat "$UUID_BACKUP")
            log "Recreating ext4 on ${SDA_DISK}1 with UUID $old_uuid"
            mkfs.ext4 -U "$old_uuid" -F "${SDA_DISK}1" || die "Failed to recreate filesystem"
        else
            log "UUID backup not found, creating new filesystem"
            mkfs.ext4 -F "${SDA_DISK}1" || die "Failed to recreate filesystem"
        fi
        log "Rollback completed. You may now restore data from backup if needed."
    else
        log "Rollback aborted."
    fi
}

# Check and install required tools
check_tools() {
    local tools=("rsync" "sgdisk" "parted" "lvm" "sfdisk" "blkid" "mkfs.ext4" "grub-install")
    local missing=()
    for t in "${tools[@]}"; do
        if ! command -v "$t" &>/dev/null; then
            missing+=("$t")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log "Missing tools: ${missing[*]}. Attempting to install..."
        apt-get update && apt-get install -y rsync gdisk parted lvm2 grub-pc grub-efi
        if [ $? -ne 0 ]; then
            die "Failed to install required tools. Please install manually."
        fi
    fi
}

# Get user-defined partition sizes
get_user_sizes() {
    echo "Default partition sizes (GB):"
    for key in "${!PART_SIZES[@]}"; do
        printf "  %-15s : %s\n" "$key" "${PART_SIZES[$key]}"
    done
    local total=0
    for key in "${!PART_SIZES[@]}"; do
        total=$(( total + PART_SIZES[$key] ))
    done
    echo "Total required: $total GB (available: 200 GB)"
    if [ $total -gt 200 ]; then
        die "Total size exceeds 200 GB. Adjust sizes."
    fi
    if confirm "Do you want to use default sizes?"; then
        return
    fi
    for key in "${!PART_SIZES[@]}"; do
        read -p "Enter size for $key (GB) [${PART_SIZES[$key]}]: " input
        if [[ -n "$input" && "$input" =~ ^[0-9]+$ ]]; then
            PART_SIZES[$key]=$input
        fi
    done
    # Recalculate total
    total=0
    for key in "${!PART_SIZES[@]}"; do
        total=$(( total + PART_SIZES[$key] ))
    done
    if [ $total -gt 200 ]; then
        die "Total size exceeds 200 GB. Please run again with smaller sizes."
    fi
}

# Check if we are running on sdb (phase 2)
is_running_on_sdb() {
    local root_dev=$(findmnt -n -o SOURCE /)
    [[ "$root_dev" == "${SDB_DISK}"* ]]
}

# Generate minimal fstab for temporary sdb system
generate_temp_fstab() {
    local root_uuid="$1"
    local esp_uuid="${2:-}"
    local fstab_file="${BACKUP_DIR}/etc/fstab"
    cat > "$fstab_file" <<EOF
# /etc/fstab: generated by CIS repartition script (temporary)
UUID=$root_uuid / ext4 defaults,noatime 0 1
EOF
    if [ -n "$esp_uuid" ] && [ "$FIRMWARE" = "UEFI" ]; then
        mkdir -p "${BACKUP_DIR}/boot/efi"
        echo "UUID=$esp_uuid /boot/efi vfat defaults 0 2" >> "$fstab_file"
    fi
    # Copy any existing swap entries from original fstab that are still valid (optional)
    if [ -f "$ORIGINAL_FSTAB" ]; then
        grep -E '^[^#]*swap' "$ORIGINAL_FSTAB" >> "$fstab_file" 2>/dev/null || true
    fi
    log "Temporary fstab created for sdb."
}

# Phase 1: Copy system to sdb and make it bootable
phase1() {
    log "================== PHASE 1 STARTED =================="
    FIRMWARE=$(detect_firmware)
    log "Detected firmware: $FIRMWARE"

    check_tools
    get_user_sizes

    # Check if sdb is large enough
    local used=$(df -B1 --output=used / | tail -1 | tr -d ' ')
    local sdb_size=$(blockdev --getsize64 "$SDB_DISK")
    if [ "$used" -gt "$sdb_size" ]; then
        die "Not enough space on $SDB_DISK. Used: $used bytes, Disk size: $sdb_size bytes."
    fi

    # Prepare sdb with appropriate boot partition
    log "Preparing $SDB_DISK with $FIRMWARE boot partition..."
    sgdisk -Z "$SDB_DISK" || die "Failed to wipe $SDB_DISK"

    local part_num=1
    if [ "$FIRMWARE" = "BIOS" ]; then
        # BIOS boot partition (1MB, ef02)
        sgdisk -n $part_num:0:+1M -t $part_num:ef02 -c $part_num:"bios_boot" "$SDB_DISK" || die "Failed to create BIOS boot partition"
        part_num=2
    else
        # UEFI: EFI system partition (512MB, ef00)
        sgdisk -n $part_num:0:+512M -t $part_num:ef00 -c $part_num:"ESP" "$SDB_DISK" || die "Failed to create ESP"
        part_num=2
    fi

    # Root partition (rest of disk)
    sgdisk -n $part_num:0:0 -t $part_num:8300 -c $part_num:"temp_root" "$SDB_DISK" || die "Failed to create root partition"
    partprobe "$SDB_DISK"
    sleep 2

    # Format root partition with nodiscard for speed
    log "Formatting root partition with nodiscard (fast mode)..."
    mkfs.ext4 -F -E nodiscard -L "temp_root" "${SDB_DISK}${part_num}" || die "Failed to format root partition"
    mkdir -p "$BACKUP_DIR"
    mount "${SDB_DISK}${part_num}" "$BACKUP_DIR" || die "Failed to mount root partition"

    # If UEFI, format and mount ESP
    local esp_mounted=0
    if [ "$FIRMWARE" = "UEFI" ]; then
        mkfs.vfat -F 32 -n "ESP" "${SDB_DISK}1" || die "Failed to format ESP"
        mkdir -p "$BACKUP_DIR/boot/efi"
        mount "${SDB_DISK}1" "$BACKUP_DIR/boot/efi" || die "Failed to mount ESP"
        esp_mounted=1
    fi

    # Save original state before copying
    save_original_state

    # Rsync system to sdb (exclude virtual filesystems and the backup dir itself)
    log "Copying system to $BACKUP_DIR (this may take a while)..."
    rsync -aAXv --delete --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","$BACKUP_DIR"} / "$BACKUP_DIR/" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        die "rsync failed. Check $LOG_FILE."
    fi

    # Create necessary directories in the copied system
    for d in dev proc sys run tmp; do
        mkdir -p "$BACKUP_DIR/$d"
    done

    # Mount virtual filesystems for chroot
    mount --bind /dev "$BACKUP_DIR/dev"
    mount --bind /proc "$BACKUP_DIR/proc"
    mount --bind /sys "$BACKUP_DIR/sys"
    mount --bind /run "$BACKUP_DIR/run"

    # Generate new fstab for sdb
    local root_uuid=$(blkid -s UUID -o value "${SDB_DISK}${part_num}")
    local esp_uuid=""
    if [ "$FIRMWARE" = "UEFI" ]; then
        esp_uuid=$(blkid -s UUID -o value "${SDB_DISK}1")
    fi
    generate_temp_fstab "$root_uuid" "$esp_uuid"

    # Install GRUB on sdb
    log "Installing GRUB on $SDB_DISK..."
    chroot "$BACKUP_DIR" /bin/bash <<EOF
    set -e
    grub-install $SDB_DISK
    update-grub
EOF
    if [ $? -ne 0 ]; then
        umount -R "$BACKUP_DIR/dev" "$BACKUP_DIR/proc" "$BACKUP_DIR/sys" "$BACKUP_DIR/run" 2>/dev/null
        [ $esp_mounted -eq 1 ] && umount "$BACKUP_DIR/boot/efi"
        umount "$BACKUP_DIR"
        die "GRUB installation failed"
    fi

    # Cleanup mounts
    umount -R "$BACKUP_DIR/dev" "$BACKUP_DIR/proc" "$BACKUP_DIR/sys" "$BACKUP_DIR/run"
    [ $esp_mounted -eq 1 ] && umount "$BACKUP_DIR/boot/efi"
    umount "$BACKUP_DIR"

    log "Phase 1 completed successfully."
    echo "============================================================"
    echo "Now you must reboot and boot from $SDB_DISK."
    echo "If your system uses BIOS, change boot order in BIOS."
    echo "If UEFI, you may need to select the new entry or use boot menu."
    echo "After booting from sdb, run this script with --phase2"
    echo "============================================================"
}

# Phase 2: Repartition sda and restore data
phase2() {
    log "================== PHASE 2 STARTED =================="
    # Verify we are running from sdb
    if ! is_running_on_sdb; then
        die "Phase 2 must be run while booted from $SDB_DISK."
    fi

    FIRMWARE=$(detect_firmware)
    log "Detected firmware: $FIRMWARE"

    check_tools
    get_user_sizes

    # Ensure sda is not mounted
    if mount | grep -q "$SDA_DISK"; then
        log "Unmounting any mounted partitions on $SDA_DISK..."
        umount -R ${SDA_DISK}* 2>/dev/null || true
    fi

    # Create new partition table on sda with appropriate boot partition
    log "Creating new partition table on $SDA_DISK with $FIRMWARE boot partition..."
    sgdisk -Z "$SDA_DISK" || die "Failed to zap $SDA_DISK"
    sgdisk -o "$SDA_DISK" || die "Failed to create new GPT table"

    local part_num=1
    if [ "$FIRMWARE" = "BIOS" ]; then
        sgdisk -n $part_num:0:+1M -t $part_num:ef02 -c $part_num:"bios_boot" "$SDA_DISK" || die "Failed to create BIOS boot partition"
        part_num=2
    else
        sgdisk -n $part_num:0:+512M -t $part_num:ef00 -c $part_num:"ESP" "$SDA_DISK" || die "Failed to create ESP"
        part_num=2
    fi

    # Create data partitions according to PART_MOUNTS
    # We'll create all except the last one with specific size, last uses rest
    local total_mounts=${#PART_MOUNTS[@]}
    for ((i=0; i<total_mounts-1; i++)); do
        local mountspec="${PART_MOUNTS[$i]}"
        local name="${mountspec%%:*}"
        local size="${PART_SIZES[$name]}"
        sgdisk -n $part_num:0:+${size}G -t $part_num:8300 -c $part_num:"$name" "$SDA_DISK" || die "Failed to create $name partition"
        part_num=$(( part_num + 1 ))
    done
    # Last partition uses remaining space
    local last_mountspec="${PART_MOUNTS[$total_mounts-1]}"
    local last_name="${last_mountspec%%:*}"
    sgdisk -n $part_num:0:0 -t $part_num:8300 -c $part_num:"$last_name" "$SDA_DISK" || die "Failed to create $last_name partition"

    partprobe "$SDA_DISK"
    sleep 3

    # Get list of all partitions on sda, sorted
    local all_parts=($(ls ${SDA_DISK}* | grep -E "${SDA_DISK}[0-9]+" | sort -V))
    # First partition is boot partition (bios_boot or ESP) - skip it for data
    local data_parts=("${all_parts[@]:1}")  # from index 1 onward

    # Format data partitions with nodiscard
    log "Formatting new partitions with nodiscard (fast mode)..."
    local i=0
    for mountspec in "${PART_MOUNTS[@]}"; do
        local name="${mountspec%%:*}"
        local mpoint="${mountspec#*:}"
        local part="${data_parts[$i]}"
        log "Formatting $part as ext4 with label $name"
        mkfs.ext4 -F -E nodiscard -L "$name" "$part" >> "$LOG_FILE" 2>&1 || die "Failed to format $part"
        i=$(( i + 1 ))
    done

    # If UEFI, format ESP
    if [ "$FIRMWARE" = "UEFI" ]; then
        log "Formatting ESP ${all_parts[0]} as vfat"
        mkfs.vfat -F 32 -n "ESP" "${all_parts[0]}" >> "$LOG_FILE" 2>&1 || die "Failed to format ESP"
    fi

    # Mount new root
    mkdir -p "$NEW_ROOT"
    # Find root partition (mount point "/")
    local root_part=""
    i=0
    for mountspec in "${PART_MOUNTS[@]}"; do
        local name="${mountspec%%:*}"
        local mpoint="${mountspec#*:}"
        if [ "$mpoint" = "/" ]; then
            root_part="${data_parts[$i]}"
            break
        fi
        i=$(( i + 1 ))
    done
    mount "$root_part" "$NEW_ROOT" || die "Failed to mount root"

    # Mount other data partitions under NEW_ROOT
    i=0
    for mountspec in "${PART_MOUNTS[@]}"; do
        local name="${mountspec%%:*}"
        local mpoint="${mountspec#*:}"
        local part="${data_parts[$i]}"
        if [ "$mpoint" != "/" ]; then
            mkdir -p "${NEW_ROOT}${mpoint}"
            mount "$part" "${NEW_ROOT}${mpoint}" || die "Failed to mount $mpoint"
        fi
        i=$(( i + 1 ))
    done

    # If UEFI, mount ESP at /boot/efi
    if [ "$FIRMWARE" = "UEFI" ]; then
        mkdir -p "${NEW_ROOT}/boot/efi"
        mount "${all_parts[0]}" "${NEW_ROOT}/boot/efi" || die "Failed to mount ESP"
    fi

    # Restore data from sdb (current root) to new sda
    log "Restoring data from / to $NEW_ROOT..."
    rsync -aAXv --delete --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","$NEW_ROOT"} / "$NEW_ROOT/" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        die "rsync restore failed."
    fi

    # Generate fstab for new system
    log "Generating /etc/fstab for new system"
    local fstab_file="$NEW_ROOT/etc/fstab"
    > "$fstab_file"
    i=0
    for mountspec in "${PART_MOUNTS[@]}"; do
        local name="${mountspec%%:*}"
        local mpoint="${mountspec#*:}"
        local part="${data_parts[$i]}"
        local uuid=$(blkid -s UUID -o value "$part")
        local opts="defaults,noatime"
        if [ "$mpoint" = "/tmp" ]; then
            opts="defaults,noatime,nosuid,nodev,noexec"
        fi
        local dump_pass="0 1"
        if [ "$mpoint" = "/" ] || [ "$mpoint" = "/boot" ]; then
            dump_pass="0 1"
        else
            dump_pass="0 2"
        fi
        echo "UUID=$uuid $mpoint ext4 $opts $dump_pass" >> "$fstab_file"
        i=$(( i + 1 ))
    done

    # If UEFI, add ESP entry
    if [ "$FIRMWARE" = "UEFI" ]; then
        local esp_uuid=$(blkid -s UUID -o value "${all_parts[0]}")
        echo "UUID=$esp_uuid /boot/efi vfat defaults 0 2" >> "$fstab_file"
    fi

    # Copy any swap entries from original fstab if they exist
    if [ -f "$ORIGINAL_FSTAB" ]; then
        grep -E '^[^#]*swap' "$ORIGINAL_FSTAB" >> "$fstab_file" 2>/dev/null || true
    fi
    log "New fstab created."

    # Install GRUB on sda
    log "Installing GRUB on $SDA_DISK..."
    mount --bind /dev "$NEW_ROOT/dev"
    mount --bind /proc "$NEW_ROOT/proc"
    mount --bind /sys "$NEW_ROOT/sys"
    mount --bind /run "$NEW_ROOT/run"
    chroot "$NEW_ROOT" /bin/bash <<EOF
    set -e
    grub-install $SDA_DISK
    update-grub
EOF
    if [ $? -ne 0 ]; then
        umount -R "$NEW_ROOT/dev" "$NEW_ROOT/proc" "$NEW_ROOT/sys" "$NEW_ROOT/run" 2>/dev/null
        die "GRUB installation failed"
    fi
    umount -R "$NEW_ROOT/dev" "$NEW_ROOT/proc" "$NEW_ROOT/sys" "$NEW_ROOT/run"

    # Cleanup mounts
    umount -R "$NEW_ROOT" || true

    log "Phase 2 completed successfully."
    echo "============================================================"
    echo "Now reboot and boot from $SDA_DISK (original disk)."
    echo "After booting into the new system, run this script with --phase3"
    echo "to configure LVM on $SDB_DISK for /mnt/data."
    echo "============================================================"
}

# Phase 3: Setup LVM on sdb for /mnt/data
phase3() {
    log "================== PHASE 3 STARTED =================="
    # Verify we are running from sda
    if is_running_on_sdb; then
        die "Phase 3 must be run while booted from $SDA_DISK."
    fi

    # Wipe sdb and create LVM
    log "Preparing $SDB_DISK for LVM..."
    sgdisk -Z "$SDB_DISK" || die "Failed to wipe $SDB_DISK"
    sgdisk -n 1:0:0 -t 1:8e00 -c 1:"lvm" "$SDB_DISK" || die "Failed to create LVM partition"
    partprobe "$SDB_DISK"
    sleep 2

    pvcreate "${SDB_DISK}1" || die "Failed to create PV"
    vgcreate vg_data "${SDB_DISK}1" || die "Failed to create VG"
    lvcreate -l 100%FREE -n lv_data vg_data || die "Failed to create LV"
    log "Formatting LVM volume with nodiscard..."
    mkfs.ext4 -F -E nodiscard /dev/vg_data/lv_data || die "Failed to format LV"

    mkdir -p /mnt/data
    mount /dev/vg_data/lv_data /mnt/data || die "Failed to mount /mnt/data"

    # Add to fstab
    local uuid=$(blkid -s UUID -o value /dev/vg_data/lv_data)
    echo "UUID=$uuid /mnt/data ext4 defaults 0 2" >> /etc/fstab
    log "LVM setup completed. /mnt/data is ready."

    # Optionally clean up backup files
    rm -f "$PARTITION_BACKUP" "$UUID_BACKUP" "$ORIGINAL_FSTAB" 2>/dev/null || true
    log "Phase 3 completed. All done."
}

# ---------------------------- Main --------------------------------------------
main() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root."
        exit 1
    fi

    case "${1:-}" in
        --phase2)
            phase2
            ;;
        --phase3)
            phase3
            ;;
        --rollback)
            rollback_sda
            ;;
        *)
            # Default: phase1
            phase1
            ;;
    esac
}

main "$@"
