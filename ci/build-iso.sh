#!/usr/bin/env bash
#
# bnasec 1.2.0 ISO build — runs INSIDE an archlinux:base-devel container.
#
#   1. validate every package name in packages.x86_64 against the repos (fail fast)
#   2. bootstrap chaotic-aur in the container (prebuilt AUR coverage)
#   3. install the full package list into the container (validates + preinstalls)
#   4. create user bna and run the Hyde installer (github.com/Hyde-project/HyDE)
#   5. collect Hyde output (home dots, sddm theme, fonts, cursors) into the profile
#   6. mkarchiso → ISO
#   7. post-build assertions (Hyde configs baked, toolbox baked, sudo setuid intact)
#
set -euo pipefail

PROFILE=/__w/arch/arch/profile     # actions checkout path, override via PROFILE_DIR
PROFILE_DIR="${PROFILE_DIR:-$PROFILE}"
WORK="${WORK_DIR:-$PWD/bnasec-build-work}"
OUT="${OUT_DIR:-$PWD/bnasec-build-out}"
HYDE_REPO="https://github.com/HyDE-project/HyDE"

mkdir -p "$WORK" "$OUT"
cd "$(dirname "$0")/.."

# ------------------------------------------------------------- 0. env
echo "== [0] environment =="
test "$(id -u)" = 0 || { echo "must run as root (container)"; exit 1; }
. /etc/os-release
echo "host: $PRETTY_NAME"
pacman -Sy --noconfirm >/dev/null
pacman -Q archiso >/dev/null 2>&1 || pacman -S --noconfirm --needed archiso >/dev/null

# ------------------------------------------------------------- 1. chaotic-aur bootstrap
echo "== [1] bootstrapping chaotic-aur in the container =="
CHAOTIC_DIR=/tmp/chaotic-bootstrap
mkdir -p "$CHAOTIC_DIR"; cd "$CHAOTIC_DIR"
for pkg in chaotic-keyring chaotic-mirrorlist; do
  f=$(curl -sL "https://builds.garudalinux.org/repos/chaotic-aur/x86_64/" | grep -oE "${pkg}-[0-9][^-]*-[0-9]+-any\.pkg\.tar\.zst" | sort -V | tail -n1)
  echo "fetching $f"
  curl -fsLO "https://builds.garudalinux.org/repos/chaotic-aur/x86_64/$f"
  pacman -U --noconfirm "$f" >/dev/null
done
# container keyrings are not initialized/populated — chaotic packages would fail
# signature checks ("unknown trust") without this
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux chaotic
grep -q '^\[chaotic-aur\]' /etc/pacman.conf || cat >> /etc/pacman.conf <<'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
pacman -Sy --noconfirm >/dev/null
pacman -Si chaotic-keyring >/dev/null && echo "chaotic-aur active"

# ------------------------------------------------------------- 2. package validation
echo "== [2] validating packages.x86_64 against configured repos =="
cd - >/dev/null
PKGS=$(grep -vE '^\s*#|^\s*$' "$PROFILE_DIR/packages.x86_64")
MISSING=()
for p in $PKGS; do
  if ! pacman -Si "$p" >/dev/null 2>&1; then
    MISSING+=("$p")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  id builduser >/dev/null 2>&1 || useradd -m builduser
  echo 'builduser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/98-builduser
  chmod 440 /etc/sudoers.d/98-builduser
  LOCALREPO=/tmp/bnasec-localrepo
  rm -rf "$LOCALREPO"; mkdir -p "$LOCALREPO"
  ALLBUILT=()

  # (a) name-shims: packages Hyde references by a name that only exists under a
  #     -git suffix in chaotic. A tiny empty package under the expected name keeps
  #     deez/paru name-resolution happy while the real files come from the -git pkg.
  SHIM_PKGS=(hyprquery)   # shim name -> real implementation is <name>-git (hyq binary)
  for p in "${SHIM_PKGS[@]}"; do
    [[ " ${MISSING[*]} " == *" $p "* ]] || continue
    SD="/tmp/shim-$p"; rm -rf "$SD"; mkdir -p "$SD/$p"
    cat > "$SD/$p/PKGBUILD" <<PKGEOF
pkgname=$p
pkgver=1.0
pkgrel=1
pkgdesc="bnasec shim: name placeholder, real files from $p-git"
arch=('any')
license=('MIT')
package() { :; }
PKGEOF
    chown -R builduser: "$SD"
    ( cd "$SD/$p" && sudo -u builduser makepkg -f --noconfirm --noprogressbar ) > "/tmp/shim-$p.log" 2>&1 || { echo "shim build failed for $p:"; tail -20 "/tmp/shim-$p.log"; exit 1; }
    mv "$SD/$p/$p-1.0-1-any.pkg.tar.zst" "$LOCALREPO/"
    ALLBUILT+=("$LOCALREPO/$p-1.0-1-any.pkg.tar.zst")
    echo "built shim: $p"
  done
  # drop shim names from MISSING (they are resolved now)
  NEW=(); for p in "${MISSING[@]}"; do
    skip=0
    for s in "${SHIM_PKGS[@]}"; do [ "$s" = "$p" ] && skip=1; done
    [ "$skip" = 0 ] && NEW+=("$p")
  done
  MISSING=("${NEW[@]:-}")

  # (b) generic AUR build for anything still missing
  for p in "${MISSING[@]:-}"; do
    [ -z "$p" ] && continue
    BD="/tmp/aurbuild-$p"
    rm -rf "$BD"; mkdir -p "$BD"; chown builduser: "$BD"
    if ! sudo -u builduser git clone --depth 1 "https://aur.archlinux.org/${p}.git" "$BD" > "/tmp/aurbuild-$p.log" 2>&1; then
      echo "AUR repo for '$p' not found"; tail -5 "/tmp/aurbuild-$p.log"; exit 1
    fi
    ( cd "$BD" && sudo -u builduser makepkg -sf --noconfirm --noprogressbar ) >> "/tmp/aurbuild-$p.log" 2>&1 || { echo "makepkg failed for $p:"; tail -40 "/tmp/aurbuild-$p.log"; exit 1; }
    PKGFILE=$(ls "$BD"/*.pkg.tar.zst 2>/dev/null | head -n1)
    [ -n "$PKGFILE" ] || { echo "no package produced for $p:"; tail -20 "/tmp/aurbuild-$p.log"; exit 1; }
    mv "$PKGFILE" "$LOCALREPO/"
    ALLBUILT+=("$LOCALREPO/$(basename "$PKGFILE")")
    echo "built locally: $(basename "$PKGFILE")"
  done

  if [ ${#ALLBUILT[@]} -gt 0 ]; then
    repo-add "$LOCALREPO/bnasec-local.db.tar.gz" "${ALLBUILT[@]}" > /tmp/repo-add.log 2>&1 || { cat /tmp/repo-add.log; exit 1; }
    for conf in /etc/pacman.conf "$PROFILE_DIR/pacman.conf"; do
      grep -q '^\[bnasec-local\]' "$conf" || cat >> "$conf" <<EOF

[bnasec-local]
Server = file://${LOCALREPO}
SigLevel = Never
EOF
    done
    pacman -Sy --noconfirm >/dev/null
  fi
  for p in $PKGS; do
    pacman -Si "$p" >/dev/null 2>&1 || { echo "STILL UNRESOLVED: $p"; exit 1; }
  done
fi
echo "all $(echo "$PKGS" | wc -w) packages resolve in repos"

# ------------------------------------------------------------- 3. install full list
echo "== [3] installing the full package list into the container =="
# qemu-desktop (installed by the workflow for boot tests) drags in jack2, which
# conflicts with pipewire-jack — evict it (dd: qemu-audio-jack depends on it but
# we do not care about qemu audio in this throwaway container)
pacman -Rdd --noconfirm --nosave jack2 > /dev/null 2>&1 || true
pacman -S --noconfirm --needed pipewire-jack > /tmp/pkg-install.log 2>&1 || { tail -20 /tmp/pkg-install.log; exit 1; }
pacman -S --noconfirm --needed $(grep -vE '^\s*#|^\s*$' "$PROFILE_DIR/packages.x86_64" | grep -vx pipewire-jack) >> /tmp/pkg-install.log 2>&1 || { tail -30 /tmp/pkg-install.log; exit 1; }
locale-gen
echo "container now has: $(pacman -Qq | wc -l) packages"

# ------------------------------------------------------------- 4. user + Hyde
echo "== [4] creating user bna + installing Hyde =="
id bna >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/zsh -G wheel,video,audio,storage,optical,network,users bna
echo 'bna:bnasec' | chpasswd
echo 'bna ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-bna-build   # container only, never collected
chmod 440 /etc/sudoers.d/99-bna-build

# systemctl shim (container only): Hyde's restore_svc runs 'systemctl enable --now'
# which cannot start units without systemd PID 1 — let enable() create the symlinks
# and pretend the start part succeeded. Never collected into the ISO.
mv /usr/bin/systemctl /usr/bin/systemctl.real
cat > /usr/bin/systemctl <<'EOF'
#!/bin/bash
# bnasec build shim: allow enable (symlink creation) but fake runtime verbs
args=()
now=0
for a in "$@"; do
  [ "$a" = "--now" ] && { now=1; continue; }
  args+=("$a")
done
if [ "$now" = 1 ]; then
  /usr/bin/systemctl.real "${args[@]}" || true
  exit 0
fi
case "${args[0]:-}" in
  enable|disable|mask) exec /usr/bin/systemctl.real "${args[@]}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x /usr/bin/systemctl
ls -la /usr/bin/systemctl /usr/bin/systemctl.real

sudo -u bna -H git clone --depth 1 "$HYDE_REPO" /home/bna/HyDE 2>&1 | tail -1
HYDE_HEAD=$(git -C /home/bna/HyDE rev-parse --short HEAD)
echo "Hyde @ $HYDE_HEAD"

echo "-- running Hyde installer (non-interactive flags; stdin EOF walks prompts to defaults) --"
set +e
timeout 3600 sudo -u bna -H bash -lc 'cd ~/HyDE/Scripts && ./install.sh -d -r -s -n' < /dev/null > /tmp/hyde-install.log 2>&1
HYDE_RC=$?
set -e
echo "hyde installer rc=$HYDE_RC"
tail -40 /tmp/hyde-install.log
if [ "$HYDE_RC" != 0 ]; then
  echo "!! Hyde install failed — last 80 lines of log:"
  tail -80 /tmp/hyde-install.log
  exit 1
fi

# ------------------------------------------------------------- 5. collect into profile
echo "== [5] collecting Hyde output into the profile =="
A="$PROFILE_DIR/airootfs"
mkdir -p "$A/home/bna" "$A/etc/sddm.conf.d" "$A/usr/share/sddm/themes"

# dots: everything in bna's home except the clone + transient venvs/caches
rm -rf /home/bna/HyDE /home/bna/.local/state/hyde/python_env
du -sh /home/bna/.cache 2>/dev/null || true
cp -a /home/bna/. "$A/home/bna/"

# display manager theme written by install_pst.sh
cp -a /etc/sddm.conf.d/. "$A/etc/sddm.conf.d/" 2>/dev/null || true
if compgen -G '/usr/share/sddm/themes/*' >/dev/null; then
  cp -a /usr/share/sddm/themes/. "$A/usr/share/sddm/themes/"
fi
if [ -d /usr/share/sddm/faces ]; then
  cp -a /usr/share/sddm/faces "$A/usr/share/sddm/faces"
fi

# system-wide fonts/cursors Hyde dropped into /usr/local/share
if [ -d /usr/local/share/fonts ]; then
  mkdir -p "$A/usr/local/share/fonts" && cp -a /usr/local/share/fonts/. "$A/usr/local/share/fonts/"
fi
if [ -d /usr/local/share/icons ]; then
  mkdir -p "$A/usr/local/share/icons" && cp -a /usr/local/share/icons/. "$A/usr/local/share/icons/"
fi

# pacman config for the live system + chaotic mirrorlist
# (strip the build-only [bnasec-local] file:// repo — it does not exist at runtime)
mkdir -p "$A/etc/pacman.d"
sed '/^\[bnasec-local\]/,+3d' "$PROFILE_DIR/pacman.conf" > "$A/etc/pacman.conf"
cp /etc/pacman.d/chaotic-mirrorlist "$A/etc/pacman.d/chaotic-mirrorlist"

# locale archive (locale-gen ran in the container)
mkdir -p "$A/usr/lib/locale"
cp /usr/lib/locale/locale-archive "$A/usr/lib/locale/locale-archive"

# build metadata
mkdir -p "$A/usr/share/bnasec"
cat > "$A/usr/share/bnasec/BUILD-INFO" <<EOF
iso: bnasec-arch-1.2.0
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
hyde-commit: $HYDE_HEAD
hyde-repo: $HYDE_REPO
packages: $(pacman -Qq | wc -l)
toolbox-sha256-12: $(sha256sum "$A/usr/local/bin/bnasec-toolbox" | cut -c1-12)
EOF

chown -R 1000:1000 "$A/home/bna"
echo "collected. home size: $(du -sh "$A/home/bna" | cut -f1)"

# ------------------------------------------------------------- 6. mkarchiso
echo "== [6] mkarchiso =="
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"
mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE_DIR" 2>&1 | tail -60
ISO=$(find "$OUT" -maxdepth 1 -name '*.iso' | head -1)
[ -n "$ISO" ] || { echo "no ISO produced"; exit 1; }
echo "ISO: $ISO ($(du -h "$ISO" | cut -f1))"

# ------------------------------------------------------------- 7. assertions
echo "== [7] post-build assertions =="
SFS=$(find "$WORK" -name 'airootfs.sfs' | head -1)
CHECK=/tmp/sfs-check
rm -rf "$CHECK"; mkdir -p "$CHECK"
unsquashfs -f -d "$CHECK" "$SFS" \
  'home/bna/.config/hypr' 'usr/local/bin/bnasec-toolbox' \
  'usr/share/sddm/themes' 'etc/sddm.conf.d' 'etc/pacman.conf' \
  'usr/lib/initcpio/hooks/archiso_bnasec' 'usr/bin/sudo' \
  > /tmp/unsquashfs.log 2>&1 || { tail -20 /tmp/unsquashfs.log; exit 1; }
FAIL=0
[ -d "$CHECK/home/bna/.config/hypr" ] && echo "PASS hypr dots baked ($(find "$CHECK/home/bna/.config/hypr" -type f | wc -l) files)" || { echo "FAIL hypr dots missing"; FAIL=1; }
[ -x "$CHECK/usr/local/bin/bnasec-toolbox" ] && echo "PASS toolbox baked" || { echo "FAIL toolbox missing"; FAIL=1; }
[ -d "$CHECK/usr/share/sddm/themes/Corners" ] && echo "PASS sddm theme baked" || { echo "FAIL sddm theme missing"; FAIL=1; }
grep -q chaotic-aur "$CHECK/etc/pacman.conf" && echo "PASS chaotic in live pacman.conf" || { echo "FAIL chaotic missing from pacman.conf"; FAIL=1; }
[ -f "$CHECK/usr/lib/initcpio/hooks/archiso_bnasec" ] && echo "PASS persist hook baked" || { echo "FAIL persist hook missing"; FAIL=1; }
SUID=$(find "$CHECK/usr" -perm -4000 -type f 2>/dev/null | wc -l)
[ "$SUID" -ge 15 ] && echo "PASS setuid binaries intact ($SUID)" || { echo "FAIL setuid count low ($SUID)"; FAIL=1; }
[ "$FAIL" = 0 ] || { echo "ASSERTIONS FAILED"; exit 1; }

sha256sum "$ISO" > "$ISO.sha256"
echo "== BUILD COMPLETE: $ISO =="
