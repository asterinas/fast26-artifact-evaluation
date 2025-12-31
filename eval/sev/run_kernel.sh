#!/bin/bash

# Configuration Paths
KERNEL_IMG="$HOME/ssd/linux/arch/x86/boot/bzImage"
SSD_DISK_A="$HOME/ssd/sworn.img"
SSD_DISK_B="$HOME/ssd/crypt.img"
HOST_SHARED_DIR="/" 

if [ ! -f "$KERNEL_IMG" ]; then
    echo "Error: Kernel image not found at $KERNEL_IMG"
    exit 1
fi

echo "==== Launching QEMU (Fixed Script) ===="

# Run QEMU without inline comments to avoid bash parsing errors
sudo qemu-system-x86_64 \
    -kernel "$KERNEL_IMG" \
    -enable-kvm \
    -cpu host \
    -smp 16,sockets=1,cores=8,threads=2 \
    -m 50G \
    -nographic \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -append "console=ttyS0 root=/dev/root rootfstype=9p rootflags=trans=virtio,version=9p2000.L rw init=/home/yxy/ssd/fast26_ae/sev/guest_init.sh" \
    -virtfs local,path="$HOST_SHARED_DIR",mount_tag=/dev/root,security_model=none,id=root \
    -drive file="$SSD_DISK_A",format=raw,if=virtio,cache=none,aio=native,id=vda \
    -drive file="$SSD_DISK_B",format=raw,if=virtio,cache=none,aio=native,id=vdb
