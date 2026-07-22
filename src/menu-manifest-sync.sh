#!/usr/bin/env bash
# Assert that the boot menu and the signing manifest describe the same set of
# kernel/initrd images - in BOTH directions.
#
# The two lists are written for different purposes - one boots the image, the
# other signs it - and nothing but this check ties them together. When they
# drift, the failure is silent either way: the signer keeps mirroring a
# release the menu no longer boots (so a release is cut containing images
# nobody uses), and the menu boots a release that will never appear in a
# signed release (so imgverify has nothing to check it against).
#
# Needs no network, so it gates every push (build-test.yml) as well as the
# weekly watchdog (upstream-watch.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

# The 22.04 GitHub assets are exempt by design on the menu side: the manifest
# reaches that release through an `iso:` row that extracts the images from the
# official Ubuntu ISO instead of fetching them loose.
#
# Both lists are materialised into variables FIRST. Reading them straight into
# a loop via process substitution would hide the producer's exit status from
# both `set -e` and `pipefail` - and menu-urls.sh is *designed* to die on a
# menu it cannot fully parse, so this assertion would have printed "agree" and
# exited 0 at exactly the moment it was most needed.
menu_urls=$(./src/menu-urls.sh)
manifest_out=$(./src/sign-boot-images.sh --dry-run)

menu_paths=$(printf '%s\n' "$menu_urls" \
  | awk '$1 == "ipxe" {print $2}' \
  | grep -v 'github\.com/' \
  | sed 's|^[a-z]*://||' | sort -u)

manifest_paths=$(printf '%s\n' "$manifest_out" \
  | awk '$2 != "iso" {print $3}' \
  | sed 's|^[a-z]*://||' | sort -u)

[ -n "$menu_paths" ]     || { echo "no ipxe rows from menu-urls.sh" >&2; exit 1; }
[ -n "$manifest_paths" ] || { echo "no rows from sign-boot-images.sh --dry-run" >&2; exit 1; }

fail=0
while read -r p; do
  [ -n "$p" ] || continue
  echo "the menu fetches $p but src/sign-boot-images.sh does not mirror it" >&2
  fail=1
done <<< "$(comm -23 <(printf '%s\n' "$menu_paths") <(printf '%s\n' "$manifest_paths"))"

while read -r p; do
  [ -n "$p" ] || continue
  echo "src/sign-boot-images.sh mirrors $p but the menu no longer fetches it" >&2
  fail=1
done <<< "$(comm -13 <(printf '%s\n' "$menu_paths") <(printf '%s\n' "$manifest_paths"))"

[ "$fail" = 0 ] && echo "menu and signing manifest agree ($(printf '%s\n' "$menu_paths" | wc -l | tr -d ' ') images)"
exit "$fail"
