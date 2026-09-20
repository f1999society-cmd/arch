# bnasec Arch — Hyprland Persistent Live ISO

A customized **Arch Linux + Hyprland** live ISO based on [bnasec-os](https://github.com/f1999society-cmd/bnasec-os), fully riced with the [low-sepecs-hyprland-dotfiles](https://github.com/okyashgajjar/low-sepecs-hyprland-dotfiles) and rebuilt with **true USB persistence** — everything you change on the live system survives reboots.

![rice](https://img.shields.io/badge/WM-Hyprland_0.56.2-blueviolet) ![kernel](https://img.shields.io/badge/kernel-7.2.6--arch2--1-red) ![size](https://img.shields.io/badge/ISO-1.7_GB-green)

## Download

Grab the latest ISO from the [**Releases**](https://github.com/f1999society-cmd/arch/releases) page:
`bnasec-arch-1.1.0-amd64.iso` (~1.7 GB) + `sha256` checksum.

## What's inside

- **Arch Linux** live system, kernel `7.2.6-arch2-1`
- **Hyprland 0.56.2** (Wayland) with the full low-specs rice: Catppuccin waybar, fastfetch, tuigreet greeter, autologin-ready user `bna` / password `bnasec`
- **Automatic persistence**: on first boot the init scans the boot disk, appends a new partition, formats it `ext4` labelled `persistence` and mounts the whole root through an overlay — every file change (home, configs, installed packages) lands on the stick
- **Boot menu** (BIOS: isolinux / UEFI: systemd-boot):
  - `Arch Hyprland (Noro rice) — persistent` ← default
  - `Arch Hyprland — RAM-only session (no persistence)`
  - `verbose boot (debug)` — serial console enabled

## Flash to USB

> A **4 GB+** stick is enough (2 GB of free space becomes your persistence partition).

**Linux / macOS (dd)**
```bash
# replace sdX with your USB stick — this wipes it!
sudo dd if=bnasec-arch-1.1.0-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

**Windows (Rufus)**
1. Open Rufus → select the ISO
2. Partition scheme: **MBR**, target: **BIOS or UEFI** (both work)
3. Write in **DD mode** (important — not ISO mode)

**Ventoy** also works (the persistence partition is created automatically on the stick itself).

## Persistence — how it works

- On every boot the init looks for a partition labelled `persistence` on the boot device.
- If none exists (and the medium is a USB disk, or `bnasec.persist=force` is set — the default) it **appends a new partition** in the free space after the ISO data and formats it as ext4 labelled `persistence`.
- The root filesystem is mounted read-only from the ISO and combined with the persistence partition via **overlayfs**, so `/`, `/home`, `/etc`… are all writable and **stored on the stick**.
- A read-only view of the persistence store is also bind-mounted at `/run/bnasec/persist`.
- To reset to a fresh system: re-flash the ISO (or delete the `persistence` partition).
- To boot **without** persisting anything: pick `RAM-only session` in the boot menu.

Verified in QEMU on both firmware paths: BIOS and UEFI boot → desktop login → file created → **reboot** → file still there + desktop intact.

## Verifying the download

```bash
sha256sum -c bnasec-arch-1.1.0-amd64.iso.sha256
```

## Building / customizing

The ISO layout is a standard archiso-style tree (`airootfs.sfs` + initramfs with a custom `bnasec-init` hook). Drop into the live session, modify, and re-squash — or fork this repo and rebuild.
