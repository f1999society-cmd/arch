# bnasec: autologin on tty1 goes straight into the Hyprland session (no display
# manager — the v1.2.0 X11-greeter black screen bug class is gone entirely).
# Any other tty keeps a normal login shell.
if [ "$(tty)" = "/dev/tty1" ] && command -v uwsm >/dev/null 2>&1; then
    # v3.0.0: inside QEMU/VMs Aquamarine (Hyprland's renderer) needs modifier
    #-less buffers on virtio-gpu; set it for both the uwsm systemd-user path
    # (set-environment) and a direct exec fallback (export).
    if grep -qa QEMU /sys/class/dmi/id/product_name 2>/dev/null \
       || grep -qa QEMU /sys/class/dmi/id/sys_vendor 2>/dev/null; then
        systemctl --user set-environment AQ_NO_MODIFIERS=1 2>/dev/null || true
        export AQ_NO_MODIFIERS=1
    fi
    if ! uwsm start hyprland.desktop 2>/tmp/bnasec-uwsm.log; then
        rm -f /tmp/bnasec-uwsm.log
        exec Hyprland
    fi
elif [ "$(tty)" = "/dev/tty1" ] && command -v Hyprland >/dev/null 2>&1; then
    exec Hyprland
fi
