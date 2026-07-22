#!/usr/bin/env bash
# Single source of truth for "what does the boot menu fetch": parse
# fluxbilling.ipxe and print one URL per line, tagged by WHO fetches it.
#
#   ipxe <url>   fetched by iPXE itself (kernel/initrd). Probe these with
#                --max-redirs 0: iPXE follows redirects, but a redirect that
#                flips http->https or moves host silently changes the trust
#                and availability story (see the scheme policy in the menu),
#                so the watchdog treats any 3xx here as a warning.
#   bulk <url>   fetched by the installer (casper/anaconda/linuxrc/dracut)
#                with a full CA bundle - probing with -L matches the client.
#   manifest <url>  the boot-time version manifest iPXE chainloads at :commit.
#                Its failure is deliberately silent in the menu (a fielded ISO
#                must still boot offline), which is exactly why it needs
#                watching HERE - nothing else would ever report it broken.
#
# upstream-watch.yml consumes this instead of carrying its own hand-copied
# list, and cross-checks the ipxe rows against the sign-boot-images.sh
# manifest - so a version bump in the menu can no longer leave the watchdog
# probing stale URLs, and the netbootxyz GitHub assets the 22.04 entry
# actually boots are finally monitored.
#
# Anything this script cannot extract is a hard failure: silently emitting a
# shorter list would read as "everything is covered" when it is not.
set -euo pipefail
cd "$(dirname "$0")/.."
MENU=fluxbilling.ipxe

die() { echo "menu-urls: $*" >&2; exit 1; }

getvar() { # getvar <name> -> value of `set <name> ...`, must exist
  local v
  v=$(sed -n "s/^set $1 //p" "$MENU" | head -n1)
  [ -n "$v" ] || die "no 'set $1' line found in $MENU"
  printf '%s\n' "$v"
}

# --- Ubuntu casper (22.04+) -------------------------------------------------
rel2204=$(getvar rel2204); rel2404=$(getvar rel2404)
rel2510=$(getvar rel2510); rel2604=$(getvar rel2604)
boot2204=$(getvar boot2204)

for rel in "$rel2404" "$rel2510" "$rel2604"; do
  echo "ipxe http://releases.ubuntu.com/$rel/netboot/amd64/linux"
  echo "ipxe http://releases.ubuntu.com/$rel/netboot/amd64/initrd"
done
# 22.04.5: the third-party GitHub release the menu actually boots today
# (kernel is named vmlinuz there - see :ubu2204).
echo "ipxe $boot2204/vmlinuz"
echo "ipxe $boot2204/initrd"
for rel in "$rel2204" "$rel2404" "$rel2510" "$rel2604"; do
  echo "bulk https://releases.ubuntu.com/$rel/ubuntu-$rel-live-server-amd64.iso"
done

# --- d-i: Ubuntu 18.04/20.04 + Debian --------------------------------------
# Each :ubu*/:deb* entry block sets di_host (possibly via a deb*_host var)
# and di_path (possibly containing ${suite}); walk the blocks and resolve.
awk '
  /^:(ubu(2004|1804)|deb[0-9]+)$/ { blk=$0; next }
  blk && /^set suite /   { suite=$3; next }
  blk && /^set di_host / { host=$3; next }
  blk && /^set di_path / { path=$3; next }
  blk && /^goto /        { print blk, (host?host:"-"), (path?path:"-"), (suite?suite:"-")
                           blk=host=path=suite="" }
' "$MENU" > /tmp/di-blocks.$$
# The Debian blocks jump to :deb_di for their shared di_alt/di_path; fetch
# that template separately.
deb_path=$(awk '/^:deb_di$/{f=1} f && /^set di_path /{print $3; exit}' "$MENU")
[ -n "$deb_path" ] || die "no di_path under :deb_di"

n_di=0
while read -r blk host path suite; do
  case "$blk" in
    :ubu*) [ "$host" != - ] && [ "$path" != - ] || die "incomplete d-i block $blk" ;;
    :deb*) # host is ${debNN_host} - resolve; path comes from :deb_di
           var=${host#\$\{}; var=${var%\}}
           host=$(getvar "$var")
           [ "$suite" != - ] || die "no suite in $blk"
           path=${deb_path//\$\{suite\}/$suite} ;;
  esac
  echo "ipxe http://${host}${path}/linux"
  echo "ipxe http://${host}${path}/initrd.gz"
  # apt Release file of the suite d-i is preseeded with, same host
  rel_path=$(printf '%s' "$path" | sed 's|/main/installer-amd64/.*||')
  echo "bulk http://${host}${rel_path}/Release"
  n_di=$((n_di + 1))
done < /tmp/di-blocks.$$
rm -f /tmp/di-blocks.$$
[ "$n_di" = 5 ] || die "expected 5 d-i entries, parsed $n_di"

# --- anaconda: Alma / Rocky / CentOS Stream ---------------------------------
# :al*/:rk*/:cs* do `set ks_base ${<host_var>}/<version>` then goto either
# :boot_ks (http) or :boot_ks_https (CentOS, whose mirror redirects http to
# https anyway). Track which, so the probed scheme matches what iPXE asks for.
n_ks=0
while read -r var ver target; do
  host=$(getvar "$var")
  base="$host/$ver/BaseOS/x86_64/os"
  case "$target" in
    boot_ks_https) sch=https ;;
    boot_ks)       sch=http ;;
    *) die "unexpected goto target '$target' after set ks_base ${var}/${ver}" ;;
  esac
  echo "ipxe $sch://$base/images/pxeboot/vmlinuz"
  echo "ipxe $sch://$base/images/pxeboot/initrd.img"
  echo "bulk https://$base/repodata/repomd.xml"
  # ks.cfg adds the AppStream repo from fluxrepo= - watch it too
  echo "bulk https://$host/$ver/AppStream/x86_64/os/repodata/repomd.xml"
  n_ks=$((n_ks + 1))
done < <(awk '
  /^set ks_base \$\{[a-z_]*\}\// {
    line=$3
    sub(/^\$\{/, "", line); split(line, a, "}/")
    var=a[1]; ver=a[2]; next
  }
  var && /^goto / { print var, ver, $2; var=ver="" }
' "$MENU")
[ "$n_ks" = 8 ] || die "expected 8 kickstart entries, parsed $n_ks"

# --- openSUSE Leap ----------------------------------------------------------
leap156=$(getvar leap156_url)
leap160=$(getvar leap160_url)
for u in "$leap156" "$leap160"; do
  echo "ipxe http://$u/boot/x86_64/loader/linux"
  echo "ipxe http://$u/boot/x86_64/loader/initrd"
  echo "bulk https://$u/repodata/repomd.xml"
done
echo "bulk https://$leap160/LiveOS/squashfs.img"

# --- boot-time version manifest --------------------------------------------
man=$(sed -n 's/.*chain --timeout [0-9]* --autofree \([^ ]*\).*/\1/p' "$MENU" | head -n1)
[ -n "$man" ] || die "no manifest chain line found in $MENU"
echo "manifest $man"
