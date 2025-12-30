#!/bin/bash

# --- Configuration ---
BACKEND_DISK="/dev/vdb"
INTEGRITY_DEV="test-integrity"
CRYPT_DEV="test-crypt"
KEY="12345678123456781234567812345678"
TAG_SIZE=28

echo "==== Initializing Integrity + Crypt Layers ===="

# 1. Environment prep
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /run/cryptsetup
[ ! -b /dev/vdb ] && mknod /dev/vdb b 253 16
[ ! -c /dev/mapper/control ] && dmsetup mknodes

# 2. Clean previous devices
echo "[*] Cleaning up..."
dmsetup remove "$CRYPT_DEV" >/dev/null 2>&1
dmsetup remove "$INTEGRITY_DEV" >/dev/null 2>&1

# 3. Wipe beginning of disk
dd if=/dev/zero of="$BACKEND_DISK" bs=1M count=10 conv=notrunc status=none

# 4. Probe max usable sectors
echo "[*] Probing max usable sectors..."
dmsetup create "$INTEGRITY_DEV" --table "0 1 integrity $BACKEND_DISK 0 $TAG_SIZE D 0"

# Get status
STATUS_LINE=$(dmsetup status "$INTEGRITY_DEV")
# On 6.6 kernels, usable size is typically column 5
MAX_SECTORS=$(echo "$STATUS_LINE" | awk '{print $5}')

dmsetup remove "$INTEGRITY_DEV"

# Fallback: if column 5 is not numeric, try column 4
if ! [[ "$MAX_SECTORS" =~ ^[0-9]+$ ]]; then
    MAX_SECTORS=$(echo "$STATUS_LINE" | awk '{print $4}')
fi

if [ -z "$MAX_SECTORS" ] || [ "$MAX_SECTORS" -eq 0 ]; then
    echo "[!] Error: Failed to parse MAX_SECTORS. Status was: $STATUS_LINE"
    exit 1
fi
echo "[*] Detected Max Sectors: $MAX_SECTORS"

# 5. Create integrity layer
echo "[*] Creating dm-integrity layer..."
dmsetup create "$INTEGRITY_DEV" --table "0 $MAX_SECTORS integrity $BACKEND_DISK 0 $TAG_SIZE D 0"
dmsetup mknodes "$INTEGRITY_DEV"

# 6. Create dm-crypt layer
echo "[*] Creating dm-crypt layer..."
echo "$KEY" | cryptsetup open --type plain --key-file - --cipher aes-xts-plain64 "/dev/mapper/$INTEGRITY_DEV" "$CRYPT_DEV"

# 7. Verify
if [ -b "/dev/mapper/$CRYPT_DEV" ]; then
    echo "==== Success: /dev/mapper/$CRYPT_DEV is ACTIVE ===="
    # Print final size for confirmation
    REAL_SIZE=$(blockdev --getsize64 /dev/mapper/$CRYPT_DEV | awk '{print $1/1024/1024/1024 " GiB"}')
    echo "Total Usable Capacity: $REAL_SIZE"
else
    echo "[!] Failure: Check dmesg."
    dmesg | tail -n 10
fi
