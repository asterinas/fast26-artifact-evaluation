#!/bin/bash

# --- Configuration ---
# Device name for dmsetup
DEV_NAME="test-sworndisk"
# Path to the compiled kernel module
MODULE_PATH="/home/yxy/ssd/mlsdisk/linux/dm_sworndisk.ko"
# Backend block device (60G virtio-blk disk)
BACKEND_DISK="/dev/vda"
# Mapping size: 104857600 sectors = 50GiB
SECTORS=104857600
# 128-bit encryption key (Hex format)
KEY="12345678123456781234567812345678"

echo "==== Initialization: Resetting SwornDisk Target ===="

# 1. Cleanup: Remove existing Device Mapper target if active
if dmsetup status "$DEV_NAME" >/dev/null 2>&1; then
    echo "[*] Removing existing device: $DEV_NAME"
    dmsetup remove "$DEV_NAME"
fi

# 2. Module Management: Reload the Rust kernel module to apply latest changes
if lsmod | grep -q "dm_sworndisk"; then
    echo "[*] Unloading existing module: dm_sworndisk"
    rmmod dm_sworndisk
fi

if [ -f "$MODULE_PATH" ]; then
    echo "[*] Loading new module from: $MODULE_PATH"
    insmod "$MODULE_PATH"
else
    echo "[!] Error: Module file not found at $MODULE_PATH"
    exit 1
fi

# 3. Environment Check: Ensure essential device nodes exist
# Create /dev/vda if missing (standard for init=/bin/bash environment)
[ ! -b /dev/vda ] && mknod /dev/vda b 253 0
# Create DM control node if missing
[ ! -c /dev/mapper/control ] && dmsetup mknodes

# 4. Target Creation: Map the logical device to the backend disk
# Format: 0 [sector_count] sworndisk [op] [backend_path] [key]
echo "[*] Creating Device Mapper device..."
echo "0 $SECTORS sworndisk create $BACKEND_DISK $KEY" | dmsetup create "$DEV_NAME"

# 5. Node Synchronization: Force create the /dev/mapper/ entry
dmsetup mknodes "$DEV_NAME"

# 6. Verification: Confirm the device is ready for I/O
if [ -b "/dev/mapper/$DEV_NAME" ]; then
    echo "==== Success: Device Mapper target is ACTIVE ===="
    dmsetup info "$DEV_NAME" | grep -E "Name|State|Major"
else
    echo "[!] Failure: Device node /dev/mapper/$DEV_NAME was not created."
    dmesg | tail -n 15
    exit 1
fi
