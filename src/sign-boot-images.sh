#!/usr/bin/env bash
# Mirror every kernel/initrd this menu boots, sign each one, and stage the
# result for a GitHub release on this repo.
#
# WHY THIS EXISTS
# ---------------
# iPXE fetches kernel and initrd itself, and it cannot verify them over the
# wire: its default trust store holds one fingerprint (the iPXE root CA, see
# crypto/rootcert.c), so any public certificate chain is completed by pulling
# a cross-signed certificate over PLAIN HTTP from ca.ipxe.org. HTTPS there
# buys no verified transport, only a third-party boot dependency.
#
# The fix is to stop trusting the transport and verify the payload instead:
# sign each image with our own key, bake OUR CA fingerprint into the iPXE
# binary with TRUST=, and have the menu run `imgverify` after each fetch. A
# tampered or truncated image then fails closed, over plain HTTP, with no
# dependency on anyone else's PKI.
#
# Only kernel+initrd are mirrored - roughly 350 MB for all 19 pairs, versus
# ~10 GB for the ISOs. Everything bulky (the Ubuntu ISO, the anaconda stage2
# and repos, the Leap squashfs) stays on the official mirrors over HTTPS,
# where the installers validate properly with a full CA bundle.
#
# USAGE
#   ./src/sign-boot-images.sh            # mirror + sign into out/boot-images
#   ./src/sign-boot-images.sh --dry-run  # list what would be fetched
#
# Needs certs/flux-codesign.{crt,key} and certs/flux-ca.crt - see
# docs/SIGNED-BOOT.md for the one-time key generation. Private keys are
# gitignored and must never be committed.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=out/boot-images
CERTDIR=certs
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# name                     kernel URL                                                                                        initrd URL
# Kept deliberately in sync with the URL block at the top of fluxbilling.ipxe.
read -r -d '' MANIFEST <<'EOF' || true
# 22.04.5 predates Canonical's netboot/ tree (404 there and for every /22.04/
# variant), so its images are extracted from the official ISO instead. The
# iso: prefix switches this row to that path - both files come out of the very
# ISO the menu boots, so they cannot be out of step with it.
ubuntu-22.04  iso:https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-live-server-amd64.iso  iso:
ubuntu-24.04  https://releases.ubuntu.com/24.04.4/netboot/amd64/linux  https://releases.ubuntu.com/24.04.4/netboot/amd64/initrd
ubuntu-25.10  https://releases.ubuntu.com/25.10/netboot/amd64/linux  https://releases.ubuntu.com/25.10/netboot/amd64/initrd
ubuntu-26.04  https://releases.ubuntu.com/26.04/netboot/amd64/linux  https://releases.ubuntu.com/26.04/netboot/amd64/initrd
ubuntu-20.04  https://archive.ubuntu.com/ubuntu/dists/focal-updates/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/linux  https://archive.ubuntu.com/ubuntu/dists/focal-updates/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/initrd.gz
ubuntu-18.04  https://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/linux       https://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/initrd.gz
debian-13     https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux    https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz
debian-12     https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux  https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz
debian-11     https://deb.debian.org/debian/dists/bullseye/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux  https://deb.debian.org/debian/dists/bullseye/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz
alma-10       https://repo.almalinux.org/almalinux/10/BaseOS/x86_64/os/images/pxeboot/vmlinuz  https://repo.almalinux.org/almalinux/10/BaseOS/x86_64/os/images/pxeboot/initrd.img
alma-9        https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/images/pxeboot/vmlinuz   https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/images/pxeboot/initrd.img
alma-8        https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/images/pxeboot/vmlinuz   https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/images/pxeboot/initrd.img
rocky-10      https://download.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/images/pxeboot/vmlinuz  https://download.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/images/pxeboot/initrd.img
rocky-9       https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/images/pxeboot/vmlinuz   https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/images/pxeboot/initrd.img
rocky-8       https://download.rockylinux.org/pub/rocky/8/BaseOS/x86_64/os/images/pxeboot/vmlinuz   https://download.rockylinux.org/pub/rocky/8/BaseOS/x86_64/os/images/pxeboot/initrd.img
centos-10     https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/images/pxeboot/vmlinuz  https://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os/images/pxeboot/initrd.img
centos-9      https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/images/pxeboot/vmlinuz   https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/images/pxeboot/initrd.img
leap-15.6     https://download.opensuse.org/distribution/leap/15.6/repo/oss/boot/x86_64/loader/linux  https://download.opensuse.org/distribution/leap/15.6/repo/oss/boot/x86_64/loader/initrd
leap-16.0     https://download.opensuse.org/distribution/leap/16.0/repo/oss/boot/x86_64/loader/linux  https://download.opensuse.org/distribution/leap/16.0/repo/oss/boot/x86_64/loader/initrd
# Oracle publishes NO loose boot files and NO install tree - the boot ISO
# under yum.oracle.com/ISOS is the only official source, so kernel + initrd
# + the anaconda stage2 (install.img) all come out of it. The elboot: prefix
# extracts all three; the stage2 is staged under stage2-olN/ and released on
# the slash tag <flux_rel>-olN/images so inst.stage2 resolves (see the
# flux_boot note in fluxbilling.ipxe). Pin the freshest update level - the
# initrd and the rolling baseos/latest repo drift apart like every other
# anaconda pair (see REFRESH CADENCE below).
oracle-10     elboot:https://yum.oracle.com/ISOS/OracleLinux/OL10/u2/x86_64/OracleLinux-R10-U2-x86_64-boot.iso  elboot:
oracle-9      elboot:https://yum.oracle.com/ISOS/OracleLinux/OL9/u8/x86_64/OracleLinux-R9-U8-x86_64-boot.iso  elboot:
oracle-8      elboot:https://yum.oracle.com/ISOS/OracleLinux/OL8/u10/x86_64/OracleLinux-R8-U10-x86_64-boot.iso  elboot:
# Proxmox publishes only the install ISO. pveiso: extracts /boot/linux26 and
# /boot/initrd.img, and additionally signs the WHOLE ISO (detached,
# proxmox-N-iso.sig) - the menu fetches that ISO over plain http, forced by
# a download.proxmox.com certificate that does not name the host, so the
# signature is what lets the future imgverify wiring pin its content. Keep
# these rows in step with the pveN_iso pins in fluxbilling.ipxe.
proxmox-9     pveiso:https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso  pveiso:
proxmox-8     pveiso:https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso  pveiso:
EOF

if [ "$DRY" = 0 ]; then
  for f in flux-codesign.crt flux-codesign.key flux-ca.crt; do
    [ -r "$CERTDIR/$f" ] || {
      echo "missing $CERTDIR/$f - see docs/SIGNED-BOOT.md" >&2; exit 1; }
  done
fi

# Inside the guard: --dry-run only prints the manifest, and the watchdog runs
# it weekly. Truncating SHA256SUMS there would wipe the checksum list of a
# staged release - the very baseline the drift check compares against.
if [ "$DRY" = 0 ]; then
  mkdir -p "$OUT"
  : > "$OUT/SHA256SUMS"
fi

sign() {
  # iPXE verifies a detached CMS SignedData in DER form (crypto/cms.c).
  openssl cms -sign -binary -noattr -in "$1" \
    -signer "$CERTDIR/flux-codesign.crt" -inkey "$CERTDIR/flux-codesign.key" \
    -certfile "$CERTDIR/flux-ca.crt" -outform DER -out "$1.sig"
}

# Build the AUTOMATED-mode variant of a d-i initrd: the answer files ride as
# an uncompressed cpio member PREPENDED to the vendor image, with the preseed
# at /preseed.cfg - the AUTO-LOAD name. Both halves of that are load-bearing:
#
#  - Prepended, because [plain cpio][vendor gzip] is the one concatenation
#    layout the old 4.15/5.4 kernels are guaranteed to unpack (verified both
#    ways on the real bionic netboot kernel - everything AFTER the vendor
#    member is discarded with "junk in compressed archive").
#  - /preseed.cfg, because Ubuntu's legacy d-i never reads preseed/file= at
#    all: with the file verifiably present as /flux-preseed.cfg the install
#    still stalled at "Select a language" and then "Partition disks", and
#    renaming it to the auto-load name made the same install run end to end.
#
# The auto-load name is exactly why this is a SEPARATE asset: /preseed.cfg
# is loaded unconditionally, so baking it into the one initrd both modes
# boot would re-arm automated partitioning on a MANUAL install. The menu
# fetches ubuntu-<ver>-initrd (verbatim vendor copy) in manual mode and
# ubuntu-<ver>-auto-initrd (this one) in automated mode - see :boot_di_flux.
# cpio runs in the builder container, not on the host: macOS ships BSD cpio,
# and a subtly different archive here would be a silently broken initrd.
build_di_auto_initrd() {
  local vendor=$1 auto=$2 name=$3
  # 20.04 also carries /flux-virtio_blk.ko: its legacy netboot d-i cannot be
  # made to load virtio_blk any polite way (anna/choose_modules is silently
  # dropped, anna-install exits 0 without installing - both matrix-proven),
  # so the module is pulled out of the mirror's own virtio-modules udeb here
  # and the preseed's partman/early_command insmods it. The udeb version is
  # resolved from the mirror's Packages index against the netboot kernel, so
  # a kernel bump breaks the build loudly instead of the install silently.
  local getmod=""
  if [ "$name" = ubuntu-20.04 ]; then getmod=1; fi
  docker run --rm --platform linux/amd64 \
    -v "$PWD/src":/s:ro -v "$PWD/$OUT":/o -e GETMOD="$getmod" fluxbilling-builder \
    bash -euc 'd=$(mktemp -d)
      cp /s/preseed.cfg "$d/preseed.cfg"
      cp /s/flux-scrub  "$d/flux-scrub"
      cp /s/flux-scrub.service "$d/flux-scrub.service"
      files="preseed.cfg\nflux-scrub\nflux-scrub.service\n"
      if [ -n "$GETMOD" ]; then
        # The module comes out of the full linux-modules POOL deb, not a -di
        # udeb: the netboot kernel is so old that its block-modules udeb has
        # been pruned from every dists/ index (only the frozen netboot meta
        # still Depends on it), while pool debs stay fetchable. The kernel
        # version is read from the vendor initrd itself and the deb filename
        # from the pool listing, so a netboot kernel bump re-resolves
        # automatically or fails loudly - never ships a stale module.
        M=http://archive.ubuntu.com/ubuntu
        kver=$(zcat /o/.flux-vendor-initrd.gz 2>/dev/null | cpio -it --quiet 2>/dev/null | sed -n "s|^lib/modules/\([^/]*\)/.*|\1|p" | head -n1)
        [ -n "$kver" ] || { echo "FATAL: cannot read kernel version out of the 20.04 vendor initrd" >&2; exit 1; }
        fn=$(curl -fsSL "$M/pool/main/l/linux/" | grep -o "linux-modules-${kver}_[^\"]*_amd64\.deb" | head -n1)
        [ -n "$fn" ] || { echo "FATAL: no linux-modules deb for netboot kernel $kver in the pool" >&2; exit 1; }
        curl -fsSL -o "$d/lm.deb" "$M/pool/main/l/linux/$fn"
        ( cd "$d" && ar x lm.deb && tar xf data.tar.* ./lib/modules/$kver/kernel/drivers/block/virtio_blk.ko )
        ko="$d/lib/modules/$kver/kernel/drivers/block/virtio_blk.ko"
        [ -s "$ko" ] || { echo "FATAL: virtio_blk.ko missing from $fn" >&2; exit 1; }
        cp "$ko" "$d/flux-virtio_blk.ko"
        rm -rf "$d/lib" "$d"/lm.deb "$d"/data.tar.* "$d"/control.tar.* "$d"/debian-binary
        files="${files}flux-virtio_blk.ko\n"
      fi
      ( cd "$d" && printf "$files" | cpio -o -H newc --quiet ) > /o/.flux-di.cpio'
  cat "$OUT/.flux-di.cpio" "$vendor" > "$auto"
  rm -f "$OUT/.flux-di.cpio" "$OUT/.flux-vendor-initrd.gz"
}

# Pull casper/vmlinuz + casper/initrd straight out of an official ISO, for the
# releases Canonical never published a netboot/ tree for. xorriso lives in the
# builder image, so this runs there rather than assuming a host toolchain; the
# names are DISCOVERED rather than hardcoded, because casper has spelled them
# vmlinuz/vmlinuz.efi/initrd/initrd.lz across releases - a wrong guess would
# otherwise fail late and silently.
extract_from_iso() {
  local url=$1 name=$2 iso="$OUT/.$name.iso"
  echo ">> $name: downloading official ISO (this is a few GB)"
  curl -fSL --retry 3 -o "$iso" "$url"
  echo ">> $name: extracting casper kernel + initrd"
  docker run --rm --platform linux/amd64 -v "$PWD/$OUT":/o fluxbilling-builder \
    bash -euc '
      n=$1
      list=$(xorriso -indev "/o/.$n.iso" -find /casper 2>/dev/null)
      k=$(printf "%s\n" "$list" | sed -n "s|^.*'\''\(/casper/vmlinuz[^'\'']*\)'\''.*$|\1|p" | head -n1)
      i=$(printf "%s\n" "$list" | sed -n "s|^.*'\''\(/casper/initrd[^'\'']*\)'\''.*$|\1|p" | head -n1)
      [ -n "$k" ] && [ -n "$i" ] || { echo "casper kernel/initrd not found in ISO" >&2; exit 1; }
      echo "   found $k and $i"
      xorriso -osirrox on -indev "/o/.$n.iso" \
        -extract "$k" "/o/$n-vmlinuz" -extract "$i" "/o/$n-initrd"
    ' _ "$name"
  rm -f "$iso"
}

# Pull kernel + initrd (+ stage2) out of an EL boot ISO - Oracle's only
# official packaging of them. Fixed paths, not discovery: every EL boot ISO
# spells them images/pxeboot/{vmlinuz,initrd.img} and images/install.img,
# and xorriso -extract fails loudly if that ever changes.
extract_el_boot() {
  local url=$1 name=$2 iso="$OUT/.$name.iso" v=${2#oracle-}
  echo ">> $name: downloading official boot ISO (~1-1.5 GB)"
  curl -fSL --retry 3 -o "$iso" "$url"
  mkdir -p "$OUT/stage2-ol$v"
  docker run --rm --platform linux/amd64 -v "$PWD/$OUT":/o fluxbilling-builder \
    bash -euc '
      n=$1; v=$2
      xorriso -osirrox on -indev "/o/.$n.iso" \
        -extract /images/pxeboot/vmlinuz "/o/$n-vmlinuz" \
        -extract /images/pxeboot/initrd.img "/o/$n-initrd" \
        -extract /images/install.img "/o/stage2-ol$v/install.img"
    ' _ "$name" "$v"
  rm -f "$iso"
}

# Carry the automated-install hook across the installer's switch_root.
#
# The menu cpio-injects src/pve-bashrc as the initramfs /etc/bash.bashrc so
# that when the stock installer drops to its "no answer file" debug shell -
# interactive bash - it sources the hook, which generates the answers and
# exits. But the Proxmox init switch_roots into the installer squashfs BEFORE
# unconfigured.sh runs (verified: `exec switch_root .../.installer-mp .../
# unconfigured.sh` in the vendor init), and switch_root discards the initramfs
# - so the debug shell there sources the squashfs's own stock /etc/bash.bashrc
# and the hook never runs. A cpio-injected file simply cannot reach past the
# pivot. This patches the vendor init to copy the hook into the writable
# overlay root the init has already built (lowerdir=squashfs, upperdir=tmpfs),
# right where it copies /etc/hostid, so it survives into the installer system.
# Anchored on that copy; if the installer layout ever changes it FAILS LOUD
# rather than silently shipping an initrd whose automated mode is dead.
patch_pve_initrd() {
  local name=$1
  cat > "$OUT/.flux-pve-patch.sh" <<'PATCH'
#!/bin/bash
set -euo pipefail
n=$1
work=$(mktemp -d)
zstd -dc "/o/$n-initrd" | ( cd "$work" && cpio -idm --quiet )
init="$work/init"
[ -f "$init" ] || { echo "FATAL: $n initrd has no /init" >&2; exit 1; }
# Replace the vendor /etc/bash.bashrc INSIDE the initrd, do not rely on the
# menu's cpio injection: the kernel decompresses the zstd vendor member and
# then DISCARDS everything iPXE appended after it ("junk" - same trailing-
# member behaviour that eats the d-i preseed on old kernels), so the
# injected hook never lands and the stock file wins. Baking it into the
# asset is the only placement that provably survives, and the init snippet
# below then carries it across switch_root.
[ -s /s/pve-bashrc ] || { echo "FATAL: src/pve-bashrc missing from the build context" >&2; exit 1; }
mkdir -p "$work/etc"
cp /s/pve-bashrc "$work/etc/bash.bashrc"
if grep -q 'FluxBilling: carry the automated-install hook' "$init"; then
  echo "   $n: init already patched"
else
  grep -q 'cp /.cd-info /mnt/.installer-mp/' "$init" || {
    echo "FATAL: $n init lacks the '/.cd-info -> overlay root' copy anchor -" >&2
    echo "       the Proxmox installer layout changed; refusing to ship an" >&2
    echo "       initrd whose automated install is silently broken." >&2
    exit 1; }
  cat > "$work/.snip" <<'SNIP'
    # FluxBilling: carry the automated-install hook across switch_root. The boot
    # menu cpio-injects src/pve-bashrc as the initramfs /etc/bash.bashrc, but the
    # switch_root below drops the initramfs - so unconfigured.sh's debug shell
    # would source the squashfs's stock file and the hook (which writes
    # /run/automatic-installer-answers) would never run. Copy it into the
    # writable overlay root here, exactly as /etc/hostid is copied just above.
    # Guarded on the arm flag so a non-flux boot of this initrd is untouched.
    if grep -qw fluxpveauto=1 /proc/cmdline 2>/dev/null && [ -f /etc/bash.bashrc ]; then
        cp /etc/bash.bashrc /mnt/.installer-mp/etc/bash.bashrc
        echo "FluxBilling: automated-install hook staged into the installer root"
    fi
SNIP
  awk 'i==0 && /cp \/\.cd-info \/mnt\/\.installer-mp\//{print; while((getline l < snip)>0) print l; i=1; next}{print}' \
      snip="$work/.snip" "$init" > "$init.new"
  mv "$init.new" "$init"; chmod 755 "$init"; rm -f "$work/.snip"
fi
grep -q 'cp /etc/bash.bashrc /mnt/.installer-mp/etc/bash.bashrc' "$init" || {
  echo "FATAL: $n init patch did not apply" >&2; exit 1; }
( cd "$work" && find . | cpio -o -H newc --quiet | zstd -q -19 -T0 ) > "/o/$n-initrd.new"
mv "/o/$n-initrd.new" "/o/$n-initrd"
rm -rf "$work"
echo "   $n: initrd patched for automated install ($(du -h /o/$n-initrd | cut -f1))"
PATCH
  docker run --rm --platform linux/amd64 \
    -v "$PWD/src":/s:ro -v "$PWD/$OUT":/o fluxbilling-builder \
    bash /o/.flux-pve-patch.sh "$name"
  rm -f "$OUT/.flux-pve-patch.sh"
}

# Pull the Proxmox installer kernel + initrd out of the official ISO, then
# sign the ISO ITSELF (detached) before deleting it: the menu has to fetch it
# over plain http (the download host's certificate does not name the host),
# so the staged .sig is the only integrity anchor that payload can ever get.
# The download here IS verified - enterprise.proxmox.com presents a valid
# certificate for the same /iso/ tree.
extract_pve() {
  local url=$1 name=$2 iso="$OUT/.$name.iso"
  echo ">> $name: downloading official ISO (~1.5-2 GB)"
  curl -fSL --retry 3 -o "$iso" "$url"
  docker run --rm --platform linux/amd64 -v "$PWD/$OUT":/o fluxbilling-builder \
    bash -euc '
      n=$1
      xorriso -osirrox on -indev "/o/.$n.iso" \
        -extract /boot/linux26 "/o/$n-vmlinuz" \
        -extract /boot/initrd.img "/o/$n-initrd"
    ' _ "$name"
  # The stock initrd's automated mode is dead without this - see the note above.
  patch_pve_initrd "$name"
  sign "$iso"
  mv "$iso.sig" "$OUT/$name-iso.sig"
  rm -f "$iso"
}

while read -r name kurl iurl; do
  # Blank lines and comments live inside the manifest heredoc - skip them, or
  # every comment word gets treated as a URL.
  case "${name:-}" in ''|\#*) continue ;; esac

  # All three extraction prefixes print the type "iso" in --dry-run: that is
  # the column menu-manifest-sync.sh keys its exemption on, and to the sync
  # they are the same thing - images that come out of an official ISO rather
  # than a loose URL the menu also fetches.
  if [ "${kurl#iso:}" != "$kurl" ]; then
    if [ "$DRY" = 1 ]; then
      printf '%-14s %-8s %s\n' "$name" "iso" "${kurl#iso:}"
      continue
    fi
    extract_from_iso "${kurl#iso:}" "$name"
    for kind in vmlinuz initrd; do
      sign "$OUT/$name-$kind"
      ( cd "$OUT" && sha256sum "$name-$kind" >> SHA256SUMS )
    done
    continue
  fi

  if [ "${kurl#elboot:}" != "$kurl" ]; then
    if [ "$DRY" = 1 ]; then
      printf '%-14s %-8s %s\n' "$name" "iso" "${kurl#elboot:}"
      continue
    fi
    extract_el_boot "${kurl#elboot:}" "$name"
    v=${name#oracle-}
    for kind in vmlinuz initrd; do
      sign "$OUT/$name-$kind"
      ( cd "$OUT" && sha256sum "$name-$kind" >> SHA256SUMS )
    done
    sign "$OUT/stage2-ol$v/install.img"
    ( cd "$OUT" && sha256sum "stage2-ol$v/install.img" >> SHA256SUMS )
    continue
  fi

  if [ "${kurl#pveiso:}" != "$kurl" ]; then
    if [ "$DRY" = 1 ]; then
      printf '%-14s %-8s %s\n' "$name" "iso" "${kurl#pveiso:}"
      continue
    fi
    extract_pve "${kurl#pveiso:}" "$name"
    for kind in vmlinuz initrd; do
      sign "$OUT/$name-$kind"
      ( cd "$OUT" && sha256sum "$name-$kind" >> SHA256SUMS )
    done
    ( cd "$OUT" && sha256sum "$name-iso.sig" >> SHA256SUMS )
    continue
  fi

  for pair in "vmlinuz:$kurl" "initrd:$iurl"; do
    kind=${pair%%:*}; url=${pair#*:}
    dest="$OUT/$name-$kind"
    if [ "$DRY" = 1 ]; then
      # The 18.04/20.04 rows print as "src", not vmlinuz/initrd: the menu
      # boots the flux-prepended RELEASE ASSET (see :boot_di_flux), so these
      # URLs are build inputs, not images the menu fetches - the manifest
      # sync exempts "src" rows exactly like the iso-extraction ones.
      dk=$kind
      case "$name" in ubuntu-18.04|ubuntu-20.04) dk=src ;; esac
      printf '%-14s %-8s %s\n' "$name" "$dk" "$url"
      continue
    fi
    echo ">> $name-$kind"
    curl -fSL --retry 3 -o "$dest" "$url"
    sign "$dest"
    ( cd "$OUT" && sha256sum "$name-$kind" >> SHA256SUMS )
    # The 18.04/20.04 rows ALSO stage an -auto-initrd variant carrying the
    # answer files - see build_di_auto_initrd() for why it must be a
    # separate asset and why the vendor copy alone cannot be automated.
    case "$name-$kind" in
      ubuntu-18.04-initrd|ubuntu-20.04-initrd)
        # Staged copy so the container can read the vendor image (it only
        # mounts $OUT) - build_di_auto_initrd cleans it up.
        cp "$dest" "$OUT/.flux-vendor-initrd.gz"
        build_di_auto_initrd "$dest" "$OUT/$name-auto-initrd" "$name"
        sign "$OUT/$name-auto-initrd"
        ( cd "$OUT" && sha256sum "$name-auto-initrd" >> SHA256SUMS )
        ;;
    esac
  done
done <<< "$MANIFEST"

[ "$DRY" = 1 ] && exit 0

# The tag is read from the menu, not invented here: fluxbilling.ipxe pins
# flux_rel, and a release published under any other name would leave the
# menu fetching 404s while this script reports success.
TAG=$(sed -n 's/^set flux_rel //p' fluxbilling.ipxe | head -n1)
[ -n "$TAG" ] || { echo "WARNING: no flux_rel pin found in fluxbilling.ipxe" >&2; TAG="boot-$(date +%Y%m%d)"; }

cat <<EOM

Staged in $OUT ($(du -sh "$OUT" | cut -f1)).

Publish on this repo under the tag the menu already pins (flux_rel = $TAG):

  gh release create '$TAG' $OUT/*-vmlinuz* $OUT/*-initrd* $OUT/*-iso.sig $OUT/SHA256SUMS \\
     --title "Signed boot images $TAG" \\
     --notes "kernel + initrd extracted/mirrored from the official media and signed"

The Oracle stage2 images go on SLASH TAGS - the /images path segment lives
inside the tag so that anaconda's inst.stage2=<base> fetch of
<base>/images/install.img resolves on GitHub's flat release URLs:

  for v in 10 9 8; do
    gh release create "$TAG-ol\$v/images" "$OUT/stage2-ol\$v/install.img" \\
       --title "Oracle Linux \$v stage2 ($TAG)" \\
       --notes "anaconda install.img extracted from the official OL\$v boot ISO"
  done

Then VERIFY the shape GitHub actually serves - once, with:

  curl -fsIL "\$(sed -n 's/^set flux_boot //p' fluxbilling.ipxe)/$TAG-ol9/images/install.img"

If that ever 404s on the slash tag, host <base>/images/install.img on any
static host instead and point the menu's inst.stage2 base at it.

REFRESH CADENCE - this is not fire-and-forget. anaconda's initrd and the
stage2 it pulls from inst.repo come from the same compose; Alma, Rocky and
CentOS Stream roll their repos forward continuously, so a pinned initrd
drifts out of step with a moving repo and eventually fails to start stage2.
Oracle is the same story with one more moving part: the boot ISO pins above
carry an update level (u2/u8/u10) that must track new OL point releases.
The Proxmox rows pin exact ISO versions - keep them in step with the
pveN_iso vars in the menu. Re-run this script and cut a fresh release
whenever a point release lands, or pin inst.repo to a versioned compose
instead of the rolling one.
EOM
