#!/usr/bin/env bash
# Drive src/99fluxseed the way casper does and check what it leaves behind.
#
# The failure this exists for: the seed described the network for the INSTALLED
# system but never for the installer image itself, so cloud-init in the live
# environment fell back to DHCP. On a static-only network - the only kind this
# product configures - nothing answers, and cloud-init-network.service sits at
# "start running (9min / no limit)" with the install never starting. The matrix
# never caught it because QEMU's user-mode network always hands out a lease.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
rc=0
ok()   { echo "SEED OK      $1"; }
bad()  { echo "SEED FAIL    $1"; rc=1; }

mkdir -p "$WORK/scripts" "$WORK/root"
cat > "$WORK/scripts/casper-functions" <<'F'
log_begin_msg() { :; }
log_end_msg() { :; }
F

CMD="BOOT_IMAGE=/casper/vmlinuz initrd=initrd.magic ip=203.0.113.10::203.0.113.1:255.255.255.224:web12::none:9.9.9.9:149.112.112.112 BOOTIF=01-7c-d3-0a-d7-a9-f0 hostname=web12 autoinstall ds=nocloud fluxhost=web12 fluxpass=Sup3rSecret! fluxcidr=27 console=tty0"
run_seed() { # <cmdline>
	rm -rf "$WORK/root"; mkdir -p "$WORK/root"
	printf '%s\n' "$1" > "$WORK/cmdline"
	( export flux_cmdline="$WORK/cmdline" flux_root="$WORK/root" \
	         flux_casper_functions="$WORK/scripts/casper-functions"
	  sh ./src/99fluxseed >/dev/null 2>&1 )
}
SEED="$WORK/root/var/lib/cloud/seed/nocloud"

run_seed "$CMD"
[ -f "$SEED/user-data" ] && ok "autoinstall mode writes the NoCloud seed" \
	|| bad "no user-data written"
[ -f "$SEED/meta-data" ] && ok "meta-data written" || bad "no meta-data written"

# The fix itself: the live image must be told its address, or it DHCPs forever.
if [ -f "$SEED/network-config" ]; then
	ok "network-config written for the live environment"
else
	bad "no network-config - cloud-init will fall back to DHCP and hang"
fi
grep -q "203.0.113.10/27" "$SEED/network-config" 2>/dev/null \
	&& ok "live network carries the address the operator typed" \
	|| bad "live network is missing the static address"
grep -q "via: 203.0.113.1" "$SEED/network-config" 2>/dev/null \
	&& ok "live network carries the gateway" || bad "live network has no gateway"
grep -q "dhcp4: false" "$SEED/network-config" 2>/dev/null \
	&& ok "DHCP explicitly disabled in the live environment" \
	|| bad "DHCP not disabled - the hang can come back"
grep -q "7c:d3:0a:d7:a9:f0" "$SEED/network-config" 2>/dev/null \
	&& ok "live network is matched to the boot NIC by MAC" \
	|| bad "live network does not match the boot NIC"
# Nameservers come from the ip= argument, not from a hardcoded pair.
grep -q "9.9.9.9" "$SEED/network-config" 2>/dev/null \
	&& ok "live resolver comes from the menu, not a default" \
	|| bad "live resolver is not the one the operator configured"

# The installed system must not probe cloud metadata on every boot: that is a
# ~5 minute stall per reboot on bare metal, measured in the field.
grep -q "datasource_list: \[ NoCloud, None \]" "$SEED/user-data" 2>/dev/null \
	&& ok "installed system's datasource list is pinned to local sources" \
	|| bad "no datasource pin - every boot will hunt for cloud metadata"
grep -q "90-flux-datasource.cfg" "$SEED/user-data" 2>/dev/null \
	&& ok "datasource pin is written through curtin in-target" \
	|| bad "datasource pin is not applied to the target"

# Speed of the install itself: no global-mirror pin, no driver lookup, and a
# mirror that cannot answer must not block the install.
# A uri: line, not any mention - the comment above the setting names the old
# host on purpose, and matching that would fail for the wrong reason.
grep -qE "^[^#]*uri:.*archive\.ubuntu\.com" "$SEED/user-data" 2>/dev/null \
	&& bad "apt is still pinned to the global archive host" \
	|| ok "apt is not pinned to the slow global archive"
grep -q "geoip: true" "$SEED/user-data" 2>/dev/null \
	&& ok "apt picks a country mirror by geoip" || bad "no geoip mirror selection"
grep -q "fallback: offline-install" "$SEED/user-data" 2>/dev/null \
	&& ok "an unusable mirror falls back to installing from the ISO" \
	|| bad "an unusable mirror can still block the install"
grep -qA1 "^  drivers:" "$SEED/user-data" 2>/dev/null \
	&& ok "third-party driver lookup is off" || bad "driver lookup still runs"

DROPIN="$WORK/root/etc/systemd/system/cloud-init-network.service.d/99-flux-timeout.conf"
grep -q "TimeoutStartSec=300" "$DROPIN" 2>/dev/null \
	&& ok "cloud-init network stage can no longer hang without limit" \
	|| bad "no timeout backstop for cloud-init-network.service"

# Invariants that existed before this change and must survive it.
grep -q "Sup3rSecret" "$SEED/user-data" 2>/dev/null \
	&& bad "the password leaked into user-data" \
	|| ok "password stays out of user-data"
grep -q "local-hostname: web12" "$SEED/meta-data" 2>/dev/null \
	&& ok "hostname reaches meta-data" || bad "hostname missing from meta-data"

# MANUAL mode: no autoinstall keyword, so nothing may be written at all - an
# autoinstall: key in user-data would wipe the disk of an interactive install.
run_seed "${CMD/ autoinstall/}"
[ -e "$SEED/user-data" ] && bad "manual mode wrote a seed anyway" \
	|| ok "manual mode writes no seed"
[ -e "$WORK/root/etc/systemd/system/cloud-init-network.service.d" ] \
	&& bad "manual mode touched the live system" \
	|| ok "manual mode leaves the live system alone"

# --- no install, in any family, pulls updates -------------------------------
# Deterministic installs: two servers built weeks apart get the same bits, and
# on a slow path the install never turns into a package download. Patching is
# the installed system's job. Each family has its own way of saying it, so
# each is asserted where it is actually written.
run_seed "$CMD"   # regenerate after the manual-mode case above

grep -q "disable_suites: \[security, updates, backports, proposed\]" "$SEED/user-data" 2>/dev/null \
	&& ok "ubuntu: every updating pocket is off during the install" \
	|| bad "ubuntu: an updating pocket is still live during the install"
grep -q "package_upgrade: false" "$SEED/user-data" 2>/dev/null \
	&& ok "ubuntu: no upgrade on first boot" || bad "ubuntu: first boot still upgrades"
grep -q "Suites: \$C \$C-updates \$C-security \$C-backports" "$SEED/user-data" 2>/dev/null \
	&& ok "ubuntu: the installed system gets its pockets back" \
	|| bad "ubuntu: installed system would be stuck on release-day packages"

grep -q "^d-i pkgsel/upgrade select none" src/preseed.cfg \
	&& ok "debian/d-i: no upgrade during install" || bad "debian/d-i: upgrade still runs"
grep -q "^d-i pkgsel/update-policy select none" src/preseed.cfg \
	&& ok "debian/d-i: no automatic updates configured" \
	|| bad "debian/d-i: update policy still set"

grep -q "<do_online_update config:type=\"boolean\">false</do_online_update>" src/autoinst.xml \
	&& ok "leap/autoyast: online update off" || bad "leap/autoyast: online update can still run"

grep -qE "^\s*(dnf|yum)\s+(-y\s+)?(update|upgrade)" src/ks.cfg \
	&& bad "rhel family: kickstart runs an update step" \
	|| ok "rhel family: kickstart installs from the repo only, no update step"

[ "$rc" = 0 ] && echo "seed: OK" || echo "seed: FAIL"
exit "$rc"
