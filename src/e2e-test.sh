#!/bin/bash
# E2E initrd-injection + kernel-exec test for a casper (Ubuntu 22.04+) entry.
# Builds a test ISO whose selected Ubuntu entry fetches kernel/initrd from a
# LOCAL http server (fast) and drops into the initramfs shell (break=top),
# then verifies the kernel actually EXECUTES (catches wrong-arch/EFI-only
# kernel pins) and that the injected FluxBilling files survived the
# initramfs unpack (this is where the real-hardware "Cannot open root
# device" panic came from).
#
# REL selects the entry: 2404 (default), 2510, 2604.
# .cache/${REL}-vmlinuz + ${REL}-initrd are fetched (and refreshed) HERE,
# from the OFFICIAL Canonical netboot tree pinned in the menu: a version
# stamp ties the cache to `set rel<REL>` in fluxbilling.ipxe, so a
# point-release bump can never silently keep testing stale kernels.
#
# EXIT CODE IS REAL: setup errors abort, boot assertions accumulate into a
# fail flag, and CI gates on the result.
set -euo pipefail

REL=${REL:-2404}
case $REL in
  2604) ARROWS='' ;;                    # u2604 is the menu default
  2510) ARROWS='\033[B' ;;
  2404) ARROWS='\033[B\033[B' ;;
  *) echo "unsupported REL=$REL"; exit 1 ;;
esac
# The boot base for this release, straight from the menu script (variable is
# boot<rel>; it was sqfs<rel>, and nbx<rel> before that - a stale name here
# silently produced an empty value, which then rewrote the URLs wrong and
# tested nothing).
BASE=$(sed -n "s|^set boot${REL} ||p" /w/fluxbilling.ipxe)
test -n "$BASE" || { echo "BASE-EMPTY: no 'set boot${REL} ...' line in fluxbilling.ipxe"; exit 1; }
# Canonical calls the netboot kernel "linux"; keep this in step with :ubu<rel>.
KNAME=linux
set -x
mkdir -p /work

# --- 0. cache: fetch/refresh the official netboot images for this pin ------
VER=$(sed -n "s/^set rel${REL} //p" /w/fluxbilling.ipxe)
test -n "$VER" || { echo "VER-EMPTY: no 'set rel${REL}' line"; exit 1; }
mkdir -p /w/.cache
STAMP=/w/.cache/${REL}.ver
if [ ! -s "/w/.cache/${REL}-vmlinuz" ] || [ ! -s "/w/.cache/${REL}-initrd" ] \
   || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$VER" ]; then
  echo ">> cache refresh: $REL -> $VER (menu pin changed or cache missing)"
  # Bounded: a blackholing mirror would otherwise hang the CI job until the
  # 6-hour runner limit (the only other timeouts here wrap QEMU).
  curl -fSL --retry 3 --connect-timeout 30 --max-time 900 -o "/w/.cache/${REL}-vmlinuz" "http://releases.ubuntu.com/$VER/netboot/amd64/linux"
  curl -fSL --retry 3 --connect-timeout 30 --max-time 900 -o "/w/.cache/${REL}-initrd"  "http://releases.ubuntu.com/$VER/netboot/amd64/initrd"
  echo "$VER" > "$STAMP"
fi

# --- 1. stock initrd must NOT already contain /conf/param.conf ------------
rm -rf /tmp/un && mkdir /tmp/un
unmkinitramfs "/w/.cache/${REL}-initrd" /tmp/un
ls /tmp/un/main/conf/ >/dev/null 2>&1 || { echo "UNPACK-FAILED: unmkinitramfs produced no conf dir"; exit 1; }
echo "stock conf dir: $(ls /tmp/un/main/conf/ 2>/dev/null | tr '\n' ' ')"
test ! -e /tmp/un/main/conf/param.conf || { echo "STOCK-PARAM-CONF-PRESENT: refusing to test injection over it"; exit 1; }
echo "STOCK-PARAM-CONF-ABSENT-OK"
rm -rf /tmp/un

# --- 2. test ISO: local URLs + serial console + initramfs breakpoint ------
# Point just THIS release's boot base at the local server, and break into the
# initramfs shell. Rewriting the `set boot<rel>` line (rather than a literal
# URL) keeps this working across point-release bumps; :boot_casper copies it
# into ${kbase} at entry, so the kernel line to patch is the ${kbase} one.
# The third expression pre-latches flux_manifested so the :commit manifest
# chainload never runs: the manifest is fetched AFTER these `set` lines and
# may legitimately re-set boot<REL>, which would silently override the local
# test server and make this test depend on production state.
sed -e "s|^set boot${REL} .*|set boot${REL} http://10.0.2.2:8000|" \
    -e "s|^kernel --name kboot \${kbase}/\${kname} initrd=initrd.magic |&break=top console=ttyS0 |" \
    -e "s|^isset \${flux_manifested} .*|set flux_manifested 1|" \
    /w/fluxbilling.ipxe > /work/test.ipxe
grep -q "break=top" /work/test.ipxe || { echo "SED-MISSED-KERNEL-LINE"; exit 1; }
grep -q "http://10.0.2.2:8000" /work/test.ipxe || { echo "SED-MISSED-URL"; exit 1; }
grep -q "^set flux_manifested 1" /work/test.ipxe || { echo "SED-MISSED-MANIFEST"; exit 1; }
grep -q "boot.fluxbilling.app" /work/test.ipxe && { echo "MANIFEST-STILL-LIVE"; exit 1; }
python3 /w/src/logo-compose.py /w/assets/FluxBilling.png /work/logo.png
cp /w/src/preseed.cfg /w/src/99fluxseed /w/src/param.conf \
   /w/src/ks.cfg /w/src/autoinst.xml /w/src/50-flux-agama.sh \
   /w/src/flux-scrub /w/assets/agama-leap16.json /work/
# MUST stay in step with build.sh's EMBEDLIST. A file the menu imgargs's but
# that is missing here is not a registered image, so iPXE falls through to
# downloading its bare name and prints "Could not start download: Operation
# not supported" - and the injected file silently never reaches the initrd.
EMBEDLIST=/work/test.ipxe,/work/logo.png,/work/preseed.cfg,/work/99fluxseed,/work/param.conf,/work/ks.cfg,/work/autoinst.xml,/work/agama-leap16.json,/work/50-flux-agama.sh,/work/flux-scrub
# NOTE: fluxcidr_cmd.c is already baked into image_cmd.c by the builder
# image - appending it again here would redefine the command and kill the
# build (which then silently produced a non-bootable test.iso).
cd /ipxe/src
make -j"$(nproc)" bin/ipxe.lkrn EMBED="$EMBEDLIST" > /tmp/make.log 2>&1 \
  || { echo "MAKE-FAILED"; tail -30 /tmp/make.log; exit 1; }
./util/genfsimg -o /work/test.iso bin/ipxe.lkrn || { echo "GENFSIMG-FAILED"; exit 1; }
test -s /work/test.iso || { echo "TEST-ISO-EMPTY"; exit 1; }

# --- 3. serve kernel/initrd locally ---------------------------------------
mkdir -p /srv/t && cd /srv/t
cp "/w/.cache/${REL}-vmlinuz" ${KNAME}
cp "/w/.cache/${REL}-initrd" initrd
python3 -m http.server 8000 &>/dev/null &
sleep 1

# --- 4. boot, walk menu, land in initramfs shell, inspect ----------------
# From here on failures ACCUMULATE (no -e): every assertion runs, then the
# fail flag decides the exit code.
set +e
fail=0
# See qemu-test.sh: a dead QEMU must not SIGPIPE the walk into exit 141.
trap '' PIPE

ESC=$(printf '')
fz() {
  local s=$1 out="" c i gap
  # Between two expected characters allow up to 6 "units", each either a whole
  # ANSI escape sequence or one stray character. BOTH are needed: iPXE output
  # reaches the serial line twice under -nographic (native console + BIOS
  # int10 redirect) and interleaves char by char, AND the menu colours every
  # label, so e.g. "Gateway[0m [37m[ENTER" puts 10 bytes between the
  # "y" and the "[" - a plain .{0,3} gap could never match it, which is
  # exactly how the first rewrite of this script stalled at the gateway
  # prompt while reporting nothing but a timeout.
  gap="(${ESC}\[[0-9;?]*[a-zA-Z]|.){0,6}"
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [\[\]\(\).*+?^\$\/]) c="\$c" ;; esac
    out+="$c$gap"
  done
  printf '%s' "$out"
}
LOG=${LOGDIR:-/tmp}/e2e.log
mkdir -p "${LOGDIR:-/tmp}"
wait_for() {
  local s=$1 t=$2 i=0
  while [ "$i" -lt "$t" ]; do
    grep -aqE "$(fz "$s")" "$LOG" && return 0
    sleep 1; i=$((i + 1))
  done
  echo "FAIL TIMEOUT(${t}s) waiting for: $s"
  fail=1
  return 1
}

FIFO=/tmp/e2e.fifo
rm -f "$FIFO" "$LOG"; mkfifo "$FIFO"; : > "$LOG"
timeout 600 qemu-system-x86_64 -machine accel=kvm:tcg -m 2048 -cdrom /work/test.iso \
  -nographic -boot d < "$FIFO" > "$LOG" 2>&1 &
QPID=$!
exec 3> "$FIFO"
send() { printf "$1" >&3 2>/dev/null || true; }

wait_for "Port number" 300      && send '0\r'
wait_for "IP / subnet" 90       && send '10.0.2.15/27\r'
wait_for "Gateway" 90           && send '\r'
wait_for "Hostname" 90          && send 'srv1\r'
wait_for "Root password" 90     && { sleep 1; send '\t'; sleep 1; send 'Passw0rd123\r'; }
wait_for "Review your setup" 90 && send '\r'
if wait_for "Install mode" 90; then
  sleep 3; send "${ARROWS}\r"   # select u${REL}; local fetch + boot to break=top
fi
# (initramfs) is the break=top shell prompt - the kernel executed and the
# initrd chain unpacked.
if wait_for "(initramfs)" 300; then
  sleep 2
  # `ls && echo MARK1-OK`: the marker must be produced BY the command, not
  # typed into it. The initramfs tty echoes input, so a marker on the command
  # line itself would satisfy any grep even when ls listed nothing at all.
  send 'ls /conf/param.conf /scripts/casper-bottom/99fluxseed /flux-preseed.cfg /flux-ks.cfg /flux-autoinst.xml /flux-agama.json /flux-scrub && echo MARK1-OK\n'
  wait_for "MARK1-OK" 30; sleep 3
  send 'echo MARK2; cat /conf/param.conf\n'
  wait_for "MARK2" 30; sleep 3
  send 'echo MARK3; head -3 /scripts/casper-bottom/99fluxseed\n'
  wait_for "MARK3" 30; sleep 3
fi
exec 3>&-
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
rm -f "$FIFO"

echo "===== E2E CHECKS (REL=$REL ver=$VER base=$BASE) ====="
must_zero() {
  local n; n=$(grep -ac "$2" "$LOG")
  [ "$n" -eq 0 ] && echo "OK   zero $1" || { echo "FAIL $1: $n hits"; fail=1; }
}
must_have() { # <label> <literal>
  grep -aq "$2" "$LOG" && echo "OK   $1" || { echo "FAIL $1: not found"; fail=1; }
}
must_zero "exec-failed"    'Could not boot'
must_zero "unpack-failed"  'Initramfs unpacking failed'
must_zero "rootdev-panic"  'Cannot open root device'
must_have "initramfs-shell" '(initramfs)'
# MARK1: ls must have listed every injected file and complained about none.
# MARK1-OK only appears if ls exited 0, i.e. all seven paths exist; the
# 'No such file' scan is the belt to that braces. The MARK blocks arrive on
# the kernel console as a single clean stream.
must_have "MARK1 all injected files present" 'MARK1-OK'
grep -aA8 'flux-scrub' "$LOG" | grep -q 'No such file' && { echo "FAIL MARK1: injected file missing"; fail=1; }
# MARK2: the casper trigger reached /conf/param.conf and calls the seed hook
grep -aA4 'MARK2' "$LOG" | grep -q '99fluxseed' && echo "OK   MARK2 param.conf content" || { echo "FAIL MARK2: param.conf missing/empty"; fail=1; }
# MARK3: the seed generator itself survived with its shebang intact
grep -aA4 'MARK3' "$LOG" | grep -q 'FluxBilling' && echo "OK   MARK3 99fluxseed content" || { echo "FAIL MARK3: 99fluxseed missing/empty"; fail=1; }

echo "===== RESULT: $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ====="
exit "$fail"
