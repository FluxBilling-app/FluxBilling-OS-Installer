<p align="center">
  <a href="https://fluxbilling.app">
    <picture>
      <source srcset="https://fluxbilling.app/images/FluxBilling-xs.avif" type="image/avif">
      <img src="assets/FluxBilling.png" width="120" alt="FluxBilling">
    </picture>
  </a>
</p>

<h1 align="center">FluxBilling OS Installer</h1>

<p align="center">
  <b>A 3 MB boot ISO that installs 20+ server operating systems — fully automated.</b><br>
  Free and open source, from <a href="https://fluxbilling.app"><b>FluxBilling.app</b></a> —
  billing, DCIM and IPAM for hosting providers.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/engine-iPXE-blue">
  <img src="https://img.shields.io/badge/image-~3%20MB-brightgreen">
  <img src="https://img.shields.io/badge/boot-BIOS%20%2B%20UEFI-orange">
  <img src="https://img.shields.io/badge/OS%20entries-19-purple">
  <img src="https://img.shields.io/badge/license-GPL--2.0--or--later-blue">
</p>

---

Rack the server, attach the ISO to iDRAC/iLO/IPMI virtual media, answer five
prompts, pick an OS, walk away. It reboots into a configured system with SSH
root login.

**Every heavy payload — kernels, initrds, install ISOs — streams at boot over
the data NIC you choose in the menu**, straight from the official distro
mirrors. The slow management port only ever carries the 3 MB image, and there
is no private config webserver: installer identity and network config are
generated *on the machine itself* from your answers.

- **Tiny** — ~3 MB, attaches over IPMI virtual media in seconds.
- **Zero-touch** — hostname, static IP and root password typed once.
- **No PXE server, no DHCP** — static IP from the menu; works in any colo.
- **Manual mode** — one toggle boots the *same* installer interactively.
- **BIOS + UEFI**, serial console (SOL) mirrored, /31 subnets supported.

## Supported operating systems

| Family | Versions | Automated config |
|---|---|---|
| Ubuntu (subiquity) | 26.04 LTS, 25.10, 24.04 LTS, 22.04 LTS | NoCloud seed generated at boot |
| Ubuntu (d-i) | 20.04, 18.04 | preseed + cmdline |
| Debian | 13, 12, 11 | preseed + cmdline |
| AlmaLinux | 10, 9, 8 | kickstart (`%pre` from cmdline) |
| Rocky Linux | 10, 9, 8 | kickstart |
| CentOS Stream | 10, 9 | kickstart |
| openSUSE Leap | 15.6 | AutoYaST profile |
| openSUSE Leap | 16.0 | Agama profile injected into the initrd |

## Quick start

1. Grab `FluxBilling-OS-Installer_v1.0.iso` from
   [Releases](../../releases) — or [build it](#building).
2. Attach via virtual media — or flash a USB stick:

   ```sh
   # macOS - replace diskN with the USB stick
   diskutil unmountDisk /dev/diskN
   sudo dd if=FluxBilling-OS-Installer_v1.0.iso of=/dev/rdiskN bs=1m
   ```

   ```sh
   # Linux - replace sdX with the USB stick
   sudo dd if=FluxBilling-OS-Installer_v1.0.iso of=/dev/sdX bs=1M status=progress conv=fsync
   ```

   **Windows** — Windows has no `dd`. Use
   [Rufus](https://rufus.ie): select the ISO, and when it asks, pick
   **DD Image** mode (not ISO mode), then Start.

   > **USB boot needs a hybrid MBR.** Virtual media — the intended path — is
   > unaffected: iDRAC/iLO present the image as a CD and El Torito handles it.
   > Verify a build is USB-bootable before trusting a stick:
   > `xxd -s 510 -l 2 *.iso` must read `55aa`, not `0000`.

3. Boot it and answer:

   ```text
   Port number [ENTER = 0]             <- live NIC list (pick the data NIC)
   IP / subnet: 203.0.113.111/27       <- one field; /1../31 (incl. /31 p2p)
   Gateway [ENTER = 203.0.113.97]      <- auto-calculated, ENTER accepts
   Hostname:
   Password:                           <- hidden (TAB to the field, ENTER)
   ```

4. Review screen, fix any field, pick an OS. Done.

The first OS-menu entry toggles **AUTOMATED** (answer files injected,
zero-touch, watchable over SOL) and **MANUAL** (same installer, no answer
file, driven by hand). `BOOTIF=01-<mac>` lets every installer find the boot
NIC by MAC, so there is no NIC-name guessing on any hardware.

## How it works

One iPXE image with a custom CIDR parser (`fluxcidr`, C, compiled in) and
eight embedded payload files. At boot iPXE fetches the official kernel/initrd
for the chosen OS and **injects the matching answer file into the initrd in
memory** (cpio append) — no vendor artifact is ever rebuilt or redistributed.
Answer files ride under `flux-*` names so no installer auto-probes them during
a manual install.

Per-family mechanics, mirror URLs and the hard-won gotchas are documented
inline in [fluxbilling.ipxe](fluxbilling.ipxe) and
[src/builder.Dockerfile](src/builder.Dockerfile).

## Requirements & limits

- **RAM:** Ubuntu 22.04+ stream the full live ISO to RAM — **8 GB+**.
  Alma/Rocky/CentOS stage2 — **4 GB+**. Leap 16.0 — **2.5 GB+**.
- **CPU:** Alma/Rocky 10 and CentOS Stream 10 need x86_64-v3 (Haswell/EPYC or
  newer). Older Xeons: use the 9.x entries.
- Internet reachability from the static IP you enter.
- Password rides the kernel command line: letters, digits and `._-!@#%^*+=`
  are safe; avoid spaces, quotes, `;`, `\`, `/`.
- Fallback identity if prompts arrive empty: `fluxserver` / `fluxbilling`.
- Tested end-to-end so far: Ubuntu 24.04 on Dell iDRAC. The other entries
  share the same verified mechanics but deserve a hardware smoke test.

## Building

Needs Docker. Everything is pinned:

```sh
./build.sh        # outputs FluxBilling-OS-Installer_v1.0.iso
```

First run bakes the builder image (~10 min); every rebuild after that is ~15
seconds. `src/qemu-test.sh` walks the prompts in QEMU; `src/e2e-test.sh`
verifies the injected files survive the initrd unpack.

## Why we built this

**FluxBilling does not use this ISO.** Inside the panel, bare-metal
deployment and IPAM are fully automated — nothing to attach, nothing to type.

But plenty of machines sit outside a panel: a box you're rebuilding, a one-off
install, a rack you don't manage yet, someone else's colo. That is the job
this image does, and we release it free because provisioning a server should
not require a PXE stack or an afternoon of virtual media.

<h3 align="center"><a href="https://fluxbilling.app">FluxBilling.app</a></h3>

<p align="center">
  <b>Billing, DCIM and IPAM for hosting providers — in one place.</b><br>
  Servers, IPs, invoices and clients, with bare-metal deployment fully
  automated inside the panel. Built like a native app.<br><br>
  <a href="https://fluxbilling.app"><b>→ See the panel</b></a>
</p>

## License

**GPL-2.0-or-later** — see [LICENSE](LICENSE).

The ISO is a **modified [iPXE](https://ipxe.org)** binary (copyright Michael
Brown and contributors), distributed under the GNU GPL v2 or later with
iPXE's Unmodified Binary Distribution Licence exception (`COPYING.UBDL`).
Base: iPXE commit
[`56a4f695`](https://github.com/ipxe/ipxe/commit/56a4f695d6d17a4a1c93d196c586d481dbe3b934).
Every modification is an explicit patch step in
[src/builder.Dockerfile](src/builder.Dockerfile) — config edits, the EFI
autoexec stub, and the added `fluxcidr` command
([src/fluxcidr_cmd.c](src/fluxcidr_cmd.c)). Corresponding source is this
repository; `./build.sh` rebuilds the released ISO from it. The embedded
answer files are original work under the same terms.

**No operating system is redistributed here.** Kernels, initrds, install ISOs
and repositories are fetched at boot, unmodified, from the vendors' own
mirrors. Answer files are injected into the vendor initrd in RAM, on the
operator's own machine.

**Trademarks.** Ubuntu is a trademark of Canonical Ltd; Debian of Software in
the Public Interest, Inc; Red Hat and CentOS of Red Hat, Inc; AlmaLinux of the
AlmaLinux OS Foundation; Rocky Linux of the Rocky Enterprise Software
Foundation; openSUSE of SUSE LLC. All marks belong to their respective owners
and are used descriptively to identify the operating systems this installer
can fetch. This project is not affiliated with, sponsored by or endorsed by
any of them, nor by the iPXE project or netboot.xyz.

---

<p align="center">
  <i>FluxBilling OS Installer v1.0 — powered by <a href="https://ipxe.org">iPXE</a>.</i>
</p>
