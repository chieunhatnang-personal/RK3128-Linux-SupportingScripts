#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOLCHAIN_DIR="/mnt/Data/tvbox/rk3128/Toolchain/gcc-arm-10.3-2021.07-x86_64-arm-none-linux-gnueabihf"
CROSS_COMPILE_PREFIX="${TOOLCHAIN_DIR}/bin/arm-none-linux-gnueabihf-"

ARCH="arm"
JOBS="$(nproc)"

# Optional in-file kernel source override. Exported KERNEL_DIR takes precedence.
ENV_KERNEL_DIR="${KERNEL_DIR:-}"
KERNEL_DIR="/mnt/Data/tvbox/rk3128/Kernel/kernel66/kernel"

usage() {
  echo "Usage: $0 [deb] [-h|--help]"
  echo "Builds the RK3128 kernel either as staged boot artifacts or Debian packages."
  echo
  echo "Behavior:"
  echo "  - No argument: build zImage/zImage.gz, DTB, overlays, and modules into out/."
  echo "  - deb: build Debian kernel packages with bindeb-pkg and copy the generated"
  echo "    .deb files into out/."
  echo "  - The script looks in ${SCRIPT_DIR} for one directory whose name contains '3128'"
  echo "    and that looks like a kernel source root."
  echo "  - build/ and out/ are created next to the resolved kernel directory."
  echo "  - Any DTS overlays in arch/${ARCH}/boot/dts/rockchip/overlay are compiled to dtbo"
  echo "    (falling back to arch/${ARCH}/boot/dts/overlay if needed) and"
  echo "    copied to out/overlay/ in the default artifact mode."
  echo
  echo "Env overrides:"
  echo "  KERNEL_DIR=/path/to/kernel            (priority: env > in-file KERNEL_DIR > auto-detect)"
  echo "  RK_DEFCONFIG=rk3128_linux_tvbox_defconfig   (default: rk3128_linux_tvbox_defconfig)"
  echo "  RK_DTS=rk3128-linux                   (default: rk3128-linux -> rk3128-linux.dtb)"
  echo "  KDEB_SOURCENAME=linux-rk3128          (default in deb mode)"
  echo "  KDEB_PKGVERSION=<version>             (default in deb mode: <kernelrelease>-<buildno>)"
}

resolve_kernel_dir() {
  local candidate="${1}"
  local resolved

  [[ -n "${candidate}" ]] || return 1

  if [[ -d "${candidate}" ]]; then
    resolved="${candidate}"
  elif [[ "${candidate}" != /* && -d "${SCRIPT_DIR}/${candidate}" ]]; then
    resolved="${SCRIPT_DIR}/${candidate}"
  else
    return 1
  fi

  (
    cd "${resolved}" >/dev/null 2>&1
    pwd
  )
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

validate_kernel_dir() {
  local candidate="${1}"

  if [[ ! -d "${candidate}" ]]; then
    echo "ERROR: kernel dir not found: ${candidate}" >&2
    exit 1
  fi

  if [[ ! -f "${candidate}/Makefile" ]]; then
    echo "ERROR: kernel dir is missing Makefile: ${candidate}" >&2
    exit 1
  fi

  if [[ ! -d "${candidate}/arch/${ARCH}" ]]; then
    echo "ERROR: kernel dir is missing arch/${ARCH}: ${candidate}" >&2
    exit 1
  fi
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

resolve_overlay_src_dir() {
  local dir
  local -a candidates=(
    "${KERNEL_DIR}/arch/${ARCH}/boot/dts/rockchip/overlay"
    "${KERNEL_DIR}/arch/${ARCH}/boot/dts/overlay"
  )

  for dir in "${candidates[@]}"; do
    if [[ -d "${dir}" ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
  done

  return 1
}

build_dtbo_overlays() {
  local overlay_src_dir
  local overlay_rel_dir
  local overlay_build_dir
  local overlay_out_dir="${OUT_DIR}/overlay"
  local dtc_bin="${BUILD_DIR}/scripts/dtc/dtc"
  local cpp_bin
  local src name tmp out
  local -a overlay_sources=()

  if ! overlay_src_dir="$(resolve_overlay_src_dir)"; then
    echo "[*] No overlay DTS directory found under arch/${ARCH}/boot/dts/{rockchip/overlay,overlay}"
    return 0
  fi

  overlay_rel_dir="${overlay_src_dir#${KERNEL_DIR}/}"
  overlay_build_dir="${BUILD_DIR}/${overlay_rel_dir}"

  while IFS= read -r src; do
    overlay_sources+=("${src}")
  done < <(find "${overlay_src_dir}" -maxdepth 1 -type f -name '*.dts' | sort)

  if [[ ${#overlay_sources[@]} -eq 0 ]]; then
    echo "[*] No overlay DTS sources found in ${overlay_src_dir}"
    return 0
  fi

  if [[ ! -x "${dtc_bin}" ]]; then
    dtc_bin="${KERNEL_DIR}/scripts/dtc/dtc"
  fi

  if [[ ! -x "${dtc_bin}" ]]; then
    echo "ERROR: dtc binary not found after kernel build" >&2
    echo "       looked for ${BUILD_DIR}/scripts/dtc/dtc and ${KERNEL_DIR}/scripts/dtc/dtc" >&2
    return 1
  fi

  cpp_bin="$(command -v cpp || true)"
  if [[ -z "${cpp_bin}" ]]; then
    echo "ERROR: host cpp not found" >&2
    return 1
  fi

  rm -rf "${overlay_build_dir}" "${overlay_out_dir}"
  mkdir -p "${overlay_build_dir}" "${overlay_out_dir}"

  echo "[*] Building DT overlays from ${overlay_src_dir}"
  for src in "${overlay_sources[@]}"; do
    name="$(basename "${src}" .dts)"
    tmp="${overlay_build_dir}/${name}.dts.tmp"
    out="${overlay_build_dir}/${name}.dtbo"

    echo "[*]   CPP ${name}.dts"
    "${cpp_bin}" \
      -nostdinc \
      -I"${overlay_src_dir}" \
      -I"${KERNEL_DIR}/arch/${ARCH}/boot/dts/rockchip" \
      -I"${KERNEL_DIR}/arch/${ARCH}/boot/dts" \
      -I"${KERNEL_DIR}/scripts/dtc/include-prefixes" \
      -undef \
      -D__DTS__ \
      -x assembler-with-cpp \
      -o "${tmp}" \
      "${src}"

    echo "[*]   DTC ${name}.dtbo"
    "${dtc_bin}" \
      -@ \
      -O dtb \
      -o "${out}" \
      -b 0 \
      -i "${overlay_src_dir}" \
      -i "${KERNEL_DIR}/arch/${ARCH}/boot/dts/rockchip" \
      -i "${KERNEL_DIR}/arch/${ARCH}/boot/dts" \
      -Wno-unit_address_vs_reg \
      "${tmp}"

    cp -av "${out}" "${overlay_out_dir}/"
  done
}

copy_new_deb_packages() {
  local stamp_file="${1}"
  local -a deb_packages=()
  local pkg

  while IFS= read -r pkg; do
    deb_packages+=("${pkg}")
  done < <(find "${ROOT_DIR}" -maxdepth 1 -type f -name '*.deb' -newer "${stamp_file}" | sort)

  if [[ ${#deb_packages[@]} -eq 0 ]]; then
    echo "ERROR: bindeb-pkg completed but no new .deb packages were found in ${ROOT_DIR}" >&2
    return 1
  fi

  echo "[*] Copying Debian packages into ${OUT_DIR}"
  for pkg in "${deb_packages[@]}"; do
    cp -av "${pkg}" "${OUT_DIR}/"
  done
}

mirror_modules_into_bundle_dir() {
  local modules_root="${1}"
  local bundle_dir="${2}"
  local description="${3}"
  local -a modules=()
  local module
  local rel_path
  local dest_path

  if [[ ! -d "${modules_root}" ]]; then
    echo "[*] No ${description} module directory found at ${modules_root}"
    return 0
  fi

  while IFS= read -r module; do
    modules+=("${module}")
  done < <(find "${modules_root}" \
    \( -path "${bundle_dir}" -o -path "${bundle_dir}/*" \) -prune -o \
    -type f -name '*.ko' -print | sort)

  if [[ ${#modules[@]} -eq 0 ]]; then
    echo "[*] No ${description} modules found under ${modules_root}"
    return 0
  fi

  mkdir -p "${bundle_dir}"

  echo "[*] Mirroring ${description} modules into ${bundle_dir}"
  for module in "${modules[@]}"; do
    rel_path="${module#${modules_root}/}"
    if [[ "${rel_path}" == rkwifi/* ]]; then
      rel_path="${rel_path#rkwifi/}"
    fi
    dest_path="${bundle_dir}/${rel_path}"
    mkdir -p "$(dirname "${dest_path}")"
    cp -av "${module}" "${dest_path}"
  done
}

have_command() {
  command -v "${1}" >/dev/null 2>&1
}

prepare_debhelper_shim() {
  local shim_dir="${1}"
  local shim_path="${shim_dir}/dh_listpackages"

  mkdir -p "${shim_dir}"
  cat > "${shim_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
awk '/^Package: / { print \$2 }' "${BUILD_DIR}/debian/control"
EOF
  chmod +x "${shim_path}"
}

prepare_deb_toolchain_shims() {
  local shim_dir="${1}"
  local shim_path="${shim_dir}/arm-linux-gnueabihf-gcc"
  local tool
  local target_name
  local source_name

  mkdir -p "${shim_dir}"
  cat > "${shim_path}" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-dumpmachine" ]]; then
  printf '%s\n' "arm-linux-gnueabihf"
  exit 0
fi
exec "${CROSS_COMPILE_PREFIX}gcc" "\$@"
EOF
  chmod +x "${shim_path}"

  for tool in "${TOOLCHAIN_DIR}"/bin/arm-none-linux-gnueabihf-*; do
    [[ -e "${tool}" ]] || continue
    source_name="$(basename "${tool}")"
    target_name="${source_name/arm-none-linux-gnueabihf-/arm-linux-gnueabihf-}"
    [[ "${target_name}" == "arm-linux-gnueabihf-gcc" ]] && continue
    ln -sf "${tool}" "${shim_dir}/${target_name}"
  done
}

normalize_deb_version_base() {
  printf '%s\n' "${1}" | sed 's/+*$//; s/+/-/g'
}

next_kernel_build_number() {
  local version_file="${BUILD_DIR}/.version"
  local current_version=0

  if [[ -f "${version_file}" ]]; then
    current_version="$(<"${version_file}")"
  fi

  if [[ ! "${current_version}" =~ ^[0-9]+$ ]]; then
    current_version=0
  fi

  printf '%s\n' "$((current_version + 1))"
}

BUILD_MODE="artifacts"
case "${1:-}" in
  "")
    ;;
  deb)
    BUILD_MODE="deb"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ -n "${ENV_KERNEL_DIR}" ]]; then
  KERNEL_DIR_OVERRIDE="${ENV_KERNEL_DIR}"
elif [[ -n "${KERNEL_DIR}" ]]; then
  KERNEL_DIR_OVERRIDE="${KERNEL_DIR}"
else
  KERNEL_DIR_OVERRIDE=""
fi

if [[ -n "${KERNEL_DIR_OVERRIDE}" ]]; then
  if ! KERNEL_DIR="$(resolve_kernel_dir "${KERNEL_DIR_OVERRIDE}")"; then
    echo "ERROR: unable to resolve kernel dir: ${KERNEL_DIR_OVERRIDE}" >&2
    exit 1
  fi
  validate_kernel_dir "${KERNEL_DIR}"
else
  KERNEL_DIR="$(find_kernel_dir)"
fi
ROOT_DIR="$(dirname "${KERNEL_DIR}")"
BUILD_DIR="${ROOT_DIR}/build"
OUT_DIR="${ROOT_DIR}/out"
OVERLAY_OUT_DIR="${OUT_DIR}/overlay"
MODULES_STAGING_DIR="${OUT_DIR}/modules"

if [[ ! -x "${CROSS_COMPILE_PREFIX}gcc" ]]; then
  echo "ERROR: toolchain gcc not found: ${CROSS_COMPILE_PREFIX}gcc"
  exit 1
fi

mkdir -p "${BUILD_DIR}" "${OUT_DIR}"

export ARCH
export CROSS_COMPILE="${CROSS_COMPILE_PREFIX}"
export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

RK_DEFCONFIG="${RK_DEFCONFIG:-rk3128_linux_tvbox_defconfig}"
RK_DTS="${RK_DTS:-rk3128-linux}"
DTB_TARGET=""
DTB_PATH=""

if [[ -f "${KERNEL_DIR}/arch/${ARCH}/boot/dts/rockchip/${RK_DTS}.dts" ]]; then
  DTB_TARGET="rockchip/${RK_DTS}.dtb"
  DTB_PATH="${BUILD_DIR}/arch/${ARCH}/boot/dts/rockchip/${RK_DTS}.dtb"
elif [[ -f "${KERNEL_DIR}/arch/${ARCH}/boot/dts/${RK_DTS}.dts" ]]; then
  DTB_TARGET="${RK_DTS}.dtb"
  DTB_PATH="${BUILD_DIR}/arch/${ARCH}/boot/dts/${RK_DTS}.dtb"
else
  echo "ERROR: DTS source not found for ${RK_DTS}" >&2
  echo "       looked for:" >&2
  echo "       - ${KERNEL_DIR}/arch/${ARCH}/boot/dts/rockchip/${RK_DTS}.dts" >&2
  echo "       - ${KERNEL_DIR}/arch/${ARCH}/boot/dts/${RK_DTS}.dts" >&2
  exit 1
fi

cd "${KERNEL_DIR}"

echo "[*] Kernel dir : ${KERNEL_DIR}"
echo "[*] Build dir  : ${BUILD_DIR}"
echo "[*] Out dir    : ${OUT_DIR}"
echo "[*] DEFCONFIG  : ${RK_DEFCONFIG}"
echo "[*] DTS/DTB    : ${RK_DTS}"
echo "[*] DTB target : ${DTB_TARGET}"
echo "[*] MODE       : ${BUILD_MODE}"
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

KERNEL_RELEASE="$(make -s O="${BUILD_DIR}" kernelrelease)"

if [[ "${BUILD_MODE}" == "deb" ]]; then
  DEB_STAMP_FILE="$(mktemp)"
  DEB_HELPER_SHIM_DIR=""
  DEB_CC_SHIM_DIR="$(mktemp -d)"
  DEB_BUILD_NUMBER="$(next_kernel_build_number)"
  DEB_VERSION_BASE="$(normalize_deb_version_base "${KERNEL_RELEASE}")"

  prepare_deb_toolchain_shims "${DEB_CC_SHIM_DIR}"
  export PATH="${DEB_CC_SHIM_DIR}:${PATH}"
  export CC="arm-linux-gnueabihf-gcc"
  export KBUILD_DEBARCH="${KBUILD_DEBARCH:-armhf}"
  export KDEB_SOURCENAME="${KDEB_SOURCENAME:-linux-rk3128}"
  export KDEB_PKGVERSION="${KDEB_PKGVERSION:-${DEB_VERSION_BASE}-${DEB_BUILD_NUMBER}}"

  echo "[*] Debian source : ${KDEB_SOURCENAME}"
  echo "[*] Debian version: ${KDEB_PKGVERSION}"

  if ! have_command dh_listpackages; then
    DEB_HELPER_SHIM_DIR="$(mktemp -d)"
    prepare_debhelper_shim "${DEB_HELPER_SHIM_DIR}"
    export PATH="${DEB_HELPER_SHIM_DIR}:${PATH}"
    export DPKG_FLAGS="${DPKG_FLAGS:-} -d"
    echo "[*] debhelper is not installed; using local dh_listpackages shim and forcing dpkg-buildpackage -d"
  fi

  trap 'rm -f "${DEB_STAMP_FILE}"; rm -rf "${DEB_CC_SHIM_DIR}"; if [[ -n "${DEB_HELPER_SHIM_DIR}" ]]; then rm -rf "${DEB_HELPER_SHIM_DIR}"; fi' EXIT

  echo "[*] Building Debian packages with bindeb-pkg"
  make -j"${JOBS}" O="${BUILD_DIR}" CROSS_COMPILE="arm-linux-gnueabihf-" bindeb-pkg

  cp -av "${BUILD_DIR}/.config" "${OUT_DIR}/kernel.config"
  printf '%s\n' "${KERNEL_RELEASE}" > "${OUT_DIR}/kernel.release"
  copy_new_deb_packages "${DEB_STAMP_FILE}"

  echo "[*] Done:"
  echo "    - ${OUT_DIR}/*.deb"
  echo "    - ${OUT_DIR}/kernel.config"
  echo "    - ${OUT_DIR}/kernel.release"
  exit 0
fi

echo "[*] Building zImage + ${DTB_TARGET} + modules"
make -j"${JOBS}" O="${BUILD_DIR}" zImage "${DTB_TARGET}" modules

build_dtbo_overlays

KERNEL_RELEASE="$(make -s O="${BUILD_DIR}" kernelrelease)"
MODULES_RELEASE_DIR="${MODULES_STAGING_DIR}/lib/modules/${KERNEL_RELEASE}"
OUT_MODULES_RELEASE_DIR="${OUT_DIR}/lib/modules/${KERNEL_RELEASE}"
ZRAM_CONFIG="$(grep '^CONFIG_ZRAM=' "${BUILD_DIR}/.config" || true)"

ZIMAGE_PATH="${BUILD_DIR}/arch/arm/boot/zImage"
ZRAM_KO_PATH="${BUILD_DIR}/drivers/block/zram/zram.ko"
STAGED_ZRAM_KO_PATH="${MODULES_RELEASE_DIR}/kernel/drivers/block/zram/zram.ko"
ROCKCHIP_WLAN_MODULES_DIR="${MODULES_RELEASE_DIR}/kernel/drivers/net/wireless/rockchip_wlan"
ROCKCHIP_WLAN_RKWIFI_DIR="${ROCKCHIP_WLAN_MODULES_DIR}/rkwifi"

if [[ ! -f "${ZIMAGE_PATH}" ]]; then
  echo "ERROR: zImage not found: ${ZIMAGE_PATH}"
  exit 1
fi

cp -av "${ZIMAGE_PATH}" "${OUT_DIR}/zImage"
gzip -c "${ZIMAGE_PATH}" > "${OUT_DIR}/zImage.gz"
cp -av "${BUILD_DIR}/.config" "${OUT_DIR}/kernel.config"
printf '%s\n' "${KERNEL_RELEASE}" > "${OUT_DIR}/kernel.release"

echo "[*] Installing modules into ${MODULES_STAGING_DIR}"
rm -rf "${MODULES_STAGING_DIR}"
rm -rf "${OUT_DIR}/lib/modules"
make O="${BUILD_DIR}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install

mirror_modules_into_bundle_dir "${ROCKCHIP_WLAN_MODULES_DIR}" "${ROCKCHIP_WLAN_RKWIFI_DIR}" "Rockchip WLAN"

echo "[*] Copying installed modules into ${OUT_DIR}/lib/modules"
mkdir -p "${OUT_DIR}/lib/modules"
cp -a "${MODULES_RELEASE_DIR}" "${OUT_DIR}/lib/modules/"

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

if [[ ! -f "${DTB_PATH}" ]]; then
  echo "ERROR: DTB not found: ${DTB_PATH}" >&2
  exit 1
fi

cp -av "${DTB_PATH}" "${OUT_DIR}/"

cat > "${OUT_DIR}/DEPLOYMENT.txt" <<EOF
Kernel release: ${KERNEL_RELEASE}
ZRAM config: ${ZRAM_CONFIG:-CONFIG_ZRAM is not set}

Deploy the matching kernel image, DTB, DT overlays, and the full modules tree from:
  ${OUT_MODULES_RELEASE_DIR}

A second staged copy is also kept at:
  ${MODULES_RELEASE_DIR}

Overlay files are copied to:
  ${OVERLAY_OUT_DIR}

Rockchip WLAN modules are additionally copied to:
  ${ROCKCHIP_WLAN_RKWIFI_DIR}

Copy the base DTB to /boot/dtb/ and the overlay .dtbo files to /boot/dtb/overlay/.
Then set armbianEnv.txt, for example:
  overlay_prefix=rk3128
  overlays=wlan-esp8089

Replace the target's /lib/modules/${KERNEL_RELEASE} directory with:
  ${OUT_MODULES_RELEASE_DIR}
Do not keep an older zram.ko alongside a kernel that has zram built in or reconfigured,
otherwise userspace modprobe can recreate the /class/zram-control duplicate warning.
EOF

echo "[*] Done:"
echo "    - ${OUT_DIR}/zImage"
echo "    - ${OUT_DIR}/zImage.gz"
echo "    - ${OUT_DIR}/${RK_DTS}.dtb (if built)"
if [[ -d "${OVERLAY_OUT_DIR}" ]]; then
  echo "    - ${OVERLAY_OUT_DIR}/*.dtbo (if built)"
fi
echo "    - ${OUT_DIR}/kernel.config"
echo "    - ${OUT_DIR}/kernel.release"
echo "    - ${MODULES_RELEASE_DIR}"
echo "    - ${OUT_MODULES_RELEASE_DIR}"
echo "    - ${ROCKCHIP_WLAN_RKWIFI_DIR}/*.ko (if built)"
echo "    - ${OUT_DIR}/DEPLOYMENT.txt"
echo "    - ${OUT_DIR}/zram.ko (if built as module)"
