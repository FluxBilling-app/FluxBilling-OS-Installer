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

while read -r name kurl iurl; do
  # Blank lines and comments live inside the manifest heredoc - skip them, or
  # every comment word gets treated as a URL.
  case "${name:-}" in ''|\#*) continue ;; esac

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

  for pair in "vmlinuz:$kurl" "initrd:$iurl"; do
    kind=${pair%%:*}; url=${pair#*:}
    dest="$OUT/$name-$kind"
    if [ "$DRY" = 1 ]; then
      printf '%-14s %-8s %s\n' "$name" "$kind" "$url"
      continue
    fi
    echo ">> $name-$kind"
    curl -fSL --retry 3 -o "$dest" "$url"
    sign "$dest"
    ( cd "$OUT" && sha256sum "$name-$kind" >> SHA256SUMS )
  done
done <<< "$MANIFEST"

[ "$DRY" = 1 ] && exit 0

cat <<EOM

Staged in $OUT ($(du -sh "$OUT" | cut -f1)).

Publish as a release on this repo, then point the menu at it:

  gh release create boot-\$(date +%Y%m%d) $OUT/* \\
     --title "Signed boot images \$(date +%Y-%m-%d)" \\
     --notes "kernel + initrd mirrored from the official mirrors and signed"

REFRESH CADENCE - this is not fire-and-forget. anaconda's initrd and the
stage2 it pulls from inst.repo come from the same compose; Alma, Rocky and
CentOS Stream roll their repos forward continuously, so a pinned initrd
drifts out of step with a moving repo and eventually fails to start stage2.
Re-run this script and cut a fresh release whenever a point release lands,
or pin inst.repo to a versioned compose instead of the rolling one.
EOM
