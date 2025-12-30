#!/bin/bash

# ============================================================
# DEVICE AND MOUNT PATH CONFIGURATION
# ============================================================
SWORNDISK_DEVICE="/dev/mapper/test-sworndisk"
SWORNDISK_MOUNT="/mnt/sworndisk"

CRYPTDISK_DEVICE="/dev/mapper/test-crypt"
CRYPTDISK_MOUNT="/mnt/cryptdisk"

# Filesystem type (ext4, xfs, etc.)
FS_TYPE="ext4"

# ============================================================
# Script Configuration
# ============================================================
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

function mount_filesystem() {
    local device=$1
    local mountpoint=$2
    local fs_type=$3

    # Check if device exists
    if [ ! -b "$device" ]; then
        echo -e "${RED}Error: Device $device not found or not a block device${NC}"
        return 1
    fi

    # Create mount point if it doesn't exist
    if [ ! -d "$mountpoint" ]; then
        echo -e "${YELLOW}Creating mount point: $mountpoint${NC}"
        mkdir -p "$mountpoint"
    fi

    # Unmount if already mounted
    if mountpoint -q "$mountpoint"; then
        echo -e "${YELLOW}Unmounting existing filesystem at $mountpoint${NC}"
        umount "$mountpoint"
    fi

    # Create filesystem
    echo -e "${YELLOW}Creating ${fs_type} filesystem on $device${NC}"
    mkfs.${fs_type} -F "$device" > /dev/null 2>&1

    # Mount filesystem
    echo -e "${YELLOW}Mounting $device to $mountpoint${NC}"
    mount "$device" "$mountpoint"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Successfully mounted $device to $mountpoint${NC}"
        return 0
    else
        echo -e "${RED}Failed to mount $device to $mountpoint${NC}"
        return 1
    fi
}

function main() {
    echo -e "${YELLOW}========== Mounting Filesystems ==========${NC}\n"

    # Mount sworndisk
    echo -e "${YELLOW}Setting up sworndisk filesystem...${NC}"
    mount_filesystem "$SWORNDISK_DEVICE" "$SWORNDISK_MOUNT" "$FS_TYPE"

    echo ""

    # Mount cryptdisk
    echo -e "${YELLOW}Setting up cryptdisk filesystem...${NC}"
    mount_filesystem "$CRYPTDISK_DEVICE" "$CRYPTDISK_MOUNT" "$FS_TYPE"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Filesystem mounting complete!${NC}"
    echo -e "${GREEN}========================================${NC}\n"

    # Show mount status
    echo -e "${YELLOW}Current mount status:${NC}"
    df -h | grep -E "(Filesystem|$SWORNDISK_MOUNT|$CRYPTDISK_MOUNT)"
}

main "$@"
