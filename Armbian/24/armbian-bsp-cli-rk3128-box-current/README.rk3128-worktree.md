# RK3128 BSP Worktree

This directory is a local RK3128 BSP worktree derived from an existing Armbian TV box BSP package.

Target package: `armbian-bsp-cli-rk3128-box-current` version `26.2.1`.

Layout:

- `rootfs/`: package payload that would be installed under `/`
- `DEBIAN/`: Debian control metadata and maintainer scripts

Important: this is only extracted here. It has not been installed into the target rootfs.
