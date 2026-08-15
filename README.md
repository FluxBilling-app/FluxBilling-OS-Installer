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
  <img src="https://img.shields.io/badge/OS%20entries-24-purple">
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
| Oracle Linux&#8224; | 10, 9, 8 | kickstart (same file as Alma/Rocky) |
| openSUSE Leap | 15.6 | AutoYaST profile |
| openSUSE Leap | 16.0 | Agama profile injected into the initrd |
| Proxmox VE&#8224; | 9 (9.2), 8 (8.4) | `answer.toml` generated in-installer from cmdline |

&#8224; Oracle publishes no netboot images and Proxmox no netboot installer at
all, so these entries boot kernel/initrd (and Oracle's anaconda stage2) from
this repo's signed `boot-*` release — **they stay on the menu but fail
cleanly until that release is cut** (see
[docs/SIGNED-BOOT.md](docs/SIGNED-BOOT.md) and `src/sign-boot-images.sh`).
The Proxmox install ISO itself streams unmodified from
`download.proxmox.com` into RAM, where the stock installer finds it as
`/proxmox.iso` — manual mode is the ordinary Proxmox GUI installer, automated
mode generates the official `answer.toml` on the machine from your typed
answers (password as a SHA-512 hash, never plaintext at rest).

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

One iPXE image with a custom CIDR parser (`fluxcidr`, C, compiled in) and the
payload files listed in `build.sh`'s `EMBEDLIST`. At boot iPXE fetches the
official kernel/initrd for the chosen OS and **injects the matching answer
file into the initrd in memory** (cpio append) — no vendor artifact is ever
rebuilt or redistributed. Answer files ride under `flux-*` names so no
installer auto-probes them during a manual install.

Per-family mechanics, mirror URLs and the hard-won gotchas are documented
inline in [fluxbilling.ipxe](fluxbilling.ipxe) and
[src/builder.Dockerfile](src/builder.Dockerfile).

### Surviving upstream moves

Every URL is baked in at build time, and an ISO burned to a customer's iDRAC
cannot be edited — so an upstream move would otherwise kill that menu entry
forever. Two mechanisms cover it, neither of which needs FluxBilling to host
anything:

- **Fallback hosts.** A failed casper fetch retries
  `old-releases.ubuntu.com`, where Ubuntu moves superseded point releases; the
  d-i entries walk a country mirror and then the archive host
  (`archive.debian.org` for a deleted Debian suite).
  [src/fallback-test.sh](src/fallback-test.sh) boots ISOs with a dead primary
  to prove both actually fire.
- **A watchdog.** [upstream-watch](.github/workflows/upstream-watch.yml)
  probes every URL the menu fetches — generated from the menu itself by
  [src/menu-urls.sh](src/menu-urls.sh), never hand-copied — the way iPXE
  fetches it, and opens a bump PR when Ubuntu supersedes a pinned release.

## Requirements & limits

- **RAM:** Ubuntu 22.04+ stream the full live ISO to RAM — **8 GB+**.
  Proxmox VE streams its full install ISO the same way — **6 GB+**.
  Alma/Rocky/CentOS/Oracle stage2 — **4 GB+**. Leap 16.0 — **2.5 GB+**.
- **CPU:** Alma/Rocky/Oracle 10 and CentOS Stream 10 need x86_64-v3
  (Haswell/EPYC or newer). Older Xeons: use the 9.x entries.
- Internet reachability from the static IP you enter.
- Password rides the kernel command line: letters, digits and `._-!@#%^*+=`
  are safe; avoid spaces, quotes, `;`, `\`, `/`.
- Fallback hostname if the prompt arrives empty: `fluxserver`. There is **no
  fallback password** — if `fluxpass=` is missing, both accounts are left
  locked rather than given a known default.
- **Secure Boot must be off.** `ipxe.efi` is built here and is not signed by a
  Microsoft-trusted CA, so UEFI firmware with Secure Boot enabled refuses to
  load it. No practical fix exists for a custom iPXE build; disable Secure
  Boot for the install, and re-enable it afterwards if the installed OS ships
  a signed shim (Ubuntu, Debian, Alma, Rocky and Leap all do).
- Tested end-to-end: **all 24 automated entries, under both legacy BIOS
  (SeaBIOS) and UEFI (OVMF)** — each install ran to completion in KVM, the
  guest rebooted off its own disk and accepted a root SSH login with the
  menu-typed password, with hostname, static IP and os-release asserted
  (src/install-matrix.sh, 48/48 PASS, 2026-08-15). Ubuntu 24.04 additionally
  verified on physical Dell iDRAC; the other entries share the same verified
  mechanics but still deserve a hardware smoke test on real NICs and RAID
  controllers, which QEMU's single virtio disk and slirp network do not
  exercise.

## Security

What is and is not protected, honestly:

- **Packages are verified.** APT and DNF check every package against the
  distro GPG keys, so what lands on disk is signature-checked end to end.
- **Bulk downloads use HTTPS.** The Ubuntu ISO, the anaconda stage2 and
  repos, the Leap live squashfs and `install=` tree are all fetched by the
  installer, which carries a full CA bundle.
- **Kernel and initrd fetches are plain HTTP and unverified** until the first
  signed `boot-*` release ships. The binary now bakes in a set of public root
  CAs (`CERT=`/`TRUST=` in [build.sh](build.sh)), so the https fetches iPXE
  does make — the 22.04 GitHub release, and mirrors that redirect http→https —
  validate with no `ca.ipxe.org` dependency; but the plain-http kernel/initrd
  fetches still trust the network. Run the installer on a trusted management
  network, and cut the signed release to close the gap for good.
- **Credentials never persist in cleartext.** The root password rides the
  kernel command line, so every family creates its accounts locked, sets the
  real password through `chpasswd` (hash only, in `/etc/shadow`), and scrubs
  `fluxpass=` out of the installer logs on first boot. One exception: a
  **manual** openSUSE Leap 16.0 install also carries `live.password=` (the
  Agama web-UI login) on the command line, and manual mode runs no profile —
  so nothing installs the scrub. Clear `/var/log/agama-installation` after a
  manual Leap 16 install, or use automated mode, which never passes it.
  Proxmox has no post-install hook a stock ISO can run, so its generated
  `answer.toml` carries a **SHA-512 crypt hash** instead of the password —
  what `/etc/shadow` would hold anyway — and the plaintext never exists
  outside the live installer's kernel command line.
- **The Proxmox install ISO is fetched over plain HTTP** — forced, not
  chosen: `download.proxmox.com`'s TLS certificate does not name that host
  (it names the `cdn.proxmox.com` pool), so an https fetch fails hostname
  validation. The signed `boot-*` release stages a detached signature for
  the exact ISO (`proxmox-N-iso.sig`, fetched for signing over valid https
  from `enterprise.proxmox.com`), closing this the same way the kernel/initrd
  gap closes.
- **Root SSH with password authentication is enabled** on every family. That
  is a deliberate provisioning convenience — harden it immediately after
  install if the box faces the internet.

To close the kernel/initrd gap, see [docs/SIGNED-BOOT.md](docs/SIGNED-BOOT.md):
mirror and sign the ~350 MB of boot images, bake your own CA fingerprint into
the iPXE binary, and let `imgverify` reject anything tampered with — over
plain HTTP, with no dependency on anyone else's PKI.

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

## Thanks

Thank you [@AlexIancu98](https://github.com/AlexIancu98) for your contribution.

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

**No operating system is redistributed here** — with narrow, documented
exceptions. Kernels, initrds, install ISOs and repositories are fetched at
boot, unmodified, from the vendors' own mirrors, except where a vendor
publishes no netboot artifacts at all: the Ubuntu 22.04 kernel/initrd come
from a [netboot.xyz](https://netboot.xyz) GitHub release (Canonical never
published a netboot tree for that series — see the `boot2204` note in
[fluxbilling.ipxe](fluxbilling.ipxe)), and the signed `boot-*` release
described in [docs/SIGNED-BOOT.md](docs/SIGNED-BOOT.md) additionally carries
the Oracle Linux kernel/initrd/stage2 and the Proxmox VE installer
kernel/initrd, each extracted unmodified from the vendor's official ISO
(both are freely redistributable under their respective licenses; sources
are the vendors' own repositories). Answer files are injected into the
vendor initrd in RAM, on the operator's own machine.

**Trademarks.** Ubuntu is a trademark of Canonical Ltd; Debian of Software in
the Public Interest, Inc; Red Hat and CentOS of Red Hat, Inc; AlmaLinux of the
AlmaLinux OS Foundation; Rocky Linux of the Rocky Enterprise Software
Foundation; openSUSE of SUSE LLC; Oracle and Oracle Linux of Oracle and/or its
affiliates; Proxmox and Proxmox VE of Proxmox Server Solutions GmbH. All marks
belong to their respective owners
and are used descriptively to identify the operating systems this installer
can fetch. This project is not affiliated with, sponsored by or endorsed by
any of them, nor by the iPXE project or netboot.xyz.

---

<p align="center">
  <i>FluxBilling OS Installer v1.0 — powered by <a href="https://ipxe.org">iPXE</a>.</i>
</p>
