# FluxBilling builder image — everything preinstalled + iPXE pre-compiled.
# Build once:  docker build --platform linux/amd64 -t fluxbilling-builder -f src/builder.Dockerfile src
# After that ./build.sh takes ~15 seconds: it only regenerates the embedded
# payload object and relinks (the whole object tree is baked below).
# Digest-pinned: a floating tag lets base-image drift change the toolchain
# (and therefore the binary) between two otherwise-identical builds. Bump
# deliberately: docker buildx imagetools inspect debian:bookworm
FROM debian:bookworm@sha256:9344f8b8992482f80cba753f323adeaf17690076c095ccff6cc9536be98185dc
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git make gcc binutils perl liblzma-dev mtools genisoimage syslinux isolinux \
    syslinux-common syslinux-utils xorriso cpio zstd initramfs-tools-core python3-pil \
    fonts-dejavu-core gcc-multilib libc6-dev-i386 xz-utils \
    qemu-system-x86 ovmf ca-certificates curl && rm -rf /var/lib/apt/lists/*
# (xz-utils: sign-boot-images.sh extracts data.tar.xz out of Ubuntu udebs/debs
#  inside this image - tar execs the xz binary, liblzma-dev alone is not it)
# (syslinux-common: ldlinux.c32 — genfsimg silently omits it otherwise and
#  BIOS isolinux dies with "Failed to load ldlinux.c32")
# (syslinux-utils: /usr/bin/isohybrid. genfsimg picks the FIRST available of
#  genisoimage/mkisofs/xorrisofs — genisoimage here — and that path only gets a
#  hybrid MBR from a post-pass guarded by "isohybrid --version >/dev/null 2>&1".
#  Debian ships isohybrid in syslinux-utils, NOT syslinux/isolinux/syslinux-common,
#  so without this the guard fails SILENTLY: the ISO builds fine and boots fine
#  over virtual media (El Torito), but dd'd to a USB stick it has no MBR boot
#  signature and won't boot. Check a build with: xxd -s 510 -l 2 out.iso -> 55aa)

# Pinned iPXE: exact commit of the proven-good v1.2 image. Today's master
# (g58ee5) breaks EFI El Torito boot under OVMF.
ARG IPXE_COMMIT=56a4f695d6d17a4a1c93d196c586d481dbe3b934

RUN git clone https://github.com/ipxe/ipxe /ipxe && \
    cd /ipxe && git checkout -q $IPXE_COMMIT

# Config. iPXE 2.0 config headers enable HTTPS and the framebuffer console
# by default, then STRIP them again for BIOS builds in a
# "#if defined ( PLATFORM_pcbios )" block — delete those #undef lines so
# BIOS gets HTTPS (github kernel fetch) and the framebuffer console (logo).
# Serial console (IPMI SOL) enabled for all platforms (indented line!).
# CONSOLE_CMD lives in the same "disable commands not historically included in
# BIOS builds" block as CERT_CMD/PCI_CMD in config/general.h - drop that #undef
# too, or `console --x .. --picture logo.png` dies with "console: command not
# found" on every BIOS boot and the branded background never draws.
# IMAGE_TRUST_CMD: imgtrust/imgverify for signed boot images (docs/
# SIGNED-BOOT.md). Commented out in stock config/general.h and, unlike
# DIGEST_CMD, not stripped again for BIOS builds - one edit covers both
# targets. The trusted roots themselves are passed per-build via TRUST= in
# build.sh, so the pre-warmed object tree here stays root-agnostic.
RUN cd /ipxe/src && \
    sed -ri "s|^([[:space:]]*)//(#define[[:space:]]+CONSOLE_SERIAL)|\1\2|" config/console.h && \
    sed -ri "s|^//(#define[[:space:]]+IMAGE_TRUST_CMD)|\1|" config/general.h && \
    sed -ri "/^[[:space:]]*#undef[[:space:]]+DOWNLOAD_PROTO_HTTPS/d" config/general.h && \
    sed -ri "/^[[:space:]]*#undef[[:space:]]+CONSOLE_FRAMEBUFFER/d" config/console.h && \
    sed -ri "/^[[:space:]]*#undef[[:space:]]+CONSOLE_CMD/d" config/general.h && \
    grep -n "CONSOLE_SERIAL\|CONSOLE_FRAMEBUFFER" config/console.h && \
    grep -n "DOWNLOAD_PROTO_HTTPS\|CONSOLE_CMD" config/general.h && \
    grep -qE "^#define[[:space:]]+IMAGE_TRUST_CMD" config/general.h && \
    ! grep -qE "^[[:space:]]*#undef[[:space:]]+CONSOLE_CMD" config/general.h

# Legacy keyboard fix. On BIOS builds iPXE's native USB host-controller drivers
# (xHCI/EHCI/UHCI) claim the controllers at startup and perform the BIOS->OS USB
# handoff, which DISABLES the firmware USB-legacy (INT 16h) keyboard emulation
# that the Dell iDRAC virtual keyboard and any local USB keyboard ride on. iPXE
# then means to read the keyboard through its own usbkbd, but it cannot enumerate
# the iDRAC emulated HID — so in legacy mode every keystroke is lost and only the
# serial console (IPMI SOL) still works. UEFI is immune: config/usb.h already
# "#undef USB_KEYBOARD" there and lets the firmware own the keyboard.
#   We never touch USB from inside iPXE (menu + seeds are EMBED-ded, kernels come
# over the operator-selected NIC), so the fix is to keep iPXE out of the USB
# stack on pcbios: leave the controllers under BIOS SMM and read the keyboard via
# the already-enabled CONSOLE_PCBIOS (INT 16h) — the same path the BIOS setup and
# isolinux menu use. Trade-off: no iPXE USB-NIC boot on BIOS, irrelevant here
# (server NICs are PCIe). grep -q fails the build loudly if the pinned
# config/usb.h ever drifts from the matched shape.
RUN cd /ipxe/src && \
    perl -0777 -pi -e 's{\n#endif /\* CONFIG_USB_H \*/}{\n\n#if defined ( PLATFORM_pcbios )\n  /* FluxBilling: keep iPXE OUT of the USB stack on BIOS builds so the firmware\n   * USB-legacy (INT 16h) keyboard emulation the Dell iDRAC virtual keyboard\n   * rides on stays alive; iPXE reads it via CONSOLE_PCBIOS. See builder.Dockerfile. */\n  #undef USB_HCD_XHCI\n  #undef USB_HCD_EHCI\n  #undef USB_HCD_UHCI\n  #undef USB_KEYBOARD\n  #undef USB_BLOCK\n#endif\n\n#endif /* CONFIG_USB_H */}s' config/usb.h && \
    grep -q "keep iPXE OUT of the USB stack" config/usb.h && \
    grep -nE "^  #undef USB_HCD_XHCI" config/usb.h

# Silence the cosmetic EFI autoexec probe. On every EFI boot iPXE probes the
# boot media for autoexec.ipxe BEFORE running our embedded menu, printing
# "file:autoexec.ipxe... Not found" x2 to the console. We EMBED the menu and
# never ship an autoexec.ipxe, so the probe can only ever fail — stub the
# filesystem loader to return -ENOTSUP (no console output). The network loader
# stays; it only logs at DBG and does nothing without a working URI. grep -q
# fails the build loudly if the pinned source ever drifts from this shape.
RUN cd /ipxe/src && \
    perl -0777 -pi -e 's/static int efi_autoexec_filesystem \(.*?\n\}\n/static int efi_autoexec_filesystem ( EFI_HANDLE handle __unused,\n\t\t\t\t     struct image **image __unused ) {\n\t\/* FluxBilling: autoexec.ipxe probe disabled; menu is EMBED-ded so no\n\t * autoexec.ipxe is ever shipped and this only emits cosmetic\n\t * "file:autoexec.ipxe... Not found" console lines. *\/\n\treturn -ENOTSUP;\n}\n/s' interface/efi/efi_autoexec.c && \
    grep -q "autoexec.ipxe probe disabled" interface/efi/efi_autoexec.c

# Brand palette for the menu/form CHROME. The `menu`, `item` and `form` widgets
# never see the ANSI vars from fluxbilling.ipxe - they paint from compile-time
# colour PAIRS (core/ansicol.c), whose stock values are white-on-red for the
# selected row and cyan for the edit field. Both are overridden here through
# config/local/colour.h, the upstream-sanctioned hook (config/colour.h includes
# it last), so no vendored header is edited.
#
#   NORMAL_BG stays COLOR_BLUE and is NOT a visible blue: ansicoldef.c maps
#   whichever colour equals NORMAL_BG to ANSICOL_MAGIC, and vesafb/efi_fbcon
#   call ansicol_set_magic_transparent() whenever a background picture is set -
#   so blue IS the transparency channel that lets the logo watermark show
#   through the menus. Leave it alone; picking a different NORMAL_BG would
#   paint a solid box over the watermark, and any colour used as a foreground
#   elsewhere would turn invisible.
RUN mkdir -p /ipxe/src/config/local && \
    printf '%s\n' \
      '/* FluxBilling brand chrome - see src/builder.Dockerfile */' \
      '#undef COLOR_SELECT_BG' \
      '#define COLOR_SELECT_BG COLOR_CYAN   /* brand blue bar, not red */' \
      '#undef COLOR_ALERT_BG' \
      '#define COLOR_ALERT_BG  COLOR_CYAN   /* ditto - no red anywhere */' \
      '#undef COLOR_EDIT_BG' \
      '#define COLOR_EDIT_BG   COLOR_WHITE  /* password field reads as paper */' \
      > /ipxe/src/config/local/colour.h

# Give the two chrome colours their real RGB. The 8-colour palette is generated
# at 0xaa intensity (fbcon_ansi_colour), so plain CYAN is a #00AAAA teal and
# WHITE a #AAAAAA grey. ansicoldef.c can attach a 24-bit value to a palette
# entry, which ansicol_set then emits as "38;2;r;g;b" after the basic code -
# framebuffer consoles repaint exactly, text/serial consoles keep the basic
# colour. CYAN becomes the fluxbilling.app blue #038BF8 (the same hex the menu
# script writes for its own accent) and WHITE becomes true #FFFFFF so the menu
# text stops looking dimmer than the bold-white prompts above it.
RUN cd /ipxe/src && \
    perl -pi -e 's{^\t\[COLOR_CYAN\]\t= ANSICOL_DEFAULT \( COLOR_CYAN \),$}{\t[COLOR_CYAN]\t= ANSICOL_DEFINE ( COLOR_CYAN, 0x038bf8 ),}; s{^\t\[COLOR_WHITE\]\t= ANSICOL_DEFAULT \( COLOR_WHITE \),$}{\t[COLOR_WHITE]\t= ANSICOL_DEFINE ( COLOR_WHITE, 0xffffff ),}' core/ansicoldef.c && \
    grep -q "ANSICOL_DEFINE ( COLOR_CYAN, 0x038bf8 )" core/ansicoldef.c && \
    grep -q "ANSICOL_DEFINE ( COLOR_WHITE, 0xffffff )" core/ansicoldef.c

# Bake the custom fluxcidr command into the always-linked command file so its
# object is pre-compiled here, not on every build.
COPY fluxcidr_cmd.c /tmp/fluxcidr_cmd.c
RUN cat /tmp/fluxcidr_cmd.c >> /ipxe/src/hci/commands/image_cmd.c

# Pre-warm BOTH targets with the SAME EMBED signature build.sh uses at runtime.
# iPXE triggers a full-tree rebuild whenever the EMBED flag changes between
# invocations; matching it here means runtime only rebuilds embedded.o + links.
# Dummy payload files stand in for the real ones (overwritten at runtime — a
# content change only rebuilds the tiny embedded object, not the tree).
RUN mkdir -p /work && cd /work && \
    : > fluxbilling.ipxe && : > logo.png && : > preseed.cfg && \
    : > 99fluxseed && : > param.conf && : > ks.cfg && : > autoinst.xml && \
    : > agama-leap16.json && : > 50-flux-agama.sh && : > flux-scrub && \
    : > flux-scrub.service
ARG EMBEDLIST=/work/fluxbilling.ipxe,/work/logo.png,/work/preseed.cfg,/work/99fluxseed,/work/param.conf,/work/ks.cfg,/work/autoinst.xml,/work/agama-leap16.json,/work/50-flux-agama.sh,/work/flux-scrub,/work/flux-scrub.service
# The BIOS lkrn tree rebuilds itself once on a fresh checkout (a generated
# prereg settles only after the first link); EFI settles in one pass. Bake a
# SECOND lkrn pass so the image ships the already-settled state — otherwise
# every --rm container repeats that one-time full BIOS rebuild (~1000 objects).
# x86_64-pcbios, not 32-bit bin/: matches build.sh, which explains why (the
# 32-bit build cannot address 64-bit PCI BARs, which SeaBIOS places above
# 4 GiB on guests with more than ~3.5 GiB RAM - virtio init then corrupts
# the netdev state).
RUN cd /ipxe/src && make -j"$(nproc)" bin-x86_64-pcbios/ipxe.lkrn EMBED="$EMBEDLIST"
RUN cd /ipxe/src && make -j"$(nproc)" bin-x86_64-efi/ipxe.efi EMBED="$EMBEDLIST"
RUN cd /ipxe/src && make -j"$(nproc)" bin-x86_64-pcbios/ipxe.lkrn EMBED="$EMBEDLIST"
