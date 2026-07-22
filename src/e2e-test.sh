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
# Expects /w/.cache to hold ${REL}-vmlinuz + ${REL}-initrd. Refresh them from
# the OFFICIAL Canonical netboot tree - the same URL the menu now boots, e.g.
#   V=$(sed -n 's/^set rel2404 //p' fluxbilling.ipxe)
#   curl -o .cache/2404-vmlinuz http://releases.ubuntu.com/$V/netboot/amd64/linux
#   curl -o .cache/2404-initrd  http://releases.ubuntu.com/$V/netboot/amd64/initrd
# (a netbootxyz-era cache is a DIFFERENT build and no longer matches the menu).
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

# --- 0. stock initrd must NOT already contain /conf/param.conf ------------
rm -rf /tmp/un && mkdir /tmp/un
unmkinitramfs /w/.cache/${REL}-initrd /tmp/un
echo "stock conf dir: $(ls /tmp/un/main/conf/ 2>/dev/null | tr '\n' ' ')"
test ! -e /tmp/un/main/conf/param.conf && echo "STOCK-PARAM-CONF-ABSENT-OK"
rm -rf /tmp/un

# --- 1. test ISO: local URLs + serial console + initramfs breakpoint ------
# Point just THIS release's boot base at the local server, and break into the
# initramfs shell. Rewriting the `set boot<rel>` line (rather than a literal
# URL) keeps this working across point-release bumps.
sed -e "s|^set boot${REL} .*|set boot${REL} http://10.0.2.2:8000|" \
    -e "s|^kernel --name kboot \${boot\${rtag}}/\${kname} initrd=initrd.magic |&break=top console=ttyS0 |" \
    /w/fluxbilling.ipxe > /work/test.ipxe
grep -q "break=top" /work/test.ipxe || { echo "SED-MISSED-KERNEL-LINE"; exit 1; }
grep -q "http://10.0.2.2:8000" /work/test.ipxe || { echo "SED-MISSED-URL"; exit 1; }
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

# --- 2. serve kernel/initrd locally ---------------------------------------
mkdir -p /srv/t && cd /srv/t
cp /w/.cache/${REL}-vmlinuz ${KNAME}
cp /w/.cache/${REL}-initrd initrd
python3 -m http.server 8000 &>/dev/null &
sleep 1

# --- 3. boot, walk menu, land in initramfs shell, inspect ----------------
feed() {
  sleep 14
  printf '0\r'; sleep 3
  printf '10.0.2.15/27\r'; sleep 2
  printf '\r'; sleep 2
  printf 'srv1\r'; sleep 2
  printf '\t'; sleep 2
  printf 'Passw0rd123\r'; sleep 4
  printf '\r'; sleep 3      # review -> continue
  printf "${ARROWS}\r"; sleep 75  # select u${REL}; local fetch + boot to break=top
  printf 'echo MARK1; ls /conf/param.conf /scripts/casper-bottom/99fluxseed /flux-preseed.cfg /flux-ks.cfg /flux-autoinst.xml /flux-agama.json /flux-scrub\n'; sleep 3
  printf 'echo MARK2; cat /conf/param.conf\n'; sleep 3
  printf 'echo MARK3; head -3 /scripts/casper-bottom/99fluxseed\n'; sleep 3
}
feed | timeout 240 qemu-system-x86_64 -m 2048 -cdrom /work/test.iso \
  -nographic -boot d 2>&1 | tee /tmp/e2e.log | tail -30

echo "===== E2E CHECKS (REL=$REL base=$BASE) ====="
echo "exec-failed(0):   $(grep -c 'Could not boot' /tmp/e2e.log)"
echo "unpack-failed(0): $(grep -c 'Initramfs unpacking failed' /tmp/e2e.log)"
echo "rootdev-panic(0): $(grep -c 'Cannot open root device' /tmp/e2e.log)"
echo "initramfs-shell:  $(grep -c '(initramfs)' /tmp/e2e.log)"
grep -A4 "MARK1" /tmp/e2e.log | head -8
grep -A4 "MARK2" /tmp/e2e.log | head -6
grep -A4 "MARK3" /tmp/e2e.log | head -5
