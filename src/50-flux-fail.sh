#!/bin/sh
# FluxBilling: dracut's half of the failure banner - see the panic() wrapper in
# src/param.conf for the casper half and the reasoning behind both.
#
# dracut runs every script in its emergency hook directory before it opens the
# emergency shell, and that shell lands on ONE console (the last console= on
# the cmdline, the serial line in AUTOMATED mode). This prints the same
# labelled banner to every console the kernel has, so the failure is readable
# on an iDRAC/iLO screen as well. It does not reboot and does not change what
# dracut does next.
#
# Injected at the initramfs root as /flux-fail.sh, and copied into dracut's
# own emergency hook directory at boot by src/flux-fail.conf - no cpio path
# reaches that directory on every release (EL8/EL9 keep it in usr/lib, EL10
# and Leap 16 in var/lib; the imgargs block in fluxbilling.ipxe has why). An
# initramfs that is not dracut never copies it, so it never runs there.
#
# dracut runs its emergency hooks with no arguments, so the reason usually
# comes from a file: the one src/flux-giveup.sh writes when the installer image
# never arrived, else the last critical error anaconda's dracut module logged.
flux_reason="$1"
if [ -z "$flux_reason" ] && [ -s "${flux_run:-/run}/flux-fail.reason" ]; then
	flux_reason=$(cat "${flux_run:-/run}/flux-fail.reason")
fi
if [ -z "$flux_reason" ] && [ -s "${flux_run:-/run}/anaconda/initrd_errors.txt" ]; then
	while IFS= read -r flux_l; do flux_reason=$flux_l; done \
		< "${flux_run:-/run}/anaconda/initrd_errors.txt"
fi
flux_reason="${flux_reason:-the installer stopped without a message}"
# The paths are variables so src/console-ux-test.sh can aim them at a temp
# directory; in a real initramfs they are the defaults.
seen=""
for d in $(awk '{print $1}' "${flux_proc_consoles:-/proc/consoles}" 2>/dev/null) tty0 ttyS0; do
	case " $seen " in *" $d "*) continue ;; esac
	seen="$seen $d"
	dev="${flux_devdir:-/dev}/$d"
	{ [ -c "$dev" ] || [ -f "$dev" ]; } || continue
	{
		printf '\n\033[1;31m'
		printf '======================================================\n'
		printf '  FluxBilling OS - INSTALL FAILED\n'
		printf '======================================================\033[0m\n'
		# A reason may span lines; keep them under the first one, each cut to
		# one row of an 80-column console. On an 80x25 BIOS text screen this
		# banner and dracut's emergency text below it fill every row, so a
		# line that wrapped would scroll the title off the top. The full
		# text is in the journal and the serial scrollback.
		printf '%s\n' "$flux_reason" | {
			flux_label='Reason:'
			while IFS= read -r flux_l; do
				printf '  %-8s%.70s\n' "$flux_label" "$flux_l"
				flux_label=
			done
		}
		printf '  Nothing has been written to the target disk.\n'
		printf '\n'
		printf '  The server is HELD here on purpose - it will not\n'
		printf '  reboot on its own. Reset it (or Ctrl-Alt-Del) to\n'
		printf '  return to the FluxBilling boot menu and pick an\n'
		printf '  entry again.\n'
		printf '======================================================\n\n'
	} > "$dev" 2>/dev/null
done
