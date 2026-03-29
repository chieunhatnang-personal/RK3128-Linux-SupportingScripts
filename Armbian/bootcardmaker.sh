#!/usr/bin/env bash

set -e

echo "=== Available removable devices ==="
lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -E "usb|mmc" || true
echo
read -rp "Enter target device (e.g. /dev/sdb or sdb): " DEV

if [[ "$DEV" != /dev/* ]]; then
    DEV="/dev/$DEV"
fi

if [[ ! -b "$DEV" ]]; then
    echo "Invalid device"
    exit 1
fi

echo "WARNING: This will erase all data on $DEV"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

find_mounted_entries() {
    local path
    local target

    while IFS= read -r path; do
        while IFS= read -r target; do
            [[ -n "$target" ]] && printf '%s\t%s\n' "$path" "$target"
        done < <(findmnt -rn -S "$path" -o TARGET 2>/dev/null || true)
    done < <(lsblk -nrpo NAME "$DEV")
}

ensure_unmounted() {
    local mounted_entries=()
    local entry
    local path
    local target
    local force_unmount
    local i

    while IFS= read -r entry; do
        [[ -n "$entry" ]] && mounted_entries+=("$entry")
    done < <(find_mounted_entries)

    (( ${#mounted_entries[@]} == 0 )) && return

    echo "The following device nodes are mounted:"
    for entry in "${mounted_entries[@]}"; do
        IFS=$'\t' read -r path target <<< "$entry"
        printf '  %s -> %s\n' "$path" "$target"
    done

    read -rp "Force unmount all mounted paths on $DEV? [y/N]: " force_unmount
    if [[ ! "$force_unmount" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        echo "Device is mounted. Aborting."
        exit 1
    fi

    for (( i=${#mounted_entries[@]} - 1; i>=0; i-- )); do
        IFS=$'\t' read -r path target <<< "${mounted_entries[$i]}"
        echo "Unmounting $path from $target"
        sudo umount "$path"
    done
}

ensure_unmounted

echo "=== Creating MBR partition table ==="
parted -s "$DEV" mklabel msdos
parted -s "$DEV" mkpart primary ext4 16MB 100%

PART="${DEV}1"
sleep 2

echo "=== Locate images ==="
CURRENT_DIR=$(pwd)

find_required_file() {
    local filename="$1"
    local matches=()

    mapfile -d '' matches < <(find "$CURRENT_DIR" -maxdepth 1 -type f -iname "$filename" -print0 | sort -z)

    if (( ${#matches[@]} == 0 )); then
        echo "Required file not found in $CURRENT_DIR: $filename" >&2
        exit 1
    fi

    if (( ${#matches[@]} > 1 )); then
        echo "Multiple matches found in $CURRENT_DIR for $filename:" >&2
        local match
        for match in "${matches[@]}"; do
            printf '  %s\n' "${match#$CURRENT_DIR/}" >&2
        done
        exit 1
    fi

    printf '%s\n' "${matches[0]}"
}

choose_rootfs_file() {
    local matches=()
    local i
    local choice

    mapfile -d '' matches < <(find "$CURRENT_DIR" -maxdepth 1 -type f -iname '*rootfs*' -print0 | sort -z)

    if (( ${#matches[@]} == 0 )); then
        echo "No files containing 'rootfs' found in $CURRENT_DIR" >&2
        exit 1
    fi

    echo "Available rootfs files in $CURRENT_DIR:" >&2
    for i in "${!matches[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${matches[$i]#$CURRENT_DIR/}" >&2
    done

    while true; do
        read -rp "Select rootfs file [1-${#matches[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
            printf '%s\n' "${matches[$((choice - 1))]}"
            return
        fi
        echo "Invalid selection" >&2
    done
}

IDBLOADER=$(find_required_file "idbloader.img")
UBOOT=$(find_required_file "uboot.img")
TRUST=$(find_required_file "trust.img")
ROOTFS=$(choose_rootfs_file)

echo "Using idbloader: ${IDBLOADER#$CURRENT_DIR/}"
echo "Using uboot: ${UBOOT#$CURRENT_DIR/}"
echo "Using trust: ${TRUST#$CURRENT_DIR/}"
echo "Using rootfs: ${ROOTFS#$CURRENT_DIR/}"

echo "=== Writing bootloader ==="

sudo dd if="$IDBLOADER" of="$DEV" seek=64 conv=fsync
sudo dd if="$UBOOT" of="$DEV" seek=16384 conv=fsync
sudo dd if="$TRUST" of="$DEV" seek=24576 conv=fsync

echo "=== Writing rootfs to partition ==="

sudo dd if="$ROOTFS" of="$PART" conv=fsync

sync

echo "=== Done ==="
echo "Boot device created on $DEV"
