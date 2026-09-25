#!/usr/bin/env bash
# Small airootfs plumbing files + symlinks (idempotent helper used by repo tooling)
set -euo pipefail
P="$(cd "$(dirname "$0")/.." && pwd)/profile"
A="$P/airootfs"

# ---- basic identity
echo bnasec > "$A/etc/hostname"
printf 'LANG=en_US.UTF-8\n' > "$A/etc/locale.conf"
printf 'en_US.UTF-8 UTF-8\n' > "$A/etc/locale.gen"
printf 'FONT=latarcyrheb-sun32\n' > "$A/etc/vconsole.conf"

# ---- mkinitcpio preset for the linux kernel
mkdir -p "$A/etc/mkinitcpio.d"
cat > "$A/etc/mkinitcpio.d/linux.preset" <<'EOF'
# mkinitcpio preset for the 'linux' kernel — bnasec ISO
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')
default_image="/boot/initramfs-linux.img"
fallback_options="-S autodetect"
EOF

# ---- anti-rot / anti-lag: keep writes off the stick
cat > "$A/etc/fstab" <<'EOF'
# bnasec live — volatile write sinks (real root is the persistence overlay)
tmpfs /tmp tmpfs rw,nosuid,nodev,size=1G,mode=1777 0 0
tmpfs /var/tmp tmpfs rw,nosuid,nodev,size=512M,mode=1777 0 0
tmpfs /var/cache/pacman/pkg tmpfs rw,nosuid,nodev,size=1G,mode=0755 0 0
tmpfs /var/log tmpfs rw,nosuid,nodev,size=128M,mode=0755 0 0
tmpfs /home/bna/.cache tmpfs rw,nosuid,nodev,size=768M,uid=1000,gid=1000,mode=0700 0 0
EOF

cat > "$A/etc/systemd/journald.conf.d/bnasec.conf" <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
ForwardToConsole=no
ForwardToWall=no
EOF

cat > "$A/etc/sysctl.d/99-bnasec-usblag.conf" <<'EOF'
# USB-stick friendly write batching: batch dirty pages, flush late,
# prefer zram swap for anonymous pressure (stick never takes sync storms)
vm.dirty_writeback_centisecs = 6000
vm.dirty_expire_centisecs = 6000
vm.dirty_background_ratio = 10
vm.dirty_ratio = 30
vm.swappiness = 100
vm.vfs_cache_pressure = 50
EOF

cat > "$A/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# /run/persist convenience path for toolbox v1.7 space_rescue/doctor expectations
cat > "$A/etc/tmpfiles.d/bnasec-persist.conf" <<'EOF'
L+ /run/persist - - - - /run/archiso/cowspace/persist
EOF

# ---- login
mkdir -p "$A/etc/systemd/system/getty@tty1.service.d" "$A/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$A/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin bna --noclear %I 115200,38400,9600 vt100
EOF

# ---- enable services (sddm greeter, networking, bluetooth, ssh off by default)
mkdir -p "$A/etc/systemd/system/multi-user.target.wants" "$A/etc/systemd/system/sockets.target.wants" "$A/etc/systemd/system/display-manager.service.d"
ln -sfn /usr/lib/systemd/system/NetworkManager.service      "$A/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
ln -sfn /usr/lib/systemd/system/bluetooth.service           "$A/etc/systemd/system/multi-user.target.wants/bluetooth.service"
ln -sfn /usr/lib/systemd/system/sddm.service                "$A/etc/systemd/system/display-manager.service"
ln -sfn /usr/lib/systemd/system/systemd-timesyncd.service   "$A/etc/systemd/system/multi-user.target.wants/systemd-timesyncd.service"

# ---- sddm: Hyde's install_pst.sh writes the theme conf into /etc/sddm.conf.d at build
# ---- resolv.conf managed by systemd-resolved? NM+resolved: stub symlink
rm -f "$A/etc/resolv.conf"
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$A/etc/resolv.conf"
mkdir -p "$A/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/systemd-resolved.service "$A/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"

echo "airootfs plumbing OK"
