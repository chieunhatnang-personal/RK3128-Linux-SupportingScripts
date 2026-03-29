#!/usr/bin/env bash

set -e

echo "=== Available removable devices ==="
lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -E "usb|mmc" || true
echo
read -rp "Enter target device (e.g. /dev/sdb): " DEV

if [[ ! -b "$DEV" ]]; then
    echo "Invalid device"
    exit 1
fi

echo "WARNING: This will erase all data on $DEV"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

echo "=== Creating MBR partition table ==="
parted -s "$DEV" mklabel msdos
parted -s "$DEV" mkpart primary ext4 16MB 100%

PART="${DEV}1"
sleep 2

echo "=== Locate images ==="

ask_file() {
    local prompt="$1"
    local default="$2"
    local var
    if [[ -f "$default" ]]; then
        read -rp "$prompt [$default]: " var
        echo "${var:-$default}"
    else
        read -rp "$prompt: " var
        echo "$var"
    fi
}

IDBLOADER=$(ask_file "Path to idbloader.img" "./idbloader.img")
UBOOT=$(ask_file "Path to uboot.img" "./uboot.img")
TRUST=$(ask_file "Path to trust.img" "./trust.img")
ROOTFS=$(ask_file "Path to rootfs.img" "./rootfs.img")

for f in "$IDBLOADER" "$UBOOT" "$TRUST" "$ROOTFS"; do
    [[ -f "$f" ]] || { echo "File not found: $f"; exit 1; }
done

echo "=== Writing bootloader ==="

sudo dd if="$IDBLOADER" of="$DEV" seek=64 conv=fsync
sudo dd if="$UBOOT" of="$DEV" seek=16384 conv=fsync
sudo dd if="$TRUST" of="$DEV" seek=24576 conv=fsync

echo "=== Writing rootfs to partition ==="

sudo dd if="$ROOTFS" of="$PART" conv=fsync

sync

echo "=== Done ==="
echo "Boot device created on $DEV"