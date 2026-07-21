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
    cp /flux-agama.json /run/flux-agama.json
fi
