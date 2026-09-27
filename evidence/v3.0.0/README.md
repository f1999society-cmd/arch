# bnasec-arch v3.0.0 — Test Evidence

Visual and log evidence from the final verification run of bnasec-arch v3.0.0
(CI run 36292483926: **41 PASS / 0 FAIL / 1 WARN**).

## T1 — Boot & Persistence Mount (11 checks)
| File | What it shows |
|------|---------------|
| `t1-01-menu.png`, `t1-02-menu.png` | Boot menu: persistent entry selected by default (cow_label=persistence) |
| `t1-03-early.png` → `t1-06-ready.png` | Boot sequence stages through sshd-ready |
| `t1-07-probes.png` | Persistence probes: root overlay upperdir on USB cowspace, bind mounts, fsck |
| `t1-08-desktop.png`, `t1-09-desktop2.png` | First desktop arrivals on live session |

## T2 — Session Verification (11 checks)
| File | What it shows |
|------|---------------|
| `t2-01-early.png` | Early session boot |
| `t2-04-desktop-grim.png` | **Key evidence** — full desktop captured from *inside* Hyprland via grim (486,953 bytes): quickshell top bar, dock, welcome window, wallpaper |
| `t2-verdict.txt` | `~/.config/bnasec/verdict` → `BAR=quickshell` |
| `t3-install-tail.txt`, `t3-space.log` | See T3 below |

## T3 — Persistence Stress Test (16 checks)
LibreOffice 26.8.0-2 installed + 1GB file written → **reboot** → package still
present, soffice executable, file sha256 byte-identical, 1696 MB consumed from
the persistent partition. Logs: `t3-install-tail.txt`, `t3-space.log`.

## T4 — RAM-only Mode (3 checks)
`t4-01-early.png`, `t4-02-mid.png`, `t4-03-session.png`

## T5 — UEFI/OVMF (3 checks)
`t5-01-ovmf.png`, `t5-02-menu.png`, `t5-03-mid.png`, `t5-04-session.png`

## Other
- `report-cover.html` — cover art source for the 10-page verification PDF.

ISO + sha256: https://github.com/f1999society-cmd/arch/releases/tag/v3.0.0
