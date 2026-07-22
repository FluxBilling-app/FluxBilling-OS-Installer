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

# build_iso <out.iso> <marker> <sed-expr...> - embed a patched menu, rest stock
build_iso() {
  local out=$1 marker=$2; shift 2
  local menu=/work/fb-menu.ipxe
  sed "$@" "$MENU" > "$menu"
  # A sed expression that matches NOTHING exits 0 and copies the menu through
  # unchanged - the test would then boot a stock ISO, watch it succeed against
  # the real mirror, and never reach the fallback it exists to prove. Assert
  # the patch landed, exactly as e2e-test.sh does.
  grep -q "$marker" "$menu" || { echo "FATAL: sed did not apply (no '$marker' in patched menu)"; return 1; }
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
  local fifo=/tmp/fb.fifo qpid i=0 rc=0
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
      [ -e "$log" ] || { echo "FAIL $label: log $log disappeared mid-run"; fail=1; rc=1; return 1; }
      grep -aqE "$(fz "$1")" "$log" && return 0
      sleep 1; j=$((j+1))
    done
    echo "FAIL $label: timeout waiting for '$1'"; fail=1; rc=1; return 1
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
    fail=1; rc=1
  fi
  sleep 3
  exec 3>&-; kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
  rm -f "$fifo"
  # This case's OWN verdict - `fail` is a monotonic global, so returning it
  # would mark every later case failed once any earlier one did.
  return "$rc"
}

REL2604=$(sed -n 's/^set rel2604 //p' "$MENU")
[ -n "$REL2604" ] || { echo "FATAL: no rel2604 in menu"; exit 1; }

echo "===== CASE 1: casper primary dead -> old-releases ====="
build_iso /work/fb-casper.iso "set boot2604 http://127.0.0.1:1/dead" -e "s|^set boot2604 .*|set boot2604 http://127.0.0.1:1/dead|" \
  && walk /work/fb-casper.iso "$LOGDIR/fallback-casper.log" 0 \
       "old-releases.ubuntu.com/releases/${REL2604}/netboot/amd64/linux" "casper" \
  || fail=1

echo "===== CASE 2: Debian primary dead -> archive.debian.org ====="
# Derive the row offset from the menu. Hardcoding it means the next release
# added above deb12 silently retargets the walk at a different entry, and the
# test then "fails" for a reason that has nothing to do with the fallback.
DEF=$(sed -n 's/^choose --default \([a-z0-9]*\) .*/\1/p' "$MENU" | head -n1)
[ -n "$DEF" ] || { echo "FATAL: no 'choose --default' in menu"; exit 1; }
ROWS=$(awk -v def="$DEF" -v tgt=deb12 '
  /^item /{ n++; if ($2 == def) d = n; if ($2 == tgt) t = n }
  END { if (d && t) print t - d; else print "" }' "$MENU")
[ -n "$ROWS" ] && [ "$ROWS" -gt 0 ] || { echo "FATAL: cannot locate deb12 below $DEF"; exit 1; }
echo "deb12 is $ROWS rows below the default ($DEF)"
build_iso /work/fb-deb.iso "set deb12_host 127.0.0.1:1" -e "s|^set deb12_host .*|set deb12_host 127.0.0.1:1|" \
  && walk /work/fb-deb.iso "$LOGDIR/fallback-debian.log" "$ROWS" \
       "archive.debian.org/debian/dists/bookworm" "debian" \
  || fail=1

echo "===== RESULT: $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ====="
exit "$fail"
