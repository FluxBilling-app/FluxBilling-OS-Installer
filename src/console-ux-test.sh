#!/usr/bin/env bash
# Prove the two things an operator actually sees during an install behave:
#
#   - progress: casper's wget draws its bar on ONE console, so the other one
#     shows nothing for the 40+ minutes a slow ISO fetch takes. The watcher in
#     src/param.conf must mirror the download to the consoles wget is not on,
#     and must not print on the one it is (that would fight the bar).
#   - failure: print the reason on EVERY console, never reboot the machine,
#     and still leave the debug shell the stock initramfs would have opened.
#
# Runs offline in seconds - it drives the real src/param.conf panic() wrapper
# and the real dracut hook against a temp directory standing in for /dev, so
# there is no QEMU boot in the way of asserting the actual text an operator
# will read. What it cannot prove is that casper reaches our panic() at all;
# that is what the injection test (src/e2e-test.sh) and the boot smoke test
# (src/qemu-test.sh) are for.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
rc=0
ok()   { echo "BANNER OK    $1"; }
fail() { echo "BANNER FAIL  $1"; rc=1; }

# Stand-ins for the two consoles a Dell/HP box has in AUTOMATED mode: the
# video console and the serial line the installer UI actually draws on.
mkdir -p "$WORK/dev"
: > "$WORK/dev/tty0"
: > "$WORK/dev/ttyS0"
printf 'ttyS0                -W- (EC p  a)    4:64\ntty0                 -WU (EC p  )    4:1\n' > "$WORK/consoles"

# A reboot or halt from the failure path is the thing we are asserting does
# NOT happen, so make either one leave a trace instead of acting.
mkdir -p "$WORK/bin"
for c in reboot halt setsid chvt; do
	printf '#!/bin/sh\ntouch "%s/called-%s"\nexit 0\n' "$WORK" "$c" > "$WORK/bin/$c"
	chmod +x "$WORK/bin/$c"
done

REASON="Unable to find a live file system on the network"

# --- casper half: the panic() wrapper in src/param.conf ---------------------
cat > "$WORK/drive-casper.sh" <<'DRV'
# Stand in for the parts of initramfs-tools our wrapper leans on.
# flux_progress_on: param.conf starts its download watcher when sourced, and
# this case is about panic() - the watcher gets its own section below.
flux_progress_on=1
run_scripts() { touch "$WORK/ran-panic-hooks"; }
panic() { touch "$WORK/vendor-panic-ran"; }   # overwritten by param.conf
. ./src/param.conf
panic "$REASON"
DRV
( export WORK REASON PATH="$WORK/bin:$PATH" flux_devdir="$WORK/dev" flux_proc_consoles="$WORK/consoles"
  bash "$WORK/drive-casper.sh" >/dev/null 2>&1 )

for c in tty0 ttyS0; do
	if grep -q "INSTALL FAILED" "$WORK/dev/$c" 2>/dev/null; then
		ok "casper banner reached /dev/$c"
	else
		fail "casper banner never reached /dev/$c"
	fi
done
grep -q "$REASON" "$WORK/dev/tty0" && ok "casper banner carries the reason" \
	|| fail "casper banner does not carry the reason"
grep -qi "will not" "$WORK/dev/tty0" && ok "casper banner says it is holding" \
	|| fail "casper banner does not tell the operator it is holding"
grep -qi "boot menu" "$WORK/dev/tty0" && ok "casper banner says how to get back to the menu" \
	|| fail "casper banner does not say how to get back to the menu"
[ -e "$WORK/called-reboot" ] && fail "casper path called reboot" || ok "casper path never rebooted"
[ -e "$WORK/called-halt" ]   && fail "casper path called halt"   || ok "casper path never halted"
[ -e "$WORK/ran-panic-hooks" ] && ok "casper path still runs /scripts/panic" \
	|| fail "casper path skipped /scripts/panic"
[ -e "$WORK/vendor-panic-ran" ] && fail "the stock panic() ran instead of ours" \
	|| ok "our panic() replaced the stock one"

# A panic= boot argument must NOT turn this into a reboot loop - that is the
# whole reason the wrapper drops the stock reboot branch.
: > "$WORK/dev/tty0"; : > "$WORK/dev/ttyS0"
( export WORK REASON PATH="$WORK/bin:$PATH" flux_devdir="$WORK/dev" flux_proc_consoles="$WORK/consoles" panic=30
  bash "$WORK/drive-casper.sh" >/dev/null 2>&1 )
[ -e "$WORK/called-reboot" ] && fail "panic=30 still rebooted the box" \
	|| ok "panic=30 does not reboot the box"

# --- dracut half: src/50-flux-fail.sh ---------------------------------------
: > "$WORK/dev/tty0"; : > "$WORK/dev/ttyS0"
( export flux_devdir="$WORK/dev" flux_proc_consoles="$WORK/consoles"
  sh ./src/50-flux-fail.sh "$REASON" >/dev/null 2>&1 )
for c in tty0 ttyS0; do
	if grep -q "INSTALL FAILED" "$WORK/dev/$c" 2>/dev/null; then
		ok "dracut banner reached /dev/$c"
	else
		fail "dracut banner never reached /dev/$c"
	fi
done
grep -q "$REASON" "$WORK/dev/ttyS0" && ok "dracut banner carries the reason" \
	|| fail "dracut banner does not carry the reason"

# --- the console a real box would have missed --------------------------------
# /proc/consoles lists ttyS0 first in AUTOMATED mode, which is exactly why the
# stock shell was invisible on video. Assert we still wrote to tty0 when the
# kernel only names ttyS0.
: > "$WORK/dev/tty0"; : > "$WORK/dev/ttyS0"
printf 'ttyS0                -W- (EC p  a)    4:64\n' > "$WORK/consoles"
( export flux_devdir="$WORK/dev" flux_proc_consoles="$WORK/consoles"
  sh ./src/50-flux-fail.sh "$REASON" >/dev/null 2>&1 )
grep -q "INSTALL FAILED" "$WORK/dev/tty0" \
	&& ok "video console still gets the banner when only ttyS0 is registered" \
	|| fail "video console missed the banner - the original bug is back"

# --- dracut half, delivery: src/flux-fail.conf --------------------------------
# No cpio path reaches dracut's hook directory on every release (the imgargs
# block in fluxbilling.ipxe has why), so the hook rides in at the initramfs
# root and a conf.d snippet copies it into $hookdir when a dracut stage sources
# /etc/conf.d. EVERY stage sources that snippet, and dracut's sh is bash in
# POSIX mode, where a `.` file that does not parse ends the sourcing script -
# so a typo here would stop every dracut install cold, not just the banner.
for f in src/flux-fail.conf src/50-flux-fail.sh; do
	bash --posix -n "$f" 2>/dev/null && ok "$f parses as POSIX-mode bash" \
		|| fail "$f does not parse - a dracut stage that sources it would die"
	if command -v dash >/dev/null 2>&1; then
		dash -n "$f" 2>/dev/null && ok "$f parses as dash" \
			|| fail "$f does not parse as dash"
	fi
done

# Source it the way dracut's source_conf does, with $hookdir pointing at a
# stand-in hook tree.
mkdir -p "$WORK/hooks/emergency"
cp ./src/50-flux-fail.sh "$WORK/flux-fail.sh"
source_flux_conf() { # <hookdir> -> prints the status the snippet left behind
	hookdir=$1 flux_fail_hook="$WORK/flux-fail.sh" \
		bash --posix -c '. ./src/flux-fail.conf; echo "$?"' 2>/dev/null
}
rc=$(source_flux_conf "$WORK/hooks")
if [ "$rc" = 0 ] && cmp -s "$WORK/hooks/emergency/50-flux-fail.sh" ./src/50-flux-fail.sh; then
	ok "conf.d snippet installs the hook into \$hookdir/emergency"
else
	fail "conf.d snippet did not install the hook (status '$rc')"
fi
rc=$(source_flux_conf "$WORK/hooks")
[ "$rc" = 0 ] && ok "sourcing it again (every later stage does) still succeeds" \
	|| fail "re-sourcing the conf.d snippet returned '$rc'"
rc=$(env -u hookdir flux_fail_hook="$WORK/flux-fail.sh" \
	bash --posix -c '. ./src/flux-fail.conf; echo "$?"' 2>/dev/null)
[ "$rc" = 0 ] && ok "no \$hookdir (not dracut): the snippet does nothing, successfully" \
	|| fail "without \$hookdir the conf.d snippet returned '$rc'"
mkdir -p "$WORK/nohooks"
rc=$(source_flux_conf "$WORK/nohooks")
if [ "$rc" = 0 ] && [ -z "$(ls -A "$WORK/nohooks")" ]; then
	ok "no emergency hook directory: nothing created, still succeeds"
else
	fail "with no emergency hook dir the snippet returned '$rc' or created files"
fi

# Run what it installed the way dracut's source_hook does: sourced, with no
# arguments - so the operator gets the default reason, not an empty one.
: > "$WORK/dev/tty0"; : > "$WORK/dev/ttyS0"
printf 'ttyS0                -W- (EC p  a)    4:64\ntty0                 -WU (EC p  )    4:1\n' > "$WORK/consoles"
( export flux_devdir="$WORK/dev" flux_proc_consoles="$WORK/consoles" hd="$WORK/hooks/emergency"
  bash --posix -c 'for f in "$hd"/*.sh; do [ -e "$f" ] && . "$f"; done' >/dev/null 2>&1 )
for c in tty0 ttyS0; do
	if grep -q "INSTALL FAILED" "$WORK/dev/$c" 2>/dev/null; then
		ok "installed hook, run as dracut runs it, reached /dev/$c"
	else
		fail "installed hook, run as dracut runs it, never reached /dev/$c"
	fi
done
grep -q "stopped without a message" "$WORK/dev/tty0" \
	&& ok "dracut passes no reason, so the banner falls back to its default" \
	|| fail "the hook printed no reason line when dracut passed none"

# The menu has to put both files where the snippet expects them, and must not
# stamp ANY path through a directory the vendor initrds ship as a symlink:
# those files unpack before the vendor's, so the path is either dropped or,
# with mkdir=, turned into a real directory that the vendor symlink can no
# longer replace (that is how an EL initrd loses /lib/dracut-lib.sh).
conf_path=$(sed -n 's|^imgargs flux-fail\.conf \([^ ]*\).*|\1|p' fluxbilling.ipxe)
hook_path=$(sed -n 's|^imgargs 50-flux-fail\.sh \([^ ]*\).*|\1|p' fluxbilling.ipxe)
want_hook=$(sed -n 's|.*${flux_fail_hook:-/\([^}]*\)}.*|\1|p' src/flux-fail.conf)
[ "$conf_path" = "etc/conf.d/flux-fail.conf" ] \
	&& ok "menu stamps the snippet into etc/conf.d" \
	|| fail "menu stamps flux-fail.conf at '$conf_path', not etc/conf.d/flux-fail.conf"
[ -n "$hook_path" ] && [ "$hook_path" = "$want_hook" ] \
	&& ok "menu puts the hook where the snippet copies it from (/$hook_path)" \
	|| fail "menu puts the hook at '$hook_path', the snippet copies '/$want_hook'"
bad=$(sed -n 's|^imgargs [^ ]* \([^ ]*\).*|\1|p' fluxbilling.ipxe |
	grep -E '^(lib|lib64|bin|sbin)/|^usr/lib/dracut/hooks/' | tr '\n' ' ')
[ -z "$bad" ] && ok "no injected path runs through a vendor symlink" \
	|| fail "injected path(s) through a vendor symlink: $bad"

# --- progress watcher: src/param.conf ---------------------------------------
# A fake /proc holding one wget whose -O target is a file we control, and a
# /proc/consoles that names ttyS0 first - the AUTOMATED-mode layout, where the
# bar goes to serial and the video console is the one left blank.
: > "$WORK/dev/tty0"; : > "$WORK/dev/ttyS0"
printf 'ttyS0                -W- (EC p  a)    4:64\ntty0                 -WU (EC p  )    4:1\n' > "$WORK/consoles"
mkdir -p "$WORK/proc/4242"
ISO="$WORK/ubuntu-26.04-latest-live-server-amd64.iso"
python3 - "$ISO" <<'MK'
import sys
with open(sys.argv[1], "wb") as f:
    f.truncate(547 * 1024 * 1024)   # the size the real box was sitting at
MK
printf 'wget\0https://releases.ubuntu.com/resolute/ubuntu-26.04-latest-live-server-amd64.iso\0-O\0%s\0' "$ISO" > "$WORK/proc/4242/cmdline"
printf '812.44 3201.11\n' > "$WORK/proc/uptime"

cat > "$WORK/drive-progress.sh" <<'DRV'
panic() { :; }
run_scripts() { :; }
. ./src/param.conf
sleep 7
DRV
( export WORK PATH="$WORK/bin:$PATH" flux_devdir="$WORK/dev" \
         flux_proc_consoles="$WORK/consoles" flux_procdir="$WORK/proc"
  bash "$WORK/drive-progress.sh" >/dev/null 2>&1 )

grep -q "downloading ubuntu-26.04-latest-live-server-amd64.iso" "$WORK/dev/tty0" \
	&& ok "progress reaches the console wget is NOT drawing on" \
	|| fail "progress never reached the video console"
grep -q "547 MB" "$WORK/dev/tty0" && ok "progress reports how much has landed" \
	|| fail "progress does not report the byte count"
grep -q "13m32s elapsed" "$WORK/dev/tty0" && ok "progress reports elapsed time" \
	|| fail "progress does not report elapsed time"
# The primary console is wget's; printing there would interleave with its bar.
if [ -s "$WORK/dev/ttyS0" ]; then
	fail "progress also printed on wget's own console"
else
	ok "progress stays off wget's own console"
fi
# When the download ends the watcher must say so and stop, not sit forever.
rm -rf "$WORK/proc/4242"
sleep 8
grep -q "mounting it and starting the installer" "$WORK/dev/tty0" \
	&& ok "progress announces the handover to the installer" \
	|| fail "progress never announced the end of the download"
if pgrep -f drive-progress.sh >/dev/null 2>&1; then
	fail "progress watcher outlived the download"
else
	ok "progress watcher exits once wget is gone"
fi

# One console only: wget already draws there, so the watcher must stay silent.
: > "$WORK/dev/tty0"; : > "$WORK/dev/ttyS0"
printf 'ttyS0                -W- (EC p  a)    4:64\n' > "$WORK/consoles"
rm -f "$WORK/dev/tty0"
mkdir -p "$WORK/proc/4243"; cp "$WORK/proc/4242/cmdline" "$WORK/proc/4243/cmdline" 2>/dev/null
printf 'wget\0-O\0%s\0' "$ISO" > "$WORK/proc/4243/cmdline"
( export WORK PATH="$WORK/bin:$PATH" flux_devdir="$WORK/dev" \
         flux_proc_consoles="$WORK/consoles" flux_procdir="$WORK/proc"
  bash "$WORK/drive-progress.sh" >/dev/null 2>&1 )
if [ -s "$WORK/dev/ttyS0" ]; then
	fail "watcher duplicated the bar onto the only console there is"
else
	ok "single console: watcher stays quiet"
fi

# --- mirror picker: src/flux-mirror-pick ------------------------------------
# A stub wget that reports a per-URL speed the way the real one does - by
# leaving an rchar count in /proc/<pid>/io - plus stubs for the mount path, so
# the whole do_urlmount decision can be driven without a network or an ISO.
mkdir -p "$WORK/conf" "$WORK/mnt"
echo "fc54d02b-b0cf-4470-96ca-93f8ccb4689c" > "$WORK/conf/uuid.conf"
cat > "$WORK/bin/wget" <<'WG'
#!/bin/sh
mkdir -p "$flux_procdir/$$"
url=""; out=""; quiet=""
prev=""
for a in "$@"; do
	case $prev in -O) out=$a ;; esac
	case $a in http*) url=$a ;; -q) quiet=1 ;; esac
	prev=$a
done
# -q marks a PROBE (flux_probe/flux_probe_into); the real fetch is not quiet.
# Without this the final download would also be treated as a probe and hang.
[ -n "$quiet" ] || out="${out}!real"
case "$out" in
	-)   # directory index
		echo '<a href="ubuntu-26.04.1-live-server-amd64.iso">ubuntu-26.04.1-live-server-amd64.iso</a>'
		exit 0 ;;
	*'!real')   # the real fetch: completes at once
		out=${out%!real}
		echo "$url" > "$WORK/fetched-from"
		: > "$out"
		exit 0 ;;
	*.iso)   # origin probe: measured like a probe, but keeps the bytes
		echo "rchar: ${FAKE_ORIGIN_RCHAR:-1600000}" > "$flux_procdir/$$/io"
		: > "$out"
		exec sleep 30 </dev/null >/dev/null 2>&1 ;;
	/dev/null)   # speed probe: fast only for the mirror we want to win
		case "$url" in
			*fastmirror*) echo "rchar: 600000000" > "$flux_procdir/$$/io" ;;
			*slowmirror*) echo "rchar: 1000000"   > "$flux_procdir/$$/io" ;;
			*) echo "rchar: ${FAKE_ORIGIN_RCHAR:-1600000}" > "$flux_procdir/$$/io" ;;
		esac
		# exec, and with the inherited stdout closed: a plain `sleep` would be
		# an orphan holding the command-substitution pipe open long after
		# flux_probe killed its parent, which hangs the whole test.
		exec sleep 30 </dev/null >/dev/null 2>&1 ;;
	*)   # the real fetch
		echo "$url" > "$WORK/fetched-from"
		: > "$out"
		exit 0 ;;
esac
WG
chmod +x "$WORK/bin/wget"

drive_mirror() { # <origin-rchar> <casper-ok> <uuid-ok> -> prints "rc|URL|UUID"
cat > "$WORK/drive-mirror.sh" <<'DRV'
flux_consoles() { echo "$WORK/dev/tty0"; }
mountpoint="$WORK/mnt"; MP_QUIET=-q
modprobe() { :; }
mount() { :; }
umount() { :; }
is_casper_path() { [ "$CASPER_OK" = 1 ]; }
# Modelled on casper's own: an empty UUID (what ignore_uuid leaves behind)
# short-circuits to success, which is exactly what the origin path relies on.
matches_uuid() { [ -z "$UUID" ] && return 0; [ "$UUID_OK" = 1 ]; }
URL="https://releases.ubuntu.com/resolute/ubuntu-26.04-latest-live-server-amd64.iso"
. ./src/flux-mirror-pick
FLUX_MIRRORS="https://slowmirror.test/ubuntu-releases
https://fastmirror.test/ubuntu-releases"
cd "$WORK"
do_urlmount; printf '%s|%s|%s
' "$?" "$URL" "$UUID"
DRV
	( export WORK PATH="$WORK/bin:$PATH" flux_devdir="$WORK/dev" flux_procdir="$WORK/proc" \
	         flux_proc_consoles="$WORK/consoles" flux_confdir="$WORK/conf" \
	         FAKE_ORIGIN_RCHAR="$1" CASPER_OK="$2" UUID_OK="$3"
	  bash "$WORK/drive-mirror.sh" 2>/dev/null | tail -n1 )
}

: > "$WORK/dev/tty0"
out=$(drive_mirror 1600000 1 1)     # origin 0.8 MB/s, mirror mounts cleanly
case "$out" in
	0\|https://fastmirror.test/*) ok "slow origin: switches to the fastest mirror" ;;
	*) fail "slow origin: expected the fast mirror, got '$out'" ;;
esac
case "$out" in
	*\|fc54d02b-*) ok "mirror is checked against this initrd's casper uuid" ;;
	*) fail "mirror was mounted without restoring the uuid check: '$out'" ;;
esac
grep -q "using https://fastmirror.test" "$WORK/dev/tty0" \
	&& ok "mirror choice is announced on the console" \
	|| fail "mirror choice was never announced"

: > "$WORK/dev/tty0"
out=$(drive_mirror 1600000 1 0)     # mirror is a different compose
case "$out" in
	0\|https://releases.ubuntu.com/*\|) ok "stale mirror falls back to the origin, uuid check off" ;;
	*) fail "stale mirror did not fall back cleanly: '$out'" ;;
esac
grep -q "falling back to releases.ubuntu.com" "$WORK/dev/tty0" \
	&& ok "fallback is announced on the console" \
	|| fail "fallback was never announced"

: > "$WORK/dev/tty0"
out=$(drive_mirror 60000000 1 1)    # origin already ~28 MB/s
case "$out" in
	0\|https://releases.ubuntu.com/*) ok "fast origin: no mirror race at all" ;;
	*) fail "fast origin: should have stayed on the origin, got '$out'" ;;
esac
grep -q "fetching from releases.ubuntu.com" "$WORK/dev/tty0" \
	&& ok "fast origin is reported, not silently assumed" \
	|| fail "fast origin was not reported"

[ "$rc" = 0 ] && echo "console ux: OK" || echo "console ux: FAIL"
exit "$rc"
