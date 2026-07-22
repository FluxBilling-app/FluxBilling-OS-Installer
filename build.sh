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

  # fluxcidr command is already baked into image_cmd.c in the builder image.

  cd /ipxe/src
  make -j"$(nproc)" bin/ipxe.lkrn EMBED="$EMBEDLIST"
  make -j"$(nproc)" bin-x86_64-efi/ipxe.efi EMBED="$EMBEDLIST"

  ./util/genfsimg -o /w/FluxBilling-OS-Installer_v1.0.iso bin/ipxe.lkrn bin-x86_64-efi/ipxe.efi
  ls -la /w/FluxBilling-OS-Installer_v1.0.iso
'
echo "Done: FluxBilling-OS-Installer_v1.0.iso"
