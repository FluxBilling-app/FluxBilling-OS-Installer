# FluxBilling: a time limit on anaconda's wait for its installer image.
#
# With inst.repo/inst.stage2 on the network, anaconda's dracut module fetches
# the installer image (stage2) from an "online" hook that dracut re-runs on
# EVERY pass of its initqueue loop, until the image arrives. dracut does give
# up eventually - but after 2 x rd.retry passes (360 by default), counting
# passes, not time, and with the mirror or the network unreachable one pass is
# three curl fetches that each retry and wait on their own. Measured on Alma 9
# with the menu's own kernel line: 25 s a pass when the mirror refuses
# connections, 3 minutes with no gateway, 4.5 with DNS unreachable, 15 with
# every SYN dropped - so the emergency shell, and the INSTALL FAILED banner
# that hangs off it (src/50-flux-fail.sh), came 2.5 hours to 4 days late.
# Until then all an operator sees is "anaconda: failed to fetch stage2"
# scrolling past, with no banner and no prompt. An rd.retry= on the kernel
# line cannot fix that: it shortens the count, not the passes, and a value
# small enough for a 15-minute pass gives up on a 25-second one in a minute.
#
# This job replaces that pass count with a clock: when the image has not
# loaded within flux_giveup_secs of the first pass, it writes the reason for
# the banner and opens dracut's emergency shell itself - the one dracut
# would at the end of rd.retry. The first pass starts once the network is up
# (EL9/EL10 order dracut-initqueue after NetworkManager's wait-online; EL8
# runs NetworkManager inside the pass), so the budget goes on retrying the
# mirror. A download still running at the deadline is never cut short: this
# only runs between passes, and a pass that ends with the image in place
# ends the loop.
#
# MANUAL mode gets the same banner and shell. "Exit the shell to continue"
# keeps dracut's meaning: exiting starts another full budget of retries, so an
# operator who fixed a cable or a switch port can carry on without a reboot.
#
# Injected at the initramfs root as /flux-giveup.sh and copied into dracut's
# $hookdir/initqueue/ at boot by src/flux-fail.conf - no cpio path reaches the
# hook tree on every release (the imgargs block in fluxbilling.ipxe has why).
#
# SOURCED by dracut-initqueue on every pass of its main loop, never executed,
# in the loop's own shell: never `exit` (that would end dracut-initqueue), keep
# every variable under flux_, and do nothing slow until the budget is spent.
# The flux_* path overrides exist so src/console-ux-test.sh can run this
# against a temp directory; in a real initramfs they are the defaults.

# Only anaconda's network installs wait like this; any other dracut boot (and
# a disk or CD install) keeps dracut's own rules.
case "$root" in anaconda-net:*) ;; *) return 0 ;; esac
# The image is in place - dracut leaves the loop on this pass.
[ -e "${flux_dev_root:-/dev/root}" ] && return 0

flux_secs=${flux_giveup_secs:-300}
flux_at_file=${flux_run:-/run}/flux-giveup.at
read -r flux_now flux_rest < "${flux_proc_uptime:-/proc/uptime}"
flux_now=${flux_now%%.*}

if ! [ -s "$flux_at_file" ]; then
	echo $((flux_now + flux_secs)) > "$flux_at_file"
	# Bound each pass too, or the deadline is overshot by a whole one: url-lib
	# runs curl with --retry 3 and no connect timeout, which is how a pass
	# with dropped SYNs takes 15 minutes. It also points curl at
	# $CURL_HOME/.curlrc, which can add what the command line leaves unset:
	# a connect timeout (DNS and TLS included; a slow transfer is unaffected)
	# and no retries inside a fetch - dracut's next pass, half a second
	# later, is the retry. Measured, a dead-network pass drops to 1-1.5 min.
	mkdir -p "${CURL_HOME:-/run/initramfs/url-lib}"
	printf 'connect-timeout = 30\nretry-max-time = 1\n' \
		>> "${CURL_HOME:-/run/initramfs/url-lib}/.curlrc"
	return 0
fi
read -r flux_at flux_rest < "$flux_at_file"
[ "$flux_now" -lt "$flux_at" ] && return 0

# Out of time. curl's own words for the last failure tell DNS, routing, a dead
# mirror, a 404 and a TLS problem (wrong clock) apart, so the banner carries
# them; journalctl is in every dracut initramfs this menu boots. curl prints
# the error at the end of its progress meter, on the same \r-separated journal
# line, hence -o and a match that stops at the next control character.
flux_src=${root#anaconda-net:}
flux_host=${flux_src#*://}
flux_host=${flux_host%%/*}
flux_err=$(journalctl -b -q -o cat -t dracut-initqueue 2>/dev/null |
	grep -ao 'curl: ([0-9]*)[^[:cntrl:]]*' |
	{ flux_l=; while IFS= read -r flux_x; do flux_l=$flux_x; done; printf '%s' "$flux_l"; })
# Two short lines, naming the host only: on an 80x25 BIOS text console the
# banner, this reason and the emergency text below it (EL10's sulogin prompt
# adds two rows) leave room for three, the banner cuts each to 70 columns, and
# one more row scrolls the INSTALL FAILED title off the top. The full URL is
# in the warning line just below.
{
	echo "no installer image from $flux_host after $((flux_secs / 60)) minutes"
	[ -n "$flux_err" ] && echo "$flux_err"
} > "${flux_run:-/run}/flux-fail.reason"
emergency_shell "FluxBilling: no installer image after ${flux_secs}s from $flux_src - giving up"
# Back from the shell - the operator typed exit. Start a new budget.
read -r flux_now flux_rest < "${flux_proc_uptime:-/proc/uptime}"
echo $((${flux_now%%.*} + flux_secs)) > "$flux_at_file"
