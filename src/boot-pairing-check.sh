#!/usr/bin/env bash
# One question, asked of EVERY menu entry: do the images iPXE boots and the
# payload the installer then downloads come out of the same upstream compose?
#
# This exists because of a 2026-09-15 field failure on the Ubuntu 24.04 entry.
# iPXE fetched releases.ubuntu.com/24.04.4/netboot/amd64/{linux,initrd} and
# casper then downloaded the 24.04.4 live ISO beside it. Same directory, two
# different composes: Canonical REBUILDS the netboot subtree whenever the
# series kernel moves (stamped 2026-09-09, 7.0.0-31-generic) while the ISO
# stays frozen at release day (2026-02-10, 6.8.0-100-generic). casper compares
# its own /conf/uuid.conf with the ISO's .disk/casper-uuid*, and on a mismatch
# it UNMOUNTS the ISO it just downloaded and panics onto /dev/console - the
# serial line in automated mode, so the operator watching the video console
# saw the loop0 attach and then nothing, forever.
#
# The lesson generalises past Ubuntu: any entry whose kernel/initrd and whose
# payload come from DIFFERENT upstream paths can be split apart by either
# side's next refresh, and every distro refreshes on its own schedule. So this
# script classifies all of them:
#
#   same-var pairing   kernel URL and payload URL are built from the SAME menu
#                      variable (Debian d-i, Alma/Rocky/CentOS, Leap 15.6).
#                      They cannot drift apart without a menu edit, and the
#                      check is a textual assertion that the edit has not
#                      happened - no network needed.
#   cross-path pairing kernel URL and payload URL come from different places
#                      (Ubuntu casper, Leap 16 Agama, Oracle, Proxmox, the
#                      flux-hosted d-i pair). Each one needs a CONTENT check,
#                      below, and an entry that has none is a hard failure.
#
# That last rule is the point: adding a distro whose halves can skew, without
# teaching this script how to verify them, fails the build.
#
#   ./src/boot-pairing-check.sh          structural + cheap content checks
#   ./src/boot-pairing-check.sh --deep   also downloads each casper initrd
#                                        (~100 MB) to compare casper UUIDs
set -uo pipefail
cd "$(dirname "$0")/.."
MENU=${MENU:-fluxbilling.ipxe}
MANIFEST=${MANIFEST:-src/sign-boot-images.sh}
PROBE="python3 src/boot-pairing-probe.py"
DEEP=0
[ "${1:-}" = "--deep" ] && DEEP=1
[ -s "$MENU" ] || { echo "FATAL: menu not found: $MENU"; exit 1; }
[ -s "$MANIFEST" ] || { echo "FATAL: manifest not found: $MANIFEST"; exit 1; }

rc=0
say() { printf '%-9s %-8s %s\n' "$1" "$2" "$3"; }
bad() { say "$1" FAIL "$2"; rc=1; }
warn() { say "$1" WARN "$2"; }

# --- menu variable expansion ------------------------------------------------
# Menu values interpolate other menu values; resolve them the same way iPXE
# would, and refuse to guess when a name is missing.
mraw() { sed -n "s/^set $1 //p" "$MENU" | head -n1; }
mval() {
  local v name sub i=0
  v=$(mraw "$1")
  while [ "$i" -lt 12 ]; do
    case $v in *'${'*) ;; *) break ;; esac
    name=${v#*\$\{}; name=${name%%\}*}
    sub=$(mraw "$name")
    [ -n "$sub" ] || { echo "FATAL: cannot resolve \${$name}" >&2; return 1; }
    v=${v//\$\{$name\}/$sub}
    i=$((i + 1))
  done
  printf '%s' "$v"
}
url() { case $1 in http*) printf '%s' "$1" ;; *) printf 'https://%s' "$1" ;; esac; }

# --- structural rule --------------------------------------------------------
# Both halves must interpolate the same menu variable on the entry's own
# kernel line. Cheap, offline, and it is exactly the invariant that makes a
# same-tree entry immune: one variable, one compose.
same_var() { # same_var <label> <kernel-line-grep> <var> <payload-regex>
  local label=$1 sig=$2 var=$3 pay=$4 line
  line=$(grep -m1 -- "$sig" "$MENU")
  [ -n "$line" ] || { bad "$label" "no kernel line matching '$sig' - menu changed shape"; return; }
  grep -q "\${$var}" <<<"$line" || { bad "$label" "kernel URL no longer uses \${$var}"; return; }
  grep -qE "$pay" <<<"$line" || { bad "$label" "payload arg no longer derives from \${$var}"; return; }
  say "$label" OK "same-var pairing on \${$var}"
}

# --- content rules ----------------------------------------------------------
# casper: the netboot kernel must be one of the kernels INSIDE the ISO the
# entry downloads. A server ISO ships the GA kernel as casper/vmlinuz and, on
# an LTS with HWE, a second as casper/hwe-vmlinuz; the netboot tree is built
# from one of them, so matching either proves one compose.
#
# :casper_fallback's leg is deliberately not content-checked: old-releases.
# ubuntu.com keeps the ORIGINAL netboot tree beside the ORIGINAL ISO, both
# frozen, so that pair cannot skew - and src/menu-urls.sh already emits it as
# an `alt` row the watchdog probes for liveness.
check_casper() { # check_casper <tag>
  local tag=$1 kbase img kname nb iso_k found=""
  kbase=$(mval "boot$tag") || { bad "ubu$tag" "cannot read boot$tag"; return; }
  img=$(mval "img$tag")   || { bad "ubu$tag" "cannot read img$tag"; return; }
  case "$kbase" in *github.com/*) kname=vmlinuz ;; *) kname=linux ;; esac
  nb=$($PROBE kver "$(url "$kbase")/$kname") || { bad "ubu$tag" "netboot kernel unreadable"; return; }
  for p in casper/vmlinuz casper/hwe-vmlinuz; do
    iso_k=$($PROBE iso-kver "$(url "$img")" "$p" 2>/dev/null)
    [ "$iso_k" = "ABSENT" ] || [ -z "$iso_k" ] || found="$found $p=$iso_k"
  done
  [ -n "$found" ] || { bad "ubu$tag" "ISO carries no casper kernel to compare"; return; }
  if grep -q " [a-z/-]*=$nb\$\| [a-z/-]*=$nb " <<<"$found "; then
    say "ubu$tag" OK "kernel $nb is in the ISO ($found )"
  else
    bad "ubu$tag" "netboot kernel $nb is NOT in the ISO ($found ) - modules will be missing"
  fi
  if [ "$DEEP" = 1 ]; then
    local tmp; tmp=$(mktemp -d)
    if curl -sL --max-time 600 -o "$tmp/initrd" "$(url "$kbase")/initrd"; then
      local u; u=$($PROBE initrd-uuid "$tmp/initrd" "$(url "$img")")
      case "$u" in
        MATCH*) say "ubu$tag" OK "casper uuid ${u#MATCH }" ;;
        # ignore_uuid on the kernel line neutralises this one, so it is a
        # warning: it still means the two halves are from different composes.
        *) warn "ubu$tag" "casper uuid drift (ignore_uuid covers it): ${u#MISMATCH }" ;;
      esac
    else
      warn "ubu$tag" "initrd fetch failed - uuid row skipped"
    fi
    rm -rf "$tmp"
  fi
}

# Leap 16: iPXE boots repo/oss/.../loader/linux while dracut livenet mounts the
# separately published Agama installer ISO, whose LiveOS squashfs carries the
# modules. Same shape as casper, so the same proof: the booted kernel must be
# the one inside that ISO.
check_agama() {
  local k iso nb iso_k
  k=$(mval leap160_url); iso=$(mval leap160_live)
  nb=$($PROBE kver "$(url "$k")/boot/x86_64/loader/linux") || { bad leap160 "loader kernel unreadable"; return; }
  iso_k=$($PROBE iso-kver "$(url "$iso")" boot/x86_64/loader/linux 2>/dev/null)
  [ -n "$iso_k" ] && [ "$iso_k" != ABSENT ] || { bad leap160 "no kernel found inside the Agama ISO"; return; }
  [ "$nb" = "$iso_k" ] && say leap160 OK "kernel $nb matches the Agama ISO" \
                       || bad leap160 "loader kernel $nb != Agama ISO $iso_k"
}

# Proxmox: iPXE hands the installer the WHOLE official ISO as a second initrd,
# and the kernel it boots was extracted from that same ISO by
# sign-boot-images.sh. One file, two places that name it - so the check is that
# both still name the same file.
check_pve() { # check_pve <menu-var>
  local var=$1 iso host
  iso=$(mval "$var"); host=$(mval pve_host)
  grep -q "pveiso:.*${iso}" "$MANIFEST" \
    && say "${var%_iso}" OK "$iso is the ISO the manifest extracts from" \
    || bad "${var%_iso}" "$iso is booted but $MANIFEST extracts a different ISO"
  curl -sIL --max-time 25 "http://$host/iso/$iso" | grep -qE '^HTTP/[0-9.]+ 200' \
    || bad "${var%_iso}" "http://$host/iso/$iso is not 200"
}

# Oracle and the flux-hosted Ubuntu d-i pair boot images this repo extracted
# and signed itself, so their two halves can only skew when UPSTREAM moves
# after a release was cut. That is precisely what upstream-watch's
# "Detect drift from the last signed release" step compares SHA256SUMS for, so
# the rule here is the cross-file one: the thing the menu boots must be the
# thing the manifest mirrors, under the same release tag.
check_mirrored() { # check_mirrored <label> <manifest-row-name>
  local label=$1 row=$2 rel
  rel=$(mval flux_rel)
  grep -qE "^$row[[:space:]]" "$MANIFEST" \
    || { bad "$label" "no '$row' row in $MANIFEST - the menu boots an unmirrored image"; return; }
  [ -n "$rel" ] || { bad "$label" "flux_rel unset"; return; }
  say "$label" OK "boots $rel assets mirrored by '$row' (content drift: upstream-watch)"
}

# --- coverage ---------------------------------------------------------------
# Every OS entry must be claimed by a rule above, and every `kernel` line in
# the menu must be claimed by a signature below. Either list growing alone is
# the failure this whole script exists to prevent, so both are asserted.
entries=$(sed -n 's/^item \([a-z0-9_]*\) .*/\1/p' "$MENU" \
          | sed -n '/^toggle_mode$/,/^settings$/p' | grep -vE '^(toggle_mode|settings)$')
[ -n "$entries" ] || { echo "FATAL: cannot parse the OS menu out of $MENU"; exit 1; }

for e in $entries; do
  case $e in
    ubu2204|ubu2404|ubu2604|ubu2004|ubu1804|deb11|deb12|deb13|al8|al9|al10|rk8|rk9|rk10|cs9|cs10|ol8|ol9|ol10|leap156|leap160|pve8|pve9) ;;
    *) echo "FATAL: menu entry '$e' has no pairing rule in $0 - add one before shipping it"; rc=1 ;;
  esac
done

want_kernels=8
got_kernels=$(grep -c '^kernel ' "$MENU")
[ "$got_kernels" = "$want_kernels" ] || {
  echo "FATAL: $got_kernels kernel lines in $MENU, rules cover $want_kernels - a boot path was added or removed"
  rc=1
}

# --- run --------------------------------------------------------------------
echo "pairing check: $(wc -w <<<"$entries") entries, $got_kernels boot paths"
check_casper 2204
check_casper 2404
check_casper 2604
check_mirrored ubu2004 ubuntu-20.04
check_mirrored ubu1804 ubuntu-18.04
same_var "deb11-13" 'kernel --name kboot http://${di_host}${di_path}/linux' di_host 'mirror/http/hostname=\$\{di_host\}'
same_var "al/rk/cs" '${ks_sch}://${ks_base}/BaseOS' ks_base 'inst\.repo=https://\$\{ks_base\}'
check_mirrored ol8-10 oracle-9
same_var leap156 '${leap156_url}/boot/x86_64/loader/linux' leap156_url 'install=https://\$\{leap156_url\}'
check_agama
check_pve pve9_iso
check_pve pve8_iso

[ "$rc" = 0 ] && echo "boot pairing: OK" || echo "boot pairing: FAIL - see above"
exit "$rc"
