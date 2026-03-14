#!/usr/bin/env bash

set -euo pipefail

MOUNT_DIR="/mnt/armbian"
ROOTFS_IMG="armbian_rootfs.img"
DEFAULT_EXTEND_SIZE="100M"
DEFAULT_SHRINK_PADDING="64M"

usage() {
    local status="${1:-1}"
    echo "Usage:"
    echo "  $0 h                  # show help"
    echo "  $0 m <image>          # mount image and optionally extend first"
    echo "  $0 c <image>          # mount image and chroot with qemu-arm-static"
    echo "  $0 u                  # unmount image"
    echo "  $0 e <image> [size]   # extend filesystem image (default: ${DEFAULT_EXTEND_SIZE})"
    echo "  $0 s <image>          # shrink filesystem image, repacking if needed"
    exit "$status"
}

die() {
    echo "$*" >&2
    exit 1
}

check_rootfs() {
    file "$1" | grep -qi "filesystem"
}

ensure_mount_dir() {
    if [ -e "$MOUNT_DIR" ] && [ ! -d "$MOUNT_DIR" ]; then
        die "Mount path exists but is not a directory: $MOUNT_DIR"
    fi

    if [ ! -d "$MOUNT_DIR" ]; then
        echo "Creating mount dir: $MOUNT_DIR"
        sudo mkdir -p "$MOUNT_DIR"
    fi
}

prepare_target_image() {
    local img="$1"
    local target_img

    if [ ! -f "$img" ]; then
        die "Image not found: $img"
    fi

    echo "Checking if image is a rootfs..." >&2

    if check_rootfs "$img"; then
        echo "Image already contains filesystem." >&2
        target_img="$img"
    else
        echo "Image does not appear to be a raw filesystem." >&2

        read -r -p "Create rootfs image by skipping first 4M? (y/n): " ans

        if [[ "$ans" != "y" ]]; then
            die "Aborted."
        fi

        echo "Creating $ROOTFS_IMG ..." >&2
        dd if="$img" of="$ROOTFS_IMG" bs=1M skip=4 status=progress

        echo "Re-checking filesystem..." >&2

        if check_rootfs "$ROOTFS_IMG"; then
            echo "Rootfs image created successfully." >&2
            target_img="$ROOTFS_IMG"
        else
            die "Failed to detect filesystem in new image."
        fi
    fi

    printf '%s\n' "$target_img"
}

setup_loop_device() {
    sudo losetup -f --show "$1"
}

detach_loop_device() {
    local loopdev="${1:-}"

    if [ -n "$loopdev" ]; then
        sudo losetup -d "$loopdev" >/dev/null 2>&1 || true
    fi
}

human_size() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$1"
    else
        echo "$1 bytes"
    fi
}

size_to_bytes() {
    local value="$1"

    if command -v numfmt >/dev/null 2>&1; then
        numfmt --from=iec "$value"
    else
        case "$value" in
            *K|*k) echo $(( ${value%[Kk]} * 1024 )) ;;
            *M|*m) echo $(( ${value%[Mm]} * 1024 * 1024 )) ;;
            *G|*g) echo $(( ${value%[Gg]} * 1024 * 1024 * 1024 )) ;;
            *) echo "$value" ;;
        esac
    fi
}

get_fs_header_value() {
    local dev="$1"
    local field="$2"

    sudo dumpe2fs -h "$dev" 2>/dev/null | awk -F: -v field="$field" '
        $1 ~ field {
            gsub(/ /, "", $2)
            print $2
            exit
        }
    '
}

get_image_free_space_bytes() {
    local img="$1"
    local block_size free_blocks

    block_size="$(get_fs_header_value "$img" "^Block size$")"
    free_blocks="$(get_fs_header_value "$img" "^Free blocks$")"

    if [ -z "$block_size" ] || [ -z "$free_blocks" ]; then
        die "Failed to read filesystem free space from $img"
    fi

    echo $((block_size * free_blocks))
}

extend_filesystem() {
    local img="$1"
    local inc="${2:-$DEFAULT_EXTEND_SIZE}"
    local old_size new_size

    old_size="$(stat -c%s "$img")"

    echo "Checking filesystem before extend..."
    sudo e2fsck -f -y "$img" >/dev/null

    echo "Extending image by $inc ..."
    truncate -s +"$inc" "$img"

    echo "Growing filesystem..."
    sudo resize2fs "$img" >/dev/null

    new_size="$(stat -c%s "$img")"

    echo "Extended: $img"
    echo "Size: $(human_size "$old_size") -> $(human_size "$new_size")"
}

prompt_yes_no() {
    local prompt="$1"
    local default_yes="${2:-no}"
    local answer

    if [ ! -e /dev/tty ]; then
        [ "$default_yes" = "yes" ] && return 0
        return 1
    fi

    if [ "$default_yes" = "yes" ]; then
        read -r -p "$prompt [Y/n]: " answer </dev/tty
        case "${answer:-Y}" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    else
        read -r -p "$prompt [y/N]: " answer </dev/tty
        case "${answer:-N}" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

mount_loop_image() {
    local img="$1"
    local mount_dir="$2"
    local options="${3:-}"
    local loopdev

    sudo mkdir -p "$mount_dir"
    loopdev="$(setup_loop_device "$img")"

    if [ -n "$options" ]; then
        sudo mount -o "$options" "$loopdev" "$mount_dir"
    else
        sudo mount "$loopdev" "$mount_dir"
    fi

    printf '%s\n' "$loopdev"
}

umount_loop_image() {
    local mount_dir="$1"
    local loopdev="${2:-}"

    if mountpoint -q "$mount_dir"; then
        sudo umount "$mount_dir"
    fi

    detach_loop_device "$loopdev"
    sudo rmdir "$mount_dir" >/dev/null 2>&1 || true
}

repack_shrink_filesystem() {
    local img="$1"
    local block_size="$2"
    local free_blocks="$3"
    local old_size="$4"
    local used_blocks target_bytes temp_img src_mnt dst_mnt src_loop dst_loop actual_new_size

    used_blocks="$(sudo dumpe2fs -h "$img" 2>/dev/null | awk -F: '
        /^Block count:/ {gsub(/ /, "", $2); block_count=$2}
        /^Free blocks:/ {gsub(/ /, "", $2); free_blocks=$2}
        END {if (block_count != "" && free_blocks != "") print block_count - free_blocks}
    ')"
    if [ -z "$used_blocks" ]; then
        die "Failed to determine used block count for repack: $img"
    fi

    target_bytes=$((used_blocks * block_size + $(size_to_bytes "$DEFAULT_SHRINK_PADDING")))
    temp_img="${img}.repack.tmp"
    src_mnt="$(mktemp -d /tmp/rk3128-src.XXXXXX)"
    dst_mnt="$(mktemp -d /tmp/rk3128-dst.XXXXXX)"
    src_loop=""
    dst_loop=""

    cleanup_repack() {
        umount_loop_image "$src_mnt" "$src_loop"
        umount_loop_image "$dst_mnt" "$dst_loop"
        rm -f "$temp_img"
    }

    trap cleanup_repack EXIT

    echo "Repacking into a fresh ext4 image to reclaim free space..."
    echo "Target size before final tighten: $(human_size "$target_bytes") (${target_bytes} bytes)"

    truncate -s "$target_bytes" "$temp_img"
    sudo mkfs.ext4 -F -q -b "$block_size" "$temp_img"

    src_loop="$(mount_loop_image "$img" "$src_mnt" "ro")"
    dst_loop="$(mount_loop_image "$temp_img" "$dst_mnt")"

    sudo rsync -aHAX --numeric-ids "$src_mnt"/ "$dst_mnt"/
    sync

    umount_loop_image "$src_mnt" "$src_loop"
    src_loop=""
    umount_loop_image "$dst_mnt" "$dst_loop"
    dst_loop=""

    sudo e2fsck -f -y "$temp_img" >/dev/null
    sudo resize2fs -M "$temp_img" >/dev/null

    actual_new_size="$(( $(get_fs_header_value "$temp_img" "^Block size$") * $(get_fs_header_value "$temp_img" "^Block count$") ))"
    truncate -s "$actual_new_size" "$temp_img"
    mv -f "$temp_img" "$img"

    trap - EXIT
    rm -rf "$src_mnt" "$dst_mnt"

    echo "Repacked shrink completed."
    echo "Size: $(human_size "$old_size") (${old_size} bytes) -> $(human_size "$actual_new_size") (${actual_new_size} bytes)"
}

shrink_filesystem() {
    local img="$1"
    local old_size block_size block_count free_blocks new_size actual_new_size freed_bytes

    old_size="$(stat -c%s "$img")"

    echo "Checking filesystem before shrink..."
    sudo e2fsck -f -y "$img" >/dev/null

    echo "Shrinking filesystem to minimum..."
    sudo resize2fs -M "$img" >/dev/null
    sudo e2fsck -f -y "$img" >/dev/null

    block_size="$(get_fs_header_value "$img" "^Block size$")"
    block_count="$(get_fs_header_value "$img" "^Block count$")"
    free_blocks="$(get_fs_header_value "$img" "^Free blocks$")"

    if [ -z "$block_size" ] || [ -z "$block_count" ]; then
        die "Failed to read filesystem size after shrink: $img"
    fi

    new_size=$((block_size * block_count))

    truncate -s "$new_size" "$img"
    actual_new_size="$(stat -c%s "$img")"
    freed_bytes=$((old_size - actual_new_size))

    echo "Shrunk: $img"
    echo "Size: $(human_size "$old_size") (${old_size} bytes) -> $(human_size "$actual_new_size") (${actual_new_size} bytes)"
    if [ "$freed_bytes" -gt 0 ]; then
        echo "Freed: $(human_size "$freed_bytes") (${freed_bytes} bytes)"
    elif [ -n "${free_blocks:-}" ] && [ "$free_blocks" -gt 0 ]; then
        echo "WARN: filesystem still reports $(human_size $((free_blocks * block_size))) of free space after shrink."
        echo "WARN: ext4 metadata/layout may currently prevent shrinking the image file any smaller."
        if prompt_yes_no "Try a slower repack-based shrink fallback?" "yes"; then
            repack_shrink_filesystem "$img" "$block_size" "$free_blocks" "$old_size"
        fi
    fi
}

prompt_mount_extend_size() {
    local free_bytes="$1"
    local answer

    echo "Free space in image: $(human_size "$free_bytes")" >&2

    if [ ! -e /dev/tty ]; then
        echo "Non-interactive shell detected, skipping extend prompt." >&2
        printf '0\n'
        return 0
    fi

    read -r -p "Extend filesystem before mounting? [${DEFAULT_EXTEND_SIZE}, 0 to skip]: " answer </dev/tty
    answer="${answer:-$DEFAULT_EXTEND_SIZE}"
    printf '%s\n' "$answer"
}

prompt_extend_size() {
    local answer

    if [ ! -e /dev/tty ]; then
        printf '%s\n' "$DEFAULT_EXTEND_SIZE"
        return 0
    fi

    read -r -p "Extend filesystem by how much? [${DEFAULT_EXTEND_SIZE}]: " answer </dev/tty
    answer="${answer:-$DEFAULT_EXTEND_SIZE}"
    printf '%s\n' "$answer"
}

mount_image() {
    local img="$1"
    local ask_extend="${2:-yes}"
    local target_img loopdev free_bytes extend_size

    target_img="$(prepare_target_image "$img")"
    ensure_mount_dir

    if mountpoint -q "$MOUNT_DIR"; then
        die "Mount dir is already in use: $MOUNT_DIR"
    fi

    if [[ "$ask_extend" == "yes" ]]; then
        free_bytes="$(get_image_free_space_bytes "$target_img")"
        extend_size="$(prompt_mount_extend_size "$free_bytes")"

        if [[ "$extend_size" != "0" ]]; then
            extend_filesystem "$target_img" "$extend_size"
            free_bytes="$(get_image_free_space_bytes "$target_img")"
            echo "Free space after extend: $(human_size "$free_bytes")"
        fi
    fi

    echo "Setting up loop device..."
    loopdev="$(setup_loop_device "$target_img")"

    echo "Loop device: $loopdev"
    echo "Mounting..."

    sudo mount "$loopdev" "$MOUNT_DIR"

    echo "Mounted at $MOUNT_DIR"
}

mount_chroot_binds() {
    sudo mkdir -p "$MOUNT_DIR/dev" "$MOUNT_DIR/sys" "$MOUNT_DIR/proc" "$MOUNT_DIR/usr/bin"

    if ! mountpoint -q "$MOUNT_DIR/dev"; then
        sudo mount --bind /dev "$MOUNT_DIR/dev"
    fi

    if ! mountpoint -q "$MOUNT_DIR/sys"; then
        sudo mount --bind /sys "$MOUNT_DIR/sys"
    fi

    if ! mountpoint -q "$MOUNT_DIR/proc"; then
        sudo mount -t proc proc "$MOUNT_DIR/proc"
    fi

    if command -v qemu-arm-static >/dev/null 2>&1; then
        sudo cp -f "$(command -v qemu-arm-static)" "$MOUNT_DIR/usr/bin/"
    else
        die "qemu-arm-static not found on host"
    fi
}

chroot_image() {
    local img="$1"

    if ! mountpoint -q "$MOUNT_DIR"; then
        mount_image "$img" "yes"
    else
        echo "Using existing mount at $MOUNT_DIR"
    fi

    mount_chroot_binds

    echo "Entering chroot at $MOUNT_DIR"
    echo "Exit the shell to return to the host."
    sudo chroot "$MOUNT_DIR" /usr/bin/qemu-arm-static /bin/bash
}

umount_image() {
    local loopdev=""

    echo "Unmounting $MOUNT_DIR..."

    if mountpoint -q "$MOUNT_DIR/proc"; then
        sudo umount "$MOUNT_DIR/proc"
    fi

    if mountpoint -q "$MOUNT_DIR/sys"; then
        sudo umount "$MOUNT_DIR/sys"
    fi

    if mountpoint -q "$MOUNT_DIR/dev"; then
        sudo umount "$MOUNT_DIR/dev"
    fi

    if mountpoint -q "$MOUNT_DIR"; then
        loopdev="$(findmnt -n -o SOURCE --target "$MOUNT_DIR" 2>/dev/null || true)"
        sudo umount "$MOUNT_DIR"
    else
        echo "Nothing mounted."
    fi

    if [ -z "$loopdev" ] && [ -f "$ROOTFS_IMG" ]; then
        loopdev="$(losetup -j "$ROOTFS_IMG" | head -n1 | cut -d: -f1 || true)"
    fi

    if [ -n "$loopdev" ]; then
        echo "Detaching $loopdev"
        sudo losetup -d "$loopdev"
    fi

    echo "Done."
}

extend_image_cmd() {
    local target_img
    local size="${2:-}"

    target_img="$(prepare_target_image "$1")"
    if [ -z "$size" ]; then
        size="$(prompt_extend_size)"
    fi
    extend_filesystem "$target_img" "$size"
}

shrink_image_cmd() {
    local target_img

    target_img="$(prepare_target_image "$1")"
    shrink_filesystem "$target_img"
}

if [ "$#" -lt 1 ]; then
    usage
fi

case "$1" in
    h|--help|-h)
        usage 0
        ;;
    m)
        if [ "$#" -ne 2 ]; then
            usage
        fi
        mount_image "$2"
        ;;
    c)
        if [ "$#" -ne 2 ]; then
            usage
        fi
        chroot_image "$2"
        ;;
    u)
        if [ "$#" -ne 1 ]; then
            usage
        fi
        umount_image
        ;;
    e)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage
        fi
        extend_image_cmd "$2" "${3:-}"
        ;;
    s)
        if [ "$#" -ne 2 ]; then
            usage
        fi
        shrink_image_cmd "$2"
        ;;
    *)
        usage
        ;;
esac
