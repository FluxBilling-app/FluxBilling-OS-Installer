#!/bin/bash
# Smoke-test FluxBilling ISO in QEMU - a BIOS (SeaBIOS) pass AND a UEFI (OVMF)
# pass, both over the serial console. Each pass walks all prompts, accepts the
# review screen, verifies the OS menu shows the expected entries + the
# install-mode toggle, flips the toggle to MANUAL and back, then boots the
# default entry (Ubuntu 26.04) and verifies the boot sequence reaches the
# network fetch stage with the embedded aux files intact (no "Operation not
# supported").
#
# The menu is DRIVEN BY THE LOG, not by fixed sleeps: each keystroke goes out
# only after the prompt it answers has actually appeared on the serial line,
# so a slow TCG host (CI, or qemu-under-Rosetta) shifts timing without
# breaking the walk.
#
# EXIT CODE IS REAL: any MISS, timeout or forbidden line -> exit 1. CI gates
# on it (.github/workflows/build-test.yml).
set -uo pipefail
# QEMU can exit mid-walk (crash, or the timeout firing). Without this the next
# write into the fifo delivers SIGPIPE, bash dies with 141, and NO checks are
# printed and the second pass never runs - a real failure would look like an
# infrastructure hiccup.
trap '' PIPE

ISO=${ISO:-/iso/FluxBilling-OS-Installer_v1.1.iso}
LOGDIR=${LOGDIR:-/tmp}; mkdir -p "$LOGDIR"
[ -s "$ISO" ] || { echo "FATAL: ISO not found or empty: $ISO"; exit 1; }
fail=0

ESC=$(printf '\033')
# Build a tolerant ERE for a plain-text phrase. Two things make a literal grep
# useless here: iPXE output reaches the serial line TWICE under -nographic on
# BIOS (native serial console + BIOS int10 redirect), interleaved character by
# character, and the menu colours every label, so a phrase such as
# "Gateway<ESC>[0m <ESC>[37m[ENTER" carries 10 bytes inside itself. Between two
# expected characters, allow up to 6 "units", each either a whole ANSI escape
# sequence or one stray character.
fz() {
  local s=$1 out="" c i gap
  gap="(${ESC}\[[0-9;?]*[a-zA-Z]|.){0,6}"
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [\[\]\(\).*+?^\$\\/]) c="\\$c" ;; esac
    out+="$c$gap"
  done
  printf '%s' "$out"
}

# Prove the matcher works before trusting it to drive a long boot walk. This
# is not decoration: an earlier version of fz had its backslash escaping
# mangled, so every phrase containing "/" or "[" silently stopped matching,
# and the walk hung at a prompt that was plainly on screen while reporting
# nothing but a timeout.
fz_self_test() {
  local sample p rc=0
  sample=$(printf 'x\033[1m\033[37mIP / subnet\033[0m \033[37m(e.g. 1.2.3.4/27):\033[0m\ny\033[1mGateway\033[0m \033[37m[ENTER = 1.2.3.1]:\033[0m\n')
  for p in "IP / subnet" "Gateway [ENTER"; do
    printf '%s' "$sample" | grep -aqE "$(fz "$p")" || {
      echo "FATAL: fz self-test cannot match '$p'"; rc=1; }
  done
  printf '%s' "$sample" | grep -aqE "$(fz "Port number")" && {
    echo "FATAL: fz self-test matched a phrase that is not there"; rc=1; }
  return $rc
}
fz_self_test || exit 1

# wait_for <log> <string> <timeout_s>: poll until the string (fuzzy) shows up.
wait_for() {
  local log=$1 s=$2 t=$3 i=0
  while [ "$i" -lt "$t" ]; do
    grep -aqE "$(fz "$s")" "$log" && return 0
    sleep 1; i=$((i + 1))
  done
  echo "FAIL TIMEOUT(${t}s) waiting for: $s"
  fail=1
  return 1
}

chk() {
  grep -aqE "$(fz "$1")" "$2" && echo "OK   $1" || { echo "MISS $1"; fail=1; }
}
must_zero() { # <label> <pattern> <log> [fuzzy]
  local n
  if [ "${4:-}" = fuzzy ]; then n=$(grep -acE "$(fz "$2")" "$3"); else n=$(grep -ac "$2" "$3"); fi
  [ "$n" -eq 0 ] && echo "OK   zero $1" || { echo "FAIL $1: $n hits"; fail=1; }
}

run_pass() { # <label> <extra qemu args...>
  local label=$1; shift
  local log=$LOGDIR/$label.log fifo=/tmp/$label.fifo qpid
  rm -f "$log" "$fifo"; mkfifo "$fifo"; : > "$log"
  echo "===== ${label^^} PASS ====="
  # accel=kvm:tcg - KVM when the container gets /dev/kvm (CI), TCG otherwise.
  timeout 900 qemu-system-x86_64 -machine accel=kvm:tcg -m 4096 -cdrom "$ISO" -nographic -boot d "$@" \
    < "$fifo" > "$log" 2>&1 &
  qpid=$!
  exec 3> "$fifo"                       # keep the writer open across sends
  send() { printf "$1" >&3 2>/dev/null || true; }

  wait_for "$log" "Port number" 300     && send '0\r'
  wait_for "$log" "IP / subnet" 90      && send '10.0.2.15/27\r'
  wait_for "$log" "Gateway" 90          && send '\r'
  wait_for "$log" "Hostname" 90         && send 'srv1\r'
  wait_for "$log" "Root password" 90    && { sleep 1; send '\t'; sleep 1; send 'Passw0rd123\r'; }
  wait_for "$log" "Review your setup" 90 && send '\r'
  if wait_for "$log" "Install mode" 90; then
    sleep 2; send '\033[A'; sleep 1; send '\r'      # toggle -> MANUAL
    wait_for "$log" "MANUAL" 60
    sleep 2; send '\033[A'; sleep 1; send '\r'      # toggle -> AUTOMATED
    sleep 3; send '\r'                              # boot default (Ubuntu 26.04)
    # 26.04 boots Canonical's own netboot images - the URL prints as the
    # fetch starts.
    wait_for "$log" "netboot/amd64/linux" 300
    sleep 20                                        # let the kernel start (or panic)
  fi
  exec 3>&-
  kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
  rm -f "$fifo"

  echo "===== ${label^^} CHECKS ====="
  chk "FluxBilling.app"    "$log"
  chk "Port number"        "$log"
  chk "IP / subnet"        "$log"
  chk "Gateway [ENTER"     "$log"
  chk "Review your setup"  "$log"
  chk "Install mode"       "$log"
  chk "MANUAL"             "$log"
  chk "AUTOMATED"          "$log"
  chk "Ubuntu 26.04 LTS"   "$log"
  chk "Ubuntu 24.04 LTS"   "$log"
  chk "AlmaLinux 9"        "$log"
  chk "Rocky Linux 9"      "$log"
  chk "CentOS Stream 9"    "$log"
  chk "releases.ubuntu.com" "$log"
  chk "netboot/amd64/linux" "$log"
  # (openSUSE/Other section sits below the ~18-row menu viewport on the 80x24
  #  serial console - never drawn unless scrolled, so not display-checked)
  must_zero "not-supported"       'Operation not supported'      "$log" fuzzy
  must_zero "could-not-start"     'Could not start download'     "$log" fuzzy
  # Kernel messages arrive on ttyS0 as a single clean stream (only iPXE/BIOS
  # output is doubled), so these grep literally. They catch the class of bug
  # where an EMBED-ded image reaches the initrd chain without a cpio path and
  # gets spliced in verbatim - the whole chain then fails to unpack.
  must_zero "unpack-failed"       'Initramfs unpacking failed'   "$log"
  must_zero "kernel-panic"        'Kernel panic'                 "$log"
  must_zero "console-cmd-missing" 'console: command not found'   "$log" fuzzy
}

run_pass bios

# UEFI: the shipped ISO carries bin-x86_64-efi/ipxe.efi as its El Torito EFI
# image - the half of the product the old test never booted, and exactly the
# regression class the iPXE commit pin exists for (master broke EFI El Torito
# under OVMF; see builder.Dockerfile).
OVMF=""
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
  [ -e "$f" ] && { OVMF=$f; break; }
done
if [ -n "$OVMF" ]; then
  VARS=${OVMF/CODE/VARS}
  cp "$VARS" /tmp/ovmf-vars.fd
  run_pass uefi \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF" \
    -drive if=pflash,format=raw,file=/tmp/ovmf-vars.fd
else
  echo "FAIL no OVMF firmware found - UEFI pass cannot run"
  fail=1
fi

echo "===== RESULT: $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ====="
exit "$fail"
