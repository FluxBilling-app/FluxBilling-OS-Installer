#!/usr/bin/env bash
# Prove src/boot-pairing-check.sh still FAILS on the breakages it exists to
# catch. A gate that has quietly stopped checking reads exactly like a gate
# that passes, which is how the 2026-09-15 casper drift survived a green
# watchdog for months - src/menu-urls.sh was rebuilding the ISO URL from the
# point release instead of reading it out of the menu, so the probe hit a URL
# nothing boots and reported it healthy.
#
# Each case mutates a COPY of the menu (or manifest) and asserts a specific
# failure line. Offline by default so it can gate every push; --net adds the
# cases that need upstream (content comparison against a real ISO).
set -uo pipefail
cd "$(dirname "$0")/.."
NET=0
[ "${1:-}" = "--net" ] && NET=1
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
rc=0

expect_fail() { # expect_fail <name> <grep-pattern> <menu> [manifest]
  local name=$1 pat=$2 menu=$3 man=${4:-src/sign-boot-images.sh} out
  out=$(MENU="$menu" MANIFEST="$man" ./src/boot-pairing-check.sh 2>&1)
  if [ $? -eq 0 ]; then
    echo "SELFTEST FAIL  $name: the gate PASSED a menu it must reject"; rc=1; return
  fi
  if grep -qE -- "$pat" <<<"$out"; then
    echo "SELFTEST OK    $name"
  else
    echo "SELFTEST FAIL  $name: gate failed, but not with '$pat'"; sed 's/^/    /' <<<"$out"; rc=1
  fi
}

# 1. A distro added to the menu with no rule written for it. This is the case
#    that makes the whole thing hold: a future entry cannot ship unverified.
sed 's|^item leap156 .*|item fedora42 Fedora 42\n&|' fluxbilling.ipxe > "$WORK/new-entry.ipxe"
expect_fail "unrules-entry" "no pairing rule" "$WORK/new-entry.ipxe"

# 2. A new boot path (kernel line) that no rule claims.
awk '1; /^kernel --name kboot \$\{flux_boot\}\/\$\{flux_rel\}\/proxmox/{print "kernel --name kboot http://example.net/linux initrd=initrd.magic"}' \
  fluxbilling.ipxe > "$WORK/new-path.ipxe"
expect_fail "unrules-path" "kernel lines in .*rules cover" "$WORK/new-path.ipxe"

# 3. A same-var pairing split in two - anaconda pointed at a mirror that is no
#    longer the tree the kernel came from.
sed 's|inst.repo=https://${ks_base}/BaseOS/x86_64/os/|inst.repo=https://mirror.example.net/BaseOS/x86_64/os/|' \
  fluxbilling.ipxe > "$WORK/split-repo.ipxe"
expect_fail "split-anaconda" "no longer derives from" "$WORK/split-repo.ipxe"

# 4. Same, on the Debian d-i side.
sed 's|mirror/http/hostname=${di_host}|mirror/http/hostname=deb.example.net|g' \
  fluxbilling.ipxe > "$WORK/split-di.ipxe"
expect_fail "split-debian" "no longer derives from" "$WORK/split-di.ipxe"

# 5. The Proxmox ISO pin moved in the menu but not in the signing manifest, so
#    the kernel would come from one ISO and the installer payload from another.
sed 's|^set pve9_iso .*|set pve9_iso proxmox-ve_9.3-1.iso|' fluxbilling.ipxe > "$WORK/pve-pin.ipxe"
expect_fail "pve-pin-split" "extracts a different ISO" "$WORK/pve-pin.ipxe"

# 6. An image the menu boots that the manifest does not mirror at all.
sed '/^ubuntu-20.04 /d' src/sign-boot-images.sh > "$WORK/manifest-gap.sh"
expect_fail "unmirrored-image" "no 'ubuntu-20.04' row" fluxbilling.ipxe "$WORK/manifest-gap.sh"

if [ "$NET" = 1 ]; then
  # 7. The real 2026-09-15 bug: casper pointed back at the frozen point-release
  #    ISO while the netboot tree has moved on. Needs upstream to compare.
  sed 's|^set img2404 .*|set img2404 ${ubu_rel}/${rel2404}/ubuntu-${rel2404}-live-server-amd64.iso|' \
    fluxbilling.ipxe > "$WORK/frozen-iso.ipxe"
  expect_fail "casper-drift" "is NOT in the ISO" "$WORK/frozen-iso.ipxe"
fi

# And the real menu must still pass, or every case above proves nothing.
if MENU=fluxbilling.ipxe ./src/boot-pairing-check.sh >/dev/null 2>&1; then
  echo "SELFTEST OK    live-menu-passes"
else
  echo "SELFTEST FAIL  live-menu-passes: the shipping menu does not pass its own gate"; rc=1
fi

[ "$rc" = 0 ] && echo "pairing selftest: OK" || echo "pairing selftest: FAIL"
exit "$rc"
