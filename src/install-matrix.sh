#!/bin/bash
# Install EVERY automated menu entry to completion, in parallel, and prove the
# result is a working server: the VM must reboot off its own disk and accept a
# root SSH login with the password typed at the prompts.
#
# This is the test the other three are not. qemu-test.sh walks the menu and
# stops at the kernel fetch; e2e-test.sh proves one injected initrd unpacks;
# fallback-test.sh proves a dead mirror is survived. None of them ever let an
# installer finish, so "the answer file is accepted and the box comes up
# configured" has been a claim about 18 of the 19 entries, not a result.
#
# NEEDS A REAL x86_64 HOST WITH /dev/kvm. Under TCG these installs take days.
#
# NETWORKING - the detail every earlier test got away with ignoring. QEMU's
# user-mode (slirp) net is 10.0.2.0/24 with the ROUTER AT 10.0.2.2; .1 answers
# nothing. The menu derives the gateway as the first host address, so accepting
# its default (10.0.2.1) yields a guest that cannot route - which is precisely
# what test-logs/bios.log shows: the releases.ubuntu.com fetch times out and
# falls through to the fallback host. Here the gateway prompt is answered
# EXPLICITLY with 10.0.2.2, so payloads actually download and installs actually
# run. Keep /24: a /27 puts the router outside the guest's own subnet.
#
# EXIT CODE IS REAL: any entry that does not end in a root SSH login fails the
# run, and the per-entry reason is printed in the summary table.
set -uo pipefail
trap '' PIPE

WORK=${WORK:-/var/tmp/flux-matrix}
LOGDIR=${LOGDIR:-$WORK/logs}
ISO=${ISO:-$PWD/FluxBilling-OS-Installer_v1.0.iso}
PASS=${PASS:-Passw0rd123}
DISK_GB=${DISK_GB:-20}
# Total guest RAM allowed in flight at once. Entries are admitted while they
# fit and queue when they do not, so one budget knob adapts the run to the
# host instead of a fixed -P N that either wastes a big box or thrashes a
# small one. Default: 70% of host RAM.
MEMBUDGET_MB=${MEMBUDGET_MB:-$(awk '/MemTotal/ {printf "%d", $2/1024*0.7}' /proc/meminfo)}

# entry-key  menu-label  downs-from-default  guest-MB  install-timeout-s
#
# `downs` is the entry's index in the OS menu below the default (Ubuntu 26.04
# is the default, so it is 0). The item order lives in :kargs_done in
# fluxbilling.ipxe - a reordered menu MUST be mirrored here, which
# check_menu_order() below enforces rather than trusting this comment.
#
# RAM follows README's "Requirements & limits": casper streams the whole live
# ISO into RAM (8G), anaconda stages stage2 (4G), Leap 16 Agama (3G), and d-i
# is happy in 1.5G. Timeouts are ~3x an observed KVM install, generous enough
# that a slow mirror is not reported as a product failure.
MATRIX='
ubu2604  Ubuntu-26.04   0   8192  5400
ubu2510  Ubuntu-25.10   1   8192  5400
ubu2404  Ubuntu-24.04   2   8192  5400
ubu2204  Ubuntu-22.04   3   8192  5400
ubu2004  Ubuntu-20.04   4   1536  5400
ubu1804  Ubuntu-18.04   5   1536  5400
deb13    Debian-13      6   1536  5400
deb12    Debian-12      7   1536  5400
deb11    Debian-11      8   1536  5400
al10     AlmaLinux-10   9   4096  5400
al9      AlmaLinux-9   10   4096  5400
al8      AlmaLinux-8   11   4096  5400
rk10     Rocky-10      12   4096  5400
rk9      Rocky-9       13   4096  5400
rk8      Rocky-8       14   4096  5400
cs10     CentOS-10     15   4096  5400
cs9      CentOS-9      16   4096  5400
leap160  Leap-16.0     17   3072  5400
leap156  Leap-15.6     18   2048  5400
'

ENTRIES=${ENTRIES:-$(awk 'NF {print $1}' <<<"$MATRIX")}

# --- preflight: fail loudly and early, never half-run a 90-minute matrix ----
die() { echo "FATAL: $*" >&2; exit 1; }
[ -s "$ISO" ] || die "ISO not found or empty: $ISO"
[ -e /dev/kvm ] || die "/dev/kvm absent - this harness is unusable without hardware virt (TCG would take days)"
[ "$(uname -m)" = x86_64 ] || die "host is $(uname -m); the guests are x86_64 and need native KVM"
for t in qemu-system-x86_64 qemu-img sshpass ssh; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
MENU=${MENU:-$PWD/fluxbilling.ipxe}
[ -s "$MENU" ] || die "menu not found: $MENU (run from the repo root, or set MENU=)"

# The whole walk is "press Down N times", so a menu reorder silently installs
# the WRONG OS and still passes every assertion below (each check is generic).
# Verify the table against the menu itself before booting anything.
check_menu_order() {
  local want got rc=0
  want=$(awk 'NF {print $1}' <<<"$MATRIX")
  # [a-z0-9_] - the underscore is load-bearing: without it `toggle_mode` never
  # matches, the sed range never opens, `got` comes back EMPTY, and an empty
  # list compares unequal to every real table only by luck. The explicit
  # emptiness check below is the real backstop.
  got=$(sed -n 's/^item \([a-z0-9_]*\) .*/\1/p' "$MENU" \
        | sed -n '/^toggle_mode$/,/^settings$/p' | grep -v '^toggle_mode$\|^settings$')
  [ -n "$got" ] || { echo "FATAL: cannot parse the OS menu out of $MENU"; return 1; }
  if [ "$want" != "$got" ]; then
    echo "FATAL: MATRIX does not match the menu order in $MENU"
    diff <(echo "$want") <(echo "$got") | sed 's/^/  /'
    rc=1
  fi
  return $rc
}
check_menu_order || exit 1

mkdir -p "$WORK" "$LOGDIR"

ESC=$(printf '\033')
# Tolerant matcher - see qemu-test.sh: iPXE output is doubled on the BIOS
# serial console and every menu label carries colour escapes inside itself.
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
fz_self_test() {
  local sample p rc=0
  sample=$(printf 'x\033[1m\033[37mIP / subnet\033[0m \033[37m(e.g. 1.2.3.4/27):\033[0m\ny\033[1mGateway\033[0m \033[37m[ENTER = 1.2.3.1]:\033[0m\n')
  for p in "IP / subnet" "Gateway [ENTER"; do
    printf '%s' "$sample" | grep -aqE "$(fz "$p")" || { echo "FATAL: fz self-test cannot match '$p'"; rc=1; }
  done
  printf '%s' "$sample" | grep -aqE "$(fz "Port number")" && {
    echo "FATAL: fz self-test matched a phrase that is not there"; rc=1; }
  return $rc
}
fz_self_test || exit 1

# ssh_try <port> <cmd> - one non-interactive root login attempt.
# No known-hosts churn: every VM is throwaway and reuses 127.0.0.1:<port>.
ssh_try() {
  local port=$1; shift
  sshpass -p "$PASS" ssh -p "$port" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o LogLevel=ERROR \
    root@127.0.0.1 "$@" 2>/dev/null
}

# run_entry <key> <label> <downs> <mem_mb> <timeout_s> <port>
# Writes "<key> <PASS|FAIL> <reason>" to $LOGDIR/<key>.result.
run_entry() {
  local key=$1 label=$2 downs=$3 mem=$4 tmo=$5 port=$6
  local log=$LOGDIR/install-$key.log fifo=$WORK/$key.fifo disk=$WORK/$key.qcow2
  local host=flux-$key qpid rc reason=""

  rm -f "$fifo" "$log" "$disk"; mkfifo "$fifo"; : > "$log"
  qemu-img create -f qcow2 "$disk" "${DISK_GB}G" >/dev/null 2>&1 \
    || { echo "$key FAIL qemu-img-create-failed" > "$LOGDIR/$key.result"; return 1; }

  # -boot once=d: boot the installer ISO for THIS boot only. Without `once`,
  # the post-install reboot lands back in the iPXE menu and the VM installs
  # itself forever while the harness waits for an SSH port that never opens.
  # hostfwd targets 10.0.2.15 because the guest holds that address statically -
  # slirp only forwards to the address it was told, and the guest never DHCPs.
  timeout "$tmo" qemu-system-x86_64 \
    -machine accel=kvm -cpu host -smp 2 -m "$mem" \
    -drive file="$disk",if=virtio,format=qcow2 \
    -cdrom "$ISO" -boot once=d -nographic \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$port"-10.0.2.15:22 \
    -device virtio-net-pci,netdev=n0 \
    < "$fifo" > "$log" 2>&1 &
  qpid=$!
  exec {fd}> "$fifo"
  s() { printf "$1" >&$fd 2>/dev/null || true; }

  # w <phrase> <timeout> - poll the log, bail the moment QEMU dies so a crash
  # is not reported as "timeout waiting for a prompt".
  w() {
    local j=0
    while [ "$j" -lt "$2" ]; do
      grep -aqE "$(fz "$1")" "$log" && return 0
      kill -0 "$qpid" 2>/dev/null || { reason="qemu-exited-before:$1"; return 1; }
      sleep 2; j=$((j + 2))
    done
    reason="timeout-waiting:$1"; return 1
  }

  # One-shot loop, purely so a failed prompt can `break` out of the walk: the
  # first `w` that times out leaves `reason` set and skips the rest, instead
  # of typing a hostname into a menu that never appeared.
  for _walk in 1; do
    w "Port number" 300     || break
    s '0\r'
    w "IP / subnet" 120     || break
    s '10.0.2.15/24\r'
    # Gateway: type slirp's router explicitly - see the header note.
    w "Gateway" 120         || break
    s '10.0.2.2\r'
    w "Hostname" 120        || break
    s "$host\r"
    w "Root password" 120   || break
    sleep 1; s '\t'; sleep 1; s "$PASS\r"
    w "Review your setup" 120 || break
    s '\r'
    w "Install mode" 120    || break
    # Arrow keys one at a time: iPXE distinguishes a bare ESC from an ESC[B
    # cursor key BY TIMING, so a burst in one write is parsed as something
    # else and the highlight never moves (see fallback-test.sh).
    sleep 3
    local k=0
    while [ "$k" -lt "$downs" ]; do s '\033[B'; sleep 1; k=$((k + 1)); done
    sleep 1; s '\r'
  done

  # Menu walk done (or broken). If it broke, `reason` is already set.
  if [ -z "$reason" ]; then
    # Install runs unattended from here. Success is defined by the product
    # claim, not by log scraping: the box reboots off disk and takes a root
    # SSH login with the typed password. Poll until the deadline.
    local deadline=$((SECONDS + tmo - 120))
    reason="install-never-completed"
    while [ "$SECONDS" -lt "$deadline" ]; do
      kill -0 "$qpid" 2>/dev/null || { reason="qemu-exited-during-install"; break; }
      if ssh_try "$port" true; then reason=""; break; fi
      sleep 20
    done
  fi

  # Post-install assertions - only meaningful once SSH answered.
  if [ -z "$reason" ]; then
    local got_host got_ip got_os
    got_host=$(ssh_try "$port" 'hostname' | tr -d '\r')
    got_ip=$(ssh_try "$port" 'ip -4 -o addr show scope global' | tr -d '\r')
    got_os=$(ssh_try "$port" '. /etc/os-release; echo "$ID $VERSION_ID"' | tr -d '\r')
    echo "--- post-install: host=$got_host os=$got_os" >> "$log"
    echo "--- post-install: addr=$got_ip" >> "$log"
    [ "$got_host" = "$host" ]        || reason="hostname-not-applied(got:$got_host)"
    grep -q '10\.0\.2\.15' <<<"$got_ip" || reason="${reason:+$reason,}static-ip-not-applied"
    [ -n "$got_os" ]                 || reason="${reason:+$reason,}os-release-unreadable"
    echo "$got_os" > "$LOGDIR/$key.os"
  fi

  exec {fd}>&-
  kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
  rm -f "$fifo" "$disk"

  if [ -z "$reason" ]; then
    echo "$key PASS $(cat "$LOGDIR/$key.os" 2>/dev/null)" > "$LOGDIR/$key.result"
  else
    echo "$key FAIL $reason" > "$LOGDIR/$key.result"
  fi
}

# --- scheduler: admit entries while they fit in the RAM budget -------------
declare -A PIDMEM=()
inflight_mem() { local t=0 m; for m in "${PIDMEM[@]}"; do t=$((t + m)); done; echo "$t"; }
reap() {
  local p
  for p in "${!PIDMEM[@]}"; do
    kill -0 "$p" 2>/dev/null || unset 'PIDMEM[$p]'
  done
}

echo "===== INSTALL MATRIX ====="
echo "iso=$ISO  budget=${MEMBUDGET_MB}MB  work=$WORK  logs=$LOGDIR"
echo "entries: $(echo "$ENTRIES" | tr '\n' ' ')"
rm -f "$LOGDIR"/*.result "$LOGDIR"/*.os
started=0
for key in $ENTRIES; do
  row=$(awk -v k="$key" '$1 == k {print; exit}' <<<"$MATRIX")
  [ -n "$row" ] || { echo "$key FAIL unknown-entry" > "$LOGDIR/$key.result"; continue; }
  read -r _ label downs mem tmo <<<"$row"
  [ "$mem" -le "$MEMBUDGET_MB" ] \
    || { echo "$key FAIL needs-${mem}MB-budget-is-${MEMBUDGET_MB}MB" > "$LOGDIR/$key.result"; continue; }
  while true; do
    reap
    [ $(( $(inflight_mem) + mem )) -le "$MEMBUDGET_MB" ] && break
    sleep 10
  done
  port=$((22000 + downs))
  echo ">> start $label (${mem}MB, ssh 127.0.0.1:$port)"
  run_entry "$key" "$label" "$downs" "$mem" "$tmo" "$port" &
  PIDMEM[$!]=$mem
  started=$((started + 1))
  sleep 5   # stagger: 19 simultaneous mirror connections from one IP get throttled
done
wait

echo
echo "===== RESULTS ====="
fail=0
printf '%-9s %-6s %s\n' ENTRY STATUS DETAIL
for key in $ENTRIES; do
  r=$(cat "$LOGDIR/$key.result" 2>/dev/null || echo "$key FAIL no-result-file")
  read -r k st detail <<<"$r"
  printf '%-9s %-6s %s\n' "$k" "$st" "${detail:-}"
  [ "$st" = PASS ] || fail=1
done
echo
echo "===== RESULT: $([ "$fail" -eq 0 ] && echo PASS || echo FAIL) ====="
echo "per-entry serial logs: $LOGDIR/install-<entry>.log"
exit "$fail"
