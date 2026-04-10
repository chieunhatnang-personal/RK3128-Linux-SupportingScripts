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
  echo "  - deb: build the same kernel artifacts once, then assemble fast local"
  echo "    linux-image/linux-headers/linux-libc-dev Debian packages from those"
  echo "    outputs. The linux-image package includes DTB, overlays, and modules."
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
  local -a deb_packages=("$@")
  local pkg

  if [[ ${#deb_packages[@]} -eq 0 ]]; then
    echo "ERROR: no .deb packages were produced" >&2
    return 1
  fi

  echo "[*] Copying Debian packages into ${OUT_DIR}"
  for pkg in "${deb_packages[@]}"; do
    cp -av "${pkg}" "${OUT_DIR}/"
  done
}

refresh_deb_md5sums() {
  local pkg_root="${1}"

  (
    cd "${pkg_root}"
    find . -type f ! -path './DEBIAN/*' -print0 \
      | sort -z \
      | xargs -0 md5sum \
      | sed 's#  \./#  #'
  ) > "${pkg_root}/DEBIAN/md5sums"
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

prune_rockchip_wlan_duplicates() {
  local modules_root="${1}"
  local rockchip_wlan_dir="${modules_root}/kernel/drivers/net/wireless/rockchip_wlan"
  local entry
  local removed=0

  [[ -d "${rockchip_wlan_dir}" ]] || return 0

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    rm -rf "${entry}"
    removed=1
  done < <(find "${rockchip_wlan_dir}" -mindepth 1 -maxdepth 1 ! -name 'rkwifi' -print | sort)

  if (( removed )); then
    echo "[*] Removed duplicate Rockchip WLAN modules outside rkwifi/ under ${rockchip_wlan_dir}"
  fi
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

deb_host_multiarch() {
  dpkg-architecture -aarmhf -qDEB_HOST_MULTIARCH 2>/dev/null || printf '%s\n' "arm-linux-gnueabihf"
}

deb_maintainer() {
  local name email

  name="$(git config --get user.name 2>/dev/null || true)"
  email="$(git config --get user.email 2>/dev/null || true)"

  if [[ -n "${name}" && -n "${email}" ]]; then
    printf '%s <%s>\n' "${name}" "${email}"
  else
    printf '%s\n' "rk3128 builder <root@localhost>"
  fi
}

write_deb_control() {
  local pkg_root="${1}"
  local package_name="${2}"
  local description="${3}"

  cat > "${pkg_root}/DEBIAN/control" <<EOF
Package: ${package_name}
Source: ${KDEB_SOURCENAME}
Version: ${KDEB_PKGVERSION}
Architecture: armhf
Maintainer: ${DEB_MAINTAINER}
Section: kernel
Priority: optional
Homepage: https://www.kernel.org/
Description: ${description}
EOF
}

write_kernel_image_script() {
  local script_path="${1}"
  local hook_name="${2}"
  local run_depmod="${3}"

  cat > "${script_path}" <<EOF
#!/bin/sh

set -e

export DEB_MAINT_PARAMS="\$*"
export INITRD=Yes
EOF

  if [[ "${run_depmod}" == "yes" ]]; then
    cat >> "${script_path}" <<EOF

depmod ${KERNEL_RELEASE} >/dev/null 2>&1 || true
EOF
  fi

  cat >> "${script_path}" <<EOF

test -d /etc/kernel/${hook_name}.d && run-parts --arg="${KERNEL_RELEASE}" --arg="/boot/vmlinuz-${KERNEL_RELEASE}" /etc/kernel/${hook_name}.d
exit 0
EOF

  chmod 0755 "${script_path}"
}

build_linux_image_deb() {
  local pkg_root="${1}"
  local image_pkg="${2}"
  local modules_root="${3}"
  local package_dtb_dir
  local package_overlay_dir
  local modules_pkg_dir

  rm -rf "${pkg_root}"
  mkdir -p "${pkg_root}/DEBIAN" "${pkg_root}/boot" "${pkg_root}/etc/kernel" "${pkg_root}/lib/modules"

  cp -av "${ZIMAGE_PATH}" "${pkg_root}/boot/vmlinuz-${KERNEL_RELEASE}" >/dev/null
  cp -av "${SYSTEM_MAP_PATH}" "${pkg_root}/boot/System.map-${KERNEL_RELEASE}" >/dev/null
  cp -av "${KERNEL_CONFIG_PATH}" "${pkg_root}/boot/config-${KERNEL_RELEASE}" >/dev/null

  package_dtb_dir="${pkg_root}/boot/dtb"
  package_overlay_dir="${package_dtb_dir}/overlay"
  mkdir -p "${package_dtb_dir}" "${package_overlay_dir}"
  cp -av "${DTB_PATH}" "${package_dtb_dir}/${RK_DTS}.dtb" >/dev/null

  if [[ -d "${OVERLAY_OUT_DIR}" ]]; then
    find "${OVERLAY_OUT_DIR}" -maxdepth 1 -type f -name '*.dtbo' -exec cp -av {} "${package_overlay_dir}/" \; >/dev/null
  fi

  modules_pkg_dir="${pkg_root}/lib/modules/${KERNEL_RELEASE}"
  cp -a "${modules_root}/lib/modules/${KERNEL_RELEASE}" "${pkg_root}/lib/modules/"
  rm -f "${modules_pkg_dir}/build" "${modules_pkg_dir}/source"

  mkdir -p \
    "${pkg_root}/etc/kernel/postinst.d" \
    "${pkg_root}/etc/kernel/postrm.d" \
    "${pkg_root}/etc/kernel/preinst.d" \
    "${pkg_root}/etc/kernel/prerm.d"

  write_deb_control \
    "${pkg_root}" \
    "linux-image-${KERNEL_RELEASE}" \
    "Linux kernel, version ${KERNEL_RELEASE}
 This package contains the Linux kernel image, DTB, overlays and modules,
 version: ${KERNEL_RELEASE}."
  write_kernel_image_script "${pkg_root}/DEBIAN/preinst" "preinst" "no"
  write_kernel_image_script "${pkg_root}/DEBIAN/postinst" "postinst" "yes"
  write_kernel_image_script "${pkg_root}/DEBIAN/prerm" "prerm" "no"
  write_kernel_image_script "${pkg_root}/DEBIAN/postrm" "postrm" "yes"
  refresh_deb_md5sums "${pkg_root}"
  dpkg-deb --root-owner-group --build "${pkg_root}" "${image_pkg}" >/dev/null
}

build_linux_headers_deb() {
  local pkg_root="${1}"
  local headers_pkg="${2}"

  rm -rf "${pkg_root}"
  mkdir -p "${pkg_root}/DEBIAN"

  (
    cd "${BUILD_DIR}"
    srctree="${KERNEL_DIR}" \
    SRCARCH="${ARCH}" \
    KCONFIG_CONFIG="${BUILD_DIR}/.config" \
    "${KERNEL_DIR}/scripts/package/install-extmod-build" "${pkg_root}/usr/src/linux-headers-${KERNEL_RELEASE}"
  )

  mkdir -p "${pkg_root}/lib/modules/${KERNEL_RELEASE}"
  ln -s "/usr/src/linux-headers-${KERNEL_RELEASE}" "${pkg_root}/lib/modules/${KERNEL_RELEASE}/build"

  write_deb_control \
    "${pkg_root}" \
    "linux-headers-${KERNEL_RELEASE}" \
    "Linux kernel headers for ${KERNEL_RELEASE} on armhf
 This package provides kernel header files for ${KERNEL_RELEASE} on armhf.
 .
 This is useful for people who need to build external modules."
  refresh_deb_md5sums "${pkg_root}"
  dpkg-deb --root-owner-group --build "${pkg_root}" "${headers_pkg}" >/dev/null
}

build_linux_libc_dev_deb() {
  local pkg_root="${1}"
  local libc_pkg="${2}"
  local multiarch_dir

  rm -rf "${pkg_root}"
  mkdir -p "${pkg_root}/DEBIAN"

  make O="${BUILD_DIR}" headers >/dev/null
  make O="${BUILD_DIR}" INSTALL_HDR_PATH="${pkg_root}/usr" headers_install >/dev/null

  multiarch_dir="$(deb_host_multiarch)"
  mkdir -p "${pkg_root}/usr/include/${multiarch_dir}"
  if [[ -d "${pkg_root}/usr/include/asm" ]]; then
    mv "${pkg_root}/usr/include/asm" "${pkg_root}/usr/include/${multiarch_dir}/"
  fi

  write_deb_control \
    "${pkg_root}" \
    "linux-libc-dev" \
    "Linux support headers for userspace development
 This package provides userspace headers from the Linux kernel. These headers
 are used by the installed headers for GNU glibc and other system libraries."
  refresh_deb_md5sums "${pkg_root}"
  dpkg-deb --root-owner-group --build "${pkg_root}" "${libc_pkg}" >/dev/null
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

if git -C "${KERNEL_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  export GIT_DIR
  export GIT_WORK_TREE
  GIT_DIR="$(git -C "${KERNEL_DIR}" rev-parse --absolute-git-dir)"
  GIT_WORK_TREE="$(git -C "${KERNEL_DIR}" rev-parse --show-toplevel)"
fi

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
ZIMAGE_PATH="${BUILD_DIR}/arch/arm/boot/zImage"
SYSTEM_MAP_PATH="${BUILD_DIR}/System.map"
KERNEL_CONFIG_PATH="${BUILD_DIR}/.config"

if [[ "${BUILD_MODE}" == "deb" ]]; then
  DEB_MODULES_STAGING_DIR="$(mktemp -d)"
  DEB_PACKAGE_STAGING_DIR="$(mktemp -d)"
  DEB_BUILD_NUMBER="$(next_kernel_build_number)"
  DEB_VERSION_BASE="$(normalize_deb_version_base "${KERNEL_RELEASE}")"
  export KDEB_SOURCENAME="${KDEB_SOURCENAME:-linux-rk3128}"
  export KDEB_PKGVERSION="${KDEB_PKGVERSION:-${DEB_VERSION_BASE}-${DEB_BUILD_NUMBER}}"
  DEB_MAINTAINER="$(deb_maintainer)"
  IMAGE_DEB_PATH="${ROOT_DIR}/linux-image-${KERNEL_RELEASE}_${KDEB_PKGVERSION}_armhf.deb"
  HEADERS_DEB_PATH="${ROOT_DIR}/linux-headers-${KERNEL_RELEASE}_${KDEB_PKGVERSION}_armhf.deb"
  LIBC_DEB_PATH="${ROOT_DIR}/linux-libc-dev_${KDEB_PKGVERSION}_armhf.deb"

  echo "[*] Debian source : ${KDEB_SOURCENAME}"
  echo "[*] Debian version: ${KDEB_PKGVERSION}"
  echo "[*] Maintainer    : ${DEB_MAINTAINER}"

  trap 'rm -rf "${DEB_MODULES_STAGING_DIR}" "${DEB_PACKAGE_STAGING_DIR}"' EXIT

  echo "[*] Building zImage + ${DTB_TARGET} + modules for Debian packaging"
  make -j"${JOBS}" O="${BUILD_DIR}" zImage "${DTB_TARGET}" modules

  build_dtbo_overlays

  echo "[*] Installing modules into ${DEB_MODULES_STAGING_DIR} for Debian packaging"
  rm -rf "${DEB_MODULES_STAGING_DIR}"
  mkdir -p "${DEB_MODULES_STAGING_DIR}"
  make O="${BUILD_DIR}" INSTALL_MOD_PATH="${DEB_MODULES_STAGING_DIR}" modules_install
  mirror_modules_into_bundle_dir \
    "${DEB_MODULES_STAGING_DIR}/lib/modules/${KERNEL_RELEASE}/kernel/drivers/net/wireless/rockchip_wlan" \
    "${DEB_MODULES_STAGING_DIR}/lib/modules/${KERNEL_RELEASE}/kernel/drivers/net/wireless/rockchip_wlan/rkwifi" \
    "Rockchip WLAN"
  prune_rockchip_wlan_duplicates \
    "${DEB_MODULES_STAGING_DIR}/lib/modules/${KERNEL_RELEASE}"

  rm -f "${IMAGE_DEB_PATH}" "${HEADERS_DEB_PATH}" "${LIBC_DEB_PATH}"

  build_linux_image_deb \
    "${DEB_PACKAGE_STAGING_DIR}/linux-image" \
    "${IMAGE_DEB_PATH}" \
    "${DEB_MODULES_STAGING_DIR}"
  build_linux_headers_deb \
    "${DEB_PACKAGE_STAGING_DIR}/linux-headers" \
    "${HEADERS_DEB_PATH}"
  build_linux_libc_dev_deb \
    "${DEB_PACKAGE_STAGING_DIR}/linux-libc-dev" \
    "${LIBC_DEB_PATH}"

  cp -av "${BUILD_DIR}/.config" "${OUT_DIR}/kernel.config"
  printf '%s\n' "${KERNEL_RELEASE}" > "${OUT_DIR}/kernel.release"
  copy_new_deb_packages "${IMAGE_DEB_PATH}" "${HEADERS_DEB_PATH}" "${LIBC_DEB_PATH}"

  echo "[*] Done:"
  echo "    - ${OUT_DIR}/*.deb"
  echo "    - ${OUT_DIR}/kernel.config"
  echo "    - ${OUT_DIR}/kernel.release"
  echo "    - linux-image package now contains /boot/dtb/${RK_DTS}.dtb"
  echo "    - linux-image package now contains /boot/dtb/overlay/*.dtbo"
  echo "    - linux-image package now contains runtime modules only (no build/source symlink)"
  echo "    - linux-headers package now owns /lib/modules/${KERNEL_RELEASE}/build"
  exit 0
fi

echo "[*] Building zImage + ${DTB_TARGET} + modules"
make -j"${JOBS}" O="${BUILD_DIR}" zImage "${DTB_TARGET}" modules

build_dtbo_overlays

KERNEL_RELEASE="$(make -s O="${BUILD_DIR}" kernelrelease)"
MODULES_RELEASE_DIR="${MODULES_STAGING_DIR}/lib/modules/${KERNEL_RELEASE}"
OUT_MODULES_RELEASE_DIR="${OUT_DIR}/lib/modules/${KERNEL_RELEASE}"
ZRAM_CONFIG="$(grep '^CONFIG_ZRAM=' "${BUILD_DIR}/.config" || true)"

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
prune_rockchip_wlan_duplicates "${MODULES_RELEASE_DIR}"

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
