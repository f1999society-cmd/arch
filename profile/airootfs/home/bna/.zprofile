# bnasec: autologin on tty1 goes straight into the Hyprland session (no display
# manager — the v1.2.0 X11-greeter black screen bug class is gone entirely).
# Any other tty keeps a normal login shell.
if [ "$(tty)" = "/dev/tty1" ] && command -v uwsm >/dev/null 2>&1; then
    if ! uwsm start hyprland.desktop 2>/tmp/bnasec-uwsm.log; then
        rm -f /tmp/bnasec-uwsm.log
        exec Hyprland
    fi
elif [ "$(tty)" = "/dev/tty1" ] && command -v Hyprland >/dev/null 2>&1; then
    exec Hyprland
fi
