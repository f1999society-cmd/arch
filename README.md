# bnasec Arch — HyDE Persistent Live ISO

A customized **Arch Linux live ISO** with the [HyDE](https://github.com/HyDE-project/HyDE)
desktop baked in, **hardened USB persistence**, and every lesson from the 1.1.x
stick-rot saga fixed at the ISO level.

- **ISO:** ~2 GB single file — grab it from [**Releases**](https://github.com/f1999society-cmd/arch/releases) (`v1.2.0`)
- **Desktop:** HyDE rice (waybar / rofi / wlogout / wallbash themes / Bibata cursors / nerd fonts), sddm Corners greeter
- **Login:** user `bna` / password `bnasec` (sudo: same password)
- **Build:** fully reproducible via GitHub Actions — the ISO is built *and boot-tested* in CI on every release

![rice](https://img.shields.io/badge/WM-Hyprland-blueviolet) ![dots](https://img.shields.io/badge/dots-HyDE-8A2BE2) ![size](https://img.shields.io/badge/ISO-~2GB-green)

## Flash to USB

> A **4 GB+** stick is enough — the rest becomes your persistence partition.

**Linux / macOS (dd)**
```bash
sha256sum bnasec-arch-1.2.0-amd64.iso          # verify against the release page
sudo dd if=bnasec-arch-1.2.0-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**Windows (Rufus)** — MBR, DD mode (not ISO mode).

## Persistence — rebuilt from scratch

Every failure mode the 1.1.x sticks hit is fixed in the boot path itself:

| 1.1.x failure | 1.2.0 fix |
|---|---|
| first boot needed manual partition prep | initramfs **auto-creates** the `persistence` partition (ext4 + journal) on the boot disk |
| silent ext4 allocator rot (`error 28`, truncated files, GPGME failures, segfaults) | **every boot fscks the persist fs before the overlay mounts** (preen, auto-escalates to full repair) |
| phantom "No space left" from the ext4 5% reserve | `tune2fs -m 0` on every boot |
| persist partition filled by package downloads | `/var/cache/pacman/pkg`, `/tmp`, `/var/tmp`, `/var/log`, `~/.cache` are tmpfs — downloads never touch the stick |
| USB write stalls | journald volatile (32M), 60s write batching, zram swap (ram/2, zstd) |
| unrepairable fs → dropped to initramfs shell | session **falls back to RAM-only** with a clear console message instead |

Boot menu: `bnasec HyDE — persistent` (default) · `RAM-only session` · `verbose boot (debug)`.

## Toolbox preinstalled

`bnasec-toolbox` v1.7 ships in the image (`/usr/local/bin/bnasec-toolbox`, alias `bnasec`):
rice fixes, volume keys + OSD, hyprlock, night light, USB anti-lag, **menu 10 space rescue**,
**menu 11 system doctor** (fs health / keyring rebuild / rot audit / spotify repair).

## Rebuild it yourself

The whole ISO is built in CI (`.github/workflows/build-iso.yml`): an
`archlinux:base-devel` container installs the package list, runs the real
Hyde installer non-interactively, bakes the result into an archiso profile,
then QEMU-tests the ISO (BIOS boot, persistence proof across reboots,
RAM-only boot, UEFI via OVMF) before publishing the release.

Manual local build (any Arch machine or container):

```bash
sudo bash ci/build-iso.sh     # build + assertions
sudo bash ci/boot-tests.sh    # boot tests (KVM or TCG)
```

## Credits

- [HyDE](https://github.com/HyDE-project/HyDE) — the desktop dots
- [archiso](https://gitlab.archlinux.org/archlinux/archiso) — the live system foundation
- previous rice: [low-sepecs-hyprland-dotfiles](https://github.com/okyashgajjar/low-sepecs-hyprland-dotfiles) (1.0.x/1.1.x line)
