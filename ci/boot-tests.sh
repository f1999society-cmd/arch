#!/usr/bin/env bash
#
# bnasec 3.0.0 boot tests — run INSIDE the build container after build-iso.sh.
#
# One 16 GiB virtual USB stick is dd'd from the ISO and driven through the
# exact journey the user will take:
#
#   T1  BIOS first boot from the stick (default 'persistent' entry — root is
#       an overlay whose upperdir lives on the stick's auto-created ext4
#       data partition). Serial-console assertions + VGA screenshots.
#   T2  second boot (direct kernel, same stick) over an SSH control channel:
#       session verdict (bar actually up), environment checks (zsh/omz,
#       eza/fzf, kitty, firefox, network, audio), Hyprland + quickshell
#       processes, and a REAL desktop screenshot pulled with grim.
#   T3  heavy persistence grand tour on the same stick:
#       boot A: disk space check -> write markers -> install libreoffice-fresh
#               into the root overlay (~1.2 GB) -> soffice smoke test ->
#               write a 1 GB file into ~/Documents -> sha256 manifest ->
#               space check -> reboot
#       boot B: markers intact, libreoffice-fresh still installed, soffice
#               still runs, 1 GB file checksum identical, space consistent.
#               PERSISTENCE PROVEN for packages AND data.
#   T4  RAM-only session on a fresh stick boots volatile, stick untouched.
#   T5  UEFI boot via OVMF reaches the session.
#
# The SSH channel exists ONLY for tests: the guest installs the key from the
# kernel cmdline (bnasec.sshkey=...). The shipped ISO starts sshd with
# key-only auth and an EMPTY authorized_keys — no key, no entry.
#
# set -uo pipefail (no -e: every check is hand-rolled PASS/FAIL)

OUT="${OUT_DIR:-$PWD/bnasec-build-out}"
TESTS="${TEST_DIR:-$PWD/bnasec-tests}"
ISO=$(find "$OUT" -maxdepth 1 -name '*.iso' | head -1)
[ -n "$ISO" ] || { echo "no ISO in $OUT"; exit 1; }
mkdir -p "$TESTS"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SHOTS="$TESTS/shots"
MON_SOCK="$TESTS/qemu-mon.sock"
mkdir -p "$SHOTS"

# ---- VGA screenshot plumbing (QEMU monitor screendump, best-effort) -------
shot() {
    local name="$1" i
    command -v socat >/dev/null 2>&1 || return 0
    [ -n "${MON_SOCK:-}" ] || return 0
    for i in 1 2 3 4 5; do [ -S "$MON_SOCK" ] && break; sleep 1; done
    [ -S "$MON_SOCK" ] || return 0
    printf 'screendump %s/%s.ppm\n' "$SHOTS" "$name" \
        | timeout 5 socat - UNIX-CONNECT:"$MON_SOCK" >/dev/null 2>&1 || true
}
sched_shots() {
    SHOT_PID=""
    (
        prev=0
        for item in "$@"; do
            at="${item%%:*}"; name="${item#*:}"
            sleep $((at - prev)); prev=$at
            shot "$name"
        done
    ) >/dev/null 2>&1 &
    SHOT_PID=$!
}
end_shots() {
    [ -n "${SHOT_PID:-}" ] && { kill "$SHOT_PID" 2>/dev/null; wait "$SHOT_PID" 2>/dev/null; }
    SHOT_PID=""
    return 0
}

# ---- qemu install (kept OUT of the build phase: disk pressure) ------------
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "installing qemu for boot tests"
  PAC=pacman-static
  command -v pacman-static >/dev/null 2>&1 || PAC=pacman
  # openssh: the purge phase strips the container to the build keep-closure —
  # ssh-keygen/ssh/scp are GONE by the time tests run. Without them the CI
  # control channel silently degrades (guest saw 'no bnasec.sshkey= on
  # cmdline', run 36266931861).
  $PAC -Sy --noconfirm --needed --overwrite '/usr/lib/libstdc++*' \
    qemu-desktop qemu-img edk2-ovmf socat python mesa virglrenderer openssh > /tmp/qemu-install.log 2>&1 \
    || { tail -20 /tmp/qemu-install.log; exit 1; }
fi

# ---- acceleration
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else ACCEL="tcg"; fi
echo "accel: $ACCEL"
if [ "$ACCEL" = "kvm" ]; then BOOT_WAIT=180; CMD_WAIT=25; HARD_WAIT=420; IT_WAIT=1800; else BOOT_WAIT=540; CMD_WAIT=45; HARD_WAIT=900; IT_WAIT=2700; fi
# IT_WAIT: interactive ssh phases (T2/T3) stay up as long as the script needs
# (run 36270352167: the serial-era 420s timeout killed qemu mid-T2 — every
# later check died with 'connection refused')

# ---- can this qemu do virgl GL? (egl-headless probe, 4s throwaway VM)
GPU_DEVICE=virtio-gpu-pci
timeout 4 qemu-system-x86_64 -machine q35 -m 128 -accel "$ACCEL" \
    -display egl-headless,gl=on -device virtio-vga-gl -monitor none > /tmp/gpu-probe.log 2>&1
if [ $? -eq 124 ]; then
    GPU_DEVICE=virtio-vga-gl
else
    echo "virtio-vga-gl probe failed ($(tail -1 /tmp/gpu-probe.log 2>/dev/null)), using virtio-gpu-pci"
fi
echo "gpu: $GPU_DEVICE"

PASS=0; FAILN=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAILN=$((FAILN+1)); echo "----- evidence for $1 -----"; tail -40 "$2" 2>/dev/null; }

Q() {  # base qemu invocation (arg1: hard timeout seconds, rest: extra args)
    local tmo="$1"; shift
    local mon="none" disp="-display none"
    [ -n "${MON_SOCK:-}" ] && mon="unix:$MON_SOCK,server,nowait"
    [ "$GPU_DEVICE" = virtio-vga-gl ] && disp="-display egl-headless,gl=on"
    timeout "$tmo" qemu-system-x86_64 -machine q35 -m 3072 -smp 2 \
        -accel "$ACCEL" $disp \
        -device "$GPU_DEVICE" \
        -monitor "$mon" \
        -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
        -no-reboot "$@"
}

# qemu 9/10 dropped the implicit USB controller on q35 — create one explicitly
DISK_ARGS=(-drive if=none,id=udisk,format=raw,file="$TESTS/usb.img"
           -device qemu-xhci,id=xhci
           -device usb-storage,bus=xhci.0,drive=udisk,removable=on)

# ---- SSH control channel ---------------------------------------------------
echo "generating CI ssh key for the guest control channel"
rm -f "$TESTS/testkey" "$TESTS/testkey.pub"
ssh-keygen -q -t ed25519 -N '' -C bnasec-ci -f "$TESTS/testkey" \
  || { echo "!! ssh-keygen failed — openssh missing from the test container?"; exit 1; }
[ -s "$TESTS/testkey.pub" ] || { echo "!! testkey.pub empty — cannot build the control channel"; exit 1; }
echo "ci key: $(cat "$TESTS/testkey.pub")"
SSH_PORT=2222
SSH_OPTS=(-i "$TESTS/testkey" -p "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)
# scp has DIFFERENT port-flag case (-P) and chokes on ssh's -p: build its own opts
SCP_OPTS=(-i "$TESTS/testkey" -P "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)
ssh_g() { ssh "${SSH_OPTS[@]}" bna@127.0.0.1 "$@" 2>&1; }
scp_g() { scp "${SCP_OPTS[@]}" "$@" 2>&1; }
# pubkey onto the kernel cmdline with %20 escapes (no shell quoting games)
SSHKEY_CMDLINE="$(sed 's/ /%20/g' "$TESTS/testkey.pub" | tr -d '\n')"

wait_ssh() { # arg1: timeout seconds
    local deadline=$((SECONDS + ${1:-120}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        ssh_g true >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

wait_verdict() { # poll for the session bootstrap verdict (arg1: timeout secs)
    local deadline=$((SECONDS + ${1:-150}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        ssh_g 'test -f ~/.cache/bnasec-session-verdict' >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

# hard-stop any qemu still holding the stick/port between phases — a lingering
# qemu would make the next phase's ssh silently land on the WRONG boot
stop_qemu() {
    pkill -f "qemu-system-x86_64.*$TESTS/usb.img" 2>/dev/null || true
    sleep 3
    pkill -9 -f "qemu-system-x86_64.*$TESTS/usb.img" 2>/dev/null || true
    sleep 2
    return 0
}

# in-guest desktop screenshot via grim (compositor's own framebuffer —
# independent of what QEMU's emulated GPU scans out). HARD-BOUNDED: every
# step has a timeout so a wedged renderer can never hang the phase again
# (run 36273739860: an unbounded grim burned 30 minutes of the T2 window).
# Fallback: create a headless output and capture THAT — it renders through
# the same compositor pipeline even when the real scanout is broken in VMs.
guest_grim() { # arg1: local file name for the png
    ssh_g 'export XDG_RUNTIME_DIR=/run/user/1000;
           WD=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -oE "^wayland-[0-9]+$" | head -1);
           echo "WAYLAND_DISPLAY=$WD";
           if [ -z "$WD" ]; then echo GRIM_NOWAYLAND; exit 0; fi
           export WAYLAND_DISPLAY="$WD";
           # hyprctl needs the instance signature of the RUNNING compositor:
           # without it every hyprctl call dies with "not set!" (run 36279981276)
           SIG=$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1);
           [ -z "$SIG" ] && SIG=$(ls "$HOME/.local/state/hypr" 2>/dev/null | head -1);
           [ -z "$SIG" ] && SIG=$(ls /tmp/hypr 2>/dev/null | head -1);
           echo "HYPRLAND_INSTANCE_SIGNATURE=$SIG";
           [ -n "$SIG" ] && export HYPRLAND_INSTANCE_SIGNATURE="$SIG";
           # the compositor IPC is busy right after the session verdict — retry
           # until 'monitors all' answers (run 36285890840: called 1s too early)
           ALL="";
           for t in 1 2 3 4 5 6 7 8; do
               ALL=$(timeout 8 hyprctl monitors all 2>/dev/null)
               echo "$ALL" | grep -q "^Monitor" && break
               echo "ipc retry $t (compositor busy)"; sleep 6
           done
           echo "== monitors (full) =="; echo "$ALL" | head -30;
           # ONE IPC parse from the same output; NO headless-output creation —
           # it wedges the compositor IPC thread (run 36283921325)
           MON1=$(echo "$ALL" | awk "/^Monitor/{print \\$2; exit}");
           echo "target monitor: ${MON1:-none}";
           if [ -n "$MON1" ]; then
               timeout 40 grim -o "$MON1" /tmp/bnasec-desktop.png 2>/tmp/grim-err.txt; echo GRIM_RC=$?;
           fi
           if [ ! -s /tmp/bnasec-desktop.png ] && [ -n "$MON1" ]; then
               timeout 40 hyprctl screenshot output "$MON1" --path /tmp/bnasec-desktop.png 2>>/tmp/grim-err.txt; echo HSHOT_RC=$?;
           fi
           ls -l /tmp/bnasec-desktop.png 2>/dev/null || echo NO_SHOT_FILE;
           if [ -s /tmp/bnasec-desktop.png ]; then echo GRIM_OK; else echo "GRIM_FAIL: $(cat /tmp/grim-err.txt 2>/dev/null | head -3)"; fi' \
        > /tmp/grim-diag.txt 2>&1
    cat /tmp/grim-diag.txt   # full diagnostics land in the CI step log
    grep -q "GRIM_OK" /tmp/grim-diag.txt || return 1
    scp_g bna@127.0.0.1:/tmp/bnasec-desktop.png "$SHOTS/$1" >/dev/null 2>&1
    [ -s "$SHOTS/$1" ]
}

# ---- kernel/initrd for direct-kernel boots (deterministic cmdline) ---------
echo "extracting kernel/initrd from ISO"
KERNEL="$TESTS/vmlinuz-linux"
INITRD="$TESTS/initramfs-linux.img"
bsdtar -xOf "$ISO" 'arch/boot/x86_64/vmlinuz-linux' > "$KERNEL" 2>/dev/null
bsdtar -xOf "$ISO" 'arch/boot/x86_64/initramfs-linux.img' > "$INITRD" 2>/dev/null
[ -s "$KERNEL" ] && [ -s "$INITRD" ] || { echo "kernel extraction failed"; bsdtar -tf "$ISO" 2>&1 | head; exit 1; }
echo "kernel $(du -h "$KERNEL" | cut -f1), initrd $(du -h "$INITRD" | cut -f1)"

# ---- the virtual stick: 16 GiB (worst case the user might own) -------------
make_stick() {
    rm -f "$TESTS/usb.img"
    qemu-img create -f raw "$TESTS/usb.img" 16G >/dev/null
    dd if="$ISO" of="$TESTS/usb.img" conv=notrunc bs=4M status=none
    sync
}

# cmdline used for every direct-kernel persistent boot (ssh control channel)
PERSIST_APPEND="archisobasedir=arch archisolabel=BNASEC300 cow_label=persistence bnasec.sshkey=$SSHKEY_CMDLINE console=ttyS0,115200n8 quiet loglevel=3"

# ===========================================================================
# T1: BIOS first boot from the dd'd stick — default persistent entry
# ===========================================================================
echo "== T1: BIOS first boot (persistent entry, root overlay on stick) =="
make_stick
MON_SOCK="$TESTS/qemu-mon.sock"; rm -f "$MON_SOCK"
sched_shots 4:t1-01-menu 9:t1-02-menu 25:t1-03-early $((BOOT_WAIT/2)):t1-04-mid \
  $((BOOT_WAIT-30)):t1-05-late $((BOOT_WAIT+5)):t1-06-ready \
  $((BOOT_WAIT+CMD_WAIT+10)):t1-07-probes $((BOOT_WAIT+CMD_WAIT+18)):t1-08-desktop \
  $((BOOT_WAIT+CMD_WAIT+30)):t1-09-desktop2
{ sleep "$BOOT_WAIT"; \
  echo "printf 'BNA_SHELL_READY_%s\\n' T1"; sleep "$CMD_WAIT"; \
  echo "printf 'BNA_ROOT_FSTYPE_%s\\n' \"\$(findmnt -n -o FSTYPE /)\""; sleep 6; \
  echo "printf 'BNA_COW_UPPER_%s\\n' \"\$(findmnt -n -o OPTIONS / | grep -oE 'upperdir=[^,]*' | head -1)\""; sleep 6; \
  echo "printf 'BNA_PERSIST_MNT_%s\\n' \"\$(findmnt -n -o FSTYPE /var/lib/bnasec-persist 2>/dev/null)\""; sleep 6; \
  echo "printf 'BNA_PERSIST_SVC_%s\\n' \"\$(systemctl is-active bnasec-persist 2>&1)\""; sleep 6; \
  echo "findmnt -n -o SOURCE /home/bna/.config 2>/dev/null | head -1"; sleep 5; \
  echo "printf 'BNA_SSHD_%s\\n' \"\$(systemctl is-active sshd 2>&1)\""; sleep 6; \
  echo "df -h /var/lib/bnasec-persist | tail -1"; sleep 4; \
  echo "echo bnasec | sudo -S poweroff --no-wall"; sleep "$CMD_WAIT"; } | Q "$HARD_WAIT" "${DISK_ARGS[@]}" \
    -serial stdio > "$TESTS/t1-serial.log" 2>&1
end_shots
grep -aq "no persistence partition found, creating one" "$TESTS/t1-serial.log" \
  && ok "T1a persistence partition auto-created on first boot" || bad "T1a auto-persist" "$TESTS/t1-serial.log"
grep -aq "bnasec: checking persistence filesystem" "$TESTS/t1-serial.log" \
  && ok "T1b persist fs checked (fsck ran)" || bad "T1b fsck" "$TESTS/t1-serial.log"
grep -aq "BNA_SHELL_READY_T1" "$TESTS/t1-serial.log" \
  && ok "T1c session reached (serial shell answering)" || bad "T1c session" "$TESTS/t1-serial.log"
grep -aq "BNA_ROOT_FSTYPE_overlay" "$TESTS/t1-serial.log" \
  && ok "T1d root is overlay filesystem" || bad "T1d overlay root" "$TESTS/t1-serial.log"
grep -aq "BNA_COW_UPPER_upperdir=/run/archiso/cowspace" "$TESTS/t1-serial.log" \
  && ok "T1e root overlay upperdir lives ON THE STICK (installs persist)" || bad "T1e cow upperdir" "$TESTS/t1-serial.log"
grep -aq "BNA_PERSIST_MNT_ext4" "$TESTS/t1-serial.log" \
  && ok "T1f persistence data partition mounted (ext4)" || bad "T1f persist mount" "$TESTS/t1-serial.log"
grep -aq "BNA_PERSIST_SVC_active" "$TESTS/t1-serial.log" \
  && ok "T1g selective persist service active" || bad "T1g persist service" "$TESTS/t1-serial.log"
grep -aq "\[/home/bna/.config\]" "$TESTS/t1-serial.log" \
  && ok "T1h .config bound from stick" || bad "T1h bind .config" "$TESTS/t1-serial.log"
grep -aq "BNA_SSHD_active" "$TESTS/t1-serial.log" \
  && ok "T1i sshd active (key-only, no keys = closed)" || bad "T1i sshd" "$TESTS/t1-serial.log"
grep -aq "bnasec-fixmodes: PASS" "$TESTS/t1-serial.log" \
  && ok "T1j autostart exec bits restored" || bad "T1j fixmodes" "$TESTS/t1-serial.log"
# v3.0.0: guest installs need a writable+populated pacman keyring through the
# live overlay (run 36279981276: 'keyring is not writable' killed installs)
grep -aq "bnasec-fixmodes: KEYRING OK" "$TESTS/t1-serial.log" \
  && ok "T1k pacman keyring writable + populated (installs possible)" || bad "T1k keyring" "$TESTS/t1-serial.log"

# ===========================================================================
# T2: second boot on the SAME stick — SSH control channel, env + session
# ===========================================================================
echo "== T2: SSH-driven environment + session checks (same stick, boot 2) =="
MON_SOCK="$TESTS/qemu-mon.sock"; rm -f "$MON_SOCK"
sched_shots 25:t2-01-early $((BOOT_WAIT/2)):t2-02-mid $((BOOT_WAIT+60)):t2-03-late
Q "$IT_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t2-serial.log" 2>&1 < /dev/null &
QPID=$!
if wait_ssh 420; then
    ok "T2a ssh control channel reachable (key injected via cmdline)"
    # the session needs its own bootstrap time; poll for the verdict file
    wait_verdict 240 || echo "WARN: session verdict still absent after 240s"
    # CURRENT boot's verdict only — the persisted ~/.config copy could be a
    # previous boot's leftover
    VERDICT=$(ssh_g 'cat ~/.cache/bnasec-session-verdict 2>/dev/null; echo "(persisted: $(cat ~/.config/bnasec/verdict 2>/dev/null | head -1))"')
    echo "session verdict (this boot): $VERDICT" | tee "$TESTS/t2-verdict.txt"
    # exact match: BAR=quickshell must NOT substring-match BAR=quickshell-software
    echo "$VERDICT" | grep -E "BAR=quickshell( |$)" >/dev/null \
      && ok "T2b session verdict: BAR=quickshell (the real ML4W bar is UP)" \
      || { echo "$VERDICT" | grep -qE "BAR=(quickshell-software|waybar)" \
           && ok "T2b session verdict: fallback bar up ($(echo "$VERDICT" | grep -oE 'BAR=[a-z-]*' | head -1)) — quickshell failed, INVESTIGATE" \
           || bad "T2b session verdict" "$TESTS/t2-verdict.txt"; }
    HYPN=$(ssh_g 'pgrep -c Hyprland' | tail -1)
    [ "${HYPN:-0}" -ge 1 ] 2>/dev/null && ok "T2c Hyprland compositor alive" || bad "T2c Hyprland" "$TESTS/t2-serial.log"
    # deep guest render diagnostics: why the VGA scanout may be black in the VM
    DIAG=$(ssh_g 'echo "== /dev/dri =="; ls -l /dev/dri 2>&1 | head -6; echo "== Hyprland env =="; tr "\000" "\012" < /proc/$(pgrep -o Hyprland)/environ 2>/dev/null | grep -E "AQ_|LIBGL|WLR" | sort; echo "== hyprland.log tail =="; tail -20 /tmp/hypr/*/hyprland.log 2>/dev/null | grep -aiE "backend|egl|gl|drm|output|swrast|llvmpipe|error" | head -15; echo "== mem =="; free -h | head -2' )
    echo "$DIAG" | tee "$TESTS/t2-guest-diag.txt"
    QSN=$(ssh_g 'pgrep -cx qs' | tail -1)
    echo "quickshell procs: $QSN"
    if guest_grim t2-04-desktop-grim.png; then
        SZ=$(stat -c%s "$SHOTS/t2-04-desktop-grim.png")
        [ "$SZ" -gt 20000 ] && ok "T2d desktop screenshot captured via grim ($SZ bytes)" \
            || bad "T2d grim screenshot suspiciously small ($SZ)" "$TESTS/t2-serial.log"
    else
        bad "T2d grim screenshot" "$TESTS/t2-serial.log"
    fi
    # non-interactive probe (zsh -ic prints the ohmyposh prompt into stdout,
    # which poisoned the grep in rounds 3-4): source omz directly with -f
    OMZ=$(ssh_g 'zsh -f -c "export ZSH=\$HOME/.config/ohmyzsh; source \$ZSH/oh-my-zsh.sh >/dev/null 2>&1 && echo OMZ_LOADED"' | grep -c OMZ_LOADED)
    [ "${OMZ:-0}" -ge 1 ] 2>/dev/null \
      && ok "T2e oh-my-zsh sources cleanly from the stick" || bad "T2e oh-my-zsh" "$TESTS/t2-serial.log"
    ssh_g 'command -v eza && command -v fzf' | grep -q "/eza" \
      && ok "T2f eza + fzf installed" || bad "T2f eza/fzf" "$TESTS/t2-serial.log"
    EZA_LS=$(ssh_g 'zsh -ic "ls ~ >/dev/null 2>&1 && echo LS_OK"' | grep -c LS_OK)
    [ "$EZA_LS" -ge 1 ] && ok "T2g interactive zsh ls works (eza chain intact)" || bad "T2g zsh ls" "$TESTS/t2-serial.log"
    ssh_g 'command -v kitty && command -v firefox' | grep -q "/kitty" \
      && ok "T2h kitty + firefox installed" || bad "T2h kitty/firefox" "$TESTS/t2-serial.log"
    # network: retry a couple of times — NM may still be settling its DHCP lease
    NET=""; for t in 1 2 3; do
        NET=$(ssh_g 'curl -sI --max-time 15 https://archlinux.org | head -1')
        echo "$NET" | grep -q "HTTP" && break
        sleep 10
    done
    IP4=$(ssh_g 'ip -4 -o addr show | grep -v 127.0.0.1 | head -1')
    echo "guest net: $NET | $IP4"
    echo "$NET" | grep -q "HTTP" \
      && ok "T2i network up ($NET)" || bad "T2i network ($NET / $IP4)" "$TESTS/t2-serial.log"
    AUD=$(ssh_g 'systemctl --user is-active pipewire.socket wireplumber 2>&1' | tr '\n' ' ')
    echo "$AUD" | grep -q "active active" \
      && ok "T2j audio stack up (pipewire.socket + wireplumber)" || bad "T2j audio ($AUD)" "$TESTS/t2-serial.log"
    # persist-bind verdict from THIS boot (findmnt takes ONE mountpoint per call)
    BNDS=$(ssh_g 'findmnt -n -o SOURCE /home/bna/.config 2>/dev/null; findmnt -n -o SOURCE /home/bna/Documents 2>/dev/null' | grep -c "bna")
    [ "$(echo "$BNDS" | tail -1)" -ge 2 ] 2>/dev/null \
      && ok "T2k .config and Documents binds active in live session" || bad "T2k binds ($BNDS)" "$TESTS/t2-serial.log"
else
    bad "T2a ssh control channel reachable" "$TESTS/t2-serial.log"
fi
stop_qemu
end_shots

# ===========================================================================
# T3: heavy persistence grand tour (same stick, boots 3 + 4)
# ===========================================================================
echo "== T3a: heavy write boot — space check, LibreOffice install, 1GB file =="
MON_SOCK="$TESTS/qemu-mon.sock"; rm -f "$MON_SOCK"
Q "$IT_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t3a-serial.log" 2>&1 < /dev/null &
QPID=$!
if wait_ssh 420; then
    ok "T3a-1 boot 3 reached over ssh"
    SPACE_BEFORE=$(ssh_g 'df -k /var/lib/bnasec-persist | tail -1 | awk "{print \$4}"' | tail -1)
    echo "T3 space before: ${SPACE_BEFORE}KB" | tee -a "$TESTS/t3-space.log"
    [ -n "$SPACE_BEFORE" ] && [ "$SPACE_BEFORE" -gt 0 ] 2>/dev/null \
      && ok "T3a-2 space check before: ${SPACE_BEFORE}KB free on persistence partition" \
      || bad "T3a-2 space before" "$TESTS/t2-serial.log"
    ssh_g 'printf "BNA_MARK_CFG_%s\n" 300 > ~/.config/bnasec-proof && printf "BNA_MARK_DOC_%s\n" 300 > ~/Documents/bnasec-proof && echo MARKS_OK' | grep -q MARKS_OK \
      && ok "T3a-3 markers written (.config + Documents)" || bad "T3a-3 markers" "$TESTS/t3a-serial.log"
    echo "-- keyring bootstrap: the stale snapshot trust db cannot even verify the NEW keyring packages (chicken-and-egg, run 36283921325) — one SigLevel=Never transaction for the two keyring packages only, then re-populate, then the real install --"
    ssh_g 'sudo cp /etc/pacman.conf /tmp/pacman.conf.nosig \
           && sudo sed -i "s/^SigLevel.*/SigLevel    = Never/" /tmp/pacman.conf.nosig \
           && sudo pacman --config /tmp/pacman.conf.nosig -Sy --noconfirm archlinux-keyring chaotic-keyring >/tmp/t3-install.log 2>&1 \
           && sudo pacman-key --populate archlinux chaotic >>/tmp/t3-install.log 2>&1 \
           && sudo pacman -Syu --noconfirm --needed libreoffice-fresh >>/tmp/t3-install.log 2>&1; \
           echo INSTALL_RC=$?; tail -4 /tmp/t3-install.log' \
        | tee "$TESTS/t3-install-tail.txt" | grep -q "INSTALL_RC=0" \
      && ok "T3a-4 libreoffice-fresh installed into the persistent root" \
      || bad "T3a-4 libreoffice install (see t3-install-tail.txt)" "$TESTS/t3-install-tail.txt"
    scp_g bna@127.0.0.1:/tmp/t3-install.log "$TESTS/t3-install.log" >/dev/null 2>&1 || true
    tail -6 "$TESTS/t3-install.log" 2>/dev/null || true
    PKGQ=$(ssh_g 'pacman -Q libreoffice-fresh 2>&1' | tail -1)
    echo "$PKGQ" | grep -qE '^libreoffice-fresh [0-9]' \
      && ok "T3a-4b pacman -Q confirms install ($PKGQ)" \
      || bad "T3a-4b pacman -Q ($PKGQ)" "$TESTS/t3a-serial.log"
    SOF=$(ssh_g 'soffice --version 2>/dev/null | head -1')
    echo "soffice: $SOF"
    echo "$SOF" | grep -qi "libreoffice" \
      && ok "T3a-5 soffice runs: $SOF" || bad "T3a-5 soffice --version ($SOF)" "$TESTS/t3a-serial.log"
    echo "-- writing 1 GB file into ~/Documents (persistence partition) --"
    SUM1=$(ssh_g 'dd if=/dev/urandom of="$HOME/Documents/bnasec-1gb.bin" bs=1M count=1024 status=none; echo DD_RC=$?; sha256sum "$HOME/Documents/bnasec-1gb.bin" 2>&1' | tee "$TESTS/t3-dd.txt" | tail -1 | awk '{print $1}')
    grep -q "DD_RC=0" "$TESTS/t3-dd.txt" && echo "$SUM1" | grep -qE '^[0-9a-f]{64}$' \
      && ok "T3a-6 1GB file written, sha256=$SUM1" || bad "T3a-6 1GB write" "$TESTS/t3-dd.txt"
    SPACE_AFTER=$(ssh_g 'df -k /var/lib/bnasec-persist | tail -1 | awk "{print \$4}"' | tail -1)
    echo "T3 space after: ${SPACE_AFTER}KB" | tee -a "$TESTS/t3-space.log"
    if [ -n "$SPACE_BEFORE" ] && [ -n "$SPACE_AFTER" ]; then
        [ "$SPACE_AFTER" -lt "$SPACE_BEFORE" ] 2>/dev/null \
          && ok "T3a-7 space shrank after heavy writes ($(( (SPACE_BEFORE-SPACE_AFTER)/1024 ))MB consumed)" \
          || bad "T3a-7 space delta" "$TESTS/t3-space.log"
    else
        bad "T3a-7 space readings" "$TESTS/t3-space.log"
    fi
    # manifest INTO the persisted .config so boot 4 can compare against it
    if echo "$SUM1" | grep -qE '^[0-9a-f]{64}$'; then
        PKGSTR=$(ssh_g 'pacman -Q libreoffice-fresh 2>/dev/null' | tail -1)
        ssh_g "printf 'sha256=%s\npkg=%s\nspace_before_kb=%s\nspace_after_kb=%s\n' '$SUM1' '$PKGSTR' '$SPACE_BEFORE' '$SPACE_AFTER' > ~/.config/bnasec-t3-manifest" \
          && ok "T3a-8 manifest written to persisted .config"
    else
        echo "WARN: manifest skipped — 1GB write did not succeed"
    fi
    guest_grim t3a-09-desktop-grim.png && echo "T3a grim shot ok" || echo "T3a grim shot failed (non-fatal)"
    ssh_g 'sudo systemctl reboot' >/dev/null 2>&1 || true
    # -no-reboot makes qemu EXIT on guest reboot; wait for the port to free
    sleep 25
else
    bad "T3a-1 boot 3 reached over ssh" "$TESTS/t3a-serial.log"
fi
stop_qemu

echo "== T3b: verify EVERYTHING survived the reboot (boot 4) =="
MON_SOCK="$TESTS/qemu-mon.sock"; rm -f "$MON_SOCK"
Q "$IT_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t3b-serial.log" 2>&1 < /dev/null &
QPID=$!
if wait_ssh 420; then
    ok "T3b-1 boot 4 reached over ssh (stick re-booted cleanly)"
    ssh_g 'cat ~/.config/bnasec-proof' | grep -q "BNA_MARK_CFG_300" \
      && ok "T3b-2 .config marker survived reboot" || bad "T3b-2 config marker" "$TESTS/t2-serial.log"
    ssh_g 'cat ~/Documents/bnasec-proof' | grep -q "BNA_MARK_DOC_300" \
      && ok "T3b-3 Documents marker survived reboot" || bad "T3b-3 docs marker" "$TESTS/t2-serial.log"
    PKG=$(ssh_g 'pacman -Q libreoffice-fresh 2>&1' | tail -1)
    echo "$PKG" | grep -qE '^libreoffice-fresh [0-9]' \
      && ok "T3b-4 libreoffice-fresh STILL INSTALLED after reboot — PACKAGES PERSIST ($PKG)" \
      || bad "T3b-4 package persistence ($PKG)" "$TESTS/t3b-serial.log"
    SOF2=$(ssh_g 'soffice --version 2>/dev/null | head -1')
    echo "$SOF2" | grep -qi "libreoffice" \
      && ok "T3b-5 soffice still executes after reboot" || bad "T3b-5 soffice" "$TESTS/t2-serial.log"
    MAN=$(ssh_g 'cat ~/.config/bnasec-t3-manifest 2>/dev/null' | grep -oE 'sha256=[0-9a-f]{64}' | cut -d= -f2)
    SUM2=$(ssh_g 'sha256sum "$HOME/Documents/bnasec-1gb.bin" 2>/dev/null | awk "{print \$1}"' | tail -1)
    echo "manifest=$MAN"; echo "file    =$SUM2"
    if [ -n "$MAN" ] && [ "$MAN" = "$SUM2" ]; then
        ok "T3b-6 1GB file byte-identical after reboot — DATA INTEGRITY PROVEN"
    else
        bad "T3b-6 sha256 mismatch (manifest=$MAN file=$SUM2)" "$TESTS/t2-serial.log"
    fi
    SPACE_REBOOT=$(ssh_g 'df -k /var/lib/bnasec-persist | tail -1 | awk "{print \$4}"' | tail -1)
    echo "T3 space after reboot: ${SPACE_REBOOT}KB" | tee -a "$TESTS/t3-space.log"
    [ -n "$SPACE_REBOOT" ] && [ "$SPACE_REBOOT" -gt 0 ] 2>/dev/null \
      && ok "T3b-7 space check after reboot: ${SPACE_REBOOT}KB free" || bad "T3b-7 space" "$TESTS/t2-serial.log"
    VERDICT2=$(ssh_g 'cat ~/.cache/bnasec-session-verdict 2>/dev/null' | head -1)
    echo "boot-4 verdict: $VERDICT2" | tee "$TESTS/t3b-verdict.txt"
    guest_grim t3b-08-desktop-grim.png && echo "T3b grim shot ok" || echo "T3b grim shot failed (non-fatal)"
    ssh_g 'sudo systemctl poweroff --no-wall' >/dev/null 2>&1 || true
    sleep 15
else
    bad "T3b-1 boot 4 reached over ssh" "$TESTS/t3b-serial.log"
fi
stop_qemu
end_shots

# ===========================================================================
# T4: RAM-only volatile session on a FRESH stick
# ===========================================================================
echo "== T4: RAM-only session =="
make_stick
sched_shots 25:t4-01-early $((BOOT_WAIT/2)):t4-02-mid $((BOOT_WAIT+10)):t4-03-session
{ sleep "$BOOT_WAIT"; echo "printf 'BNA_T4_VOLATILE_%s\\n' ok"; sleep "$CMD_WAIT"; \
  echo "printf 'BNA_T4_NOTMOUNTED_%s\\n' \"\$(findmnt -n -o FSTYPE /var/lib/bnasec-persist 2>/dev/null)\""; sleep 6; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" \
    -append "archisobasedir=arch archisolabel=BNASEC300 bnasec_nopersist console=ttyS0,115200n8 quiet loglevel=3" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t4-serial.log" 2>&1
end_shots
grep -aq "BNA_T4_VOLATILE_ok" "$TESTS/t4-serial.log" \
  && ok "T4a volatile session boots" || bad "T4a volatile" "$TESTS/t4-serial.log"
grep -aq "bnasec: RAM-only session — persistence partition untouched" "$TESTS/t4-serial.log" \
  && ok "T4b stick untouched in RAM-only mode" || bad "T4b RAM-only flag" "$TESTS/t4-serial.log"
grep -aq "bnasec: persistence unavailable" "$TESTS/t4-serial.log" \
  && bad "T4c fell back unexpectedly" "$TESTS/t4-serial.log" || ok "T4c no persistence requested (correct)"

# ===========================================================================
# T5: UEFI via OVMF on a fresh stick
# ===========================================================================
echo "== T5: UEFI boot =="
OVMF_CODE=$(find /usr/share/edk2 -name 'OVMF_CODE.4m.fd' 2>/dev/null | head -1)
if [ -z "$OVMF_CODE" ]; then OVMF_CODE=$(find /usr/share/ovmf /usr/share/edk2* -name 'OVMF_CODE*.fd' 2>/dev/null | head -1); fi
if [ -n "$OVMF_CODE" ]; then
  OVMF_VARS_SRC=$(find /usr/share/edk2 /usr/share/ovmf -name 'OVMF_VARS.4m.fd' -o -name 'OVMF_VARS.fd' 2>/dev/null | head -1)
  cp -f "$OVMF_VARS_SRC" "$TESTS/ovmf-vars.fd"
  make_stick
  sched_shots 15:t5-01-ovmf 60:t5-02-menu $((BOOT_WAIT/2)):t5-03-mid $((BOOT_WAIT+15)):t5-04-session
  { sleep "$BOOT_WAIT"; echo "printf 'BNA_T5_UEFI_READY_%s\\n' ok"; sleep "$CMD_WAIT"; \
    echo "echo bnasec | sudo -S poweroff --no-wall"; sleep "$CMD_WAIT"; } | Q "$HARD_WAIT" "${DISK_ARGS[@]}" \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$TESTS/ovmf-vars.fd" \
      -serial stdio > "$TESTS/t5-serial.log" 2>&1
  end_shots
  grep -aq "BNA_T5_UEFI_READY_ok" "$TESTS/t5-serial.log" \
    && ok "T5 UEFI session reached (serial shell answering)" || bad "T5 UEFI" "$TESTS/t5-serial.log"
else
  echo "SKIP  T5 (no OVMF firmware found)"
fi

# ---- convert monitor screenshots ppm -> png --------------------------------
if command -v python3 >/dev/null 2>&1 && compgen -G "$SHOTS/*.ppm" >/dev/null; then
    python3 "$SCRIPT_DIR/ppm2png.py" "$SHOTS"/*.ppm || true
    rm -f "$SHOTS"/*.ppm
fi
echo "screenshots captured: $(ls "$SHOTS" 2>/dev/null | wc -l)"
ls -la "$SHOTS" 2>/dev/null | tail -n +2

echo "== summary: $PASS passed, $FAILN failed =="
[ "$FAILN" = 0 ]
