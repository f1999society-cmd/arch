#!/usr/bin/env bash
# ============================================================
#  bnasec live repair  (v2.0.0 stick — NO ISO re-download needed)
# ============================================================
# Fixes, in order:
#   1. exec bits on the whole ML4W script tree  -> bar/dock/wallpaper chain
#   2. oh-my-zsh + plugins cloned INTO ~/.config (persistence!) -> zsh errors gone
#   3. zshrc overrides: oh-my-zsh path, fzf guard, ls fallback (all persistent)
#   4. installs eza + fzf via pacman (live session only — root resets on boot)
#   5. relaunches the panel chain NOW (if you run this inside Hyprland/kitty)
#
# Persistent = written through ~/.config bind to the stick. Survives reboot.
# Volatile   = root filesystem packages. Re-run ~/.config/bnasec/live-pkgs.sh
#              after each reboot (10 seconds) to get eza/fzf back.
#
# Safe to run as many times as you want. Full log lands in
# ~/Documents/bnasec-repair-report.txt (also persistent).
# ============================================================
set -uo pipefail

R="$HOME/Documents/bnasec-repair-report.txt"
exec > >(tee -a "$R") 2>&1
echo "============================================================"
echo " bnasec live repair — $(date)"
echo " user: $(whoami)  |  Hyprland session: ${HYPRLAND_INSTANCE_SIGNATURE:+yes}${HYPRLAND_INSTANCE_SIGNATURE:-no}"
echo "============================================================"

# ------------------------------------------------ [1/5] exec bits
echo ""
echo "== [1/5] Restoring exec bits on the ML4W script tree =="
FIXDIRS=(
    "$HOME/.config/hypr/scripts"
    "$HOME/.config/ml4w/scripts"
    "$HOME/.config/ml4w/bin"
    "$HOME/.config/ml4w/listeners"
    "$HOME/.config/matugen/post-hook-scripts"
)
for d in "${FIXDIRS[@]}"; do
    [ -d "$d" ] && find "$d" -type f -exec chmod u+x {} + 2>/dev/null
done
chmod u+x "$HOME/.config/ml4w/listeners.sh" "$HOME/.config/waybar/launch.sh" 2>/dev/null
find "$HOME/.local/bin" "$HOME/.local/share" -type f -exec chmod u+x {} + 2>/dev/null

for f in "$HOME/.config/ml4w/scripts/ml4w-autostart" \
         "$HOME/.config/ml4w/listeners.sh" \
         "$HOME/.config/waybar/launch.sh" \
         "$HOME/.config/hypr/scripts/gtk.sh"; do
    [ -x "$f" ] && echo "OK  executable: ${f#$HOME/}" || echo "FAIL not executable: ${f#$HOME/}"
done

# ------------------------------------------------ [2/5] oh-my-zsh (persistent)
echo ""
echo "== [2/5] Installing oh-my-zsh INTO the persistence partition =="
OMZ="$HOME/.config/ohmyzsh"
if [ -f "$OMZ/oh-my-zsh.sh" ]; then
    echo "OK  oh-my-zsh already present at ~/.config/ohmyzsh"
else
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ" \
        && echo "OK  oh-my-zsh cloned (persistent)" \
        || echo "FAIL oh-my-zsh clone failed — check network (nmtui)"
fi
for p in "zsh-users/zsh-autosuggestions" "zsh-users/zsh-syntax-highlighting" "zdharma-continuum/fast-syntax-highlighting"; do
    name="${p##*/}"
    d="$OMZ/custom/plugins/$name"
    if [ ! -d "$d" ]; then
        git clone -q --depth=1 "https://github.com/$p.git" "$d" 2>/dev/null \
            && echo "OK  plugin $name" || echo "WARN plugin $name failed (non-fatal)"
    else
        echo "OK  plugin $name (already present)"
    fi
done

# ------------------------------------------------ [3/5] zshrc overrides (persistent)
echo ""
echo "== [3/5] Writing persistent zsh fixes =="
mkdir -p "$HOME/.config/zshrc/custom" "$HOME/.config/bnasec"

# (a) runs after 00-init, BEFORE 20-customization sources $ZSH — points
#     oh-my-zsh at the persistent clone inside ~/.config
cat > "$HOME/.config/zshrc/10-bnasec-ohmy.zsh" <<'EOF'
# bnasec: oh-my-zsh + plugins live INSIDE the persistence partition so they
# survive every reboot. Overrides the ~/.oh-my-zsh path set in 00-init.
[ -f "$HOME/.config/ohmyzsh/oh-my-zsh.sh" ] && export ZSH="$HOME/.config/ohmyzsh"
EOF

# (b) override copy of 20-customization with the fzf line guarded (no more
#     'command not found: fzf' noise when the volatile package is absent)
sed 's|^source <(fzf --zsh)|command -v fzf >/dev/null 2>\&1 \&\& source <(fzf --zsh)|' \
    "$HOME/.config/zshrc/20-customization" > "$HOME/.config/zshrc/custom/20-customization" 2>/dev/null \
    && echo "OK  fzf guard installed (custom/20-customization override)" \
    || echo "WARN could not write 20-customization override (non-fatal)"

# (c) runs LAST — undoes the eza aliases when the volatile package is gone
cat > "$HOME/.config/zshrc/99-bnasec.zsh" <<'EOF'
# bnasec: live-session packages (eza/fzf) reset on every boot — degrade
# gracefully instead of breaking `ls`.
if ! command -v eza >/dev/null 2>&1; then
    unalias ls ll lt 2>/dev/null
    alias ls='ls --color=auto' ll='ls -alh' lt='ls -a'
    echo "[bnasec] eza/fzf not in this session — plain ls active. Restore with: ~/.config/bnasec/live-pkgs.sh"
fi
EOF

# (d) the 10-second helper to re-install the volatile packages after a reboot
cat > "$HOME/.config/bnasec/live-pkgs.sh" <<'EOF'
#!/usr/bin/env bash
# bnasec: re-install the packages that live on the volatile root (run after
# each reboot if you miss eza/fzf). Takes ~5 seconds on good internet.
exec sudo pacman -Sy --needed eza fzf
EOF
chmod u+x "$HOME/.config/bnasec/live-pkgs.sh"
echo "OK  helper written: ~/.config/bnasec/live-pkgs.sh"

# ------------------------------------------------ [4/5] eza + fzf (volatile)
echo ""
echo "== [4/5] Installing eza + fzf for THIS session =="
if command -v eza >/dev/null 2>&1 && command -v fzf >/dev/null 2>&1; then
    echo "OK  both already installed"
else
    "$HOME/.config/bnasec/live-pkgs.sh" \
        && echo "OK  eza + fzf installed" \
        || echo "FAIL pacman failed — run ~/.config/bnasec/live-pkgs.sh manually (password: bnasec)"
fi

# ------------------------------------------------ [5/5] relaunch the panel NOW
echo ""
echo "== [5/5] Relaunching the ML4W desktop chain =="
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    pkill -f 'ml4w-autostart' 2>/dev/null
    nohup "$HOME/.config/ml4w/scripts/ml4w-autostart" \
        > "$HOME/.cache/bnasec-autostart-relaunch.log" 2>&1 &
    sleep 6
    if pgrep -f 'qs -p|quickshell' >/dev/null 2>&1; then
        echo "OK  quickshell panel processes RUNNING — look at your screen"
    else
        echo "WARN quickshell not detected yet — check ~/.cache/bnasec-autostart-relaunch.log"
        tail -5 "$HOME/.cache/bnasec-autostart-relaunch.log" 2>/dev/null
    fi
    pgrep -a awww-daemon >/dev/null 2>&1 && echo "OK  wallpaper daemon (awww) running" \
        || { nohup awww-daemon >/dev/null 2>&1 & sleep 1; echo "started awww-daemon"; }
else
    echo "SKIP not inside Hyprland right now — the panel chain starts automatically next login"
fi

# ------------------------------------------------ summary
echo ""
echo "============================================================"
echo " DONE — summary"
echo "============================================================"
echo " * Panel/dock/wallpaper : exec bits fixed + chain relaunched (see above)"
echo " * zsh errors           : fixed PERSISTENTLY (oh-my-zsh in ~/.config)"
echo " * ls                   : fixed for this session; after a reboot the"
echo "                          zsh fallback keeps ls working automatically"
echo " * After next reboot    : run  ~/.config/bnasec/live-pkgs.sh  (one line,"
echo "                          sudo password bnasec) to bring back eza+fzf"
echo " * Then REBOOT once for the clean full-desktop start"
echo " Full report saved to: ~/Documents/bnasec-repair-report.txt"
echo " If the panel is STILL missing after a reboot — send me that report file."
echo "============================================================"
