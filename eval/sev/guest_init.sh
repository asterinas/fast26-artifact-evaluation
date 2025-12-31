#!/bin/bash

# 1. 挂载基础文件系统
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp


export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


mkdir -p /dev/mapper
DM_MINOR=$(cat /proc/misc | grep device-mapper | awk '{print $1}')
if [ -n "$DM_MINOR" ]; then
    mknod /dev/mapper/control c 10 $DM_MINOR
fi



echo 1 > /proc/sys/kernel/sysrq     
dmesg -n 1                         
echo "==== Guest Environment Ready ===="
echo "You can now run: dmsetup create ..."


echo "[*] Initializing network..."
ip link set lo up
ip addr add 127.0.0.1/8 dev lo  
ip link set eth0 up
udhcpc -i eth0 > /dev/null 2>&1 || dhclient eth0 > /dev/null 2>&1


echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 114.114.114.114" >> /etc/resolv.conf

echo "==== Network Ready ===="
stty rows 42 cols 164
export COLUMNS=164
export LINES=42

echo 0 > /proc/sys/kernel/randomize_va_space


exec setsid /bin/bash -i < /dev/ttyS0 > /dev/ttyS0 2>&1

sync
echo "Bash exited. Powering off..."
echo o > /proc/sysrq-trigger




