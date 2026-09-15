#!/usr/bin/env python3
"""Range-read helpers for src/boot-pairing-check.sh - see that script for why.

Modes:
  kver <url>                  version string of a bzImage served over HTTP
  iso-kver <iso> <path>       same, for a kernel INSIDE an ISO (path is
                              slash-separated, e.g. casper/vmlinuz or
                              boot/x86_64/loader/linux)
  iso-uuid <iso>              the ISO's .disk/casper-uuid* values
  initrd-uuid <file> <iso>    a local initrd's casper UUID vs that ISO's
  iso-ls <iso> [path]         directory listing, for adding a new rule

Everything against an ISO is an HTTP range read: the volume descriptors, the
root directory, then one directory extent per path segment and one file
extent. A 4 GB image costs a few hundred KB to inspect this way, so these
checks can gate every push instead of waiting for a weekly job.
"""
import os, sys, urllib.request as u

def rng(url, a, b):
    """One HTTP range read. A failure here is upstream state, not a bug, so it
    is reported as a line the caller can grep - never a Python traceback in a
    CI log."""
    req = u.Request(url, headers={"Range": f"bytes={a}-{b}"})
    try:
        return u.urlopen(req, timeout=120).read()
    except Exception as e:                     # noqa: BLE001 - reported, not raised
        print(f"UNREACHABLE      {url} ({e})")
        raise SystemExit(3)


def le32(b, o):
    return int.from_bytes(b[o:o + 4], "little")


def kver(head):
    """Version string of an x86 bzImage: u16 at 0x20e is an offset from 0x200."""
    off = int.from_bytes(head[0x20e:0x210], "little")
    return head[0x200 + off:0x200 + off + 120].split(b"\x00")[0].decode("latin1", "ignore")


def _readdir(url, lba, size, joliet):
    data = rng(url, lba * 2048, lba * 2048 + size - 1)
    out, o = [], 0
    while o < len(data):
        L = data[o]
        if L == 0:                      # rest of this sector is padding
            o = (o // 2048 + 1) * 2048
            if o >= len(data):
                break
            continue
        rec = data[o:o + L]
        nlen = rec[32]
        raw = rec[33:33 + nlen]
        name = raw.decode("utf-16-be", "ignore") if joliet else raw.decode("latin1")
        out.append((name.rstrip("\x00"), le32(rec, 2), le32(rec, 10)))
        o += L
    return out


def iso_root(url):
    vds = rng(url, 32768, 32768 + 4 * 2048 - 1)
    pvd = joliet = None
    for i in range(4):
        d = vds[i * 2048:(i + 1) * 2048]
        if d[1:6] != b"CD001":
            continue
        if d[0] == 1:
            pvd = d
        # Joliet gives real lowercase names (.disk, casper); the primary
        # descriptor would need Rock Ridge parsing for the same thing.
        if d[0] == 2 and d[88:91] in (b"%/@", b"%/C", b"%/E"):
            joliet = d
    desc = joliet or pvd
    if desc is None:
        raise SystemExit("no ISO9660 volume descriptor")
    root = desc[156:156 + 34]
    return le32(root, 2), le32(root, 10), joliet is not None


def iso_lookup(url, path):
    """Walk a slash-separated path through the ISO's directory records."""
    lba, size, jol = iso_root(url)
    parts = [p for p in path.split("/") if p]
    for i, want in enumerate(parts):
        last = i == len(parts) - 1
        hit = None
        for nm, l, s in _readdir(url, lba, size, jol):
            name = nm.lower().split(";")[0]
            # ISO9660 stores ".disk" as "disk" in some producers; strip the
            # leading dot on directory components so both spellings match.
            if name == want.lower() or name.strip(".") == want.lower().strip("."):
                hit = (l, s)
                break
        if hit is None:
            return None
        if last:
            return hit
        lba, size = hit
    return None


def iso_uuids(url):
    lba, size, jol = iso_root(url)
    found = []
    for nm, l, s in _readdir(url, lba, size, jol):
        if nm.lower().strip(".;1") == "disk":
            for n2, l2, s2 in _readdir(url, l, s, jol):
                if "casper-uuid" in n2.lower():
                    found.append((n2.split(";")[0],
                                  rng(url, l2 * 2048, l2 * 2048 + s2 - 1).decode("latin1").strip()))
    return found


def iso_kver(url, path):
    loc = iso_lookup(url, path)
    if loc is None:
        return None
    return kver(rng(url, loc[0] * 2048, loc[0] * 2048 + 65535)).split()[0]


def initrd_uuid(path):
    """conf/uuid.conf lives in the LAST cpio segment of an initrd, which is
    zstd-compressed; the uncompressed early segments (microcode, firmware) are
    walked to find where that one starts."""
    import subprocess, tempfile, pathlib
    blob = pathlib.Path(path).read_bytes()

    def hdr(h, i):
        return int(blob[h + 6 + i * 8:h + 6 + (i + 1) * 8], 16)

    off = 0
    while off < len(blob) and blob[off:off + 6] == b"070701":
        while True:
            ns, fs = hdr(off, 11), hdr(off, 6)
            nm = blob[off + 110:off + 110 + ns - 1].decode("latin1")
            step = (110 + ns + 3) // 4 * 4
            if nm == "TRAILER!!!":
                end = off + step
                break
            off += step + (fs + 3) // 4 * 4
        while end < len(blob) and blob[end] == 0:
            end += 1
        off = end
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(f"tail -c +{off + 1} '{path}' | zstd -dq | cpio -idm 2>/dev/null",
                       shell=True, cwd=td)
        f = pathlib.Path(td) / "conf" / "uuid.conf"
        return f.read_text().strip() if f.exists() else None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "kver":
        print(kver(rng(argv[2], 0, 65535)).split()[0])
    elif cmd == "iso-kver":
        v = iso_kver(argv[2], argv[3])
        if v is None:
            print("ABSENT")
            return 1
        print(v)
    elif cmd == "iso-uuid":
        for n, v in iso_uuids(argv[2]):
            print(f"{n} {v}")
    elif cmd == "initrd-uuid":
        u = initrd_uuid(argv[2]) or "(not found)"
        iso = [v for _, v in iso_uuids(argv[3])]
        print(f"{'MATCH' if u in iso else 'MISMATCH'} initrd={u} iso={' '.join(iso) or '(none)'}")
        return 0 if u in iso else 1
    elif cmd == "iso-ls":
        lba, size, jol = iso_root(argv[2])
        if len(argv) > 3 and argv[3]:
            loc = iso_lookup(argv[2], argv[3])
            if loc is None:
                print("ABSENT")
                return 1
            lba, size = loc
        print(" ".join(n for n, _, _ in _readdir(argv[2], lba, size, jol) if n))
    else:
        print(f"unknown mode: {cmd}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
