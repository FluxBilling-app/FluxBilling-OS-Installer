#!/usr/bin/env bash
# Build FluxBilling-OS-Installer_v1.0.iso — tiny iPXE provisioning image (~2.4 MB).
#
# The ISO carries ONLY iPXE + menu + config seeds. Kernels, initrds and
# install ISOs are fetched at boot time over the data NIC the operator
# selects in the menu (mgmt/virtual-media port stays light).
#
# Uses the prebaked fluxbilling-builder docker image (toolchain + pinned,
# pre-compiled iPXE with the runtime EMBED signature already warmed). First
# run builds that image (~10 min); afterwards a rebuild takes ~15 seconds —
# only the embedded payload object is regenerated and the images relinked.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "FATAL: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "docker daemon is not running (start Docker Desktop first)"

# Everything that ends up inside the ISO. This repo lives on iCloud Drive,
# which can evict any of these to a placeholder; a placeholder bind-mounted
# into the container reads as empty and ships a silently-broken image. The
# 1-byte read forces iCloud to materialise the file (or fail loudly here).
PAYLOAD=(fluxbilling.ipxe assets/FluxBilling.png assets/agama-leap16.json
         src/preseed.cfg src/99fluxseed src/param.conf src/ks.cfg
         src/autoinst.xml src/50-flux-agama.sh src/flux-scrub
         src/logo-compose.py src/builder.Dockerfile src/fluxcidr_cmd.c)
for f in "${PAYLOAD[@]}"; do
  [ -s "$f" ] || die "payload file missing or empty (iCloud eviction?): $f"
  head -c1 "$f" >/dev/null || die "payload file unreadable (iCloud eviction?): $f"
done

BUILDER=fluxbilling-builder

# Rebuild the builder when it is missing OR when builder.Dockerfile has moved
# on since the image was baked. The Dockerfile carries real product state - the
# iPXE config patches, the brand colour palette - so a "does the image exist"
# check alone silently ships the previous palette for as long as the stale
# image sits in the local cache. The digest is stamped on as a label and
# compared here; changing the Dockerfile is the only thing that triggers the
# ~10 min rebuild.
WANT=$(shasum -a 256 src/builder.Dockerfile | cut -c1-16)
HAVE=$(docker image inspect -f '{{ index .Config.Labels "flux.builder.hash" }}' \
         "$BUILDER" 2>/dev/null || true)

if [ "$WANT" != "$HAVE" ]; then
  echo ">> building $BUILDER image (~10 min; only when builder.Dockerfile changes)"
  docker build --platform linux/amd64 -t "$BUILDER" \
    --label "flux.builder.hash=$WANT" \
    -f src/builder.Dockerfile src
fi

docker run --rm --platform linux/amd64 -v "$PWD":/w "$BUILDER" bash -exc '
  mkdir -p /work

  # logo console background
  python3 /w/src/logo-compose.py /w/assets/FluxBilling.png /work/logo.png

  # embedded payload: menu, logo, d-i preseed, casper seed hook + trigger,
  # kickstart (RHEL family), AutoYaST profile (Leap 15.6).
  # Overwrite the dummy files warmed into /work by the builder image; the
  # EMBEDLIST must match the image exactly so make stays incremental.
  cp /w/fluxbilling.ipxe /w/src/preseed.cfg /w/src/99fluxseed \
     /w/src/param.conf /w/src/ks.cfg /w/src/autoinst.xml \
     /w/src/50-flux-agama.sh /w/assets/agama-leap16.json \
     /w/src/flux-scrub /work/
  EMBEDLIST=/work/fluxbilling.ipxe,/work/logo.png,/work/preseed.cfg,/work/99fluxseed,/work/param.conf,/work/ks.cfg,/work/autoinst.xml,/work/agama-leap16.json,/work/50-flux-agama.sh,/work/flux-scrub

  # Trusted TLS roots, baked in as fingerprints via TRUST=. This is what lets
  # the https fetches iPXE makes (the 22.04.5 GitHub release, the boot-time
  # version manifest at :commit, any mirror that 301s http->https) validate
  # against real public CAs instead of leaning on the ca.ipxe.org crosscert
  # over plain HTTP. Roots come from the Debian ca-certificates package baked
  # into the builder image - no network fetch, fails loudly if a name drifts.
  # certs/flux-ca.crt (the FluxBilling boot CA, public half - see
  # docs/SIGNED-BOOT.md) rides along whenever it exists, which is what makes
  # `imgverify` of signed boot images work with no further build change.
  TRUSTLIST=""
  for c in ISRG_Root_X1 ISRG_Root_X2 \
           DigiCert_Global_Root_CA DigiCert_Global_Root_G2 DigiCert_Global_Root_G3 \
           USERTrust_RSA_Certification_Authority USERTrust_ECC_Certification_Authority \
           GlobalSign_Root_CA GlobalSign_Root_R46 GlobalSign_Root_E46 \
           Amazon_Root_CA_1 Amazon_Root_CA_2 Amazon_Root_CA_3 Amazon_Root_CA_4 \
           Comodo_AAA_Services_root; do
    f=/usr/share/ca-certificates/mozilla/$c.crt
    [ -s "$f" ] || { echo "FATAL: root cert $c missing from ca-certificates" >&2; exit 1; }
    cp "$f" "/work/root-$c.crt"
    TRUSTLIST="$TRUSTLIST,/work/root-$c.crt"
  done
  if [ -s /w/certs/flux-ca.crt ]; then
    cp /w/certs/flux-ca.crt /work/flux-ca.crt
    TRUSTLIST="$TRUSTLIST,/work/flux-ca.crt"
    echo ">> FluxBilling boot CA included in the trust list"
  else
    echo ">> note: certs/flux-ca.crt not present - building without the FluxBilling boot CA (imgverify will not chain until it exists; see docs/SIGNED-BOOT.md)"
  fi
  TRUSTLIST=${TRUSTLIST#,}

  # fluxcidr command is already baked into image_cmd.c in the builder image.

  # CERT= and TRUST= are BOTH required and do different jobs: TRUST= bakes in
  # the SHA-256 fingerprints that define what is trusted, CERT= embeds the
  # certificate BODIES in the certstore. With TRUST= alone iPXE knows the
  # fingerprint but has no copy of the root, so completing a public chain
  # sends it back to fetching a cross-signed cert from ca.ipxe.org over plain
  # HTTP - the very dependency this exists to remove - and TRUST= also
  # REPLACES the built-in iPXE root fingerprint, so that fallback fails too.
  # ~30 KB of certs in a 3 MB ISO buys fully offline chain validation.
  cd /ipxe/src
  make -j"$(nproc)" bin/ipxe.lkrn EMBED="$EMBEDLIST" CERT="$TRUSTLIST" TRUST="$TRUSTLIST"
  make -j"$(nproc)" bin-x86_64-efi/ipxe.efi EMBED="$EMBEDLIST" CERT="$TRUSTLIST" TRUST="$TRUSTLIST"

  ./util/genfsimg -o /w/FluxBilling-OS-Installer_v1.0.iso bin/ipxe.lkrn bin-x86_64-efi/ipxe.efi

  # genfsimg only gets a hybrid MBR from an isohybrid post-pass that is
  # guarded by "isohybrid --version" and SKIPPED SILENTLY when syslinux-utils
  # is missing (see builder.Dockerfile) - the ISO then boots over virtual
  # media but is dead when dd-ed to a USB stick. Fail the build instead.
  sig=$(tail -c +511 /w/FluxBilling-OS-Installer_v1.0.iso | head -c2 | od -An -tx1 | tr -d " ")
  [ "$sig" = "55aa" ] || { echo "FATAL: ISO lacks the hybrid-MBR boot signature (got: $sig)" >&2; exit 1; }

  ls -la /w/FluxBilling-OS-Installer_v1.0.iso
'
echo "Done: FluxBilling-OS-Installer_v1.0.iso"
