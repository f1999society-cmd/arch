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
set -uo pipefail

OUT="${OUT_DIR:-$PWD/bnasec-build-out}"
TESTS="${TEST_DIR:-$PWD/bnasec-tests}"
ISO=$(find "$OUT" -maxdepth 1 -name '*.iso' | head -1)
[ -n "$ISO" ] || { echo "no ISO in $OUT"; exit 1; }
mkdir -p "$TESTS"

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
        -no-reboot "$@"
}

DISK_ARGS=(-drive if=none,id=udisk,format=raw,file="$TESTS/usb.img" -device usb-storage,drive=udisk,removable=on)

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
{ sleep "$BOOT_WAIT"; \
  echo "echo BNA_T1_SHELL_READY"; sleep "$CMD_WAIT"; \
  echo "findmnt -n -o FSTYPE /"; sleep 8; \
  echo "echo bnasec | sudo -S poweroff --no-wall"; sleep "$CMD_WAIT"; } | Q "$HARD_WAIT" "${DISK_ARGS[@]}" \
    -serial stdio -monitor none > "$TESTS/t1-serial.log" 2>&1
grep -aq "no persistence partition found, creating one" "$TESTS/t1-serial.log" \
  && ok "T1a persistence partition auto-created on first boot" || bad "T1a auto-persist" "$TESTS/t1-serial.log"
grep -aq "bnasec: checking persistence filesystem" "$TESTS/t1-serial.log" \
  && ok "T1b persist fs checked (fsck ran)" || bad "T1b fsck" "$TESTS/t1-serial.log"
grep -aq "BNA_T1_SHELL_READY" "$TESTS/t1-serial.log" \
  && ok "T1c session reached (serial shell answering)" || bad "T1c session" "$TESTS/t1-serial.log"
grep -aq "overlay" <(grep -a "findmnt" "$TESTS/t1-serial.log") \
  && ok "T1d root is overlay (persistent upperdir)" || bad "T1d overlay root" "$TESTS/t1-serial.log"

# ================= T2: persistence proof across two boots =================
echo "== T2: persistence proof =="
PERSIST_APPEND="archisobasedir=arch archisolabel=BNASEC_120 cow_label=persistence cow_directory=persist console=ttyS0,115200n8 quiet loglevel=3"
{ sleep "$BOOT_WAIT"; \
  echo "echo bnasec | sudo -S sh -c 'echo BNA_PERSIST_PROOF_120 > /var/lib/persist-proof'"; sleep "$CMD_WAIT"; \
  echo "cat /var/lib/persist-proof"; sleep 8; \
  echo "echo BNA_T2_WROTE"; sleep "$CMD_WAIT"; \
  echo "echo bnasec | sudo -S systemctl poweroff --no-wall"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio -monitor none > "$TESTS/t2-boot1.log" 2>&1
grep -aq "BNA_T2_WROTE" "$TESTS/t2-boot1.log" \
  && ok "T2a marker written inside live session" || bad "T2a write" "$TESTS/t2-boot1.log"

{ sleep "$BOOT_WAIT"; \
  echo "cat /var/lib/persist-proof"; sleep 8; \
  echo "echo BNA_T2_READ"; sleep "$CMD_WAIT"; \
  echo "echo bnasec | sudo -S systemctl poweroff --no-wall"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" -append "$PERSIST_APPEND" \
    "${DISK_ARGS[@]}" -serial stdio -monitor none > "$TESTS/t2-boot2.log" 2>&1
grep -aq "BNA_PERSIST_PROOF_120" "$TESTS/t2-boot2.log" \
  && ok "T2b marker survived reboot — PERSISTENCE PROVEN" || bad "T2b persistence proof" "$TESTS/t2-boot2.log"

# ================= T3: RAM-only volatile session =================
echo "== T3: RAM-only session =="
{ sleep "$BOOT_WAIT"; echo "echo BNA_T3_VOLATILE"; sleep "$CMD_WAIT"; } | \
  Q "$HARD_WAIT" -kernel "$KERNEL" -initrd "$INITRD" \
    -append "archisobasedir=arch archisolabel=BNASEC_120 console=ttyS0,115200n8 quiet loglevel=3" \
    "${DISK_ARGS[@]}" -serial stdio -monitor none > "$TESTS/t3-serial.log" 2>&1
grep -aq "BNA_T3_VOLATILE" "$TESTS/t3-serial.log" \
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
  { sleep "$BOOT_WAIT"; echo "echo BNA_T4_UEFI_READY"; sleep "$CMD_WAIT"; \
    echo "echo bnasec | sudo -S poweroff --no-wall"; sleep "$CMD_WAIT"; } | Q "$HARD_WAIT" "${DISK_ARGS[@]}" \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$TESTS/ovmf-vars.fd" \
      -serial stdio -monitor none > "$TESTS/t4-serial.log" 2>&1
  grep -aq "BNA_T4_UEFI_READY" "$TESTS/t4-serial.log" \
    && ok "T4 UEFI session reached (serial shell answering)" || bad "T4 UEFI" "$TESTS/t4-serial.log"
else
  echo "SKIP  T4 (no OVMF firmware found)"
fi

echo "== summary: $PASS passed, $FAILN failed =="
[ "$FAILN" = 0 ]
