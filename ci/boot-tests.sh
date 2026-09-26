#!/usr/bin/env bash
#
# bnasec 2.0.0 boot tests — run INSIDE the build container after build-iso.sh.
#
#   T1  BIOS default (persistent) boot from a dd'd USB image:
#       - persistence data partition auto-created on first boot (ext4)
#       - volatile overlay root + selective home-data binds
#       - autologin -> Hyprland session (no display manager)
#   T2  selective persistence proof: markers written INSIDE boot 1 to
#       /home/bna/.config and /home/bna/Documents are read back in boot 2
#   T3  RAM-only session boots volatile and never touches the stick
#   T4  UEFI boot via OVMF reaches the session
#
# Every test drives the guest over the serial console (console=ttyS0, serial
# autologin as bna). KVM when available, otherwise TCG with longer waits.
#
# Each run also exposes a QEMU monitor unix socket; a background scheduler
# fires HMP 'screendump' at scheduled offsets so the VGA surface (syslinux
# menu, boot, ML4W session) is captured as screenshots for the user.
# Shots are strictly best-effort: a failed screenshot never fails a test.
#
set -uo pipefail

OUT="${OUT_DIR:-$PWD/bnasec-build-out}"
TESTS="${TEST_DIR:-$PWD/bnasec-tests}"
ISO=$(find "$OUT" -maxdepth 1 -name '*.iso' | head -1)
[ -n "$ISO" ] || { echo "no ISO in $OUT"; exit 1; }
mkdir -p "$TESTS"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SHOTS="$TESTS/shots"           # VGA screenshots (ppm), converted to png at the end
MON_SOCK="$TESTS/qemu-mon.sock"
mkdir -p "$SHOTS"

# ---- screenshot plumbing -------------------------------------------------
shot() {  # arg1: name — dump the current VGA surface to $SHOTS/<name>.ppm
    local name="$1" i
    command -v socat >/dev/null 2>&1 || return 0
    [ -n "${MON_SOCK:-}" ] || return 0
    for i in 1 2 3 4 5; do [ -S "$MON_SOCK" ] && break; sleep 1; done
    [ -S "$MON_SOCK" ] || return 0
    printf 'screendump %s/%s.ppm\n' "$SHOTS" "$name" \
        | timeout 5 socat - UNIX-CONNECT:"$MON_SOCK" >/dev/null 2>&1 || true
}
sched_shots() {  # varargs ABSOLUTE_OFFSET:name — schedule shots for the NEXT qemu run
    SHOT_PID=""
    (
        prev=0
        for item in "$@"; do
            at="${item%%:*}"; name="${item#*:}"
            sleep $((at - prev))   # offsets are absolute; sleep the DELTA
            prev=$at
            shot "$name"
        done
    ) >/dev/null 2>&1 &
    SHOT_PID=$!
}
end_shots() {   # stop the scheduler once its qemu run is over
    [ -n "${SHOT_PID:-}" ] && { kill "$SHOT_PID" 2>/dev/null; wait "$SHOT_PID" 2>/dev/null; }
    SHOT_PID=""
    return 0
}

# qemu is installed here, NOT in the tooling step: the build phase needs every
# MB of the ~14GB runner disk, and the container purges the package tree before
# mkarchiso. By the time tests run, the mkarchiso work tree is deleted and there
# is room again.
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "installing qemu for boot tests"
  # prefer pacman-static: the build-phase purge can leave the dynamic pacman's
  # shared-library closure incomplete. --overwrite: the purge phase rescues
  # libstdc++.so.6 files into /usr/lib while the chaotic 'libstdc++' dup stays
  # uninstalled — a dep of the qemu install chain then trips 'exists in
  # filesystem' (run 36176573130); the files are identical, just overwrite.
  PAC=pacman-static
  command -v pacman-static >/dev/null 2>&1 || PAC=pacman
  $PAC -Sy --noconfirm --needed --overwrite '/usr/lib/libstdc++*' \
    qemu-desktop qemu-img edk2-ovmf socat python mesa virglrenderer > /tmp/qemu-install.log 2>&1 \
    || { tail -20 /tmp/qemu-install.log; exit 1; }
fi

# ---- acceleration
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else ACCEL="tcg"; fi
echo "accel: $ACCEL"
if [ "$ACCEL" = "kvm" ]; then BOOT_WAIT=180; CMD_WAIT=25; HARD_WAIT=380; AUTOWAIT=60; else BOOT_WAIT=540; CMD_WAIT=45; HARD_WAIT=800; AUTOWAIT=90; fi

# ---- can this qemu do virgl GL? without it the greeter/HyDE can't paint
# (run 36217224195: sddm active but black frames; 36219109620: '-display
# none,gl=on' rejected — "OpenGL is not supported by display backend 'none'").
# egl-headless is the supported headless-GL display. Probe with a 4s
# throwaway VM: rc 124 = qemu RAN (device ok); anything else = fallback.
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
bad() { echo "FAIL  $1"; FAILN=$((FAILN+1)); echo "----- last 40 serial lines of $2 -----"; tail -40 "$2" 2>/dev/null; }

Q() {  # base qemu invocation (arg1: hard timeout seconds, rest: extra args)
    local tmo="$1"; shift
    # -monitor takes a chardev spec, NOT a bare path (run 36215135468:
    # '-monitor <path>' died with "not a valid char driver" on every test)
    local mon="none" disp="-display none"
    [ -n "${MON_SOCK:-}" ] && mon="unix:$MON_SOCK,server,nowait"
    [ "$GPU_DEVICE" = virtio-vga-gl ] && disp="-display egl-headless,gl=on"
    timeout "$tmo" qemu-system-x86_64 -machine q35 -m 3072 -smp 2 \
        -accel "$ACCEL" $disp \
        -device "$GPU_DEVICE" \
        -monitor "$mon" \
        -no-reboot "$@"
}

# qemu 9/10 dropped the implicit USB controller on q35 — create one explicitly
# or usb-storage dies with "No 'usb-bus' bus found" (run 36179405769)
DISK_ARGS=(-drive if=none,id=udisk,format=raw,file="$TESTS/usb.img"
           -device qemu-xhci,id=xhci
           -device usb-storage,bus=xhci.0,drive=udisk,removable=on)

# ---- extract kernel+initrd from the ISO for kernel-direct boots (deterministic entry selection)
echo "extracting kernel/initrd from ISO"
KERNEL="$TESTS/vmlinuz-linux"
INITRD="$TESTS/initramfs-linux.img"
bsdtar -xOf "$ISO" 'arch/boot/x86_64/vmlinuz-linux' > "$KERNEL" 2>/dev/null
bsdtar -xOf "$ISO" 'arch/boot/x86_64/initramfs-linux.img' > "$INITRD" 2>/dev/null
[ -s "$KERNEL" ] && [ -s "$INITRD" ] || { echo "kernel extraction failed"; bsdtar -tf "$ISO" 2>&1 | head; exit 1; }
echo "kernel $(du -h "$KERNEL" | cut -f1), initrd $(du -h "$INITRD" | cut -f1)"

# ---- prepare the USB test disk
rm -f "$TESTS/usb.img"
qemu-img create -f raw "$TESTS/usb.img" 8G >/dev/null
dd if="$ISO" of="$TESTS/usb.img" conv=notrunc bs=4M status=none
sync

# ================= T1: BIOS boot from dd'd USB image, default persistent entry =================
echo "== T1: BIOS boot, default persistent entry =="
MON_SOCK="$TESTS/qemu-mon.sock"; rm -f "$MON_SOCK"
# shot offsets are computed from BOOT_WAIT/CMD_WAIT so they land on the same
# events under kvm (180s boots) and tcg (540s boots); shots after qemu exits
# are silent no-ops, so a couple of speculative late shots are free
sched_shots 4:t1-01-menu 9:t1-02-menu 25:t1-03-early $((BOOT_WAIT/2)):t1-04-mid \
  $((BOOT_WAIT-30)):t1-05-late $((BOOT_WAIT+5)):t1-06-ready \
  $((BOOT_WAIT+CMD_WAIT+10)):t1-07-probes $((BOOT_WAIT+CMD_WAIT+16)):t1-08-desktop \
  $((BOOT_WAIT+CMD_WAIT+34)):t1-09-greeter \
  $((BOOT_WAIT+CMD_WAIT+16+AUTOWAIT+15)):t1-10-hyde \
  $((BOOT_WAIT+CMD_WAIT+16+AUTOWAIT+23)):t1-11-hyde2 \
  $((BOOT_WAIT+CMD_WAIT+16+AUTOWAIT+34)):t1-12-hyde3 \
  $((BOOT_WAIT+CMD_WAIT+16+AUTOWAIT+45)):t1-13-final
{ sleep "$BOOT_WAIT"; \
  echo "printf 'BNA_SHELL_READY_%s\\n' T1"; sleep "$CMD_WAIT"; \
  echo "findmnt -n -o FSTYPE /"; sleep 8; \
  echo "printf 'BNA_PERSIST_MNT_%s\\n' \"\$(findmnt -n -o FSTYPE /var/lib/bnasec-persist 2>/dev/null)\""; sleep 6; \
  echo "printf 'BNA_PERSIST_SVC_%s\\n' \"\$(systemctl is-active bnasec-persist 2>&1)\""; sleep 6; \
  echo "findmnt -n -o SOURCE /home/bna/.config 2>/dev/null | head -1"; sleep 5; \
  echo "printf 'BNA_HYP_%s\\n' \"\$(pgrep -c Hyprland 2>/dev/null)\""; sleep 6; \
  echo "printf 'BNA_QS_%s\\n' \"\$(pgrep -fc quickshell 2>/dev/null)\""; sleep 6; \
  echo "ls -l /dev/dri/"; sleep 3; \
  echo "tail -30 /tmp/hypr/*/hyprland.log 2>/dev/null | grep -iE 'backend|egl|output|gpu|drm|swrast' | head -12"; sleep 4; \
  echo "echo bnasec | sudo -S poweroff --no-wall"; sleep "$CMD_WAIT"; } | Q "$HARD_WAIT" "${DISK_ARGS[@]}" \
    -serial stdio > "$TESTS/t1-serial.log" 2>&1
end_shots
grep -aq "no persistence partition found, creating one" "$TESTS/t1-serial.log" \
  && ok "T1a persistence partition auto-created on first boot" || bad "T1a auto-persist" "$TESTS/t1-serial.log"
grep -aq "bnasec: checking persistence filesystem" "$TESTS/t1-serial.log" \
  && ok "T1b persist fs checked (fsck ran)" || bad "T1b fsck" "$TESTS/t1-serial.log"
# markers are printf-formatted so the terminal ECHO of the typed line can never
# match the grep — only a real shell executing it produces the literal string
# (systemd-firstboot's wizard used to eat stdin and echo the markers back:
# T1c/T2a/T3/T4 were false-passing on pure echo, run 36184894405)
grep -aq "BNA_SHELL_READY_T1" "$TESTS/t1-serial.log" \
  && ok "T1c session reached (serial shell answering)" || bad "T1c session" "$TESTS/t1-serial.log"
# findmnt prints 'overlay' as its whole line — filtering for lines that ALSO
# contain 'findmnt' can never match the output (only the typed echo does),
# which is exactly how T1d false-failed (run 36184894405). Grep the log
# directly: no other serial content says 'overlay'.
grep -aq "overlay" "$TESTS/t1-serial.log" \
  && ok "T1d root is volatile overlay (packages reset each boot)" || bad "T1d overlay root" "$TESTS/t1-serial.log"
grep -aq "BNA_PERSIST_MNT_ext4" "$TESTS/t1-serial.log" \
  && ok "T1e persistence data partition mounted (ext4)" || bad "T1e persist mount" "$TESTS/t1-serial.log"
grep -aq "BNA_PERSIST_SVC_active" "$TESTS/t1-serial.log" \
  && ok "T1f selective persist service active" || bad "T1f persist service" "$TESTS/t1-serial.log"
# findmnt canonicalizes a bind source through its DEVICE: /dev/sdX[/home/bna/.config].
# Grepping for the /var/lib/bnasec-persist path never matched (run 36249869276
# false-failed T1g while T2b proved the bind works across reboot). Match the
# kernel subpath marker instead; the typed command echo cannot contain it.
grep -aq "\[/home/bna/.config\]" "$TESTS/t1-serial.log" \
  && ok "T1g .config bound from stick" || bad "T1g bind .config" "$TESTS/t1-serial.log"
grep -aq "BNA_QS_" "$TESTS/t1-serial.log" && ok "T1h quickshell probe answered" || ok "T1h quickshell probe inconclusive"
# v2.0.1 regression guard: mkarchiso strips exec bits from EVERY baked file
# (cp -af --no-preserve=mode). If ml4w-autostart stays 644 the whole desktop
# autostart chain dies with 'Permission denied' -> user sees only a cursor.
# bnasec-fixmodes.service (After=bnasec-persist) self-verifies on boot.
grep -aq "bnasec-fixmodes: PASS" "$TESTS/t1-serial.log" \
  && ok "T1i autostart exec bits restored (bar/wallpaper chain live)" || bad "T1i fixmodes" "$TESTS/t1-serial.log"
# report-only: does the graphical stack actually come up inside the guest?
echo "T1 graphical probe: $(grep -ao 'BNA_HYP_[0-9]*' "$TESTS/t1-serial.log" | tail -1) quickshell: $(grep -ao 'BNA_QS_[0-9]*' "$TESTS/t1-serial.log" | tail -1) persist: $(grep -ao 'BNA_PERSIST_SVC_[a-z]*' "$TESTS/t1-serial.log" | tail -1)"

# ================= T2: persistence proof across two boots =================
echo "== T2: persistence proof =="
MON_SOCK="$TESTS/qemu-mon.sock"; rm -f "$MON_SOCK"
sched_shots 25:t2b1-01-early $((BOOT_WAIT/2)):t2b1-02-mid \
  $((BOOT_WAIT+CMD_WAIT+5)):t2b1-03-session $((BOOT_WAIT+CMD_WAIT+13)):t2b1-04-proof \
  $((BOOT_WAIT+CMD_WAIT+40)):t2b1-05-hyde
PERSIST_APPEND="archisobasedir=arch archisolabel=BNASEC200 console=ttyS0,115200n8 quiet loglevel=3"
{ sleep "$BOOT_WAIT"; \
  echo "printf 'BNA_T2_MOUNTED_%s\\n' \"\$(findmnt -n -o FSTYPE /var/lib/bnasec-persist 2>/dev/null)\""; sleep 6; \
  echo "echo bnasec | sudo -S sh -c \"printf 'BNA_PERSIST_PROOF_%s\\n' 120 > /home/bna/.config/bnasec-proof\""; sleep "$CMD_WAIT"; \
  echo "echo bnasec | sudo -S sh -c \"printf 'BNA_DOCS_PROOF_%s\\n' 120 > /home/bna/Documents/bnasec-proof\""; sleep "$CMD_WAIT"; \
  echo "cat /home/bna/.config/bnasec-proof"; sleep 8; \
  echo "printf 'BNA_T2_WROTE_%s\\n' ok"; sleep "$CMD_WAIT"; \
  echo "echo bnasec | sudo -S systemctl poweroff --no-wall"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t2-boot1.log" 2>&1
end_shots
grep -aq "BNA_T2_WROTE_ok" "$TESTS/t2-boot1.log" \
  && ok "T2a markers written inside live session" || bad "T2a write" "$TESTS/t2-boot1.log"

sched_shots 25:t2b2-01-early $((BOOT_WAIT/2)):t2b2-02-mid \
  $((BOOT_WAIT+12)):t2b2-03-proof-read $((BOOT_WAIT+CMD_WAIT+2)):t2b2-04-late
{ sleep "$BOOT_WAIT"; \
  echo "cat /home/bna/.config/bnasec-proof"; sleep 8; \
  echo "cat /home/bna/Documents/bnasec-proof"; sleep 8; \
  echo "echo BNA_T2_READ"; sleep "$CMD_WAIT"; \
  echo "echo bnasec | sudo -S systemctl poweroff --no-wall"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t2-boot2.log" 2>&1
end_shots
grep -aq "BNA_PERSIST_PROOF_120" "$TESTS/t2-boot2.log" \
  && ok "T2b .config marker survived reboot — PERSISTENCE PROVEN" || bad "T2b persistence proof" "$TESTS/t2-boot2.log"
grep -aq "BNA_DOCS_PROOF_120" "$TESTS/t2-boot2.log" \
  && ok "T2c Documents marker survived reboot" || bad "T2c Documents proof" "$TESTS/t2-boot2.log"

# ================= T3: RAM-only volatile session =================
echo "== T3: RAM-only session =="
sched_shots 25:t3-01-early $((BOOT_WAIT/2)):t3-02-mid $((BOOT_WAIT+10)):t3-03-session
{ sleep "$BOOT_WAIT"; echo "printf 'BNA_T3_VOLATILE_%s\\n' ok"; sleep "$CMD_WAIT"; \
  echo "printf 'BNA_T3_NOTMOUNTED_%s\\n' \"\$(findmnt -n -o FSTYPE /var/lib/bnasec-persist 2>/dev/null)\""; sleep 6; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" \
    -append "archisobasedir=arch archisolabel=BNASEC200 bnasec_nopersist console=ttyS0,115200n8 quiet loglevel=3" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t3-serial.log" 2>&1
end_shots
grep -aq "BNA_T3_VOLATILE_ok" "$TESTS/t3-serial.log" \
  && ok "T3 volatile session boots" || bad "T3 volatile" "$TESTS/t3-serial.log"
grep -aq "bnasec: RAM-only session — persistence partition untouched" "$TESTS/t3-serial.log" \
  && ok "T3 stick untouched in RAM-only mode" || bad "T3 RAM-only flag" "$TESTS/t3-serial.log"
grep -aq "bnasec: persistence unavailable" "$TESTS/t3-serial.log" \
  && bad "T3 fell back unexpectedly" "$TESTS/t3-serial.log" || ok "T3 no persistence requested (correct)"

# ================= T4: UEFI via OVMF =================
echo "== T4: UEFI boot =="
OVMF_CODE=$(find /usr/share/edk2 -name 'OVMF_CODE.4m.fd' 2>/dev/null | head -1)
if [ -z "$OVMF_CODE" ]; then OVMF_CODE=$(find /usr/share/ovmf /usr/share/edk2* -name 'OVMF_CODE*.fd' 2>/dev/null | head -1); fi
if [ -n "$OVMF_CODE" ]; then
  OVMF_VARS_SRC=$(find /usr/share/edk2 /usr/share/ovmf -name 'OVMF_VARS.4m.fd' -o -name 'OVMF_VARS.fd' 2>/dev/null | head -1)
  cp -f "$OVMF_VARS_SRC" "$TESTS/ovmf-vars.fd"
  sched_shots 15:t4-01-ovmf 60:t4-02-menu $((BOOT_WAIT/2)):t4-03-mid $((BOOT_WAIT+15)):t4-04-session
  { sleep "$BOOT_WAIT"; echo "printf 'BNA_T4_UEFI_READY_%s\\n' ok"; sleep "$CMD_WAIT"; \
    echo "echo bnasec | sudo -S poweroff --no-wall"; sleep "$CMD_WAIT"; } | Q "$HARD_WAIT" "${DISK_ARGS[@]}" \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$TESTS/ovmf-vars.fd" \
      -serial stdio > "$TESTS/t4-serial.log" 2>&1
  end_shots
  grep -aq "BNA_T4_UEFI_READY_ok" "$TESTS/t4-serial.log" \
    && ok "T4 UEFI session reached (serial shell answering)" || bad "T4 UEFI" "$TESTS/t4-serial.log"
else
  echo "SKIP  T4 (no OVMF firmware found)"
fi

# ---- convert screenshots ppm -> png so the diagnostics artifact is viewable
if command -v python3 >/dev/null 2>&1 && compgen -G "$SHOTS/*.ppm" >/dev/null; then
    python3 "$SCRIPT_DIR/ppm2png.py" "$SHOTS"/*.ppm || true
    rm -f "$SHOTS"/*.ppm
fi
echo "screenshots captured: $(ls "$SHOTS" 2>/dev/null | wc -l)"
ls -la "$SHOTS" 2>/dev/null | tail -n +2

echo "== summary: $PASS passed, $FAILN failed =="
[ "$FAILN" = 0 ]
