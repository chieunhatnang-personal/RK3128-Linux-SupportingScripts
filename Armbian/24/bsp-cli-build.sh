#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_WORKTREE="${SCRIPT_DIR}/armbian-bsp-cli-rk3128-box-current"
PKG_ROOT="${PKG_WORKTREE}/rootfs"
PKG_DEBIAN="${PKG_WORKTREE}/DEBIAN"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_dir() {
  local path="$1"
  [[ -d "${path}" ]] || die "missing directory: ${path}"
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || die "missing file: ${path}"
}

sync_debian_metadata() {
  echo "[*] Syncing DEBIAN metadata into package root"
  rm -rf "${PKG_ROOT}/DEBIAN"
  mkdir -p "${PKG_ROOT}/DEBIAN"
  cp -a "${PKG_DEBIAN}/." "${PKG_ROOT}/DEBIAN/"
}

refresh_md5sums() {
  echo "[*] Refreshing DEBIAN/md5sums"
  (
    cd "${PKG_ROOT}"
    find . -type f ! -path './DEBIAN/*' -print0 \
      | sort -z \
      | xargs -0 md5sum \
      | sed 's#  \./#  #'
  ) > "${PKG_DEBIAN}/md5sums"
}

package_fields() {
  PACKAGE_NAME="$(awk -F': ' '$1=="Package"{print $2; exit}' "${PKG_DEBIAN}/control")"
  PACKAGE_VERSION="$(awk -F': ' '$1=="Version"{print $2; exit}' "${PKG_DEBIAN}/control")"
  PACKAGE_ARCH="$(awk -F': ' '$1=="Architecture"{print $2; exit}' "${PKG_DEBIAN}/control")"

  [[ -n "${PACKAGE_NAME}" ]] || die "Package not found in ${PKG_DEBIAN}/control"
  [[ -n "${PACKAGE_VERSION}" ]] || die "Version not found in ${PKG_DEBIAN}/control"
  [[ -n "${PACKAGE_ARCH}" ]] || die "Architecture not found in ${PKG_DEBIAN}/control"

  PACKAGE_OUTPUT="${SCRIPT_DIR}/${PACKAGE_NAME}_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb"
}

build_package() {
  echo "[*] Building ${PACKAGE_OUTPUT}"
  rm -f "${PACKAGE_OUTPUT}"
  dpkg-deb --root-owner-group --build "${PKG_ROOT}" "${PACKAGE_OUTPUT}" >/dev/null
}

require_dir "${PKG_WORKTREE}"
require_dir "${PKG_ROOT}"
require_dir "${PKG_DEBIAN}"
require_file "${PKG_DEBIAN}/control"

refresh_md5sums
sync_debian_metadata
package_fields
build_package

echo "[*] Done:"
echo "    - ${PACKAGE_OUTPUT}"
dpkg-deb -f "${PACKAGE_OUTPUT}" Package Version Architecture Description
