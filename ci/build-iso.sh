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
# NOTE: pacman-static insurance removed — chaotic-aur dropped the package
# ('target not found', run b6e2f49; verified absent from the garuda repo
# listing). Post-purge recovery relies on the keep-closure + tool_ok heal
# passes with dynamic pacman, which run b6e2f49 proved work end-to-end.

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
# container's locale.gen ships fully commented -> locale-gen generates nothing ->
# the ISO would have no compiled en_US.UTF-8 (run 36140211038: empty locale data).
# Uncomment it, then generate; the compiled per-locale dirs under /usr/lib/locale
# are unowned by glibc and get baked into the airootfs during collect.
sed -i 's/^#en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
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

# containers get finicky about ownership (actions mounts, sudo env) — whitelist
# at the SYSTEM level so both root and bna pass safe.directory checks (per-user
# config is not enough: the clone/create user and the checking user can differ)
git config --system --add safe.directory '*' || true
chown -R bna:bna /home/bna
sudo -u bna -H git config --global --add safe.directory '*'
sudo -u bna -H git clone --depth 1 "$HYDE_REPO" /home/bna/HyDE 2>&1 | tail -1
HYDE_HEAD=$(git -C /home/bna/HyDE rev-parse --short HEAD)
echo "Hyde @ $HYDE_HEAD"

echo "-- running Hyde installer (non-interactive flags; stdin EOF walks prompts to defaults) --"
# Container has no logind, so /run/user/1000 never exists. Hyde's globalcontrol.sh
# (sourced by theme.patch.sh, cache.sh, theme.switch.sh) hard-fails without it:
#   mkdir: cannot create directory '/run/user/1000': Permission denied
#   -> "Error: unable to source globalcontrol.sh" -> every theme import fails
#   -> "Wallpaper cache was not generated" + "Theme colour state was not generated"
#   -> theme_failed=1 -> install.sh exit 1. Pre-create it and pin XDG_RUNTIME_DIR.
mkdir -p /run/user/1000
chown bna:bna /run/user/1000
chmod 700 /run/user/1000
# Pre-answer Hyde's sddm theme prompt deterministically. install_pst.sh asks via a
# bare `read -p` which kills install.sh under set -e when stdin hits EOF (this is
# what ended runs 8574ce3/9af4eb7 right after the theme step). With the backup
# marker present the whole prompt block is skipped, so extract Corners + write the
# exact files the prompt path would have written (backup stays empty like Hyde).
mkdir -p /usr/share/sddm/themes /etc/sddm.conf.d /usr/share/sddm/faces
if [ ! -d /usr/share/sddm/themes/Corners ]; then
  tar -xzf /home/bna/HyDE/Source/arcs/Sddm_Corners.tar.gz -C /usr/share/sddm/themes/
fi
: > /etc/sddm.conf.d/the_hyde_project.conf
: > /etc/sddm.conf.d/backup_the_hyde_project.conf
cp /usr/share/sddm/themes/Corners/the_hyde_project.conf /etc/sddm.conf.d/the_hyde_project.conf
mkdir -p /usr/share/sddm/faces
echo "sddm Corners pre-seeded (prompt will be skipped)"
set +e
timeout 3600 sudo -u bna -H env XDG_RUNTIME_DIR=/run/user/1000 bash -lc 'cd ~/HyDE/Scripts && ./install.sh -d -r -s -n' < /dev/null > /tmp/hyde-install.log 2>&1
HYDE_RC=$?
set -e
echo "hyde installer rc=$HYDE_RC"
tail -40 /tmp/hyde-install.log
# install.sh's FINAL prompt ("Do you want to reboot?") is a bare `read` that dies
# on EOF — after "Installation :: COMPLETED!". Everything substantive (dots, themes,
# wallpaper cache, sddm, migrations, services) finished by then; the deploy_failed
# and theme_failed exits fire BEFORE that banner. So gate on the completion marker:
# present -> accept (a nonzero rc can only come from the reboot read at EOF).
# print_log emits ANSI codes between the words, so match on the bare "COMPLETED!"
# token (unique to the success banner in install.sh) instead of the full phrase.
if ! grep -q "COMPLETED!" /tmp/hyde-install.log; then
  echo "!! Hyde install did not complete — last 80 lines of log:"
  tail -80 /tmp/hyde-install.log
  exit 1
fi
[ "$HYDE_RC" = 0 ] || echo "NOTE: rc=$HYDE_RC is the EOF'd final reboot prompt read — installation completed, ignoring"

# ------------------------------------------------------------- 5. collect into profile
echo "== [5] collecting Hyde output into the profile =="
A="$PROFILE_DIR/airootfs"
mkdir -p "$A/home/bna" "$A/etc/sddm.conf.d" "$A/usr/share/sddm/themes"

# dots: everything in bna's home except the clone + transient venvs/caches
rm -rf /home/bna/HyDE /home/bna/.local/state/hyde/python_env
# .cache holds the themepatcher clones (~full theme branches x12) and install logs —
# tens of MB to GB of dead weight; it is tmpfs-shadowed at runtime anyway (fstab)
du -sh /home/bna/.cache 2>/dev/null || true
rm -rf /home/bna/.cache
# keep 3 of the 12 Hyde themes — runner SSD (~14GB) + ISO size budget; each theme
# ships its wallpapers. Dropped ones are re-importable at runtime via themepatcher.
KEEP_THEMES=("Catppuccin Mocha" "Rosé Pine" "Gruvbox Retro")
if [ -d /home/bna/.config/hyde/themes ]; then
  for t in /home/bna/.config/hyde/themes/*; do
    base=$(basename "$t"); keep=0
    for k in "${KEEP_THEMES[@]}"; do [ "$base" = "$k" ] && keep=1; done
    [ "$keep" = 0 ] && rm -rf "$t" && echo "theme trimmed: $base"
  done
fi
cp -a /home/bna/. "$A/home/bna/"

# display manager theme written by install_pst.sh + Hyde theme archives.
# copy_unowned: copy SRC under DST but SKIP any path owned by the named packages —
# mkarchiso pacstraps those packages into the airootfs afterwards, and pre-baked
# package-owned files make pacman abort with "exists in filesystem"
# (sddm's bundled maya theme was exactly that, run 36136026081).
copy_unowned() {
  local src="$1" dst="$2"; shift 2
  local owned="/tmp/owned.$$.txt"
  # strip trailing slashes so DIRECTORY entries match our abs path form; without
  # this a package-owned dir is cp -a'd whole (recursively dragging its owned
  # files in) and pacstrap later aborts with "exists in filesystem"
  pacman -Qql "$@" 2>/dev/null | sed 's|/\+$||' | sort -u > "$owned"
  ( cd "$src" && find . -mindepth 1 -printf '%P\n' ) | while IFS= read -r rel; do
    local abs="${src%/}/$rel"
    abs="${abs%/}"
    if grep -qxF "$abs" "$owned"; then continue; fi
    mkdir -p "$dst/$(dirname "$rel")"
    cp -a "$abs" "$dst/$rel"
  done
  rm -f "$owned"
}
copy_unowned /etc/sddm.conf.d       "$A/etc/sddm.conf.d"       sddm
copy_unowned /usr/share/sddm/themes "$A/usr/share/sddm/themes" sddm
if [ -d /usr/share/sddm/faces ]; then
  copy_unowned /usr/share/sddm/faces "$A/usr/share/sddm/faces" sddm
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

# locale data (locale-gen ran in the container). Skip glibc-owned dirs (C.utf8 is
# shipped by the glibc package — pacstrap would hit the same "exists in filesystem").
mkdir -p "$A/usr/lib/locale"
copy_unowned /usr/lib/locale "$A/usr/lib/locale" glibc
echo "locale data: $([ -d "$A/usr/lib/locale" ] && du -sh "$A/usr/lib/locale" | cut -f1 || echo none)"

# build metadata
mkdir -p "$A/usr/share/bnasec"
# the toolbox is the product's spine — verify it is staged BEFORE spending 15
# minutes of mkarchiso, and print the hash visibly (BUILD-INFO alone hides a
# failed command substitution inside the heredoc)
[ -f "$A/usr/local/bin/bnasec-toolbox" ] \
  || { echo "!! bnasec-toolbox missing from profile at collect time:"; ls -laR "$A/usr/local/bin/" 2>&1; exit 1; }
chmod 755 "$A/usr/local/bin/bnasec-toolbox"
echo "toolbox staged: $(du -h "$A/usr/local/bin/bnasec-toolbox" | cut -f1) sha12=$(sha256sum "$A/usr/local/bin/bnasec-toolbox" | cut -c1-12)"
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

# ------------------------------------------------------------- 5b. disk pruning
# GitHub-hosted runners expose ~14GB SSD total. The container's 857-package tree
# (~7GB) was only needed so Hyde/deez could see the desktop installed — the ISO
# packages are installed fresh by mkarchiso's pacstrap from the network. Runners
# died at pacstrap with the container still fat (36142103152, 36140211038).
echo "== [5b] pruning build container (free: $(df -h / | awk 'NR==2{print $4}') before) =="
rm -rf /home/bna /tmp/bnasec-localrepo /tmp/chaotic-bootstrap /tmp/shim-* /tmp/aurbuild-*
pacman -Sc --noconfirm >/dev/null 2>&1 || true

# Dynamic keep-closure: every binary the post-purge phases need (mkarchiso,
# pacstrap, xorriso, mksquashfs, gh, ...) plus the shared libraries each one
# links, mapped to their owning packages via pacman -Qoq. A static list bit us:
# purging libseccomp broke pacman itself ('error while loading shared libraries:
# libseccomp.so.2', run 36146550749).
rm -f /tmp/keep-pkgs.txt
KEEP_BINS=(pacman pacstrap arch-chroot mkarchiso mksquashfs unsquashfs xorriso \
  bsdtar find mmd mcopy e2fsck mkfs.ext4 mkfs.vfat gh curl bash sha256sum \
  sed grep awk tar gzip openssl unshare mount umount \
  # gnupg runtime: 'gnupg' alone in the floor keeps the binaries but NOT their
  # libs (libgcrypt/libgpg-error/libassuan/libksba/npth) — after the purge gpg
  # existed yet could not EXECUTE, and the unguarded 'pacman-key --init' died
  # silently under set -e right after '== [6] mkarchiso ==' (run 36160555180).
  # Listing the binaries here ldd-scans them into the closure.
  gpg gpgv dirmngr gpg-agent keyboxd pacman-conf)
for b in "${KEEP_BINS[@]}"; do
  p=$(command -v "$b" 2>/dev/null) || continue
  pacman -Qoq "$p" >> /tmp/keep-pkgs.txt 2>/dev/null || true
  # ldd prints RUNPATH-resolved libs as '/path (0x..)' — no '=>' — so scan every
  # whitespace-separated token for absolute .so paths (the old $3-only parse
  # missed libstdc++ and the purge removed gcc-libs from under pacman+node)
  for lib in $(ldd "$p" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\// && $i ~ /\.so/) print $i}'); do
    pacman -Qoq "$lib" >> /tmp/keep-pkgs.txt 2>/dev/null || true
  done
done
# explicit probes for the libs everything else depends on
for lib in /usr/lib/libstdc++.so.6 /usr/lib/libgcc_s.so.1 /usr/lib/libseccomp.so.2; do
  [ -e "$lib" ] && pacman -Qoq "$lib" >> /tmp/keep-pkgs.txt 2>/dev/null || true
done
# static floor: keyrings/mirrors/CAs for the post-purge pacman -S, base metadata.
# gnupg is NOT an ldd-visible dep (pacman shells out to gpg for signature checks)
# but without it pacstrap aborts with 'invalid or corrupted package (PGP
# signature)' — the exact failure that plagued the 1.1.x sticks.
cat >> /tmp/keep-pkgs.txt <<'EOF'
pacman-mirrorlist
archlinux-keyring
chaotic-keyring
chaotic-mirrorlist
gnupg
ca-certificates
ca-certificates-utils
ca-certificates-mozilla
iana-etc
licenses
filesystem
perl
gdbm
gcc-libs
libseccomp
EOF
KEEP="^$(sort -u /tmp/keep-pkgs.txt | grep -v '^$' | paste -sd'|')$"
echo "keep-closure: $(sort -u /tmp/keep-pkgs.txt | grep -cv '^$') packages"
# (former pacman-static pre-purge install removed — package gone from chaotic;
# the keep-closure below keeps dynamic pacman alive through the purge, proven
# in run b6e2f49 where post-purge -Sy and reinstall all succeeded)
# rescue the libs the runner's node + pacman cannot live without — whatever the
# purge removes gets physically restored right after, then the reinstall below
# repairs the DB/files consistency
RESCUE=/tmp/librescue; rm -rf "$RESCUE"; mkdir -p "$RESCUE"
cp -a /usr/lib/libstdc++.so.6* /usr/lib/libgcc_s.so.1* /usr/lib/libseccomp.so.2* "$RESCUE/" 2>/dev/null || true
ls -la "$RESCUE" | tail -n +2
PURGE=$(pacman -Qq 2>/dev/null | grep -vxE "$KEEP" || true)
if [ -n "$PURGE" ]; then
  # shellcheck disable=SC2086
  pacman -Rdd --noconfirm $PURGE > /tmp/purge.log 2>&1 || { echo "purge had failures (tail):"; tail -5 /tmp/purge.log; }
  echo "evidence — gcc-libs removed: $(grep -c 'removing gcc-libs' /tmp/purge.log || true), pacman removed: $(grep -c 'removing pacman$' /tmp/purge.log || true)"
fi
cp -a "$RESCUE/." /usr/lib/ 2>/dev/null || true
/sbin/ldconfig 2>/dev/null || true
# post-purge package ops go through dynamic pacman — the keep-closure protects
# its libraries through the purge (pacman-static was dropped from chaotic-aur)
PAC=pacman
command -v pacman >/dev/null 2>&1 || { echo "!! no pacman — cannot recover"; exit 1; }
echo "post-purge package manager: $PAC"
$PAC -Sy --noconfirm >/dev/null 2>&1 || true
$PAC -S --noconfirm --needed pacman findutils mtools archiso arch-install-scripts \
  squashfs-tools libisoburn e2fsprogs dosfstools libarchive curl gpgme github-cli gcc-libs gnupg \
  >> /tmp/purge.log 2>&1 || { echo "essential reinstall failed:"; tail -10 /tmp/purge.log; exit 1; }
# overlap repair: chaotic dup packages (e.g. 'libstdc++') share FILES with kept
# packages — removing the dup physically deletes the file while the kept owner
# (gcc-libs) still claims it in its DB (run 36160555180). The DB check lies, so
# verify FUNCTIONALLY: every tool must execute, not merely exist. Anything that
# fails gets force-reextracted (-dd: --dd is not a pacman option, -dd is) —
# critical lib packages included, since a broken DEP breaks a kept binary too.
# exec probe: a tool is healthy if it RUNS — rc 126/127 means loader/PATH
# failure (missing shared lib after the purge). rc 1 from a script that merely
# has no --version flag (pacstrap, mkarchiso) is HEALTHY — run b6e2f49
# false-flagged healthy pacstrap that way and burned 2 heal passes for nothing.
tool_ok() {
  local rc
  "$1" --version >/dev/null 2>&1 && return 0
  rc=$?
  [ "$rc" -eq 126 ] && return 1
  [ "$rc" -eq 127 ] && return 1
  "$1" --help >/dev/null 2>&1 && return 0
  rc=$?
  [ "$rc" -eq 126 ] && return 1
  [ "$rc" -eq 127 ] && return 1
  return 0
}
heal_pass() {
  local broken=0
  for b in pacman pacstrap mkarchiso mksquashfs xorriso gpg curl gh find mmd bsdtar; do
    command -v "$b" >/dev/null 2>&1 || { echo "!! $b gone entirely"; broken=1; continue; }
    tool_ok "$b" || { echo "!! $b does not execute"; broken=1; }
  done
  [ "$broken" = 1 ] || return 0
  echo "heal: force-reextracting critical toolchain"
  $PAC -S --noconfirm -dd gcc-libs libseccomp libgcrypt libgpg-error libassuan \
    libksba npth sqlite pacman archiso gnupg squashfs-tools libisoburn >> /tmp/purge.log 2>&1 \
    || { echo "!! heal reinstall failed:"; tail -8 /tmp/purge.log; return 1; }
  /sbin/ldconfig 2>/dev/null || true
  local still=0
  for b in pacman pacstrap mkarchiso mksquashfs xorriso gpg curl gh find mmd bsdtar; do
    tool_ok "$b" || { echo "!! $b STILL broken after heal"; still=1; }
  done
  return $still
}
heal_pass || heal_pass || { echo "!! tools broken after 2 heal passes:"; tail -15 /tmp/purge.log; exit 1; }
echo "toolchain functional after purge"
# diagnostics for the purge side-effects
ls -l /usr/lib/libstdc++.so.6 >/dev/null 2>&1 && echo "libstdc++ present" || echo "!! libstdc++.so.6 MISSING after purge"
ls -l /usr/lib/libseccomp.so.2 >/dev/null 2>&1 && echo "libseccomp present" || echo "!! libseccomp.so.2 MISSING after purge"
gpg --version >/dev/null 2>&1 && echo "gpg functional" || echo "!! gpg not functional after purge"
echo "pruned. container: $(pacman -Qq 2>/dev/null | wc -l) packages, free: $(df -h / | awk 'NR==2{print $4}')"

# ------------------------------------------------------------- 6. mkarchiso
echo "== [6] mkarchiso =="
# WIPE the container package cache (frees ~2.5GB; step [3] downloads are dead
# weight now and the disk-full window may have corrupted them in-place)
rm -rf /var/cache/pacman/pkg/*
# rebuild the pacman keyring: the step-[3] disk-full window corrupts written
# files via delayed allocation (the runner-side twin of the 1.1.x stick's ext4
# error-28 rot) — /etc/pacman.d/gnupg written back then fails every signature
# check with 'invalid or corrupted package (PGP signature)'. Fresh populate.
rm -rf /etc/pacman.d/gnupg
pacman-key --init 2>&1 | tail -2 || { echo "!! pacman-key --init failed:"; tail -5 /tmp/purge.log; exit 1; }
pacman-key --populate archlinux chaotic 2>&1 | tail -3 || { echo "!! pacman-key --populate failed"; exit 1; }
echo "profile usr/local/bin: $(ls -la "$PROFILE_DIR/airootfs/usr/local/bin" 2>&1 | tail -n +2 | tr '\n' '|' )"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"
# xorriso's free-space check runs against the filesystem holding the ISO file —
# the runner SSD has only ~2.2GB free at this point while the ISO is 2.6GB
# (runs 36166507765 + 36168421566 both died at xorriso even with the tree
# reaped). Build the ISO into a dedicated 6GB tmpfs (--privileged container,
# ~16GB RAM), free the work tree after the assertions, then move it to disk.
ISO_TMP=/mnt/bnasec-iso-tmp
mkdir -p "$ISO_TMP"
if mount -t tmpfs -o size=6g tmpfs "$ISO_TMP" 2>/dev/null; then
  echo "ISO tmpfs armed (6g)"
else
  echo "WARN: tmpfs mount failed — ISO goes straight to disk ($OUT)"
  ISO_TMP="$OUT"
fi
mkarchiso -v -w "$WORK" -o "$ISO_TMP" "$PROFILE_DIR" > /tmp/mkarchiso.log 2>&1 &
MKPID=$!
# cache reaper: the downloaded tarballs (~3GB in /var/cache/pacman/pkg) are dead
# weight the moment the install phase ends — wipe them while mksquashfs/xorriso
# run, or the ~14GB runner SSD cannot hold work tree + ISO at peak
( while kill -0 $MKPID 2>/dev/null; do
    if grep -q "Done! Packages installed successfully" /tmp/mkarchiso.log 2>/dev/null; then
      sleep 5; rm -rf /var/cache/pacman/pkg/*; echo "cache reaped at $(date -u +%H:%M:%S)"; break
    fi
    sleep 10
  done ) &
REAPER=$!
# tree reaper: the pacstrap airootfs tree (~4-5GB) is dead weight the moment
# mksquashfs finishes — mkarchiso only needs the .sfs afterwards, but it never
# frees the tree before xorriso, and tree + sfs + sfs-copy + 2.6GB ISO cannot
# fit on the ~14GB runner SSD (run 36166507765: 'Image size 1249680s exceeds
# free space on media 676178s'). The checksum marker fires right after
# mksquashfs — drop the tree the instant it appears, before 'Creating ISO image'.
( while kill -0 $MKPID 2>/dev/null; do
    if grep -q "Creating checksum file for self-test" /tmp/mkarchiso.log 2>/dev/null; then
      sleep 2; du -sh "$WORK"/x86_64/airootfs 2>/dev/null; rm -rf "$WORK"/x86_64/airootfs
      echo "airootfs tree reaped at $(date -u +%H:%M:%S)"; break
    fi
    sleep 3
  done ) &
TREE_REAPER=$!
set +e
wait $MKPID
MKRC=$?
set -e
kill $REAPER $TREE_REAPER 2>/dev/null || true
wait $REAPER $TREE_REAPER 2>/dev/null || true
tail -60 /tmp/mkarchiso.log
[ "$MKRC" = 0 ] || { echo "mkarchiso failed rc=$MKRC"; grep -iE "error|failed" /tmp/mkarchiso.log | grep -viE "libgpg-error|perl-error|xcb-util-errors|-error-" | tail -20; exit 1; }
ISO=$(find "$ISO_TMP" -maxdepth 1 -name '*.iso' | head -1)
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
  'usr/lib/initcpio/hooks/archiso_bnasec' 'usr/bin/sudo' 'usr/bin/su' \
  'usr/bin/mount' 'usr/bin/passwd' 'usr/share/bnasec' \
  > /tmp/unsquashfs.log 2>&1 || { tail -20 /tmp/unsquashfs.log; exit 1; }
FAIL=0
[ -d "$CHECK/home/bna/.config/hypr" ] && echo "PASS hypr dots baked ($(find "$CHECK/home/bna/.config/hypr" -type f | wc -l) files)" || { echo "FAIL hypr dots missing"; FAIL=1; }
[ -x "$CHECK/usr/local/bin/bnasec-toolbox" ] && echo "PASS toolbox baked" || { echo "FAIL toolbox missing/not-exec — context:"; ls -la "$CHECK/usr/local/bin/" 2>&1; cat "$CHECK/usr/share/bnasec/BUILD-INFO" 2>&1; unsquashfs -ll "$SFS" 2>/dev/null | grep -E 'usr/local|BUILD-INFO' | head -10; FAIL=1; }
[ -d "$CHECK/usr/share/sddm/themes/Corners" ] && echo "PASS sddm theme baked" || { echo "FAIL sddm theme missing"; FAIL=1; }
grep -q chaotic-aur "$CHECK/etc/pacman.conf" && echo "PASS chaotic in live pacman.conf" || { echo "FAIL chaotic missing from pacman.conf"; FAIL=1; }
[ -f "$CHECK/usr/lib/initcpio/hooks/archiso_bnasec" ] && echo "PASS persist hook baked" || { echo "FAIL persist hook missing"; FAIL=1; }
# setuid: count only the binaries we deliberately extracted — the old find over
# "$CHECK/usr" saw just the extracted subset, so the threshold read as 1 and
# false-failed. Arch ships sudo/su/mount/passwd as 4755.
SUID=$(find "$CHECK/usr/bin" -maxdepth 1 -perm -4000 -type f 2>/dev/null | wc -l)
echo "setuid binaries found: $(find "$CHECK/usr/bin" -maxdepth 1 -perm -4000 -type f 2>/dev/null | tr '\n' ' ')"
[ "$SUID" -ge 4 ] && echo "PASS setuid binaries intact ($SUID)" || { echo "FAIL setuid count low ($SUID)"; FAIL=1; }
[ "$FAIL" = 0 ] || { echo "ASSERTIONS FAILED"; exit 1; }

# free the work tree BEFORE moving the 2.6GB ISO out of tmpfs — the sfs + tree
# are the biggest disk chunks and the assertions are done with them
rm -rf "$WORK" /tmp/sfs-check
echo "work tree freed. free: $(df -h /mnt | awk 'NR==2{print $4}')"
mv -f "$ISO" "$OUT"/ || { echo "!! ISO move out of tmpfs failed"; exit 1; }
umount "$ISO_TMP" 2>/dev/null || true
ISO="$OUT/$(basename "$ISO")"
sha256sum "$ISO" > "$ISO.sha256"
echo "== BUILD COMPLETE: $ISO =="
