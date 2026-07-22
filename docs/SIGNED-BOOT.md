# Signed boot images

Closing the last unverified link in the chain: the kernel and initrd that iPXE
fetches itself.

## The problem

Packages are GPG-verified by APT and DNF. The bulk downloads (Ubuntu ISO,
anaconda stage2 and repos, Leap squashfs) go over HTTPS and are validated by
the installers, which carry a full CA bundle.

The kernel and initrd are different. **iPXE** fetches those, and its default
trust store holds exactly one fingerprint — the iPXE root CA
([`crypto/rootcert.c`][rootcert]). Every public certificate chain therefore
fails to complete, and iPXE resolves that by downloading a cross-signed
certificate over **plain HTTP** from `ca.ipxe.org` ([`config/crypto.h`][crypto]).
So switching those URLs to HTTPS buys no verified transport — it only adds a
third-party dependency that must be reachable from the management network at
boot time.

The answer is to stop trusting the transport and verify the payload instead.

## How it works

1. Mirror each kernel/initrd from its official mirror.
2. Sign each one with our own code-signing key.
3. Bake **our** CA fingerprint into the iPXE binary at build time (`TRUST=`).
4. Have the menu run `imgverify` after each fetch.

A tampered, truncated or substituted image then fails closed — over plain
HTTP, with no dependency on anyone else's PKI.

Only kernel and initrd are mirrored: ~350 MB for all 19 pairs, versus ~10 GB
for the ISOs. Everything bulky stays on the official mirrors.

## One-time key generation

Run this on a machine you control. **The private keys must never be
committed** — `certs/` and `*.key` are gitignored. Anyone holding
`flux-ca.key` can mint a kernel that every FluxBilling installer trusts, so
keep it offline and back it up somewhere that is not this repo.

```bash
mkdir -p certs

# Root of trust. Only its FINGERPRINT goes into the iPXE binary.
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout certs/flux-ca.key -out certs/flux-ca.crt \
  -subj "/CN=FluxBilling OS Boot CA"

# Code-signing cert, issued by that CA. The codeSigning EKU is mandatory:
# iPXE rejects any other cert with EACCES_NON_CODE_SIGNING (crypto/cms.c).
openssl req -newkey rsa:4096 -sha256 -nodes \
  -keyout certs/flux-codesign.key -out certs/flux-codesign.csr \
  -subj "/CN=FluxBilling OS Boot Signer"

openssl x509 -req -in certs/flux-codesign.csr \
  -CA certs/flux-ca.crt -CAkey certs/flux-ca.key -CAcreateserial \
  -days 1825 -sha256 -extfile <(printf 'extendedKeyUsage=codeSigning') \
  -out certs/flux-codesign.crt
```

## Mirror, sign, publish

```bash
./src/sign-boot-images.sh --dry-run   # review the URL list first
./src/sign-boot-images.sh             # fetch + sign into out/boot-images
```

Then cut a release on this repo and attach everything in `out/boot-images`
(each image plus its `.sig`, and `SHA256SUMS`). The script prints a ready-made
`gh release create` line.

## Wiring it into the build

Two changes are needed once the first release exists.

**1. `src/builder.Dockerfile`** — enable the trust commands and bake in the CA
fingerprint. `IMAGE_TRUST_CMD` is commented out in stock iPXE
(`config/general.h`), and unlike `DIGEST_CMD` it is *not* stripped again for
BIOS builds, so one edit covers both targets:

```dockerfile
RUN cd /ipxe/src && \
    sed -ri "s|^//(#define[[:space:]]+IMAGE_TRUST_CMD)|\1|" config/general.h && \
    grep -qE "^#define[[:space:]]+IMAGE_TRUST_CMD" config/general.h
```

and pass the CA to both `make` invocations in `build.sh`:

```
make ... EMBED="$EMBEDLIST" TRUST=/work/flux-ca.crt
```

(copy `certs/flux-ca.crt` into `/work` alongside the embedded payload — the
public certificate is safe to ship, only the key is secret).

**2. `fluxbilling.ipxe`** — fetch from the release and verify. Every family
follows the same shape; the shared `:launch` tail covers the initrd:

```
set flux_boot https://github.com/<owner>/FluxBilling-OS/releases/download/boot-YYYYMMDD
...
kernel --name kboot ${flux_boot}/alma-9-vmlinuz ... || goto boot_fail
imgverify kboot ${flux_boot}/alma-9-vmlinuz.sig || goto boot_fail
```

Keep `${img*}`, `inst.repo=`, `install=` and the Leap squashfs pointed at the
official mirrors over HTTPS. Only the two images iPXE fetches move.

## Refresh cadence

This is **not** fire-and-forget. anaconda's initrd and the stage2 it pulls
from `inst.repo` come from the same compose, and Alma, Rocky and CentOS Stream
roll their repos forward continuously. A pinned initrd drifts out of step with
a moving repo and will eventually fail to start stage2.

Re-run the script and cut a fresh release whenever a point release lands — or
pin `inst.repo` to a versioned compose rather than the rolling one.

[rootcert]: https://github.com/ipxe/ipxe/blob/56a4f695/src/crypto/rootcert.c#L55
[crypto]: https://github.com/ipxe/ipxe/blob/56a4f695/src/config/crypto.h#L87
