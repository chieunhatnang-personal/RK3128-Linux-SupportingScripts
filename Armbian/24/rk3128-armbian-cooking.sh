#!/usr/bin/env bash

set -euo pipefail

MOUNT_DIR="/mnt/armbian"
ROOTFS_IMG="armbian_rootfs.img"
DEFAULT_EXTEND_SIZE="100M"
DEFAULT_SHRINK_PADDING="30M"

usage() {
    local status="${1:-1}"
    echo "Usage:"
    echo "  $0 h                  # show help"
    echo "  $0 m <image>          # mount image and optionally extend first"
    echo "  $0 c <image>          # mount image and chroot with qemu-arm-static"
    echo "  $0 u                  # unmount image"
    echo "  $0 e <image> [size]   # extend filesystem image (default: ${DEFAULT_EXTEND_SIZE})"
    echo "  $0 s <image>          # shrink filesystem image, repacking if needed"
    echo "  $0 o <image>          # optimize rootfs image, shrink, refresh fstab UUID, final fsck"
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

normalize_extend_size() {
    local value="${1:-}"

    value="${value//[[:space:]]/}"

    if [ -z "$value" ]; then
        printf '%s\n' "$DEFAULT_EXTEND_SIZE"
        return 0
    fi

    if [ "$value" = "0" ]; then
        printf '0\n'
        return 0
    fi

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%sM\n' "$value"
        return 0
    fi

    if [[ "$value" =~ ^[0-9]+([KkMmGgTtPp]([Bb]|[iI][Bb])?)$ ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    die "Invalid extend size: $value. Use 0 to skip, a plain number for MiB (example: 100), or a size like 100M, 1G, 512MiB."
}

shrink_padding_blocks() {
    local block_size="$1"
    local padding_bytes

    padding_bytes="$(size_to_bytes "$DEFAULT_SHRINK_PADDING")"
    echo $(( (padding_bytes + block_size - 1) / block_size ))
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

    inc="$(normalize_extend_size "$inc")"

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
    local old_size="$3"
    local used_blocks padding_blocks target_blocks target_bytes temp_img src_mnt dst_mnt src_loop dst_loop actual_new_size actual_free_bytes

    used_blocks="$(sudo dumpe2fs -h "$img" 2>/dev/null | awk -F: '
        /^Block count:/ {gsub(/ /, "", $2); block_count=$2}
        /^Free blocks:/ {gsub(/ /, "", $2); free_blocks=$2}
        END {if (block_count != "" && free_blocks != "") print block_count - free_blocks}
    ')"
    if [ -z "$used_blocks" ]; then
        die "Failed to determine used block count for repack: $img"
    fi

    padding_blocks="$(shrink_padding_blocks "$block_size")"
    target_blocks=$((used_blocks + padding_blocks))
    target_bytes=$((target_blocks * block_size))
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

    echo "Repacking into a fresh ext4 image to leave about ${DEFAULT_SHRINK_PADDING} free..."
    echo "Target image size: $(human_size "$target_bytes") (${target_bytes} bytes)"

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

    actual_new_size="$(stat -c%s "$temp_img")"
    actual_free_bytes="$(get_image_free_space_bytes "$temp_img")"
    mv -f "$temp_img" "$img"

    trap - EXIT
    rm -rf "$src_mnt" "$dst_mnt"

    echo "Repacked shrink completed."
    echo "Size: $(human_size "$old_size") (${old_size} bytes) -> $(human_size "$actual_new_size") (${actual_new_size} bytes)"
    echo "Free space left in filesystem: $(human_size "$actual_free_bytes") (target: about ${DEFAULT_SHRINK_PADDING})"
}

shrink_filesystem() {
    local img="$1"
    local old_size block_size block_count free_blocks used_blocks padding_blocks target_blocks target_bytes new_size actual_new_size freed_bytes free_bytes

    old_size="$(stat -c%s "$img")"

    echo "Checking filesystem before shrink..."
    sudo e2fsck -f -y "$img" >/dev/null

    echo "Shrinking filesystem to minimum..."
    sudo resize2fs -M "$img" >/dev/null
    sudo e2fsck -f -y "$img" >/dev/null

    block_size="$(get_fs_header_value "$img" "^Block size$")"
    block_count="$(get_fs_header_value "$img" "^Block count$")"
    free_blocks="$(get_fs_header_value "$img" "^Free blocks$")"

    if [ -z "$block_size" ] || [ -z "$block_count" ] || [ -z "$free_blocks" ]; then
        die "Failed to read filesystem size after shrink: $img"
    fi

    used_blocks=$((block_count - free_blocks))
    padding_blocks="$(shrink_padding_blocks "$block_size")"
    target_blocks=$((used_blocks + padding_blocks))

    if [ "$target_blocks" -gt "$block_count" ]; then
        target_bytes=$((target_blocks * block_size))
        echo "Adjusting image to leave about ${DEFAULT_SHRINK_PADDING} free after shrink..."
        truncate -s "$target_bytes" "$img"
        sudo resize2fs "$img" "$target_blocks" >/dev/null
        sudo e2fsck -f -y "$img" >/dev/null

        block_size="$(get_fs_header_value "$img" "^Block size$")"
        block_count="$(get_fs_header_value "$img" "^Block count$")"
        free_blocks="$(get_fs_header_value "$img" "^Free blocks$")"
    fi

    new_size=$((block_size * block_count))
    free_bytes=$((free_blocks * block_size))

    truncate -s "$new_size" "$img"
    actual_new_size="$(stat -c%s "$img")"
    freed_bytes=$((old_size - actual_new_size))

    echo "Shrunk: $img"
    echo "Size: $(human_size "$old_size") (${old_size} bytes) -> $(human_size "$actual_new_size") (${actual_new_size} bytes)"
    echo "Free space left in filesystem: $(human_size "$free_bytes") (target: about ${DEFAULT_SHRINK_PADDING})"
    if [ "$freed_bytes" -gt 0 ]; then
        echo "Freed: $(human_size "$freed_bytes") (${freed_bytes} bytes)"
    fi

    if [ "$free_bytes" -gt "$(size_to_bytes "$DEFAULT_SHRINK_PADDING")" ]; then
        echo "WARN: filesystem layout still leaves more free space than the ${DEFAULT_SHRINK_PADDING} target."
        echo "WARN: a repack can often get the image closer to the requested free-space amount."
        if prompt_yes_no "Try a slower repack-based shrink fallback to target about ${DEFAULT_SHRINK_PADDING} free?" "yes"; then
            repack_shrink_filesystem "$img" "$block_size" "$old_size"
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

    read -r -p "Extend filesystem before mounting? [Enter to skip, ${DEFAULT_EXTEND_SIZE} or plain numbers mean MiB]: " answer </dev/tty

    if [ -z "${answer//[[:space:]]/}" ]; then
        printf '0\n'
        return 0
    fi

    normalize_extend_size "$answer"
}

prompt_extend_size() {
    local answer

    if [ ! -e /dev/tty ]; then
        printf '%s\n' "$DEFAULT_EXTEND_SIZE"
        return 0
    fi

    read -r -p "Extend filesystem by how much? [${DEFAULT_EXTEND_SIZE}; plain numbers mean MiB]: " answer </dev/tty
    normalize_extend_size "$answer"
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

    ensure_qemu_arm_static
}

ensure_qemu_arm_static() {
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

run_image_chroot() {
    local script="$1"

    sudo chroot "$MOUNT_DIR" /usr/bin/qemu-arm-static /usr/bin/env -i \
        HOME=/root \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        TERM="${TERM:-dumb}" \
        /bin/bash -c "$script"
}

cleanup_image_contents() {
    local home_dir="$MOUNT_DIR/home"
    local tmp_dir="$MOUNT_DIR/tmp"
    local var_tmp_dir="$MOUNT_DIR/var/tmp"
    local apt_cache_dir="$MOUNT_DIR/var/cache/apt/archives"
    local apt_lists_dir="$MOUNT_DIR/var/lib/apt/lists"
    local log_dir="$MOUNT_DIR/var/log"
    local machine_id="$MOUNT_DIR/etc/machine-id"
    local dbus_machine_id="$MOUNT_DIR/var/lib/dbus/machine-id"

    echo "Removing copied .deb packages from /home ..."
    if [ -d "$home_dir" ]; then
        sudo find "$home_dir" -xdev -type f -name "*.deb" -delete
    fi

    echo "Clearing /tmp and /var/tmp ..."
    if [ -d "$tmp_dir" ]; then
        sudo find "$tmp_dir" -mindepth 1 -xdev -exec rm -rf {} +
    fi
    if [ -d "$var_tmp_dir" ]; then
        sudo find "$var_tmp_dir" -mindepth 1 -xdev -exec rm -rf {} +
    fi

    echo "Clearing apt archive cache ..."
    if [ -d "$apt_cache_dir" ]; then
        sudo find "$apt_cache_dir" -mindepth 1 -xdev -exec rm -rf {} +
    fi

    echo "Clearing apt package lists ..."
    if [ -d "$apt_lists_dir" ]; then
        sudo find "$apt_lists_dir" -mindepth 1 -xdev \
            ! -name "lock" ! -name "partial" \
            -exec rm -rf {} +
    fi

    echo "Truncating active logs and removing rotated/compressed logs ..."
    if [ -d "$log_dir" ]; then
        sudo find "$log_dir" -xdev -type f \
            \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.[0-9].gz" -o -name "*.old" \) \
            -delete
        sudo find "$log_dir" -xdev -type f \
            ! \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.[0-9].gz" -o -name "*.old" \) \
            -exec truncate -s 0 {} +
    fi

    echo "Resetting machine-id ..."
    if [ -e "$machine_id" ]; then
        sudo truncate -s 0 "$machine_id"
    else
        sudo install -m 0644 /dev/null "$machine_id"
    fi

    if [ -e "$dbus_machine_id" ] || [ -L "$dbus_machine_id" ]; then
        sudo rm -f "$dbus_machine_id"
    fi
    if [ -d "$(dirname "$dbus_machine_id")" ]; then
        sudo ln -s /etc/machine-id "$dbus_machine_id"
    fi
}

refresh_rootfs_uuid_in_fstab() {
    local img="$1"
    local temp_mount loopdev uuid fstab temp_fstab

    temp_mount="$(mktemp -d /tmp/rk3128-fstab.XXXXXX)"
    loopdev=""
    fstab="$temp_mount/etc/fstab"
    temp_fstab="$(mktemp /tmp/rk3128-fstab-file.XXXXXX)"

    cleanup_refresh_fstab() {
        umount_loop_image "$temp_mount" "$loopdev"
        rm -f "$temp_fstab"
    }

    trap cleanup_refresh_fstab RETURN

    loopdev="$(mount_loop_image "$img" "$temp_mount")"
    uuid="$(sudo blkid -s UUID -o value "$loopdev" 2>/dev/null || true)"

    if [ -z "$uuid" ]; then
        die "Failed to read filesystem UUID from $loopdev"
    fi

    if [ ! -f "$fstab" ]; then
        echo "No /etc/fstab found in image, skipping UUID refresh."
        return 0
    fi

    if ! awk -v uuid="$uuid" '
        BEGIN { updated = 0 }
        /^[[:space:]]*#/ { print; next }
        NF >= 3 && $2 == "/" && $3 == "ext4" {
            $1 = "UUID=" uuid
            updated = 1
        }
        { print }
        END { exit(updated ? 0 : 2) }
    ' "$fstab" >"$temp_fstab"; then
        echo "No ext4 root entry found in /etc/fstab, skipping UUID refresh."
        return 0
    fi

    sudo cp "$temp_fstab" "$fstab"
    echo "Updated /etc/fstab root UUID to $uuid"
}

optimize_image_cmd() {
    local target_img qemu_preexisting="no" first_login_backup=""

    target_img="$(prepare_target_image "$1")"

    if mountpoint -q "$MOUNT_DIR"; then
        die "Mount dir is already in use: $MOUNT_DIR"
    fi

    cleanup_optimize() {
        if [ "$qemu_preexisting" = "no" ] && [ -e "$MOUNT_DIR/usr/bin/qemu-arm-static" ]; then
            sudo rm -f "$MOUNT_DIR/usr/bin/qemu-arm-static"
        fi
        if [ -n "$first_login_backup" ] && [ -f "$first_login_backup" ] && [ ! -e "$MOUNT_DIR/root/.not_logged_in_yet" ]; then
            sudo install -m 0600 "$first_login_backup" "$MOUNT_DIR/root/.not_logged_in_yet"
        fi
        umount_image >/dev/null 2>&1 || true
        rm -f "$first_login_backup"
    }

    trap cleanup_optimize RETURN

    mount_image "$target_img" "no"
    if [ -e "$MOUNT_DIR/usr/bin/qemu-arm-static" ]; then
        qemu_preexisting="yes"
    fi
    if sudo test -f "$MOUNT_DIR/root/.not_logged_in_yet"; then
        first_login_backup="$(mktemp /tmp/rk3128-firstlogin.XXXXXX)"
        sudo cp "$MOUNT_DIR/root/.not_logged_in_yet" "$first_login_backup"
        sudo chmod 0600 "$first_login_backup"
    fi
    mount_chroot_binds

    echo "Refreshing apt metadata and pruning unneeded packages ..."
    run_image_chroot "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y autoremove && apt-get clean"

    cleanup_image_contents

    cleanup_optimize
    trap - RETURN

    echo "Shrinking optimized image ..."
    shrink_filesystem "$target_img"

    echo "Refreshing root filesystem UUID in /etc/fstab ..."
    refresh_rootfs_uuid_in_fstab "$target_img"

    echo "Running final read-only filesystem check ..."
    sudo e2fsck -f -n "$target_img"
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
    else
        size="$(normalize_extend_size "$size")"
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
    o)
        if [ "$#" -ne 2 ]; then
            usage
        fi
        optimize_image_cmd "$2"
        ;;
    *)
        usage
        ;;
esac
