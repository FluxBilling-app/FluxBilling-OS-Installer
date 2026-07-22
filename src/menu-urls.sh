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
#   alt <url>    a fallback host :casper_fallback / :di_fallback would move to.
#                DIAGNOSTIC ONLY - these legitimately 404 until the day they
#                are needed (a suite is not on archive.debian.org until Debian
#                archives it), so they must never gate the watchdog; they tell
#                the operator whether the recovery leg is live when something
#                else has already broken.
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

# Every URL leaves through here. A menu typo, or a nested ${var} this script
# does not know how to resolve, would otherwise be emitted verbatim - the
# watchdog then probes a literal "${rel2604}" and blames the mirror for the
# 404. Silently emitting a bogus URL is the same class of lie as emitting a
# short list.
emit() { # emit <tag> <url>
  case $2 in
    *'${'*) die "unresolved variable reference in: $2" ;;
    *://*) ;;
    *) die "not an absolute URL: $2" ;;
  esac
  printf '%s %s\n' "$1" "$2"
}

getvar() { # getvar <name> -> value of `set <name> ...`, must exist
  local v
  v=$(sed -n "s/^set $1 //p" "$MENU" | head -n1)
  [ -n "$v" ] || die "no 'set $1' line found in $MENU"
  printf '%s\n' "$v"
}

# --- Ubuntu casper (22.04+) -------------------------------------------------
# DISCOVER the releases from the menu - never hardcode the list. A hardcoded
# set silently ignores a newly added entry, and the watchdog would then report
# full coverage while probing nothing for it. Same reason the counts below are
# asserted: the release list and the boot* vars must correspond exactly.
casper_rels=$(sed -n 's/^set rel\([0-9]\{4\}\) .*/\1/p' "$MENU")
[ -n "$casper_rels" ] || die "no 'set relNNNN' lines found in $MENU"

n_cas=0
for tag in $casper_rels; do
  rel=$(getvar "rel$tag")
  boot=$(getvar "boot$tag")
  # boot* is written in terms of ${relNNNN}; resolve that one nested reference
  # rather than reconstructing the URL from an assumed host.
  boot=${boot//\$\{rel$tag\}/$rel}
  # Canonical's netboot tree calls the kernel "linux"; the 22.04 GitHub build
  # calls it "vmlinuz" (see :ubu2204 / :boot_casper).
  case "$boot" in
    *github.com/*) kname=vmlinuz ;;
    *) kname=linux ;;
  esac
  emit ipxe "$boot/$kname"
  emit ipxe "$boot/initrd"
  emit bulk "https://releases.ubuntu.com/$rel/ubuntu-$rel-live-server-amd64.iso"
  # :casper_fallback's target for this release - diagnostic, see the header.
  emit alt "http://old-releases.ubuntu.com/releases/$rel/netboot/amd64/$kname"
  n_cas=$((n_cas + 1))
done
# Every casper release must have a matching :ubu<tag> menu entry, and vice
# versa - otherwise one of the two lists has grown without the other.
n_items=$(grep -c '^set rtag ' "$MENU")
[ "$n_cas" = "$n_items" ] || die "found $n_cas casper releases but $n_items 'set rtag' entries"

# --- d-i: Ubuntu 18.04/20.04 + Debian --------------------------------------
# Each :ubu*/:deb* entry block sets di_host (possibly via a deb*_host var)
# and di_path (possibly containing ${suite}); walk the blocks and resolve.
# The Debian blocks jump to :deb_di for their shared di_alt/di_path; fetch
# that template separately.
deb_path=$(awk '/^:deb_di$/{f=1} f && /^set di_path /{print $3; exit}' "$MENU")
[ -n "$deb_path" ] || die "no di_path under :deb_di"
deb_alt=$(awk '/^:deb_di$/{f=1} f && /^set di_alt /{print $3; exit}' "$MENU")
[ -n "$deb_alt" ] || die "no di_alt under :deb_di"

n_di=0
# Process substitution, not a temp file: /tmp/<predictable> is a symlink
# target on any shared machine, and the parsed hostnames feed straight into
# probed URLs.
while read -r blk host path suite alt alt2; do
  case "$blk" in
    :ubu*) [ "$host" != - ] && [ "$path" != - ] || die "incomplete d-i block $blk"
           [ "$alt" != - ] && [ "$alt2" != - ] || die "no fallback hosts in $blk" ;;
    :deb*) # host is ${debNN_host} - resolve; path/alt come from :deb_di
           var=${host#\$\{}; var=${var%\}}
           host=$(getvar "$var")
           [ "$suite" != - ] || die "no suite in $blk"
           path=${deb_path//\$\{suite\}/$suite}
           alt=$deb_alt; alt2=$deb_alt ;;
  esac
  rel_path=$(printf '%s' "$path" | sed 's|/main/installer-amd64/.*||')
  emit ipxe "http://${host}${path}/linux"
  emit ipxe "http://${host}${path}/initrd.gz"
  emit bulk "http://${host}${rel_path}/Release"
  # Fallback hosts are emitted as `alt`, NOT as `ipxe`. They are expected to
  # 404 in normal operation - archive.debian.org does not carry a suite until
  # Debian archives it, and old-releases.ubuntu.com does not carry a series
  # while it is still on ESM - so failing on them would file a false alarm
  # every week. The watchdog probes them for DIAGNOSTIC value: when something
  # else is already broken, the issue reports whether the recovery leg the
  # menu would fall back to is actually serving. Duplicates (the deliberate
  # alt == alt2 in :deb_di, or shared hosts) collapse in a sort -u.
  for h in $(printf '%s\n%s\n' "$alt" "$alt2" | sort -u); do
    [ "$h" = "$host" ] && continue
    emit alt "http://${h}${path}/linux"
  done
  n_di=$((n_di + 1))
done < <(awk '
  /^:(ubu(2004|1804)|deb[0-9]+)$/ { blk=$0; next }
  blk && /^set suite /   { suite=$3; next }
  blk && /^set di_host / { host=$3; next }
  blk && /^set di_path / { path=$3; next }
  blk && /^set di_alt2 / { alt2=$3; next }
  blk && /^set di_alt /  { alt=$3; next }
  blk && /^goto /        { print blk, (host?host:"-"), (path?path:"-"), (suite?suite:"-"), (alt?alt:"-"), (alt2?alt2:"-")
                           blk=host=path=suite=alt=alt2="" }
' "$MENU")
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
  emit ipxe "$sch://$base/images/pxeboot/vmlinuz"
  emit ipxe "$sch://$base/images/pxeboot/initrd.img"
  emit bulk "https://$base/repodata/repomd.xml"
  # ks.cfg adds the AppStream repo from fluxrepo= - watch it too
  emit bulk "https://$host/$ver/AppStream/x86_64/os/repodata/repomd.xml"
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
# Discovered, like the casper releases: a hardcoded pair would ignore an added
# Leap entry and quietly under-report coverage.
n_leap=0
for v in $(sed -n 's/^set leap\([0-9]*\)_url .*/\1/p' "$MENU"); do
  u=$(getvar "leap${v}_url")
  emit ipxe "http://$u/boot/x86_64/loader/linux"
  emit ipxe "http://$u/boot/x86_64/loader/initrd"
  emit bulk "https://$u/repodata/repomd.xml"
  # Only the Agama live entry streams a squashfs; it is the one whose menu
  # entry carries root=live:.
  grep -q "root=live:https://\${leap${v}_url}" "$MENU" \
    && emit bulk "https://$u/LiveOS/squashfs.img"
  n_leap=$((n_leap + 1))
done
[ "$n_leap" -ge 1 ] || die "no 'set leapN_url' lines found in $MENU"

