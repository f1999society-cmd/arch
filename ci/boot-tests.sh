#!/usr/bin/env bash
#
# bnasec 1.2.0 boot tests — run INSIDE the build container after build-iso.sh.
#
#   T1  BIOS default (persistent) boot from a dd'd USB image:
#       - persistence partition auto-created on first boot
#       - graphical session reached
#   T2  persistence proof: marker written INSIDE boot 1 is read back in boot 2
#   T3  RAM-only session boots volatile
#   T4  UEFI boot via OVMF reaches the session
#
# Every test drives the guest over the serial console (console=ttyS0, serial
# autologin as bna). KVM when available, otherwise TCG with longer waits.
#
# Each run also exposes a QEMU monitor unix socket; a background scheduler
# fires HMP 'screendump' at scheduled offsets so the VGA surface (syslinux
# menu, boot, sddm/HyDE session) is captured as screenshots for the user.
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
sched_shots() {  # varargs delay:name — schedule shots for the NEXT qemu run
    SHOT_PID=""
    (
        for item in "$@"; do
            sleep "${item%%:*}"
            shot "${item#*:}"
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
    qemu-desktop qemu-img edk2-ovmf socat python > /tmp/qemu-install.log 2>&1 \
    || { tail -20 /tmp/qemu-install.log; exit 1; }
fi

# ---- acceleration
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else ACCEL="tcg"; fi
echo "accel: $ACCEL"
if [ "$ACCEL" = "kvm" ]; then BOOT_WAIT=180; CMD_WAIT=25; HARD_WAIT=270; else BOOT_WAIT=540; CMD_WAIT=45; HARD_WAIT=660; fi

PASS=0; FAILN=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAILN=$((FAILN+1)); echo "----- last 40 serial lines of $2 -----"; tail -40 "$2" 2>/dev/null; }

Q() {  # base qemu invocation (arg1: hard timeout seconds, rest: extra args)
    local tmo="$1"; shift
    timeout "$tmo" qemu-system-x86_64 -machine q35 -m 3072 -smp 2 \
        -accel "$ACCEL" -display none \
        -device virtio-gpu-pci \
        -monitor "${MON_SOCK:-none}" \
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
# menu shot at 4s+9s (syslinux TIMEOUT is 5s), session shots land after the
# serial shell answers and after the sddm/Hyprland probes
sched_shots 4:t1-01-menu 9:t1-02-menu 25:t1-03-early 240:t1-04-mid 520:t1-05-late 555:t1-06-session 597:t1-07-probes
{ sleep "$BOOT_WAIT"; \
  echo "printf 'BNA_SHELL_READY_%s\\n' T1"; sleep "$CMD_WAIT"; \
  echo "findmnt -n -o FSTYPE /"; sleep 8; \
  echo "printf 'BNA_SDDM_%s\\n' \"\$(systemctl is-active sddm 2>&1)\""; sleep 6; \
  echo "printf 'BNA_HYP_%s\\n' \"\$(pgrep -c Hyprland 2>/dev/null)\""; sleep 6; \
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
  && ok "T1d root is overlay (persistent upperdir)" || bad "T1d overlay root" "$TESTS/t1-serial.log"
# report-only: does the graphical stack actually come up inside the guest?
echo "T1 graphical probe: $(grep -ao 'BNA_SDDM_[a-z]*' "$TESTS/t1-serial.log" | tail -1) $(grep -ao 'BNA_HYP_[0-9]*' "$TESTS/t1-serial.log" | tail -1)"

# ================= T2: persistence proof across two boots =================
echo "== T2: persistence proof =="
MON_SOCK="$TESTS/qemu-mon.sock"; rm -f "$MON_SOCK"
sched_shots 25:t2b1-01-early 240:t2b1-02-mid 570:t2b1-03-session 610:t2b1-04-proof
PERSIST_APPEND="archisobasedir=arch archisolabel=BNASEC_120 cow_label=persistence cow_directory=persist console=ttyS0,115200n8 quiet loglevel=3"
{ sleep "$BOOT_WAIT"; \
  echo "echo bnasec | sudo -S sh -c \"printf 'BNA_PERSIST_PROOF_%s\\n' 120 > /var/lib/persist-proof\""; sleep "$CMD_WAIT"; \
  echo "cat /var/lib/persist-proof"; sleep 8; \
  echo "printf 'BNA_T2_WROTE_%s\\n' ok"; sleep "$CMD_WAIT"; \
  echo "echo bnasec | sudo -S systemctl poweroff --no-wall"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t2-boot1.log" 2>&1
end_shots
grep -aq "BNA_T2_WROTE_ok" "$TESTS/t2-boot1.log" \
  && ok "T2a marker written inside live session" || bad "T2a write" "$TESTS/t2-boot1.log"

sched_shots 25:t2b2-01-early 240:t2b2-02-mid 555:t2b2-03-proof-read 585:t2b2-04-late
{ sleep "$BOOT_WAIT"; \
  echo "cat /var/lib/persist-proof"; sleep 8; \
  echo "echo BNA_T2_READ"; sleep "$CMD_WAIT"; \
  echo "echo bnasec | sudo -S systemctl poweroff --no-wall"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t2-boot2.log" 2>&1
end_shots
grep -aq "BNA_PERSIST_PROOF_120" "$TESTS/t2-boot2.log" \
  && ok "T2b marker survived reboot — PERSISTENCE PROVEN" || bad "T2b persistence proof" "$TESTS/t2-boot2.log"

# ================= T3: RAM-only volatile session =================
echo "== T3: RAM-only session =="
sched_shots 25:t3-01-early 240:t3-02-mid 560:t3-03-session
{ sleep "$BOOT_WAIT"; echo "printf 'BNA_T3_VOLATILE_%s\\n' ok"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" \
    -append "archisobasedir=arch archisolabel=BNASEC_120 console=ttyS0,115200n8 quiet loglevel=3" \
    "${DISK_ARGS[@]}" -serial stdio > "$TESTS/t3-serial.log" 2>&1
end_shots
grep -aq "BNA_T3_VOLATILE_ok" "$TESTS/t3-serial.log" \
  && ok "T3 volatile session boots" || bad "T3 volatile" "$TESTS/t3-serial.log"
grep -aq "bnasec: persistence unavailable" "$TESTS/t3-serial.log" \
  && bad "T3 fell back unexpectedly" "$TESTS/t3-serial.log" || ok "T3 no persistence requested (correct)"

# ================= T4: UEFI via OVMF =================
echo "== T4: UEFI boot =="
OVMF_CODE=$(find /usr/share/edk2 -name 'OVMF_CODE.4m.fd' 2>/dev/null | head -1)
if [ -z "$OVMF_CODE" ]; then OVMF_CODE=$(find /usr/share/ovmf /usr/share/edk2* -name 'OVMF_CODE*.fd' 2>/dev/null | head -1); fi
if [ -n "$OVMF_CODE" ]; then
  OVMF_VARS_SRC=$(find /usr/share/edk2 /usr/share/ovmf -name 'OVMF_VARS.4m.fd' -o -name 'OVMF_VARS.fd' 2>/dev/null | head -1)
  cp -f "$OVMF_VARS_SRC" "$TESTS/ovmf-vars.fd"
  sched_shots 15:t4-01-ovmf 60:t4-02-menu 300:t4-03-mid 565:t4-04-session
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
