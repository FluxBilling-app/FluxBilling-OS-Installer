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

# Resolve EVERY ${name} against the menu's own `set` lines, not a hand-listed
# few: the casper block used to special-case ${relNNNN} and rebuild the ISO URL
# from an assumed host+filename, so when the entries moved to the codename
# alias (`${ubu_rel}/${code2404}/ubuntu-${ver2404}-latest-...`) this script
# emitted a URL the menu never fetches. emit() still rejects anything left
# unresolved, so a var this cannot reach is a hard failure, never a guess.
expand() { # expand <string>
  local v=$1 name sub i=0
  while [ "$i" -lt 12 ]; do
    case $v in
      *'${'*) ;;
      *) break ;;
    esac
    name=${v#*\$\{}; name=${name%%\}*}
    sub=$(sed -n "s/^set $name //p" "$MENU" | head -n1)
    [ -n "$sub" ] || die "cannot resolve \${$name} (no 'set $name' line)"
    v=${v//\$\{$name\}/$sub}
    i=$((i + 1))
  done
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
  boot=$(expand "$(getvar "boot$tag")")
  img=$(expand "$(getvar "img$tag")")
  # Canonical's netboot tree calls the kernel "linux"; the 22.04 GitHub build
  # calls it "vmlinuz" (see :ubu2204 / :boot_casper).
  case "$boot" in
    *github.com/*) kname=vmlinuz ;;
    *) kname=linux ;;
  esac
  emit ipxe "$boot/$kname"
  emit ipxe "$boot/initrd"
  # The ISO the initrd downloads - read from img<tag>, never rebuilt from
  # $rel: 24.04/26.04 boot the codename -latest- alias so that ISO and the
  # netboot images above stay one compose (see the img*/boot* note in the
  # menu), and a reconstructed point-release URL would have the watchdog
  # probing an image nothing boots.
  emit bulk "$img"
  # :casper_fallback's target for this release - diagnostic, see the header.
  emit alt "http://old-releases.ubuntu.com/releases/$rel/netboot/amd64/$kname"
  n_cas=$((n_cas + 1))
done
# The ISO mirrors src/flux-mirror-pick races at boot. Diagnostic rows: a dead
# mirror costs nothing (the picker falls back to the origin it just measured),
# but a list where EVERY entry has rotted silently turns the feature off, and
# nothing else would notice. Read from the picker itself, never duplicated.
mir_file=src/flux-mirror-pick
if [ -r "$mir_file" ]; then
  mir_bases=$(sed -n '/^FLUX_MIRRORS="/,/"$/p' "$mir_file" \
              | sed -e 's/^FLUX_MIRRORS="//' -e 's/"$//' | grep '^http')
  [ -n "$mir_bases" ] || die "cannot parse FLUX_MIRRORS out of $mir_file"
  for tag in $casper_rels; do
    series=$(getvar "rel$tag" | cut -d. -f1,2)
    for b in $mir_bases; do
      emit alt "$b/$series/"
    done
  done
fi

# Every casper release must have a matching :ubu<tag> menu entry, and vice
# versa - otherwise one of the two lists has grown without the other.
n_items=$(grep -c '^set rtag ' "$MENU")
[ "$n_cas" = "$n_items" ] || die "found $n_cas casper releases but $n_items 'set rtag' entries"

# --- d-i: Debian (Ubuntu 18.04/20.04 moved to the boot-* release) ----------
# Each :deb* entry block sets di_host via a deb*_host var and a suite; the
# blocks jump to :deb_di for their shared di_alt/di_path; fetch that
# template separately. The two Ubuntu d-i entries no longer walk mirror
# hosts - they boot flux-hosted assets via :boot_di_flux (their 4.15/5.4
# kernels cannot unpack iPXE-appended cpio members) and are emitted in
# their own block below.
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
    :deb*) # host is ${debNN_host} - resolve; path/alt come from :deb_di
           var=${host#\$\{}; var=${var%\}}
           host=$(getvar "$var")
           [ "$suite" != - ] || die "no suite in $blk"
           path=${deb_path//\$\{suite\}/$suite}
           alt=$deb_alt; alt2=$deb_alt ;;
    *) die "unexpected d-i block $blk" ;;
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
  /^:deb[0-9]+$/ { blk=$0; next }
  blk && /^set suite /   { suite=$3; next }
  blk && /^set di_host / { host=$3; next }
  blk && /^set di_path / { path=$3; next }
  blk && /^set di_alt2 / { alt2=$3; next }
  blk && /^set di_alt /  { alt=$3; next }
  blk && /^goto /        { print blk, (host?host:"-"), (path?path:"-"), (suite?suite:"-"), (alt?alt:"-"), (alt2?alt2:"-")
                           blk=host=path=suite=alt=alt2="" }
' "$MENU")
[ "$n_di" = 3 ] || die "expected 3 d-i entries, parsed $n_di"

# Ubuntu 18.04/20.04: boot images from the boot-* release (see :boot_di_flux
# in the menu). The apt mirror they preseed stays on archive.ubuntu.com;
# emit each suite's Release file as bulk so the watchdog still notices a
# vanished suite. The suite names are pinned HERE because the menu no longer
# carries a dists/ path for these entries.
flux_boot=$(getvar flux_boot)
flux_rel=$(getvar flux_rel)
n_ubudi=0
for dver in $(sed -n 's/^set dver //p' "$MENU" | sort -u); do
  emit ipxe "$flux_boot/$flux_rel/ubuntu-$dver-vmlinuz"
  emit ipxe "$flux_boot/$flux_rel/ubuntu-$dver-initrd"
  emit ipxe "$flux_boot/$flux_rel/ubuntu-$dver-auto-initrd"
  case $dver in
    18.04) emit bulk "http://archive.ubuntu.com/ubuntu/dists/bionic-updates/Release" ;;
    20.04) emit bulk "http://archive.ubuntu.com/ubuntu/dists/focal-updates/Release" ;;
    *) die "unknown flux-hosted d-i version $dver - add its apt suite here" ;;
  esac
  n_ubudi=$((n_ubudi + 1))
done
[ "$n_ubudi" = 2 ] || die "expected 2 flux-hosted d-i entries, parsed $n_ubudi"

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

# --- Oracle Linux: anaconda, boot images from this repo's boot-* release ----
# Discovered from the :olN entry labels. The ipxe rows point at the GitHub
# release - github.com rows are exempt from the signing-manifest sync by
# design (they ARE the signed release), and they 404 until the release is
# cut, which is the watchdog telling the truth: the entries do not boot yet.
# The stage2 goes out as bulk (dracut fetches it with a full CA bundle), and
# the two yum.oracle.com repos are what anaconda's dnf payload reads.
flux_boot=$(getvar flux_boot)
flux_rel=$(getvar flux_rel)
ol_repo=$(getvar ol_repo)
n_ol=0
for v in $(sed -n 's/^:ol\([0-9]*\)$/\1/p' "$MENU"); do
  emit ipxe "$flux_boot/$flux_rel/oracle-$v-vmlinuz"
  emit ipxe "$flux_boot/$flux_rel/oracle-$v-initrd"
  # inst.stage2=<base> makes dracut fetch <base>/images/install.img - the
  # /images/ segment lives inside the release TAG (see the menu's flux_boot
  # note), so this URL is exactly what anaconda asks GitHub for.
  emit bulk "$flux_boot/$flux_rel-ol$v/images/install.img"
  emit bulk "https://$ol_repo/OL$v/baseos/latest/x86_64/repodata/repomd.xml"
  emit bulk "https://$ol_repo/OL$v/appstream/x86_64/repodata/repomd.xml"
  n_ol=$((n_ol + 1))
done
[ "$n_ol" = 3 ] || die "expected 3 Oracle Linux entries, parsed $n_ol"

# --- Proxmox VE --------------------------------------------------------------
# kernel/initrd from the boot-* release; the full official ISO is ALSO an
# iPXE fetch (it rides into the initramfs as /proxmox.iso), so it gets the
# ipxe tag and the redirect-sensitive probe, not the bulk one. Plain http is
# deliberate and currently unavoidable - download.proxmox.com's certificate
# does not name the host (see the pve_host note in the menu).
pve_host=$(getvar pve_host)
n_pve=0
for v in $(sed -n 's/^:pve\([0-9]*\)$/\1/p' "$MENU"); do
  iso=$(getvar "pve${v}_iso")
  emit ipxe "$flux_boot/$flux_rel/proxmox-$v-vmlinuz"
  emit ipxe "$flux_boot/$flux_rel/proxmox-$v-initrd"
  emit ipxe "http://$pve_host/iso/$iso"
  n_pve=$((n_pve + 1))
done
[ "$n_pve" = 2 ] || die "expected 2 Proxmox VE entries, parsed $n_pve"

# --- openSUSE Leap ----------------------------------------------------------
# Discovered, like the casper releases: a hardcoded pair would ignore an added
# Leap entry and quietly under-report coverage.
n_leap=0
for v in $(sed -n 's/^set leap\([0-9]*\)_url .*/\1/p' "$MENU"); do
  u=$(getvar "leap${v}_url")
  emit ipxe "http://$u/boot/x86_64/loader/linux"
  emit ipxe "http://$u/boot/x86_64/loader/initrd"
  emit bulk "https://$u/repodata/repomd.xml"
  n_leap=$((n_leap + 1))
done
[ "$n_leap" -ge 1 ] || die "no 'set leapN_url' lines found in $MENU"
# The Agama live payload is the per-arch installer ISO (leap*_live vars),
# NOT ${leapN_url}/LiveOS/squashfs.img - that arch-ambiguous path serves an
# s390x root filesystem (see the leap160_live note in the menu).
n_live=0
for lv in $(sed -n 's/^set leap\([0-9]*\)_live .*/\1/p' "$MENU"); do
  emit bulk "https://$(getvar "leap${lv}_live")"
  n_live=$((n_live + 1))
done
[ "$n_live" -ge 1 ] || die "no 'set leapN_live' lines found in $MENU"

