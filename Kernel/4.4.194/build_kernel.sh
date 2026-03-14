#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOLCHAIN_DIR="/mnt/Data/tvbox/rk3128/Toolchain/gcc-linaro-6.3.1-2017.05-x86_64_arm-linux-gnueabihf"
CROSS_COMPILE_PREFIX="${TOOLCHAIN_DIR}/bin/arm-linux-gnueabihf-"

ARCH="arm"
JOBS="$(nproc)"

usage() {
  echo "Usage: $0 [-h|--help]"
  echo "Builds the RK3128 kernel as zImage/zImage.gz."
  echo
  echo "Behavior:"
  echo "  - No positional arguments are used."
  echo "  - The script looks in ${SCRIPT_DIR} for one directory whose name contains '3128'"
  echo "    and that looks like a kernel source root."
  echo "  - Output is always generated in z format."
  echo
  echo "Env overrides:"
  echo "  RK_DEFCONFIG=rk3128_linux_defconfig   (default: rk3128_linux_defconfig)"
  echo "  RK_DTS=rk3128-linux                   (default: rk3128-linux -> rk3128-linux.dtb)"
}

find_kernel_dir() {
  local candidate
  local -a matches=()

  while IFS= read -r candidate; do
    [[ -f "${candidate}/Makefile" ]] || continue
    [[ -d "${candidate}/arch/${ARCH}" ]] || continue
    matches+=("${candidate}")
  done < <(find "${SCRIPT_DIR}" -mindepth 1 -maxdepth 1 -type d -iname "*3128*" | sort)

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "ERROR: no kernel root directory containing '3128' found in ${SCRIPT_DIR}" >&2
    exit 1
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "ERROR: multiple kernel root candidates containing '3128' found:" >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
  fi

  printf '%s\n' "${matches[0]}"
}

is_source_tree_dirty() {
  local -a dirty_paths=(
    ".config"
    ".tmp_versions"
    ".version"
    "include/config"
    "include/generated"
    "Module.symvers"
    "System.map"
    "vmlinux"
    "arch/${ARCH}/boot/zImage"
    "arch/${ARCH}/boot/Image"
  )
  local path

  for path in "${dirty_paths[@]}"; do
    if [[ -e "${KERNEL_DIR}/${path}" ]]; then
      return 0
    fi
  done

  return 1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ $# -ne 0 ]]; then
  usage
  exit 1
fi

KERNEL_DIR="$(find_kernel_dir)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUT_DIR="${SCRIPT_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules"

if [[ ! -x "${CROSS_COMPILE_PREFIX}gcc" ]]; then
  echo "ERROR: toolchain gcc not found: ${CROSS_COMPILE_PREFIX}gcc"
  exit 1
fi

mkdir -p "${BUILD_DIR}" "${OUT_DIR}"

export ARCH
export CROSS_COMPILE="${CROSS_COMPILE_PREFIX}"
export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

RK_DEFCONFIG="${RK_DEFCONFIG:-rk3128_linux_defconfig}"
RK_DTS="${RK_DTS:-rk3128-linux}"

cd "${KERNEL_DIR}"

echo "[*] Kernel dir : ${KERNEL_DIR}"
echo "[*] Build dir  : ${BUILD_DIR}"
echo "[*] Out dir    : ${OUT_DIR}"
echo "[*] DEFCONFIG  : ${RK_DEFCONFIG}"
echo "[*] DTS/DTB    : ${RK_DTS}"
echo "[*] FORMAT     : z"
echo "[*] JOBS       : ${JOBS}"

# Linux 4.4 out-of-tree build fails if the source tree still has generated files.
if is_source_tree_dirty; then
  echo "[*] Source tree is dirty; running make mrproper"
  make mrproper
fi

echo "[*] make O=${BUILD_DIR} ${RK_DEFCONFIG}"
make O="${BUILD_DIR}" "${RK_DEFCONFIG}"

echo "[*] make O=${BUILD_DIR} olddefconfig"
make O="${BUILD_DIR}" olddefconfig

echo "[*] Building zImage + dtbs + modules"
make -j"${JOBS}" O="${BUILD_DIR}" zImage dtbs modules

KERNEL_RELEASE="$(make -s O="${BUILD_DIR}" kernelrelease)"
MODULES_RELEASE_DIR="${MODULES_STAGING_DIR}/lib/modules/${KERNEL_RELEASE}"
ZRAM_CONFIG="$(grep '^CONFIG_ZRAM=' "${BUILD_DIR}/.config" || true)"

ZIMAGE_PATH="${BUILD_DIR}/arch/arm/boot/zImage"
DTB_PATH="${BUILD_DIR}/arch/arm/boot/dts/${RK_DTS}.dtb"
DTB_PATH_ROCKCHIP="${BUILD_DIR}/arch/arm/boot/dts/rockchip/${RK_DTS}.dtb"
ZRAM_KO_PATH="${BUILD_DIR}/drivers/block/zram/zram.ko"
STAGED_ZRAM_KO_PATH="${MODULES_RELEASE_DIR}/kernel/drivers/block/zram/zram.ko"
ESP8089_KO_PATH="${BUILD_DIR}/drivers/net/wireless/esp8089/esp8089.ko"
ESP8089_KO_SOURCE_PATH="${KERNEL_DIR}/drivers/net/wireless/esp8089/esp8089.ko"

if [[ ! -f "${ZIMAGE_PATH}" ]]; then
  echo "ERROR: zImage not found: ${ZIMAGE_PATH}"
  exit 1
fi

cp -av "${ZIMAGE_PATH}" "${OUT_DIR}/zImage"
gzip -c "${ZIMAGE_PATH}" > "${OUT_DIR}/zImage.gz"
cp -av "${BUILD_DIR}/.config" "${OUT_DIR}/kernel.config"
printf '%s\n' "${KERNEL_RELEASE}" > "${OUT_DIR}/kernel.release"

echo "[*] Installing modules into ${MODULES_STAGING_DIR}"
rm -rf "${MODULES_RELEASE_DIR}"
make O="${BUILD_DIR}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install

if [[ "${ZRAM_CONFIG:-}" == "CONFIG_ZRAM=m" ]]; then
  if [[ -f "${STAGED_ZRAM_KO_PATH}" ]]; then
    cp -av "${STAGED_ZRAM_KO_PATH}" "${OUT_DIR}/"
  elif [[ -f "${ZRAM_KO_PATH}" ]]; then
    cp -av "${ZRAM_KO_PATH}" "${OUT_DIR}/"
  else
    echo "WARN: ZRAM is configured as a module but zram.ko was not found"
  fi
elif [[ "${ZRAM_CONFIG:-}" == "CONFIG_ZRAM=y" ]]; then
  echo "[*] ZRAM is built into the kernel image"
fi

if [[ -f "${DTB_PATH}" ]]; then
  cp -av "${DTB_PATH}" "${OUT_DIR}/"
elif [[ -f "${DTB_PATH_ROCKCHIP}" ]]; then
  cp -av "${DTB_PATH_ROCKCHIP}" "${OUT_DIR}/"
else
  echo "WARN: DTB not found:"
  echo "      - ${DTB_PATH}"
  echo "      - ${DTB_PATH_ROCKCHIP}"
  echo "      Copying all DTBs (if any)"
  if compgen -G "${BUILD_DIR}/arch/arm/boot/dts/*.dtb" > /dev/null; then
    cp -av "${BUILD_DIR}/arch/arm/boot/dts/"*.dtb "${OUT_DIR}/" || true
  fi
  echo "      Copying all rockchip DTBs (if any)"
  if compgen -G "${BUILD_DIR}/arch/arm/boot/dts/rockchip/*.dtb" > /dev/null; then
    cp -av "${BUILD_DIR}/arch/arm/boot/dts/rockchip/"*.dtb "${OUT_DIR}/" || true
  fi
fi

if [[ -f "${ESP8089_KO_PATH}" ]]; then
  cp -av "${ESP8089_KO_PATH}" "${OUT_DIR}/"
  cp -av "${ESP8089_KO_PATH}" "${ESP8089_KO_SOURCE_PATH}"
else
  echo "WARN: ESP8089 module not found: ${ESP8089_KO_PATH}"
fi

cat > "${OUT_DIR}/DEPLOYMENT.txt" <<EOF
Kernel release: ${KERNEL_RELEASE}
ZRAM config: ${ZRAM_CONFIG:-CONFIG_ZRAM is not set}

Deploy the matching kernel image, DTB, and the full modules tree from:
  ${MODULES_RELEASE_DIR}

Replace the target's /lib/modules/${KERNEL_RELEASE} directory with the staged one.
Do not keep an older zram.ko alongside a kernel that has zram built in or reconfigured,
otherwise userspace modprobe can recreate the /class/zram-control duplicate warning.
EOF

echo "[*] Done:"
echo "    - ${OUT_DIR}/zImage"
echo "    - ${OUT_DIR}/zImage.gz"
echo "    - ${OUT_DIR}/${RK_DTS}.dtb (if built)"
echo "    - ${OUT_DIR}/kernel.config"
echo "    - ${OUT_DIR}/kernel.release"
echo "    - ${MODULES_RELEASE_DIR}"
echo "    - ${OUT_DIR}/DEPLOYMENT.txt"
echo "    - ${OUT_DIR}/zram.ko (if built as module)"
echo "    - ${OUT_DIR}/esp8089.ko (if built)"
