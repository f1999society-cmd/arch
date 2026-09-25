#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# bnasec Arch 1.2.0 — HyDE desktop, hardened USB persistence
# Built with mkarchiso (archiso 90+)

iso_name="bnasec-arch"
iso_label="BNASEC_120"
iso_publisher="bnasec <https://github.com/f1999society-cmd/arch>"
iso_application="bnasec Arch Live — HyDE / persistent USB"
iso_version="1.2.0"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/home/bna/"]="1000:1000:750"
  # mkarchiso copies custom airootfs with 'cp -af --no-preserve=ownership,mode'
  # (mkarchiso line 320) — everything NOT listed here lands as 644. sudo
  # silently DROPS sudoers.d files that are not 0440; the toolbox/hook need 755.
  ["/usr/local/bin/bnasec-toolbox"]="0:0:755"
  ["/usr/local/bin/bnasec"]="0:0:755"
  ["/usr/lib/initcpio/hooks/archiso_bnasec"]="0:0:755"
  ["/usr/lib/initcpio/install/archiso_bnasec"]="0:0:644"
  ["/etc/sudoers.d/bnasec"]="0:0:440"
)
