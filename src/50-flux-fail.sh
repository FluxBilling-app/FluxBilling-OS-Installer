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
# Injected as var/lib/dracut/hooks/emergency/50-flux-fail.sh - the same hook
# directory the Agama pre-pivot script already rides in on (see the imgargs
# block in fluxbilling.ipxe); a kernel whose initramfs is not dracut simply
# never runs it.
flux_reason="${1:-the installer stopped without a message}"
# Both paths are variables so src/console-ux-test.sh can aim them at a temp
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
		printf '  Reason: %s\n' "$flux_reason"
		printf '  Nothing has been written to the target disk.\n'
		printf '\n'
		printf '  The server is HELD here on purpose - it will not\n'
		printf '  reboot on its own. Reset it (or Ctrl-Alt-Del) to\n'
		printf '  return to the FluxBilling boot menu and pick an\n'
		printf '  entry again.\n'
		printf '======================================================\n\n'
	} > "$dev" 2>/dev/null
done
