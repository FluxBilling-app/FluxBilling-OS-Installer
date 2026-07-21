#!/bin/bash
# Smoke-test FluxBilling ISO in QEMU (BIOS serial console).
# Walks all prompts, accepts the review screen, verifies the OS menu shows
# the new entries + install-mode toggle, flips the toggle to MANUAL and back,
# then boots the default entry (Ubuntu 26.04) and verifies the boot sequence
# reaches the network fetch stage with the embedded aux files intact
# (no "Operation not supported").
set -x

feed() {
  sleep 14                 # isolinux + ipxe init + banner + ifstat
  printf '0\r'; sleep 3    # interface number
  printf '10.0.2.15/27\r'; sleep 2   # IP/prefix combined
  printf '\r'; sleep 2     # gateway (accept auto-calculated)
  printf 'srv1\r'; sleep 2  # hostname
  printf '\t'; sleep 2     # login: TAB to password field
  printf 'Passw0rd123\r'; sleep 4         # login: password (hidden) + submit
  printf '\r'; sleep 3     # review menu: Continue to OS selection
  printf '\033[A'; sleep 1 # up from default (u2604) to the mode toggle
  printf '\r'; sleep 3     # toggle -> MANUAL, menu redraws at default
  printf '\033[A'; sleep 1 # up to the toggle again
  printf '\r'; sleep 3     # toggle -> AUTOMATED, menu redraws at default
  printf '\r'; sleep 170   # OS menu: Ubuntu 26.04 (default) -> fetch + kernel
}

echo "===== BIOS TEST ====="
feed | timeout 330 qemu-system-x86_64 -m 4096 -cdrom /iso/FluxBilling-OS-Installer_v1.0.iso \
  -nographic -boot d 2>&1 | tee /tmp/bios.log | tail -40

# iPXE output reaches the serial line TWICE under QEMU -nographic (native
# serial console + BIOS int10 redirect), interleaved char-by-char with a
# small lag - literal greps never match. Match fuzzily instead: allow up to
# 3 interleaved characters between every expected character.
fz() {
  local s=$1 out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [\[\]\(\).*+?^\$\\/]) c="\\$c" ;; esac
    out+="$c.{0,3}"
  done
  printf '%s' "$out"
}
chk() {
  grep -aqE "$(fz "$1")" /tmp/bios.log && echo "OK   $1" || echo "MISS $1"
}

echo "===== BIOS CHECKS ====="
chk "FluxBilling.app"
chk "Port number"
chk "IP / subnet"
chk "Gateway [ENTER"
chk "Review your setup"
chk "Install mode"
chk "MANUAL"
chk "AUTOMATED"
chk "Ubuntu 26.04 LTS"
chk "Ubuntu 24.04 LTS"
chk "AlmaLinux 9"
chk "Rocky Linux 9"
chk "CentOS Stream 9"
chk "github.com/netbootxyz"
# (openSUSE/Other section sits below the ~18-row menu viewport on the 80x24
#  serial console - never drawn unless scrolled, so not display-checked)
echo "must be 0 -> not-supported: $(grep -acE "$(fz 'Operation not supported')" /tmp/bios.log)"
echo "must be 0 -> could-not-start: $(grep -acE "$(fz 'Could not start download')" /tmp/bios.log)"
# Kernel messages arrive on ttyS0 as a single clean stream (only iPXE/BIOS
# output is doubled), so these grep literally. They catch the class of bug
# where an EMBED-ded image reaches the initrd chain without a cpio path and
# gets spliced in verbatim - the whole chain then fails to unpack.
echo "must be 0 -> unpack-failed: $(grep -ac 'Initramfs unpacking failed' /tmp/bios.log)"
echo "must be 0 -> kernel-panic: $(grep -ac 'Kernel panic' /tmp/bios.log)"
# (iPXE-side line, so fuzzy-matched like the chk strings above)
echo "must be 0 -> console-cmd-missing: $(grep -acE "$(fz 'console: command not found')" /tmp/bios.log)"
