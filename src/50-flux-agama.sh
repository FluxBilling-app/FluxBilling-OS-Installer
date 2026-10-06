#! /bin/sh
# FluxBilling: hand the embedded Agama profile across the switch_root.
# Injected into the Leap 16.0 (Agama live) initrd as
# /var/lib/dracut/hooks/pre-pivot/50-flux-agama.sh by the iPXE menu.
#
# Agama is the only family here whose installer runs AFTER the pivot, so a
# file at the initrd root is gone by the time inst.auto is read. /run is the
# tmpfs systemd moves into the live system - Agama's own hooks pass state that
# way (see 99-save-agama-conf.sh writing /run/agama/*) - so the profile is
# copied there and inst.auto reads it back as file:///run/flux-agama.json.
#
# Runs in MANUAL mode too, which is harmless: nothing reads the file unless
# the menu put inst.auto on the kernel command line, and Agama's own profile
# auto-probe only looks at OEMDRV / the install medium / the squashfs root.

# dracut SOURCES its hooks, so no `return` at top level here - it would abort
# the sourcing shell if this ever gets executed instead.
[ -e /dracut-state.sh ] && . /dracut-state.sh

if [ -e /flux-agama.json ]; then
    mkdir -p /run
    # @ZH@ -> fluxhost=, substituted HERE rather than echoed into
    # /mnt/etc/hostname by the post-script: Agama's own finish step writes
    # the hostname from its OWN settings AFTER post-scripts run, so a file
    # written there is overwritten with an empty one (matrix-proven: SSH up,
    # password right, hostname blank). The profile's hostname.static is the
    # one channel Agama itself honours end to end.
    # getarg, NEVER a raw /proc/cmdline read: Leap 16's dracut runs its
    # hooks inside sandboxed systemd services where /proc/cmdline reads
    # back EMPTY (matrix-proven at both the cmdline and pre-pivot stages),
    # so the raw read silently yields the fallback hostname on every boot.
    # dracut-lib's getarg answers from dracut's own cached copy and is the
    # canonical way for a hook to read a boot argument.
    type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
    _H=$(getarg fluxhost= 2>/dev/null)
    [ -n "$_H" ] || _H=fluxserver
    # Breadcrumb to the kernel log: this hook runs pre-pivot inside the
    # initrd, where nothing else records what it saw - and "wrong hostname
    # baked into the profile" is otherwise indistinguishable from an Agama
    # bug hours later.
    echo "flux-agama: fluxhost resolved to '$_H'" > /dev/kmsg 2>/dev/null || :
    sed "s/@ZH@/$_H/g" /flux-agama.json > /run/flux-agama.json
fi

# @ZDISK@ -> the install disk, by the rule every automated entry shares
# (src/flux-disks) - which, when the operator answered Yes on the menu's
# erase-all-disks screen (fluxwipe=1), also wipes every disk first. It cannot
# run here: this initrd need not have loaded every storage driver yet. And it
# cannot run as an Agama pre-script either: agama.service probes storage the
# moment it starts, before any profile is read, and a wipe after that probe
# leaves it planning against partitions that no longer exist. So it runs as a
# unit of its own in the live system, ordered Before=agama.service. /run is
# the one place that survives the pivot, and systemd loads units from
# /run/systemd/system once it re-executes in the new root.
#
# Automated mode only: without inst.auto no profile is read, and nothing may
# choose or wipe a disk behind the operator's back. If the unit never runs,
# the profile keeps @ZDISK@ - a drive Agama cannot find - and the install
# stops there.
if [ -e /flux-agama.json ] && [ -e /flux-disks ] && [ -n "$(getarg inst.auto= 2>/dev/null)" ]; then
    cp /flux-disks /run/flux-disks
    cat > /run/flux-agama-disks.sh <<'FLUXEOF'
#!/bin/sh
t=$(sh /run/flux-disks) || t=/dev/flux-no-fixed-disk-found
sed -i "s|@ZDISK@|$t|" /run/flux-agama.json
FLUXEOF
    mkdir -p /run/systemd/system/multi-user.target.wants
    cat > /run/systemd/system/flux-disks.service <<'FLUXEOF'
[Unit]
Description=FluxBilling: choose the install disk, wipe the disks if confirmed
After=systemd-udev-trigger.service local-fs.target
Before=agama.service agama-web-server.service agama-autoinstall.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Discarding a large SSD array can take minutes; a hung one must not hold
# the installer forever - Agama then starts and stops at @ZDISK@.
TimeoutStartSec=1800
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/bin/sh /run/flux-agama-disks.sh

[Install]
WantedBy=multi-user.target
FLUXEOF
    ln -sf ../flux-disks.service /run/systemd/system/multi-user.target.wants/flux-disks.service
fi
