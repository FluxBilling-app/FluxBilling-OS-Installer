#!/usr/bin/env bash
# Prove the disk rule every automated entry shares (src/flux-disks) chooses
# the right disk and wipes exactly what the menu's erase-all-disks screen says
# it does - and nothing else.
#
# Runs offline in seconds, against a fake /sys and /dev: every "disk" is a
# sparse file the helper really writes into with dd, and every tool it might
# call on a real system (blkdiscard, mdadm, swapoff, ...) is a stub that only
# records the call. So the assertions read the bytes an installer would leave
# behind, without a VM and without any chance of touching a real disk.
#
# FLUX_SH picks the shell the helper runs under (default: sh), and FLUX_BIN a
# directory put first on its PATH. The helper has to work under d-i's busybox
# - its ash AND its applets, since d-i has no coreutils - as well as dash and
# bash, so run this with each where they exist, e.g. FLUX_SH="busybox sh"
# FLUX_BIN=<dir of busybox applet links>.
#
# It also holds the families to the one rule: the verbatim copies in ks.cfg
# and pve-bashrc must match src/flux-disks byte for byte, every answer file
# must hand the chosen disk to its installer, and every kernel line in the
# menu must carry the authorisation the Yes answer sets - and only that answer.
set -uo pipefail
cd "$(dirname "$0")/.."
FLUX_SH=${FLUX_SH:-sh}
WORK=$(mktemp -d)
if [ -n "${DISKS_KEEP:-}" ]; then echo "fixture kept in $WORK"; else trap 'rm -rf "$WORK"' EXIT; fi
rc=0
ok()  { echo "DISKS OK     $1"; }
bad() { echo "DISKS FAIL   $1"; rc=1; }

MIB=2048                     # sectors per MiB
EDGE=$((16 * MIB))           # what the helper zeroes at each end

# --- fixture ------------------------------------------------------------------
# mkdisk <name> <sectors> <sysfs device path> [attr=value ...]
# Creates /sys/devices/<path>/block/<name> with its attributes, the
# /sys/block and /sys/class/block links real sysfs has, and /dev/<name> as a
# sparse file of the same size.
mkdisk() {
	local n=$1 sectors=$2 path=$3 kv; shift 3
	local d=$S/devices/$path/block/$n
	mkdir -p "$d/holders" "$d/slaves" "$d/queue" "$d/device"
	echo "$sectors" > "$d/size"
	echo 0 > "$d/removable"; echo 0 > "$d/ro"
	echo 0 > "$d/queue/discard_max_bytes"
	echo "TEST $n" > "$d/device/model"
	for kv in "$@"; do echo "${kv#*=}" > "$d/${kv%%=*}"; done
	ln -s "../devices/$path/block/$n" "$S/block/$n"
	ln -s "../../devices/$path/block/$n" "$S/class/block/$n"
	[ "$sectors" -gt 0 ] && dd if=/dev/zero of="$DV/$n" bs=512 count=0 seek="$sectors" 2>/dev/null
	: >> "$DV/$n"
}
# devdir <name> - a /sys/block entry's real directory, spelled under $S. Read
# from the link text rather than resolved: on macOS $TMPDIR sits behind the
# /var -> /private/var symlink, and a resolved path no longer starts with $S.
devdir() {
	local r; r=$(readlink "$S/block/$1"); echo "$S/${r#../}"
}
# mkpart <disk> <part> <start> <sectors>
mkpart() {
	local d; d=$(devdir "$1")
	mkdir -p "$d/$2/holders"
	echo 1 > "$d/$2/partition"; echo "$3" > "$d/$2/start"; echo "$4" > "$d/$2/size"
	ln -s "../../${d#"$S"/}/$2" "$S/class/block/$2"
	: > "$DV/$2"
}
# mkvirt <name> <slave sysfs dir>... - an md/dm device stacked on the slaves
mkvirt() {
	local n=$1 s; shift
	local d=$S/devices/virtual/block/$n
	mkdir -p "$d/holders" "$d/slaves" "$d/dm"
	echo "vg-$n" > "$d/dm/name"; echo 0 > "$d/removable"; echo 0 > "$d/ro"; echo 1000 > "$d/size"
	ln -s "../devices/virtual/block/$n" "$S/block/$n"
	ln -s "../../devices/virtual/block/$n" "$S/class/block/$n"
	for s in "$@"; do
		ln -s "$d" "$s/holders/$n"
		ln -s "$s" "$d/slaves/${s##*/}"
	done
	: > "$DV/$n"
}
mark() { printf 'FLUXMARK' | dd of="$DV/$1" bs=512 seek="$2" conv=notrunc 2>/dev/null; }
# nz <dev> <sector> [count] - non-zero bytes in a range
nz() { dd if="$DV/$1" bs=512 skip="$2" count="${3:-1}" 2>/dev/null | tr -d '\000' | wc -c | tr -d ' '; }
sum() { cksum < "$DV/$1"; }

build() {
	rm -rf "$WORK/t"; mkdir -p "$WORK/t"
	S=$WORK/t/sys; DV=$WORK/t/dev; PR=$WORK/t/proc; ST=$WORK/t/stub
	mkdir -p "$S/block" "$S/class/block" "$S/devices/virtual/block" "$DV" "$PR" "$ST"
	printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$PR/swaps"
	: > "$PR/mounts"
	echo "BOOT_IMAGE=/linux initrd=initrd.magic autoinstall fluxhost=web12" > "$PR/cmdline"
	PCI=pci0000:00
	# Eligible, in the order the helper must find them: nvme0n1 < sda < sdb < vda.
	mkdisk nvme0n1 $((160 * MIB)) "$PCI/0000:00:03.0/nvme/nvme0" queue/discard_max_bytes=2199023255040
	mkdisk sda $((256 * MIB)) "$PCI/0000:00:1f.2/ata1/host0/target0:0:0/0:0:0:0" queue/discard_max_bytes=2147450880
	mkdisk sdb $((128 * MIB)) "$PCI/0000:00:1f.2/ata2/host1/target1:0:0/1:0:0:0"
	mkdisk vda $((64 * MIB)) "$PCI/0000:00:05.0/virtio2"
	# Never eligible - each one is the reason in its name.
	mkdisk sdc $((64 * MIB)) "$PCI/0000:00:14.0/usb1/1-1/1-1:1.0/host6/target6:0:0/6:0:0:0" removable=1
	mkdisk sdd $((64 * MIB)) "$PCI/0000:00:14.0/usb2/2-3/2-3:1.0/host7/target7:0:0/7:0:0:0"
	mkdisk sde $((64 * MIB)) "$PCI/0000:3b:00.0/host8/rport-8:0-0/target8:0:0/8:0:0:0"
	mkdisk sdf $((64 * MIB)) "platform/host9/session1/target9:0:0/9:0:0:0"
	mkdisk sdg $((64 * MIB)) "$PCI/0000:00:1f.2/ata3/host2/target2:0:0/2:0:0:0" ro=1
	mkdisk sdh 0 "$PCI/0000:00:1f.2/ata4/host3/target3:0:0/3:0:0:0"
	mkdisk nvme0c0n1 $((160 * MIB)) "$PCI/0000:00:03.0/nvme/nvme0" hidden=1
	mkdisk sr0 $((64 * MIB)) "$PCI/0000:00:1f.2/ata5/host4/target4:0:0/4:0:0:0"
	mkdisk loop0 $((64 * MIB)) "virtual"
	mkdisk zram0 $((64 * MIB)) "virtual"
	# Partitions, with markers at both ends of each, in the middle of the big
	# one (which a quick wipe leaves alone by design) and at both ends of
	# every disk.
	mkpart sda sda1 $MIB $((64 * MIB))
	mkpart sda sda2 $((65 * MIB)) $((190 * MIB))
	mkpart sdb sdb1 $MIB $((126 * MIB))
	for n in nvme0n1 sda sdb vda sdc sdd sde sdf sdg; do
		local s; s=$(cat "$S/block/$n/size")
		mark "$n" 0; mark "$n" $((s - 1))
	done
	mark sda $MIB; mark sda $((65 * MIB - 1))
	mark sda $((65 * MIB)); mark sda $((255 * MIB - 1)); mark sda $((65 * MIB + 95 * MIB))
	mark sdb $((MIB + 40 * MIB))
	# Old install leftovers: swap on sda2, sdb1 an md member under an LVM
	# volume.
	printf '%s/sda2\tpartition\t1000\t0\t-2\n' "$DV" >> "$PR/swaps"
	mkvirt md127 "$(devdir sdb)/sdb1"
	mkvirt dm-0 "$(devdir md127)"

	# Stubs: record every call; mdadm/dmsetup/swapoff take the fixture's
	# holders/swaps down the way the real tools would, unless told to fail.
	for t in blkdiscard wipefs blockdev udevadm umount; do
		printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$t" "$WORK/t" > "$ST/$t"
	done
	# python3 -c <code> <dev> <sectors>: record what it was asked to discard.
	cat > "$ST/python3" <<EOF
#!/bin/sh
case "\$2" in *0x1277*) ioctl=BLKDISCARD ;; *) ioctl=other ;; esac
echo "python3 \$ioctl \$3 \$4" >> "$WORK/t/calls"
EOF
	cat > "$ST/mdadm" <<EOF
#!/bin/sh
echo "mdadm \$*" >> "$WORK/t/calls"
[ -e "$WORK/t/stuck-\${2##*/}" ] && exit 1
find "$S/devices" -path "*/holders/\${2##*/}" -exec rm -f {} +
EOF
	cat > "$ST/dmsetup" <<EOF
#!/bin/sh
echo "dmsetup \$*" >> "$WORK/t/calls"
[ -e "$WORK/t/stuck-\$2" ] && exit 1
find "$S/devices" -path "*/holders/dm-0" -exec rm -f {} +
EOF
	cat > "$ST/swapoff" <<EOF
#!/bin/sh
echo "swapoff \$*" >> "$WORK/t/calls"
grep -v "^\$1[[:space:]]" "$PR/swaps" > "$PR/swaps.new"; mv "$PR/swaps.new" "$PR/swaps"
EOF
	chmod +x "$ST"/*
	: > "$WORK/t/calls"
}

# run [cmdline] - the helper against the fixture; stdout -> out, rc -> ec
run() {
	[ -n "${1:-}" ] && echo "$1" > "$PR/cmdline"
	( export flux_sys="$S" flux_dev="$DV" flux_proc="$PR" flux_kmsg="$WORK/t/kmsg"
	  export PATH="$ST:${FLUX_BIN:+$FLUX_BIN:}$PATH"
	  $FLUX_SH ./src/flux-disks > "$WORK/t/out" 2> "$WORK/t/err" )
	ec=$?
}
called() { grep -q "^$1" "$WORK/t/calls"; }

# --- choosing the disk, without the authorisation ---------------------------
build
before=""; for n in nvme0n1 sda sdb vda sdc sdd sde sdf sdg; do before="$before $(sum $n)"; done
run
[ "$ec" = 0 ] && ok "exits 0 when a disk qualifies" || bad "exit $ec with eligible disks present"
[ "$(cat "$WORK/t/out")" = "$DV/nvme0n1" ] \
	&& ok "target is the first eligible disk in /sys/block order (nvme0n1)" \
	|| bad "target is '$(cat "$WORK/t/out")', expected $DV/nvme0n1"
after=""; for n in nvme0n1 sda sdb vda sdc sdd sde sdf sdg; do after="$after $(sum $n)"; done
[ "$before" = "$after" ] && ok "no fluxwipe=1: not one byte changed on any disk" \
	|| bad "no fluxwipe=1, yet a disk was written"
called blkdiscard || called mdadm || called dmsetup || called swapoff || called wipefs \
	&& bad "no fluxwipe=1, yet a destructive tool was called" \
	|| ok "no fluxwipe=1: no destructive tool called"
grep -q "install disk: $DV/nvme0n1" "$WORK/t/kmsg" && ok "the choice is in the kernel log" \
	|| bad "the kernel log does not say which disk was chosen"

# fluxwipe=10 and xfluxwipe=1 are not the authorisation.
build
run "BOOT_IMAGE=/linux fluxwipe=10 xfluxwipe=1 fluxhost=web12"
[ "$(nz sdb 0)" != 0 ] && [ "$(nz vda 0)" != 0 ] && ok "only an exact fluxwipe=1 authorises a wipe" \
	|| bad "a near-miss of fluxwipe=1 wiped a disk"

# --- the wipe -------------------------------------------------------------------
build
keep=""; for n in sdc sdd sde sdf sdg; do keep="$keep $(sum $n)"; done
run "BOOT_IMAGE=/linux initrd=initrd.magic autoinstall fluxwipe=1 fluxhost=web12"
[ "$ec" = 0 ] && [ "$(cat "$WORK/t/out")" = "$DV/nvme0n1" ] \
	&& ok "with fluxwipe=1 it still prints the same target" || bad "fluxwipe=1 changed the target or exit ($ec)"
for n in nvme0n1 sda sdb vda; do
	s=$(cat "$S/block/$n/size")
	if [ "$(nz "$n" 0 "$EDGE")" = 0 ] && [ "$(nz "$n" $((s - EDGE)) "$EDGE")" = 0 ]; then
		ok "$n: first and last 16 MiB zeroed"
	else
		bad "$n: a disk edge still holds data"
	fi
done
[ "$(nz sda $MIB)" = 0 ] && [ "$(nz sda $((65 * MIB - 1)))" = 0 ] && ok "sda1: both ends zeroed" \
	|| bad "sda1: a partition end survived"
[ "$(nz sda $((65 * MIB)))" = 0 ] && [ "$(nz sda $((255 * MIB - 1)))" = 0 ] && ok "sda2: both ends zeroed" \
	|| bad "sda2: a partition end survived"
[ "$(nz sda $((160 * MIB)))" != 0 ] && ok "quick wipe: the middle of a big partition is left as it is (documented)" \
	|| bad "the middle of sda2 was overwritten - the README promises a quick wipe"
after=""; for n in sdc sdd sde sdf sdg; do after="$after $(sum $n)"; done
[ "$keep" = "$after" ] \
	&& ok "USB stick, USB disk, FC LUN, iSCSI LUN and read-only disk untouched" \
	|| bad "a disk that is not eligible was written"
grep -q "^blkdiscard $DV/nvme0n1" "$WORK/t/calls" && grep -q "^blkdiscard $DV/sda" "$WORK/t/calls" \
	&& ok "SSD/NVMe disks discarded whole" || bad "a discard-capable disk was not discarded"
grep -q "^blkdiscard $DV/sdb" "$WORK/t/calls" && bad "discard sent to a disk without discard support" \
	|| ok "no discard sent to a spinning disk"
grep -q "^swapoff $DV/sda2" "$WORK/t/calls" && ok "live swap on a wiped disk is turned off first" \
	|| bad "swap on sda2 was not released"
grep -q "^dmsetup remove vg-dm-0" "$WORK/t/calls" && grep -q "^mdadm --stop $DV/md127" "$WORK/t/calls" \
	&& ok "LVM on md on a wiped disk taken down" || bad "stacked md/dm not released"
[ "$(grep -n "^dmsetup" "$WORK/t/calls" | cut -d: -f1)" -lt "$(grep -n "^mdadm" "$WORK/t/calls" | cut -d: -f1)" ] \
	&& ok "stack released top down (dm before md)" || bad "md stopped before the dm device on top of it"
grep -q "^blockdev --rereadpt $DV/sdb" "$WORK/t/calls" && ok "partition tables re-read" \
	|| bad "no partition table re-read"
grep -q "wiped $DV/sdb" "$WORK/t/kmsg" && grep -q "not overwritten" "$WORK/t/kmsg" \
	&& ok "the log says what was wiped, and that a spinning disk is not overwritten" \
	|| bad "the wipe report is missing from the kernel log"
[ "$(cat "$WORK/t/out" | wc -l | tr -d ' ')" = 1 ] && ok "stdout carries the device name only" \
	|| bad "stdout carries more than the device name"

# No blkdiscard (anaconda's stage2): the same ioctl through python3.
build
rm -f "$ST/blkdiscard"
mkdir -p "$WORK/t/bin"
for t in sh cat dd sed grep readlink tr sync rm mv cut wc sleep find "${FLUX_SH%% *}"; do
	case $t in */*) continue ;; esac   # an absolute FLUX_SH needs no link
	[ -e "$WORK/t/bin/$t" ] && continue
	p=$(PATH="${FLUX_BIN:+$FLUX_BIN:}$PATH" command -v "$t") && ln -s "$p" "$WORK/t/bin/$t"
done
( export flux_sys="$S" flux_dev="$DV" flux_proc="$PR" flux_kmsg="$WORK/t/kmsg"
  export PATH="$ST:$WORK/t/bin"
  echo "fluxwipe=1" > "$PR/cmdline"
  $FLUX_SH ./src/flux-disks > /dev/null 2>&1 )
grep -q "^python3 BLKDISCARD $DV/nvme0n1 $((160 * MIB))$" "$WORK/t/calls" \
	&& ok "no blkdiscard: python3 issues BLKDISCARD with the disk's size" \
	|| bad "no discard fallback when blkdiscard is missing"
# Neither tool: the disk is still wiped, and the log says the rest of it is
# not overwritten rather than claiming a discard.
rm -f "$ST/python3" "$WORK/t/kmsg"
( export flux_sys="$S" flux_dev="$DV" flux_proc="$PR" flux_kmsg="$WORK/t/kmsg"
  export PATH="$ST:$WORK/t/bin"
  $FLUX_SH ./src/flux-disks > /dev/null 2>&1 )
grep -q "wiped $DV/nvme0n1.*no discard tool in this installer" "$WORK/t/kmsg" \
	&& [ "$(nz nvme0n1 0)" = 0 ] \
	&& ok "no discard tool at all: still wiped, and the log does not claim a discard" \
	|| bad "without any discard tool the wipe or its report is wrong"

# Something that cannot be released: the disk is skipped and named, the rest
# is still wiped.
build
touch "$WORK/t/stuck-md127" "$WORK/t/stuck-vg-dm-0"
run "fluxwipe=1"
[ "$(nz sdb 0)" != 0 ] && grep -q "sdb.*still in use - NOT wiped" "$WORK/t/kmsg" \
	&& ok "a disk still in use is skipped, and the log says so" \
	|| bad "a busy disk was wiped anyway, or skipped silently"
[ "$(nz sda 0)" = 0 ] && [ "$(nz vda 0)" = 0 ] && ok "the other disks are wiped regardless" \
	|| bad "one busy disk stopped the others being wiped"

# A filesystem on a wiped disk that will not unmount: the helper tries,
# and when it stays mounted the disk is left alone rather than zeroed under a
# live mount. (The umount stub records the attempt and changes nothing.)
build
printf '%s/sda1 /mnt/old ext4 rw 0 0\n' "$DV" >> "$PR/mounts"
run "fluxwipe=1"
grep -q "^umount $DV/sda1" "$WORK/t/calls" && [ "$(nz sda 0)" != 0 ] \
	&& grep -q "sda.*still in use - NOT wiped" "$WORK/t/kmsg" \
	&& ok "a disk with a filesystem that stays mounted is skipped, after trying to unmount it" \
	|| bad "a mounted disk was wiped, or the unmount was never attempted"

# No eligible disk at all: exit 1, empty stdout, and nothing wiped.
build
for n in nvme0n1 sda sdb vda; do echo 1 > "$S/block/$n/removable"; done
run "fluxwipe=1"
[ "$ec" = 1 ] && [ ! -s "$WORK/t/out" ] && ok "no eligible disk: exit 1, nothing on stdout" \
	|| bad "no eligible disk, yet exit $ec / stdout '$(cat "$WORK/t/out")'"
[ "$(nz sda 0)" != 0 ] && [ "$(nz sdc 0)" != 0 ] && ! called blkdiscard \
	&& ok "no eligible disk: nothing wiped at all" || bad "no eligible disk, yet something was wiped"

# --- every family uses the one rule ------------------------------------------
# Verbatim copies, where nothing the menu appends to the initrd can reach the
# installer: anaconda's %pre runs after switch_root, and the Proxmox hook is
# baked into the release initrd.
for f in src/ks.cfg src/pve-bashrc; do
	if sed -n "/cat > \/tmp\/flux-disks <<'FLUXEOF'$/,/^FLUXEOF$/p" "$f" | sed '1d;$d' | cmp -s - src/flux-disks; then
		ok "$f carries src/flux-disks byte for byte"
	else
		bad "$f's copy of src/flux-disks has drifted - paste the current file between the FLUXEOF markers"
	fi
done
grep -q '^%' src/flux-disks && bad "a line of src/flux-disks starts with % - it would end ks.cfg's %pre" \
	|| ok "src/flux-disks is safe inside a kickstart section"
grep -q 'ignoredisk --only-use=${DISK#/dev/}' src/ks.cfg && ok "ks.cfg: anaconda kept to the chosen disk" \
	|| bad "ks.cfg: ignoredisk does not use the chosen disk"
grep -q 'disk=$(sh /tmp/flux-disks)' src/pve-bashrc && grep -q 'disk-list = \["$disk"\]' src/pve-bashrc \
	&& ok "pve-bashrc: the answers name the chosen disk" || bad "pve-bashrc: disk-list is not the chosen disk"
grep -q 'd=$(sh /flux-disks) && debconf-set partman-auto/disk "$d"' src/preseed.cfg \
	&& ok "preseed: partman gets the chosen disk" || bad "preseed: partman-auto/disk is not the chosen disk"
grep -q '<device>@ZDISK@</device>' src/autoinst.xml && grep -q 's|@ZDISK@|$Z|g' src/autoinst.xml \
	&& grep -q 'Z=$(sh /flux-disks)' src/autoinst.xml \
	&& ok "autoinst.xml: the pre-script writes the chosen disk into <partitioning>" \
	|| bad "autoinst.xml: <partitioning> is not tied to the chosen disk"
python3 - "$WORK" <<'PY' && ok "agama profile: the only drive is the chosen one" || bad "agama profile: storage is not tied to @ZDISK@"
import json, sys
p = json.load(open("assets/agama-leap16.json"))
d = p["storage"]["drives"]
assert len(d) == 1 and d[0]["search"] == "@ZDISK@", d
PY
grep -q 'Before=agama.service' src/50-flux-agama.sh && grep -q 's|@ZDISK@|$t|' src/50-flux-agama.sh \
	&& ok "agama hook: the disk is settled before agama.service probes storage" \
	|| bad "agama hook: the disk unit is not ordered before agama.service"
grep -q "path: '@ZDISK@'" src/99fluxseed && grep -q 'sed -i "s|@ZDISK@|$t|" /autoinstall.yaml' src/99fluxseed \
	&& ok "ubuntu seed: early-command writes the chosen disk into the storage match" \
	|| bad "ubuntu seed: storage match is not the chosen disk"
grep -q 'flux-disks' src/sign-boot-images.sh && ok "18.04/20.04 auto-initrd carries /flux-disks" \
	|| bad "sign-boot-images.sh does not ship /flux-disks to the 18.04/20.04 d-i"
grep -q '/work/flux-disks' build.sh && grep -q '^imgargs flux-disks flux-disks' fluxbilling.ipxe \
	&& ok "the ISO embeds the helper and stamps it into every initrd" \
	|| bad "the helper is not embedded, or not stamped into the initrd"

# --- the menu ------------------------------------------------------------------
M=fluxbilling.ipxe
k=$(grep -c '^kernel ' $M); kw=$(grep '^kernel ' $M | grep -c '${wipe_kargs}')
[ "$k" -gt 0 ] && [ "$k" = "$kw" ] && ok "all $k kernel lines carry \${wipe_kargs}" \
	|| bad "$((k - kw)) of $k kernel lines lack \${wipe_kargs} - that entry would never wipe"
[ "$(grep -c 'set wipe_kargs' $M)" = 1 ] && grep -B2 'set wipe_kargs fluxwipe=1' $M | grep -q 'iseq ${wipe} wipe_yes || goto os_pick' \
	&& ok "fluxwipe=1 is set in exactly one place, behind the Yes answer" \
	|| bad "wipe_kargs is set somewhere other than behind the Yes answer"
sed -n '/^:os_pick$/,/^isset/p' $M | grep -q '^clear wipe_kargs' \
	&& ok "returning to the OS menu drops the authorisation" || bad ":os_pick does not clear wipe_kargs"
grep -q '^choose --default wipe_no wipe || goto os_pick' $M && ok "the question defaults to No" \
	|| bad "the erase-all-disks question does not default to No"
grep -q '^iseq ${amode} manual && goto ${pick} ||' $M && grep -q '^goto confirm_wipe' $M \
	&& ok "AUTOMATED installs go through the question, MANUAL ones do not" \
	|| bad "the OS menu does not route automated installs through :confirm_wipe"
# Menu chrome is drawn on a serial line too: 7-bit ASCII only.
sed -n '/^:confirm_wipe$/,/^choose/p' $M | LC_ALL=C grep -q '[^ -~]' \
	&& bad "the question has non-ASCII text - SOL consoles garble it" || ok "the question is plain ASCII"

[ "$rc" = 0 ] && echo "disks: OK (shell: $FLUX_SH)" || echo "disks: FAIL (shell: $FLUX_SH)"
exit "$rc"
