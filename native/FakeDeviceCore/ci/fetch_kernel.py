#!/usr/bin/env python3
"""CI helper: download ONLY the kernelcache entry out of Apple's iOS 14.8
(18H17) IPSW for iPhone12,1, using HTTP range requests (~16 MB pulled out
of the ~6 GB IPSW), and inflate it to the IM4P file.

Usage: fetch_kernel.py <out.im4p>

Standard library only. The IPSW URL is resolved live from the ipsw.me
API (the same source the app itself uses). Adapted from the extraction
script that produced the reference kernelcache (see PROVENANCE.md in the
project's kernelcache directory); the ZIP range logic is unchanged.
"""
import json
import struct
import sys
import urllib.request
import zlib

OUT = sys.argv[1]
ENTRY_SUBSTR = "kernelcache.release.iphone12b"
API = "https://api.ipsw.me/v4/device/iPhone12,1?type=ipsw"


def resolve_ipsw_url():
    with urllib.request.urlopen(API, timeout=60) as r:
        data = json.load(r)
    for fw in data.get("firmwares", []):
        if fw.get("version") == "14.8" and fw.get("buildid") == "18H17":
            return fw["url"]
    sys.exit("iOS 14.8 (18H17) firmware not found in the ipsw.me listing")


URL = resolve_ipsw_url()
print(f"IPSW: {URL}")


def range_get(start, end):
    """GET bytes [start, end] inclusive."""
    req = urllib.request.Request(URL, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def total_size():
    req = urllib.request.Request(URL, headers={"Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        cr = r.headers.get("Content-Range", "")
        return int(cr.rsplit("/", 1)[1])


size = total_size()
print(f"IPSW total size: {size} bytes ({size/1e9:.2f} GB)")

# --- read tail to find End Of Central Directory (EOCD) ---
tail_len = min(size, 1 << 20)
tail = range_get(size - tail_len, size - 1)
idx = tail.rfind(b"PK\x05\x06")
if idx < 0:
    sys.exit("EOCD not found")
eocd = tail[idx:idx + 22]
(_, disk, cd_disk, n_disk, n_total, cd_size, cd_off, comment_len) = struct.unpack(
    "<IHHHHIIH", eocd)
if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF or n_total == 0xFFFF:
    loc = tail[idx - 20:idx]
    assert loc[:4] == b"PK\x06\x07", "zip64 locator not found"
    (lsig, ldisk, z64_off, ldisks) = struct.unpack("<IIQI", loc)
    rec = range_get(z64_off, z64_off + 56 - 1)
    assert rec[:4] == b"PK\x06\x06", "bad zip64 EOCD signature"
    (rsig, rsize, vmade, vneed, rdisk, rcddisk, rn_disk, rn_total,
     cd_size, cd_off) = struct.unpack("<IQHHIIQQQQ", rec)
    n_total = rn_total
print(f"central directory: {n_total} entries, size={cd_size}, offset={cd_off}")

# --- fetch central directory ---
cd = range_get(cd_off, cd_off + cd_size - 1)
assert cd[:4] == b"PK\x01\x02", "bad central directory signature"

entries = {}
pos = 0
while pos < len(cd):
    if cd[pos:pos + 4] != b"PK\x01\x02":
        break
    fields = struct.unpack("<IHHHHHHIIIHHHHHII", cd[pos:pos + 46])
    (sig, ver_made, ver_need, flags, method, mtime, mdate, crc,
     csize, usize, nlen, elen, clen, disk_start, iattr, eattr, lhofs) = fields
    name = cd[pos + 46:pos + 46 + nlen].decode("utf-8", "replace")
    extra = cd[pos + 46 + nlen:pos + 46 + nlen + elen]
    ep = 0
    while ep + 4 <= len(extra):
        tag, esz = struct.unpack("<HH", extra[ep:ep + 4])
        body = extra[ep + 4:ep + 4 + esz]
        if tag == 0x0001:
            bp = 0
            if usize == 0xFFFFFFFF:
                usize = struct.unpack("<Q", body[bp:bp + 8])[0]; bp += 8
            if csize == 0xFFFFFFFF:
                csize = struct.unpack("<Q", body[bp:bp + 8])[0]; bp += 8
            if lhofs == 0xFFFFFFFF:
                lhofs = struct.unpack("<Q", body[bp:bp + 8])[0]; bp += 8
        ep += 4 + esz
    entries[name] = dict(method=method, csize=csize, usize=usize,
                         lhofs=lhofs, flags=flags, crc=crc)
    pos += 46 + nlen + elen + clen

print(f"parsed {len(entries)} entries")
match = None
for name, e in entries.items():
    if ENTRY_SUBSTR in name.lower():
        match = (name, e)
        break
if match is None:
    sys.exit("no kernelcache entry matched")

name, e = match
print(f"downloading entry: {name}")

lh = range_get(e["lhofs"], e["lhofs"] + 30 - 1)
assert lh[:4] == b"PK\x03\x04", "bad local header"
lh_fields = struct.unpack("<IHHHHHIIIHH", lh)
nlen, elen = lh_fields[9], lh_fields[10]
data_start = e["lhofs"] + 30 + nlen + elen
print(f"data starts at {data_start}, compressed size {e['csize']}")

comp = range_get(data_start, data_start + e["csize"] - 1)
print(f"downloaded {len(comp)} compressed bytes")

if e["method"] == 0:
    raw = comp
elif e["method"] == 8:
    raw = zlib.decompress(comp, -15)
else:
    sys.exit(f"unsupported zip method {e['method']}")

print(f"inflated to {len(raw)} bytes; first 16 bytes: {raw[:16]!r}")
with open(OUT, "wb") as f:
    f.write(raw)
print(f"wrote {OUT}")
