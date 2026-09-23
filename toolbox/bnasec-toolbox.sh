#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  bnasec-toolbox — one-shot customization + USB toolkit
#  for the bnasec Arch / Hyprland persistent live ISO
#
#  Run:  bash bnasec-toolbox.sh
#  Needs: user with sudo (bna / password bnasec on the live ISO)
#
#  v1.3 changelog:
#   - NEW menu 9: USB anti-lag pack — journald volatile + tmpfs (/tmp, /var/tmp,
#     ~/.cache) + 60s write batching + zram swap. The full USB-persistence fix.
#   - Volume keys remapped: F1 = MUTE, F2 = LOWER, F3 = RAISE (+ XF86 keys)
#   - fix_lock now checks the login password (PAM) → no more "auth failed" on unlock
#   - volume fix self-tests the sound pipeline so we know WHERE it breaks
# ════════════════════════════════════════════════════════════════
set -uo pipefail

HCFG="$HOME/.config/hypr"
CONFF="$HCFG/hyprland.conf"
LUAF="$HCFG/hyprland.lua"      # active on Hyprland 0.55+ when present
LOCKF="$HCFG/hyprlock.conf"    # hyprlock refuses to START without a config file
VOLSH="$HCFG/bnasec-vol.sh"    # volume-key glue: OSD when possible, wpctl fallback
# per-feature markers — each option gets its own block so apply-all
# writes ALL features and re-runs stay idempotent (shared-marker bug fixed)

c_ok()   { printf "\033[1;32m✔\033[0m %s\n" "$*"; }
c_err()  { printf "\033[1;31m✘\033[0m %s\n" "$*"; }
c_info() { printf "\033[1;36m➜\033[0m %s\n" "$*"; }
c_warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
pause()  { read -rp "  [Enter] back to menu..." _; }

need_pkgs() {
  local missing=()
  for p in "$@"; do
    if command -v pacman &>/dev/null; then
      pacman -Qi "$p" &>/dev/null || missing+=("$p")
    else
      command -v "$p" &>/dev/null || missing+=("$p")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    c_info "installing: ${missing[*]}"
    if command -v pacman &>/dev/null; then
      sudo pacman -S --needed --noconfirm "${missing[@]}" || { c_err "pacman failed (check network)"; return 1; }
    else
      sudo apt-get update -qq 2>/dev/null
      sudo apt-get install -y "${missing[@]}" || { c_err "apt install failed (check network)"; return 1; }
    fi
  fi
  return 0
}

reload_hypr() {
  command -v hyprctl &>/dev/null || { c_warn "hyprctl missing — log out/in to apply"; return; }
  local OUT
  if ! OUT=$(hyprctl reload 2>&1); then
    c_warn "could not reach Hyprland — changes apply on next login"
    return
  fi
  if printf '%s' "$OUT" | grep -qiE 'error|invalid|failed|cannot|unable|exception'; then
    c_err "Hyprland reload reported problems:"
    printf '%s\n' "$OUT" | sed 's/^/    /'
    c_warn "paste the lines above to me if something looks broken"
  else
    c_ok "Hyprland config reloaded"
  fi
}

hl_live() { # $1 = a conf line, e.g. "bindel = , F2, exec, foo"
  # Hyprland 0.55+ (lua config parser) rejects `hyprctl keyword` -> use `eval`
  local kw=${1%%[ =]*} val=${1#*= }
  hyprctl eval "$1" &>/dev/null && return 0
  hyprctl keyword "$kw" "$val" &>/dev/null
}

bind_present() { # $1 = text to look for in hyprctl binds
  hyprctl binds 2>/dev/null | grep -q "$1"
}

append_block() { # $1=target file  $2=marker  $3=content
  if grep -qF "$2" "$1" 2>/dev/null; then
    c_info "already applied to $(basename "$1") — skipping"
  else
    printf "\n%s (applied %s)\n%s\n%s\n" "$2" "$(date +%F)" "$3" "${2/>>>/<<<}" >> "$1"
    c_ok "written to $(basename "$1")"
  fi
}

purge_block() { # $1=file  $2=feature tag — drop our old block so re-runs update values
  [ -f "$1" ] || return 0
  sed -i "\\#bnasec-toolbox:$2#,#bnasec-toolbox:$2#d" "$1"
}

# ════════════════════════════════════════════════════════════════
#  1) RICE UPGRADE — corners / blur / transparency
# ════════════════════════════════════════════════════════════════
rice_upgrade() {
  echo "── Rounded corners + blur + transparency ──"
  read -rp  "Corner radius [20]: " R;  R=${R:-20}
  read -rp  "Window opacity 0.0-1.0 [0.90]: " O; O=${O:-0.90}

  if [ -f "$LUAF" ]; then
    append_block "$LUAF" "-- >>> bnasec-toolbox:rice" "-- run after theme: override rounding/blur/opacity
hl.config({
    decoration = {
        rounding = ${R},
        active_opacity = ${O},
        inactive_opacity = $(awk -v o="$O" 'BEGIN{printf "%.2f", o-0.05}'),
        blur = { enabled = true, size = 8, passes = 3, vibrancy = 0.17 },
    },
})"
  else
    append_block "$CONFF" "# >>> bnasec-toolbox:rice" "decoration {
    rounding = ${R}
    active_opacity = ${O}
    inactive_opacity = $(awk -v o="$O" 'BEGIN{printf "%.2f", o-0.05}')
    blur {
        enabled = true
        size = 8
        passes = 3
        vibrancy = 0.17
    }
}"
  fi
  reload_hypr
  echo "  Tip: Super+T can switch themes; this override wins over all of them."
  pause
}

# ════════════════════════════════════════════════════════════════
#  2) FIX SCREEN LOCK — install hyprlock + Super+L
# ════════════════════════════════════════════════════════════════
fix_lock() {
  echo "── Screen lock (hyprlock + Super+L) ──"
  need_pkgs hyprlock || { pause; return; }

  # THE REAL BUG (fixed in v1.2): hyprlock refuses to start without a config
  # file ("CRIT: Config path error") — v1.1 only wrote the keybind, never this.
  if [ -f "$LOCKF" ]; then
    c_info "hyprlock.conf already exists — keeping it"
  else
    cat > "$LOCKF" <<'EOF'
# bnasec lock screen — generated by bnasec-toolbox v1.3
background {
    monitor =
    path = screenshot
    blur_passes = 3
    blur_size = 10
    brightness = 0.55
}

input-field {
    monitor =
    size = 320, 48
    outline_thickness = 3
    dots_center = true
    placeholder_text = password...
    position = 0, -70
    halign = center
    valign = center
}

label {
    monitor =
    text = cmd[update:1000] date +"%H:%M"
    font_size = 56
    color = rgba(e6e6e6dd)
    position = 0, 130
    halign = center
    valign = center
}

label {
    monitor =
    text = bnasec
    font_size = 14
    color = rgba(e6e6e677)
    position = 0, -150
    halign = center
    valign = center
}
EOF
    c_ok "created $LOCKF — this file was missing, that's why the lock did nothing"
  fi

  if [ -f "$LUAF" ]; then
    purge_block "$LUAF" lock
    append_block "$LUAF" "-- >>> bnasec-toolbox:lock" "-- lock screen on Super+L
hl.bind(\"SUPER + L\", hl.dsp.exec_cmd(\"hyprlock\"))"
  else
    purge_block "$CONFF" lock
    append_block "$CONFF" "# >>> bnasec-toolbox:lock" "bind = \$mod, L, exec, hyprlock"
  fi

  reload_hypr
  if bind_present hyprlock; then
    c_ok "Super+L is bound"
  else
    hl_live "bind = SUPER, L, exec, hyprlock" \
      && c_ok "Super+L bound for this session" || c_warn "bind failed — log out/in once"
  fi
  # v1.3: unlock goes through PAM → it wants the account's REAL password.
  # Live/persistence setups often have none → "pam ... auth failed" on unlock.
  local PU=${SUDO_USER:-$USER}
  if passwd -S "$PU" 2>/dev/null | awk '{print $2}' | grep -q '^P'; then
    c_ok "login password set — hyprlock will accept it"
  else
    c_warn "user '$PU' has NO login password → unlock says 'auth failed'"
    read -rp "   set one now? [y/N] " _pa
    if [[ $_pa =~ ^[Yy] ]]; then
      sudo passwd "$PU" && c_ok "password set — use it to unlock from now on"
    else
      c_info "later: sudo passwd $PU"
    fi
  fi
  echo "  Test NOW: run 'hyprlock' in a terminal → blurred screen + password box."
  echo "  Unlock with the login password of '$PU'. Esc cancels."
  pause
}

# ════════════════════════════════════════════════════════════════
#  3) NIGHT LIGHT — hyprsunset + Super+N toggle
# ════════════════════════════════════════════════════════════════
night_light() {
  echo "── Night light (hyprsunset + Super+N toggle) ──"
  need_pkgs hyprsunset || { pause; return; }
  read -rp "Temperature (2700 warm – 4500 mild) [3500]: " T; T=${T:-3500}

  if [ -f "$LUAF" ]; then
    purge_block "$LUAF" nightlight
    append_block "$LUAF" "-- >>> bnasec-toolbox:nightlight" "-- night light toggle on Super+N
hl.bind(\"SUPER + N\", hl.dsp.exec_cmd(\"pkill -x hyprsunset || setsid -f hyprsunset -t ${T}\"))"
  else
    purge_block "$CONFF" nightlight
    append_block "$CONFF" "# >>> bnasec-toolbox:nightlight" "bind = \$mod, N, exec, pkill -x hyprsunset || setsid -f hyprsunset -t ${T}"
  fi

  reload_hypr
  if bind_present hyprsunset; then
    c_ok "Super+N is bound"
  else
    hl_live "bind = SUPER, N, exec, pkill -x hyprsunset || setsid -f hyprsunset -t ${T}" \
      && c_ok "Super+N bound for this session" || c_warn "bind failed — log out/in once"
  fi
  echo "  Manual:  hyprsunset -t ${T}   (on)   |   hyprsunset -i   (reset)"
  pause
}

# ════════════════════════════════════════════════════════════════
#  4) LOUDER SOUND — raise PipeWire soft limit, keep after reboot
# ════════════════════════════════════════════════════════════════
louder() {
  echo "── Louder sound ──"
  command -v wpctl &>/dev/null || need_pkgs pipewire || { pause; return; }
  read -rp "Max volume boost limit in % (130 = +30% over max, distorts) [150]: " L
  L=${L:-150}; LIM=$(awk -v l="$L" 'BEGIN{printf "%.2f", l/100}')

  wpctl set-volume -l "$LIM" @DEFAULT_AUDIO_SINK@ 100% && c_ok "limit raised to ${L}% — use volume keys to go past 100%"
  wpctl set-mute @DEFAULT_AUDIO_SINK@ 0

  # re-apply on every boot via autostart
  if [ -f "$LUAF" ]; then
    purge_block "$LUAF" volume
    append_block "$LUAF" "-- >>> bnasec-toolbox:volume" "-- volume boost limit at startup
hl.on(\"hyprland.start\", function()
    hl.exec_cmd(\"wpctl set-volume -l ${LIM} @DEFAULT_AUDIO_SINK@ 100%\")
end)"
  else
    purge_block "$CONFF" volume
    append_block "$CONFF" "# >>> bnasec-toolbox:volume" "exec-once = wpctl set-volume -l ${LIM} @DEFAULT_AUDIO_SINK@ 100%"
  fi
  echo "  Extra punch (optional): sudo pacman -S easyeffects  → Effects → Loudness Equalizer"
  pause
}

# ════════════════════════════════════════════════════════════════
#  5) WORKSPACE ANIMATION — slide / slidevert / slidefade / fade
# ════════════════════════════════════════════════════════════════
ws_anim() {
  echo "── Workspace switch animation ──"
  echo "  styles: slide | slidevert | slidefade [pct] | fade"
  read -rp "Style [slide]: " S; S=${S:-slide}
  case "$S" in
    slide|slidevert|fade|slidefade|slidefade\ *) ;;
    *) c_warn "unknown style '$S' — using slide"; S=slide ;;
  esac
  read -rp "Speed 1-10 (lower = faster) [6]: " V; V=${V:-6}
  case "$V" in (*[!0-9]*|'') V=6 ;; esac
  [ "$V" -ge 1 ] && [ "$V" -le 10 ] || V=6

  if [ -f "$LUAF" ]; then
    append_block "$LUAF" "-- >>> bnasec-toolbox:anim" "-- workspace switch animation
hl.config({
    animations = {
        enabled = true,
        animation = {
            \"workspaces, 1, ${V}, default, ${S}\",
        },
    },
})"
  else
    append_block "$CONFF" "# >>> bnasec-toolbox:anim" "animations {
    enabled = true
    animation = workspaces, 1, ${V}, default, ${S}
}"
  fi

  reload_hypr
  hl_live "animation = workspaces, 1, ${V}, default, ${S}" \
    && c_ok "applied live — switch workspaces to feel it"
  echo "  Tip: slide = horizontal sweep, slidevert = vertical, slidefade 30 = subtle mix."
  pause
}

# ════════════════════════════════════════════════════════════════
#  5b) VOLUME KEYS — F1 mute / F2 lower / F3 raise + on-screen OSD
# ════════════════════════════════════════════════════════════════
write_volsh() {
  cat > "$VOLSH" <<'EOS'
#!/bin/bash
# bnasec toolbox — volume key glue: swayosd OSD when its server is up,
# raw wpctl fallback so the keys ALWAYS work. Boost capped at 150%.
ACT="$1"
pgrep -x swayosd-server >/dev/null || { setsid -f swayosd-server >/dev/null 2>&1; sleep 0.4; }
if pgrep -x swayosd-server >/dev/null; then
  case "$ACT" in
    up)   swayosd-client --output-volume raise       && exit 0 ;;
    down) swayosd-client --output-volume lower       && exit 0 ;;
    mute) swayosd-client --output-volume mute-toggle && exit 0 ;;
  esac
fi
case "$ACT" in
  up)   wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+ ;;
  down) wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%- ;;
  mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle ;;
esac
EOS
  chmod +x "$VOLSH"
}

vol_keys() {
  echo "── Volume keys + OSD  (F1 = mute, F2 = lower, F3 = raise) ──"
  need_pkgs swayosd || { pause; return; }
  command -v wpctl &>/dev/null || { c_err "wpctl missing — install pipewire"; pause; return; }
  command -v swayosd-client &>/dev/null || { c_err "swayosd-client missing"; pause; return; }

  write_volsh
  c_ok "glue script: $VOLSH (auto-starts the OSD server, wpctl fallback)"

  if [ -f "$LUAF" ]; then
    purge_block "$LUAF" vkeys
    append_block "$LUAF" "-- >>> bnasec-toolbox:vkeys" "-- volume keys: F1 mute / F2 lower / F3 raise + XF86 trio, OSD
hl.bind(\"F1\", hl.dsp.exec_cmd(\"$VOLSH mute\"))
hl.bind(\"F2\", hl.dsp.exec_cmd(\"$VOLSH down\"))
hl.bind(\"F3\", hl.dsp.exec_cmd(\"$VOLSH up\"))
hl.bind(\"XF86AudioMute\", hl.dsp.exec_cmd(\"$VOLSH mute\"))
hl.bind(\"XF86AudioLowerVolume\", hl.dsp.exec_cmd(\"$VOLSH down\"))
hl.bind(\"XF86AudioRaiseVolume\", hl.dsp.exec_cmd(\"$VOLSH up\"))"
  else
    purge_block "$CONFF" vkeys
    append_block "$CONFF" "# >>> bnasec-toolbox:vkeys" "bindel = , F1, exec, $VOLSH mute
bindel = , F2, exec, $VOLSH down
bindel = , F3, exec, $VOLSH up
bindel = , XF86AudioMute, exec, $VOLSH mute
bindel = , XF86AudioLowerVolume, exec, $VOLSH down
bindel = , XF86AudioRaiseVolume, exec, $VOLSH up
exec-once = swayosd-server"
  fi

  reload_hypr

  # v1.3: count what ACTUALLY registered — pinpoints bind problems instantly
  local n; n=$(hyprctl binds 2>/dev/null | grep -c bnasec-vol.sh)
  if [ "$n" -ge 6 ]; then
    c_ok "$n binds registered — F1 mute / F2 lower / F3 raise are live"
  elif [ "$n" -gt 0 ]; then
    c_warn "only $n/6 binds registered — log out/in once for the rest"
  else
    local ok=0
    hl_live "bindel = , F1, exec, $VOLSH mute"                   && ok=$((ok+1))
    hl_live "bindel = , F2, exec, $VOLSH down"                   && ok=$((ok+1))
    hl_live "bindel = , F3, exec, $VOLSH up"                     && ok=$((ok+1))
    hl_live "bindel = , XF86AudioMute, exec, $VOLSH mute"        && ok=$((ok+1))
    hl_live "bindel = , XF86AudioLowerVolume, exec, $VOLSH down" && ok=$((ok+1))
    hl_live "bindel = , XF86AudioRaiseVolume, exec, $VOLSH up"   && ok=$((ok+1))
    [ "$ok" -eq 6 ] && c_ok "volume keys live NOW (this session)" \
                    || c_warn "$ok/6 live binds — check the reload errors above"
  fi

  # v1.3 self-test: prove the sound pipeline WITHOUT the keyboard. If this
  # passes but the keys do nothing, the KEY never reaches Hyprland (laptop Fn
  # layer) — then use the XF86Audio keys or tell me and we rebind to other keys.
  c_info "self-test: +5% volume through the glue script..."
  if bash "$VOLSH" up; then
    c_ok "sound pipeline OK — keys dead = key not reaching Hyprland (Fn?)"
  else
    c_err "glue script failed — run: bash $VOLSH up   and paste me the error"
  fi
  echo "  First OSD after a reboot may lag ~1s while the server auto-starts."
  echo "  (The 'LibInput Backend isn't available' warning is harmless — caps-lock OSD only.)"
  pause
}

# ════════════════════════════════════════════════════════════════
#  7) USB ANTI-LAG PACK — the exact 4-step fix for persistence stutter
# ════════════════════════════════════════════════════════════════
usb_speed_fix() {
  echo "── USB anti-lag pack (kills background-write stutter) ──"
  local RUSER RHOME RUID RGID
  RUSER=${SUDO_USER:-$USER}
  RHOME=$(getent passwd "$RUSER" 2>/dev/null | cut -d: -f6); RHOME=${RHOME:-$HOME}
  RUID=$(id -u "$RUSER"); RGID=$(id -g "$RUSER")

  # 1) journald → RAM only (32M cap). #1 stutter source: the journal
  #    constantly flushing to the slow stick.
  sudo mkdir -p /etc/systemd/journald.conf.d
  printf '%s\n' "# >>> bnasec-toolbox:usblag >>>" "[Journal]" \
    "Storage=volatile" "RuntimeMaxUse=32M" "# <<< bnasec-toolbox:usblag <<<" \
    | sudo tee /etc/systemd/journald.conf.d/usb-lag.conf >/dev/null
  c_ok "1/4 journald → volatile (RAM only, 32M cap)"

  # 2) tmpfs for /tmp /var/tmp ~/.cache — app temp-writes hit RAM, not the stick
  if grep -q "bnasec-toolbox:usblag" /etc/fstab 2>/dev/null \
     || grep -qE "^tmpfs +/tmp " /etc/fstab 2>/dev/null; then
    c_info "2/4 fstab tmpfs entries already present — skipping"
  else
    printf '%s\n' "" "# >>> bnasec-toolbox:usblag >>>" \
      "tmpfs /tmp tmpfs rw,nosuid,nodev,size=512M,mode=1777 0 0" \
      "tmpfs /var/tmp tmpfs rw,nosuid,nodev,size=256M,mode=1777 0 0" \
      "tmpfs $RHOME/.cache tmpfs rw,nosuid,nodev,uid=$RUID,gid=$RGID,size=512M 0 0" \
      "# <<< bnasec-toolbox:usblag <<<" | sudo tee -a /etc/fstab >/dev/null
    c_ok "2/4 tmpfs mounts added (/tmp, /var/tmp, ~/.cache)"
  fi

  # 3) batch writes — flush dirty pages every 60s instead of every 5s
  printf '%s\n' "# >>> bnasec-toolbox:usblag >>>" \
    "vm.dirty_writeback_centisecs = 6000" \
    "vm.dirty_expire_centisecs = 6000" \
    "vm.dirty_background_ratio = 10" \
    "vm.dirty_ratio = 30" \
    "# <<< bnasec-toolbox:usblag <<<" \
    | sudo tee /etc/sysctl.d/99-bnasec-usblag.conf >/dev/null
  sudo sysctl -p /etc/sysctl.d/99-bnasec-usblag.conf >/dev/null 2>&1 \
    && c_ok "3/4 write batching on (60s writeback, 30% dirty ratio)" \
    || c_warn "3/4 sysctl file written — applies on reboot"

  # 4) zram swap — compressed-in-RAM swap absorbs churn so the stick isn't hit
  if [ ! -x /usr/lib/systemd/system-generators/zram-generator ] \
     && [ ! -x /lib/systemd/system-generators/zram-generator ]; then
    if command -v pacman &>/dev/null; then
      need_pkgs zram-generator || c_warn "zram-generator missing — skipping step 4"
    else
      need_pkgs systemd-zram-generator || c_warn "zram-generator missing — skipping step 4"
    fi
  fi
  if [ -x /usr/lib/systemd/system-generators/zram-generator ] \
     || [ -x /lib/systemd/system-generators/zram-generator ]; then
    printf '%s\n' "[zram0]" "zram-size = ram / 2" \
      "compression-algorithm = zstd" "swap-priority = 100" \
      | sudo tee /etc/systemd/zram-generator.conf >/dev/null
    sudo systemctl start systemd-zram-setup@zram0.service 2>/dev/null
    if swapon --show 2>/dev/null | grep -q zram; then
      c_ok "4/4 zram swap online:"
      swapon --show 2>/dev/null | sed 's/^/      /'
    else
      c_warn "4/4 zram configured — comes up on next reboot"
    fi
  fi

  # apply what can be applied without a reboot
  sudo systemctl daemon-reload 2>/dev/null
  sudo systemctl restart systemd-journald 2>/dev/null
  sudo mount -a 2>/dev/null
  findmnt -n /tmp >/dev/null 2>&1 \
    && c_ok "/tmp is RAM-backed now" || c_warn "/tmp tmpfs not active — one reboot finishes it"
  findmnt -n "$RHOME/.cache" >/dev/null 2>&1 && c_ok "~/.cache is RAM-backed now"

  echo
  echo "  Reboot once for the full effect, then check:  findmnt /tmp && swapon --show"
  echo "  NOTE: the stick itself is ~12 MB/s — this pack removes the STUTTER, it"
  echo "  cannot make USB 2.0 fast. A cheap portable SSD is the real speed fix."
  pause
}

apply_all() { rice_upgrade; fix_lock; night_light; louder; ws_anim; vol_keys; usb_speed_fix; }

# ════════════════════════════════════════════════════════════════
#  6) USB TOOLKIT
# ════════════════════════════════════════════════════════════════
pick_disk() { # echoes chosen /dev/sdX, refuses busy/boot disks
  lsblk -do NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
  read -rp "Device (e.g. /dev/sdb): " DEV
  case "$DEV" in
    /dev/sd[a-z]|/dev/nvme[0-9]n[0-9]) ;;
    *) c_err "not a whole disk: $DEV"; return 1 ;;
  esac
  [ -b "$DEV" ] || { c_err "no such block device"; return 1; }

  local ROOTSRC BOOTSRC
  ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null)
  BOOTSRC=$(findmnt -n -o SOURCE /run/bnasec/persist 2>/dev/null || findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null)
  for S in "$ROOTSRC" "$BOOTSRC"; do
    [ -z "$S" ] && continue
    if lsblk -no PKNAME "$S" 2>/dev/null | grep -qx "$(basename "$DEV")"; then
      c_err "REFUSED: $DEV is the system/boot disk — this would kill your session!"
      return 1
    fi
  done
  echo "$DEV"
}

confirm_disk() { # $1 = what we will do
  c_warn "About to $1 — ALL DATA on $DISK WILL BE DESTROYED."
  lsblk -do NAME,SIZE,MODEL "$DISK"
  read -rp "Type YES to continue: " A
  [ "$A" = "YES" ] || { c_info "aborted"; return 1; }
}

usb_list() { lsblk -do NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,MOUNTPOINTS; pause; }

usb_write() {
  DISK=$(pick_disk) || { pause; return; }
  read -rp "Path to .iso file: " ISO
  [ -f "$ISO" ] || { c_err "file not found: $ISO"; pause; return; }
  confirm_disk "write '$ISO' to $DISK" || { pause; return; }
  c_info "writing... (progress shown)"
  sudo dd if="$ISO" of="$DISK" bs=4M status=progress conv=fdatasync && sudo sync \
    && c_ok "done — USB is bootable" || c_err "write failed"
  pause
}

usb_format() {
  DISK=$(pick_disk) || { pause; return; }
  echo "  1) FAT32 (universal, 4GB file limit)  2) exFAT (big files, Win+Mac)"
  echo "  3) NTFS (Windows)                     4) ext4 (Linux only)"
  read -rp "Filesystem [1-4]: " FS
  read -rp "Volume label [USB]: " LBL; LBL=${LBL:-USB}
  confirm_disk "format $DISK as $FS" || { pause; return; }
  for P in "$DISK"?*; do sudo umount "$P" 2>/dev/null; done
  sudo wipefs -a "$DISK" &>/dev/null
  case "$FS" in
    1) need_pkgs dosfstools    && sudo mkfs.vfat -F32 -n "$LBL" "$DISK" ;;
    2) need_pkgs exfatprogs    && sudo mkfs.exfat -n "$LBL" "$DISK" ;;
    3) need_pkgs ntfs-3g       && sudo mkfs.ntfs -L "$LBL" --fast "$DISK" ;;
    4) need_pkgs e2fsprogs     && sudo mkfs.ext4 -L "$LBL" -F "$DISK" ;;
    *) c_err "invalid choice"; pause; return ;;
  esac && c_ok "formatted $DISK" || c_err "format failed"
  pause
}

usb_wipe() {
  DISK=$(pick_disk) || { pause; return; }
  echo "  1) quick (signatures only, seconds)   2) full zero (slow, secure-ish)"
  read -rp "Mode [1-2]: " M
  confirm_disk "wipe $DISK" || { pause; return; }
  if [ "$M" = "2" ]; then
    sudo dd if=/dev/zero of="$DISK" bs=4M status=progress conv=fdatasync && c_ok "fully zeroed"
  else
    for P in "$DISK"?*; do sudo umount "$P" 2>/dev/null; done
    sudo wipefs -a "$DISK" && c_ok "signatures wiped"
  fi
  pause
}

usb_persist() {
  echo "── Add a persistence partition (ext4, label: persistence) ──"
  echo "  NOTE: the bnasec ISO normally creates this AUTOMATICALLY on first boot."
  echo "        Use this if the auto-setup skipped (stick <2GiB free, or"
  echo "        non-removable-flagged stick) or the partition was lost."
  DISK=$(pick_disk) || { pause; return; }
  confirm_disk "append a persistence partition to $DISK (keeps existing data)" || { pause; return; }
  need_pkgs parted e2fsprogs || { pause; return; }
  sudo umount "${DISK}?*" 2>/dev/null
  END=$(sudo parted -s "$DISK" unit s print | awk '/^ *[0-9]+/{e=$3} END{print e}' | tr -d 's')
  [ -n "$END" ] || { c_err "could not read partition table"; pause; return; }
  sudo parted -s "$DISK" mkpart primary ext4 "$((END+1))s" 100% \
    && sudo parted -s "$DISK" set $(lsblk -no PARTN "${DISK}3" 2>/dev/null || echo 3) ext4 on 2>/dev/null
  LAST="${DISK}$(lsblk -no PARTN "$DISK" | sort -n | tail -1)"
  sudo mkfs.ext4 -L persistence -F "$LAST" || { c_err "mkfs failed"; pause; return; }
  # persistence.conf is REQUIRED — live-boot ignores the partition without it
  if sudo mount "$LAST" /mnt 2>/dev/null; then
    echo '/ union' | sudo tee /mnt/persistence.conf >/dev/null && sudo sync && sudo umount /mnt
    c_ok "persistence.conf written — activates on next boot"
  else
    c_err "could not mount $LAST to write persistence.conf — run:"
    echo "    sudo mount $LAST /mnt && echo '/ union' | sudo tee /mnt/persistence.conf && sudo umount /mnt"
  fi
  c_ok "persistence partition ready: $LAST"
  echo "  Now REBOOT and pick: 'Arch Hyprland (Noro rice) — persistent'"
  pause
}

usb_menu() {
  while true; do
    echo; echo "── USB toolkit ──"
    echo "  1) list drives          2) write ISO to USB"
    echo "  3) format USB           4) wipe USB"
    echo "  5) add persistence part 0) back"
    read -rp "choice: " U
    case "$U" in
      1) usb_list ;; 2) usb_write ;; 3) usb_format ;; 4) usb_wipe ;; 5) usb_persist ;;
      0) break ;; *) ;;
    esac
  done
}

# ════════════════════════════════════════════════════════════════
while true; do
  echo
  echo "╔══════════════════════════════════════════╗"
  echo "║        bnasec toolbox  v1.3              ║"
  echo "╚══════════════════════════════════════════╝"
  echo "  1) rounded corners + blur + transparency"
  echo "  2) fix screen lock (Super+L)"
  echo "  3) night light (Super+N toggle)"
  echo "  4) louder sound"
  echo "  5) volume keys F1 mute F2 lower F3 raise + OSD"
  echo "  6) workspace switch animation (slide)"
  echo "  7) apply ALL of the above (1-6 + USB anti-lag)"
  echo "  8) USB toolkit (write/format/wipe/persistence)"
  echo "  9) USB anti-lag pack (fix USB lag/stutter)"
  echo "  0) exit"
  read -rp "choice: " C
  case "$C" in
    1) rice_upgrade ;; 2) fix_lock ;; 3) night_light ;; 4) louder ;;
    5) vol_keys ;; 6) ws_anim ;; 7) apply_all ;; 8) usb_menu ;;
    9) usb_speed_fix ;; 0) exit 0 ;; *) ;;
  esac
done
