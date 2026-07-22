#!/bin/bash
# Prove the self-heal fallbacks actually fire, in a real VM.
#
# The whole "a fielded ISO survives an upstream move" claim rests on
# :casper_fallback and :di_fallback, and neither can be reached by a normal
# boot test - the primary hosts are up, which is precisely when the fallback
# does nothing. So this builds throwaway ISOs whose PRIMARY host is a dead
# address, boots them, and asserts that iPXE moves to the documented
# alternate with the URL shape the alternate actually serves.
#
# Two cases, one per mechanism:
#   casper  Ubuntu 26.04 -> old-releases.ubuntu.com/releases/<rel>/netboot/amd64
#   d-i     Debian 12    -> archive.debian.org/debian/dists/<suite>/...
#
# Costs two short boots and no large downloads: both runs stop at the kernel
# fetch, which is the only thing under test.
#
# EXIT CODE IS REAL. CI gates on it (.github/workflows/build-test.yml).
set -uo pipefail
trap '' PIPE

LOGDIR=${LOGDIR:-/tmp}; mkdir -p "$LOGDIR"
MENU=/w/fluxbilling.ipxe
fail=0

ESC=$(printf '\033')
fz() {
  local s=$1 out="" c i gap
  gap="(${ESC}\[[0-9;?]*[a-zA-Z]|.){0,6}"
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [\[\]\(\).*+?^\$\\/]) c="\\$c" ;; esac
    out+="$c$gap"
  done
  printf '%s' "$out"
}

# build_iso <out.iso> <sed-expr...> - embed a patched menu, everything else stock
build_iso() {
  local out=$1; shift
  local menu=/work/fb-menu.ipxe
  sed "$@" "$MENU" > "$menu"
  python3 /w/src/logo-compose.py /w/assets/FluxBilling.png /work/logo.png
  cp /w/src/preseed.cfg /w/src/99fluxseed /w/src/param.conf /w/src/ks.cfg \
     /w/src/autoinst.xml /w/src/50-flux-agama.sh /w/src/flux-scrub \
     /w/assets/agama-leap16.json /work/
  local e=$menu,/work/logo.png,/work/preseed.cfg,/work/99fluxseed,/work/param.conf,/work/ks.cfg,/work/autoinst.xml,/work/agama-leap16.json,/work/50-flux-agama.sh,/work/flux-scrub
  ( cd /ipxe/src \
    && make -j"$(nproc)" bin/ipxe.lkrn EMBED="$e" > /tmp/mk.log 2>&1 \
    && ./util/genfsimg -o "$out" bin/ipxe.lkrn > /dev/null 2>&1 ) \
    || { echo "FATAL: build failed"; tail -5 /tmp/mk.log; return 1; }
  test -s "$out"
}

# walk <iso> <log> <rows-below-default> <expected-url-substring> <label>
walk() {
  local iso=$1 log=$2 rows=$3 want=$4 label=$5
  local fifo=/tmp/fb.fifo qpid i=0
  rm -f "$fifo" "$log"; mkfifo "$fifo"; : > "$log"
  timeout 600 qemu-system-x86_64 -machine accel=kvm:tcg -m 2048 \
    -cdrom "$iso" -nographic -boot d < "$fifo" > "$log" 2>&1 &
  qpid=$!
  exec 3> "$fifo"

  # A vanished log must fail LOUDLY and at once. Polling a missing file just
  # burns the whole timeout and then reports "never reached ..." - which reads
  # as a product failure when the real cause is that something deleted the
  # log (a concurrent test run cleaning test-logs/ will do it).
  w() {
    local j=0
    while [ $j -lt "$2" ]; do
      [ -e "$log" ] || { echo "FAIL $label: log $log disappeared mid-run"; fail=1; return 1; }
      grep -aqE "$(fz "$1")" "$log" && return 0
      sleep 1; j=$((j+1))
    done
    echo "FAIL $label: timeout waiting for '$1'"; fail=1; return 1
  }
  s() { printf "$1" >&3 2>/dev/null || true; }

  w "Port number" 300     && s '0\r'
  w "IP / subnet" 90      && s '10.0.2.15/27\r'
  w "Gateway" 90          && s '\r'
  w "Hostname" 90         && s 'srv1\r'
  w "Root password" 90    && { sleep 1; s '\t'; sleep 1; s 'Passw0rd123\r'; }
  w "Review your setup" 90 && s '\r'
  # Arrow keys go one at a time, with a gap. iPXE tells a bare ESC from an
  # ESC[B cursor key by TIMING, so a burst of escape sequences in a single
  # write is parsed as something else entirely - seven of them in one printf
  # left the highlight on the default entry and nothing was ever selected.
  if w "Install mode" 90; then
    sleep 3
    local k=0
    while [ "$k" -lt "$rows" ]; do s '\033[B'; sleep 1; k=$((k + 1)); done
    sleep 1; s '\r'
  fi
  # The primary must be tried and must fail, then the alternate must appear.
  if w "$want" 300; then
    echo "OK   $label: fell back to $want"
  else
    echo "FAIL $label: never reached $want"
    fail=1
  fi
  sleep 3
  exec 3>&-; kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
  rm -f "$fifo"
  # Report this case's own verdict too, so the caller's || chain is a second
  # line of defence rather than the only one.
  [ "$fail" -eq 0 ]
}

REL2604=$(sed -n 's/^set rel2604 //p' "$MENU")
[ -n "$REL2604" ] || { echo "FATAL: no rel2604 in menu"; exit 1; }

echo "===== CASE 1: casper primary dead -> old-releases ====="
build_iso /work/fb-casper.iso -e "s|^set boot2604 .*|set boot2604 http://127.0.0.1:1/dead|" \
  && walk /work/fb-casper.iso "$LOGDIR/fallback-casper.log" 0 \
       "old-releases.ubuntu.com/releases/${REL2604}/netboot/amd64/linux" "casper" \
  || fail=1

echo "===== CASE 2: Debian primary dead -> archive.debian.org ====="
# Debian 12 sits 7 rows below the default (26.04) in the OS menu:
# 2604,2510,2404,2204,2004,1804,deb13,deb12 - seven Downs from the default.
build_iso /work/fb-deb.iso -e "s|^set deb12_host .*|set deb12_host 127.0.0.1:1|" \
  && walk /work/fb-deb.iso "$LOGDIR/fallback-debian.log" 7 \
       "archive.debian.org/debian/dists/bookworm" "debian" \
  || fail=1

echo "===== RESULT: $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ====="
exit "$fail"
