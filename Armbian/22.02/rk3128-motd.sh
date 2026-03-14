#!/usr/bin/env bash

set -u

# Install as /etc/update-motd.d/99-rk3128 on the target system.

if [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_HEAD="$(printf '\033[1;36m')"
    C_KEY="$(printf '\033[1;33m')"
    C_VAL="$(printf '\033[0;37m')"
    C_DIM="$(printf '\033[2m')"
else
    C_RESET=""
    C_HEAD=""
    C_KEY=""
    C_VAL=""
    C_DIM=""
fi

BORDER_LINE="======================================================================"
KEY_WIDTH=12
VALUE_WIDTH=20
PAIR_GAP=2

repeat_char() {
    local count="$1"
    local char="$2"
    local out=""

    while [ "${#out}" -lt "$count" ]; do
        out="${out}${char}"
    done

    printf '%s\n' "${out:0:$count}"
}

pad_right() {
    local text="$1"
    local width="$2"
    local padding

    if [ "${#text}" -ge "$width" ]; then
        printf '%s' "$text"
        return
    fi

    padding="$(repeat_char "$((width - ${#text}))" " ")"
    printf '%s%s' "$text" "$padding"
}

format_pair() {
    printf '%-*s %s' "$KEY_WIDTH" "$1" "$2"
}

single() {
    printf "%b%-*s%b %b%s%b\n" "$C_KEY" "$KEY_WIDTH" "$1" "$C_RESET" "$C_VAL" "$2" "$C_RESET"
}

row() {
    local left_value right_text gap

    left_value="$(pad_right "$2" "$VALUE_WIDTH")"
    right_text="$(format_pair "$3" "$4")"
    gap="$(repeat_char "$PAIR_GAP" " ")"

    if [ "${#2}" -gt "$VALUE_WIDTH" ] || [ "${#right_text}" -gt 34 ]; then
        single "$1" "$2"
        single "$3" "$4"
        return
    fi

    printf "%b%-*s%b %b%s%b%b%s%b%b%-*s%b %b%s%b\n" \
        "$C_KEY" "$KEY_WIDTH" "$1" "$C_RESET" \
        "$C_VAL" "$left_value" "$C_RESET" \
        "$C_VAL" "$gap" "$C_RESET" \
        "$C_KEY" "$KEY_WIDTH" "$3" "$C_RESET" \
        "$C_VAL" "$4" "$C_RESET"
}

print_banner() {
    if ! command -v toilet >/dev/null 2>&1; then
        printf '%s\n' "ERROR: toilet is required for rk3128-motd.sh" >&2
        return 1
    fi

    printf "%b" "$C_HEAD"
    toilet -f small "RK3128-Armbian" 2>/dev/null || toilet "RK3128-Armbian"
    printf "%b" "$C_RESET"
}

read_first_line() {
    local path="$1"
    [ -r "$path" ] || return 1
    IFS= read -r line < "$path" || true
    printf '%s\n' "${line:-}"
}

get_board_name() {
    local value

    value="$(read_first_line /proc/device-tree/model 2>/dev/null || true)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
        return
    fi

    value="$(awk -F: '/^Hardware|^Model|^system type/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
        return
    fi

    printf '%s\n' "RK3128"
}

get_cpu_model() {
    awk -F: '
        /^model name/ || /^Processor/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
            exit
        }
    ' /proc/cpuinfo 2>/dev/null
}

get_cpu_freq() {
    local freq

    if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true)"
        [ -n "$freq" ] && printf '%.0f MHz\n' "$(awk "BEGIN { print ${freq}/1000 }")" && return
    fi

    awk -F: '/cpu MHz/ {gsub(/^[ \t]+/, "", $2); printf "%.0f MHz\n", $2; exit}' /proc/cpuinfo 2>/dev/null
}

get_cpu_temp() {
    local zone temp

    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$zone" ] || continue
        temp="$(cat "$zone" 2>/dev/null || true)"
        [ -n "$temp" ] || continue
        if [ "$temp" -gt 1000 ] 2>/dev/null; then
            printf '%.1f C\n' "$(awk "BEGIN { print ${temp}/1000 }")"
        else
            printf '%s C\n' "$temp"
        fi
        return
    done

    printf '%s\n' "n/a"
}

get_mem_usage() {
    free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}'
}

get_swap_usage() {
    free -h 2>/dev/null | awk '/^Swap:/ {print $3 " / " $2}'
}

get_root_usage() {
    df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}'
}

get_os_version() {
    awk -F= '
        /^PRETTY_NAME=/ {
            gsub(/^"/, "", $2)
            gsub(/"$/, "", $2)
            print $2
            exit
        }
    ' /etc/os-release 2>/dev/null
}

get_loadavg() {
    awk '{print $1 " " $2 " " $3}' /proc/loadavg 2>/dev/null
}

get_uptime_pretty() {
    uptime -p 2>/dev/null | sed 's/^up //'
}

get_ipv4_list() {
    ip -4 -o addr show scope global 2>/dev/null | awk '
        {
            item = $2 ": " $4
            if (count == 0) {
                out = item
            } else {
                out = out ", " item
            }
            count++
        }
        END {
            if (count > 0) {
                print out
            }
        }
    '
}

get_ipv6_list() {
    ip -6 -o addr show scope global 2>/dev/null | awk '
        {
            item = $2 ": " $4
            if (count == 0) {
                out = item
            } else {
                out = out ", " item
            }
            count++
        }
        END {
            if (count > 0) {
                print out
            }
        }
    '
}

get_default_iface() {
    ip route 2>/dev/null | awk '/^default/ {print $5; exit}'
}

get_root_device() {
    findmnt -n -o SOURCE / 2>/dev/null
}

get_process_count() {
    ps -e --no-headers 2>/dev/null | wc -l | awk '{print $1}'
}

get_updates_hint() {
    if command -v apt >/dev/null 2>&1; then
        printf '%s\n' "apt update && apt upgrade"
    else
        printf '%s\n' "system package manager unavailable"
    fi
}

BOARD_NAME="$(get_board_name)"
CPU_MODEL="$(get_cpu_model)"
CPU_FREQ="$(get_cpu_freq)"
CPU_TEMP="$(get_cpu_temp)"
MEM_USAGE="$(get_mem_usage)"
SWAP_USAGE="$(get_swap_usage)"
ROOT_USAGE="$(get_root_usage)"
OS_VERSION="$(get_os_version)"
LOAD_AVG="$(get_loadavg)"
UPTIME_PRETTY="$(get_uptime_pretty)"
IPV4_LIST="$(get_ipv4_list)"
IPV6_LIST="$(get_ipv6_list)"
DEFAULT_IFACE="$(get_default_iface)"
ROOT_DEVICE="$(get_root_device)"
PROC_COUNT="$(get_process_count)"
KERNEL_INFO="$(uname -srmo 2>/dev/null)"
HOST_NAME="$(hostname 2>/dev/null)"
CPU_CORES="$(nproc 2>/dev/null || echo n/a)"

[ -n "${CPU_MODEL:-}" ] || CPU_MODEL="ARM"
[ -n "${CPU_FREQ:-}" ] || CPU_FREQ="n/a"
[ -n "${MEM_USAGE:-}" ] || MEM_USAGE="n/a"
[ -n "${SWAP_USAGE:-}" ] || SWAP_USAGE="n/a"
[ -n "${ROOT_USAGE:-}" ] || ROOT_USAGE="n/a"
[ -n "${OS_VERSION:-}" ] || OS_VERSION="n/a"
[ -n "${LOAD_AVG:-}" ] || LOAD_AVG="n/a"
[ -n "${UPTIME_PRETTY:-}" ] || UPTIME_PRETTY="n/a"
[ -n "${IPV4_LIST:-}" ] || IPV4_LIST="n/a"
[ -n "${IPV6_LIST:-}" ] || IPV6_LIST="n/a"
[ -n "${DEFAULT_IFACE:-}" ] || DEFAULT_IFACE="n/a"
[ -n "${ROOT_DEVICE:-}" ] || ROOT_DEVICE="n/a"
[ -n "${PROC_COUNT:-}" ] || PROC_COUNT="n/a"
[ -n "${KERNEL_INFO:-}" ] || KERNEL_INFO="n/a"
[ -n "${HOST_NAME:-}" ] || HOST_NAME="n/a"
[ -n "${CPU_CORES:-}" ] || CPU_CORES="n/a"

print_banner

printf "%b%s running on Kernel: %s%b\n\n" "$C_HEAD" "$OS_VERSION" "$KERNEL_INFO" "$C_RESET"

printf "%b%s%b\n" "$C_DIM" "$BORDER_LINE" "$C_RESET"
row "Board" "$BOARD_NAME" "Hostname" "$HOST_NAME"
single "CPU" "$CPU_MODEL"
row "CPU Freq" "$CPU_FREQ" "CPU Temp" "$CPU_TEMP"
row "Cores" "$CPU_CORES" "Processes" "$PROC_COUNT"
row "Memory" "$MEM_USAGE" "Swap" "$SWAP_USAGE"
row "Root FS" "$ROOT_USAGE" "Root Dev" "$ROOT_DEVICE"
row "Load" "$LOAD_AVG" "Uptime" "$UPTIME_PRETTY"
single "IPv4" "$IPV4_LIST"
single "IPv6" "$IPV6_LIST"
single "Default IF" "$DEFAULT_IFACE"
single "Updates" "$(get_updates_hint)"
printf "%b%s%b\n" "$C_DIM" "$BORDER_LINE" "$C_RESET"

printf "\n%bTips%b\n" "$C_DIM" "$C_RESET"
printf "1. This build is based on Armbian for RK322x. More RK3128 notes and build updates live at %bchieunhatnang.de%b.\n" \
    "$C_KEY" "$C_RESET"
printf "2. Run %brk3128-config%b to configure the board.\n" \
    "$C_KEY" "$C_RESET"
