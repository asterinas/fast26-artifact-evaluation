#!/bin/bash

# Simple helper to unmount SwornDisk and CryptDisk filesystems.

set -e

SWORNDISK_MOUNT="/mnt/sworndisk"
CRYPTDISK_MOUNT="/mnt/cryptdisk"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

umount_target() {
    local mountpoint=$1

    if ! mountpoint -q "$mountpoint"; then
        echo -e "${YELLOW}${mountpoint} is not mounted; skipping${NC}"
        return 0
    fi

    echo -e "${YELLOW}Unmounting ${mountpoint}...${NC}"
    if umount "$mountpoint"; then
        echo -e "${GREEN}✓ Unmounted ${mountpoint}${NC}"
    else
        echo -e "${RED}✗ Failed to unmount ${mountpoint}${NC}"
        return 1
    fi
}

echo -e "${YELLOW}========== Unmounting Filesystems ==========${NC}"
umount_target "${SWORNDISK_MOUNT}"
umount_target "${CRYPTDISK_MOUNT}"
echo -e "${GREEN}Done.${NC}"
