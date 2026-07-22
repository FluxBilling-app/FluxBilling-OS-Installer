#!/usr/bin/env bash
# Assert that every kernel/initrd the boot menu fetches is also mirrored by
# src/sign-boot-images.sh.
#
# The two lists are written for different purposes - one boots the image, the
# other signs it - and nothing but this check ties them together. When they
# drift, the failure is silent in both directions: the signer keeps mirroring
# a release the menu no longer boots, and the menu boots a release that will
# never appear in a signed release.
#
# Needs no network, so it gates every push (build-test.yml) as well as the
# weekly watchdog (upstream-watch.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

# The 22.04 GitHub assets are exempt by design: the manifest reaches that
# release through an `iso:` row that extracts the images from the official
# Ubuntu ISO instead of fetching them loose.
./src/sign-boot-images.sh --dry-run \
  | awk '$2 != "iso" {print $3}' | sed 's|^[a-z]*://||' | sort -u > /tmp/flux-manifest-paths.$$
trap 'rm -f /tmp/flux-manifest-paths.$$' EXIT

fail=0
while read -r _ url; do
  case "$url" in *github.com/*) continue ;; esac
  p=${url#*://}
  grep -qxF "$p" /tmp/flux-manifest-paths.$$ || {
    echo "menu fetches $url but src/sign-boot-images.sh does not mirror it" >&2
    fail=1; }
done < <(./src/menu-urls.sh | grep '^ipxe ')

[ "$fail" = 0 ] && echo "menu and signing manifest agree"
exit "$fail"
