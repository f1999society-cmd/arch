# bnasec-arch v3.0.0 — Test Evidence (released ISO rerun)

Visual and log evidence from the verification of **the exact ISO published at
https://github.com/f1999society-cmd/arch/releases/tag/v3.0.0** (downloaded
from the release inside CI — not a rebuild). Rerun: workflow run
`36295138374`, **0 FAIL** (the test script exits non-zero on any failure).

An earlier run (36292483926) shipped 17/19 QEMU monitor frames as solid
black: `screendump` cannot read back a virgl GL scanout. The capture rig was
fixed (serial-driven phases boot `-device VGA`; desktop phases capture with
in-guest grim; a BLACK-FRAME detector now flags uniform frames) and every
frame below was pixel-verified to contain real content. Three frames fired
in timing gaps (t1-02, t1-03, t5-01: after menu-hide, before first console
paint) were solid black and are excluded rather than shipped as fake
"evidence".

## T1 — BIOS boot, persistence mount (11 checks) — QEMU VGA surface
| File | What it shows |
|------|---------------|
| `t1-01-menu.png` | GRUB boot menu on the stick (persistent default entry) |
| `t1-04-mid.png` → `t1-09-desktop2.png` | **The live desktop captured from the monitor itself**: quickshell top bar, dock, welcome window, wallpaper — rendered through the VGA device, 61% lit, 245 gray levels |

## T2 — Session verification (11 checks + T2l)
| File | What it shows |
|------|---------------|
| `t2-04-desktop-grim.png` | Desktop captured with grim *inside* the Wayland session (early session) |
| `t2-05-desktop-late.png` | Same after all environment checks settled (T2l PASS, 486,887 bytes) |
| `t2-verdict.txt` | `BAR=quickshell WALLPAPER=ok DOCK=ok` |

## T3 — Persistence stress test (16 checks)
LibreOffice installed into the persistent root (`INSTALL_RC=0`), 1 GB file
written (sha256 `3a67ed8f…`), space 14.5 GB → 12.78 GB, then **reboot**:
package still installed, soffice runs, file byte-identical, space consistent.
Logs: `t3-install-tail.txt`, `t3-space.log`.
| File | What it shows |
|------|---------------|
| `t3b-08-desktop-grim.png` | Post-reboot session, grim capture (dim frame — dark wallpaper) |

## T4 — RAM-only mode (3 checks)
`t4-01-early.png` (quiet-mode console, dim), `t4-02-mid.png` /
`t4-03-session.png` (session up from the VGA surface).

## T5 — UEFI / OVMF
`t5-02-menu.png` — **GRUB menu under OVMF firmware**, `t5-03-mid.png` /
`t5-04-session.png` — UEFI boot reaching the session.
(A fifth frame, t5-01, landed after firmware output went quiet — excluded.)

## Other
- `report-cover.html` — cover art source for the verification PDF.

Evidence trail: every PASS line in the report maps to a serial-log marker
(`BNA_*`), an ssh probe result, or a file read back after a reboot — the
frames on this page are the visual layer on top of that log evidence.
