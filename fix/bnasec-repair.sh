#!/usr/bin/env bash
# ============================================================
#  bnasec live repair v2  (v2.0.0/2.0.1 stick — NO ISO re-download)
# ============================================================
# v2 adds the PANEL fix:
#   - permanent autostart bridge via ML4W's official custom.lua hook
#   - a guarded, logged chain script that starts the whole desktop
#     (quickshell bar, settings panel, overview, dock, welcome, wallpaper,
#      swaync, hypridle) and AUTO-RELAUNCHES with software rendering if the
#     GPU/Qt path fails (old Intel Haswell iGPUs are notorious for this)
#   - exec bits extended to ~/.config/ml4w/settings (terminal.sh, browser.sh,
#     filemanager, calculator, emoji picker — the SUPER+key binds)
#   - a last-resort trigger in zsh so the desktop heals itself every login
#
# EVERYTHING PERSISTENT IS WRITTEN THROUGH ~/.config -> your stick.
# Run ONCE. After this, the panel starts automatically on every boot.
# Full log: ~/Documents/bnasec-repair-report.txt
# ============================================================
set -uo pipefail

R="$HOME/Documents/bnasec-repair-report.txt"
exec > >(tee -a "$R") 2>&1
echo "============================================================"
echo " bnasec live repair v2 — $(date)"
echo " user: $(whoami)  |  Hyprland session: ${HYPRLAND_INSTANCE_SIGNATURE:+yes}${HYPRLAND_INSTANCE_SIGNATURE:-no}"
echo "============================================================"

# ------------------------------------------------ [1/6] exec bits
echo ""
echo "== [1/6] Restoring exec bits (incl. settings app launchers) =="
FIXDIRS=(
    "$HOME/.config/hypr/scripts"
    "$HOME/.config/ml4w/scripts"
    "$HOME/.config/ml4w/bin"
    "$HOME/.config/ml4w/listeners"
    "$HOME/.config/ml4w/settings"
    "$HOME/.config/matugen/post-hook-scripts"
)
for d in "${FIXDIRS[@]}"; do
    [ -d "$d" ] && find "$d" -type f -exec chmod u+x {} + 2>/dev/null
done
chmod u+x "$HOME/.config/ml4w/listeners.sh" "$HOME/.config/waybar/launch.sh" 2>/dev/null
find "$HOME/.local/bin" "$HOME/.local/share" -type f -exec chmod u+x {} + 2>/dev/null
for f in "$HOME/.config/ml4w/scripts/ml4w-autostart" "$HOME/.config/ml4w/settings/terminal.sh" \
         "$HOME/.config/ml4w/listeners.sh" "$HOME/.config/hypr/scripts/gtk.sh"; do
    [ -x "$f" ] && echo "OK  ${f#$HOME/}" || echo "FAIL ${f#$HOME/}"
done

# ------------------------------------------------ [2/6] stop stale duplicates
echo ""
echo "== [2/6] Cleaning up duplicate panel processes =="
pkill -f 'ml4w/scripts/ml4w-autostart' 2>/dev/null
pkill -f 'qs -p' 2>/dev/null
pkill -f 'ml4w-dock' 2>/dev/null
killall qs 2>/dev/null
sleep 1
echo "OK  cleaned (frees the RAM that stacked up from relaunch attempts)"

# ------------------------------------------------ [3/6] oh-my-zsh (persistent)
echo ""
echo "== [3/6] oh-my-zsh in the persistence partition =="
OMZ="$HOME/.config/ohmyzsh"
if [ -f "$OMZ/oh-my-zsh.sh" ]; then
    echo "OK  already present"
else
    git clone -q --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ" \
        && echo "OK  cloned (persistent)" || echo "FAIL clone failed — check network"
fi
for p in "zsh-users/zsh-autosuggestions" "zsh-users/zsh-syntax-highlighting" "zdharma-continuum/fast-syntax-highlighting"; do
    d="$OMZ/custom/plugins/${p##*/}"
    [ -d "$d" ] || git clone -q --depth=1 "https://github.com/$p.git" "$d" 2>/dev/null && echo "OK  plugin ${p##*/}"
done
cat > "$HOME/.config/zshrc/10-bnasec-ohmy.zsh" <<'EOF'
# bnasec: oh-my-zsh lives inside the persistence partition (~/.config)
[ -f "$HOME/.config/ohmyzsh/oh-my-zsh.sh" ] && export ZSH="$HOME/.config/ohmyzsh"
EOF

# ------------------------------------------------ [4/6] THE PANEL BRIDGE
echo ""
echo "== [4/6] Installing the permanent autostart bridge =="
mkdir -p "$HOME/.config/bnasec" "$HOME/.config/zshrc/custom"

# (a) the chain: guarded, logged, software-render fallback
cat > "$HOME/.config/bnasec/autostart-chain.sh" <<'EOF'
#!/usr/bin/env bash
# bnasec: guaranteed ML4W desktop chain — idempotent, flock-guarded, logged.
# Starts every desktop component that ML4W's own autostart would, and
# relaunches with QT_QUICK_BACKEND=software if quickshell dies (GPU/Qt GL).
LOG="$HOME/Documents/bnasec-chain.log"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/bnasec-chain.lock"
exec 9>"$LOCK" || exit 0
flock -n 9 || exit 0

{
echo "===== bnasec autostart-chain $(date) ====="
pgrep -x awww-daemon >/dev/null 2>&1 || { nohup awww-daemon >>"$LOG" 2>&1 & echo "started awww-daemon"; } 9>&-
if ! pgrep -f 'ml4w/scripts/ml4w-autostart' >/dev/null 2>&1; then
    QT_QUICK_BACKEND=software nohup "$HOME/.config/ml4w/scripts/ml4w-autostart" >>"$LOG" 2>&1 &
    echo "started ml4w-autostart (software rendering)"
else
    echo "ml4w-autostart already running — leaving it alone"
fi
pgrep -x swaync  >/dev/null 2>&1 || { nohup swaync  >>"$LOG" 2>&1 & } 9>&-
pgrep -x hypridle >/dev/null 2>&1 || { nohup hypridle >>"$LOG" 2>&1 & } 9>&-
"$HOME/.config/ml4w/listeners.sh" --startall >>"$LOG" 2>&1 || true

sleep 8
if ! pgrep -f 'qs -p|qs$|quickshell' >/dev/null 2>&1; then
    echo "!! quickshell not alive after 8s — hard relaunch with software rendering"
    pkill -f 'ml4w/scripts/ml4w-autostart' 2>/dev/null
    sleep 1
    QT_QUICK_BACKEND=software nohup "$HOME/.config/ml4w/scripts/ml4w-autostart" >>"$LOG" 2>&1 &
    sleep 6
fi
N=$(pgrep -c -f 'qs' 2>/dev/null || echo 0)
echo "===== chain done: quickshell procs=$N awww=$(pgrep -c -x awww-daemon 2>/dev/null || echo 0) ====="
} >>"$LOG" 2>&1
EOF
chmod u+x "$HOME/.config/bnasec/autostart-chain.sh"
echo "OK  ~/.config/bnasec/autostart-chain.sh (persistent, logged)"

# (b) ML4W's official custom hook — hyprland.lua loads this if it exists
if [ -f "$HOME/.config/hypr/custom.lua" ]; then
    cp "$HOME/.config/hypr/custom.lua" "$HOME/.config/hypr/custom.lua.bnasec-backup" 2>/dev/null
    echo "OK  existing custom.lua backed up"
fi
cat > "$HOME/.config/hypr/custom.lua" <<'EOF'
-- bnasec: guaranteed desktop autostart bridge
-- (ML4W's official custom hook — hyprland.lua requires this file if present)
local home = os.getenv("HOME")

hl.on("hyprland.start", function()
    hl.exec_cmd(home .. "/.config/bnasec/autostart-chain.sh")
end)
EOF
echo "OK  ~/.config/hypr/custom.lua (persistent — runs the chain every session start)"

# (c) last-resort trigger from the shell (covers even a missing Hyprland event)
cat > "$HOME/.config/zshrc/99-bnasec.zsh" <<'EOF'
# bnasec: live-session package degradation (eza/fzf live on volatile root)
if ! command -v eza >/dev/null 2>&1; then
    unalias ls ll lt 2>/dev/null
    alias ls='ls --color=auto' ll='ls -alh' lt='ls -a'
    echo "[bnasec] eza/fzf not in this session — plain ls active. Restore with: ~/.config/bnasec/live-pkgs.sh"
fi
# bnasec: self-healing desktop trigger (no-op when the panel is already up)
if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ] && [ -x "$HOME/.config/bnasec/autostart-chain.sh" ]; then
    "$HOME/.config/bnasec/autostart-chain.sh" >/dev/null 2>&1 &!
fi
EOF
echo "OK  zsh self-healing trigger installed"

# (d) the 10-second package helper for after reboots
cat > "$HOME/.config/bnasec/live-pkgs.sh" <<'EOF'
#!/usr/bin/env bash
exec sudo pacman -Sy --needed eza fzf
EOF
chmod u+x "$HOME/.config/bnasec/live-pkgs.sh"

# fzf guard override (no 'command not found' noise when fzf is absent)
sed 's|^source <(fzf --zsh)|command -v fzf >/dev/null 2>\&1 \&\& source <(fzf --zsh)|' \
    "$HOME/.config/zshrc/20-customization" > "$HOME/.config/zshrc/custom/20-customization" 2>/dev/null \
    && echo "OK  fzf guard override refreshed"

# ------------------------------------------------ [5/6] eza + fzf (volatile)
echo ""
echo "== [5/6] eza + fzf for THIS session =="
if command -v eza >/dev/null 2>&1 && command -v fzf >/dev/null 2>&1; then
    echo "OK  already installed"
else
    "$HOME/.config/bnasec/live-pkgs.sh" \
        && echo "OK  installed" \
        || echo "FAIL pacman — run ~/.config/bnasec/live-pkgs.sh manually (password: bnasec)"
fi

# ------------------------------------------------ [6/6] launch + STATUS
echo ""
echo "== [6/6] Launching the desktop chain NOW =="
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    "$HOME/.config/bnasec/autostart-chain.sh"
    sleep 4
else
    echo "SKIP not inside Hyprland — the chain runs automatically at next login"
fi

echo ""
echo "==================== STATUS (paste this to me if panel missing) ===================="
echo "quickshell/qs processes : $(pgrep -c -f 'qs|quickshell' 2>/dev/null || echo 0)"
echo "awww-daemon             : $(pgrep -c -x awww-daemon 2>/dev/null || echo 0) instance(s)"
echo "swaync / hypridle       : $(pgrep -c -x swaync 2>/dev/null || echo 0) / $(pgrep -c -x hypridle 2>/dev/null || echo 0)"
echo "qs version              : $(qs --version 2>&1 | head -1)"
echo "RAM                     : $(free -h | awk 'NR==2{print $3" used / "$2}')"
echo "--- last chain log lines ---"
tail -12 "$HOME/Documents/bnasec-chain.log" 2>/dev/null
echo "===================================================================================================="
if pgrep -f 'qs|quickshell' >/dev/null 2>&1; then
    echo "VERDICT: PANEL PROCESSES RUNNING — look at your screen. Then REBOOT once to confirm auto-start."
else
    echo "VERDICT: PANEL NOT RUNNING — paste the whole STATUS block above to me."
fi
echo "Saved: ~/Documents/bnasec-repair.sh is this script (re-runnable anytime)."
