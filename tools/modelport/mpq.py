"""MPQ version 1 archives (the 1.12 client's patch format) in pure Python: read and write.

Writes what tools/build_mpq.py made with StormLib: zlib-compressed 4 KB sectors, an unencrypted
(listfile), no (attributes). Reads zlib, bzip2 and stored files (what patches use).
"""
import bz2
import struct
import zlib


def _readb(path):
    with open(path, "rb") as f:
        return f.read()


def _writeb(path, data):
    with open(path, "wb") as f:
        f.write(data)

_CRYPT = []


def _crypt_table():
    seed = 0x00100001
    table = [0] * 0x500
    for i in range(0x100):
        for j in range(5):
            idx = i + j * 0x100
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t2 = seed & 0xFFFF
            table[idx] = t1 | t2
    return table


def _hash(name, kind):
    global _CRYPT
    if not _CRYPT:
        _CRYPT = _crypt_table()
    s1, s2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in name.upper().replace("/", "\\").encode("latin1"):
        s1 = (_CRYPT[(kind << 8) + ch] ^ (s1 + s2)) & 0xFFFFFFFF
        s2 = (ch + s1 + s2 + (s2 << 5) + 3) & 0xFFFFFFFF
    return s1


def _crypt(data, key, decrypt):
    global _CRYPT
    if not _CRYPT:
        _CRYPT = _crypt_table()
    words = list(struct.unpack(f"<{len(data) // 4}I", data[: len(data) // 4 * 4]))
    seed = 0xEEEEEEEE
    out = []
    for w in words:
        seed = (seed + _CRYPT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        v = (w ^ (key + seed)) & 0xFFFFFFFF
        plain = v if decrypt else w
        key = (((~key << 0x15) + 0x11111111) | (key >> 0x0B)) & 0xFFFFFFFF
        seed = (plain + seed + (seed << 5) + 3) & 0xFFFFFFFF
        out.append(v)
    return struct.pack(f"<{len(out)}I", *out) + data[len(words) * 4:]


EXISTS, COMPRESS, IMPLODE, SINGLE, ENCRYPTED = 0x80000000, 0x00000200, 0x00000100, 0x01000000, 0x00010000


class Archive:
    def __init__(self, path):
        self.data = _readb(path)
        off = 0
        while self.data[off:off + 4] != b"MPQ\x1a":
            if self.data[off:off + 4] == b"MPQ\x1b":  # user data header
                off = struct.unpack_from("<I", self.data, off + 8)[0] + off
                continue
            off += 512
            if off >= len(self.data):
                raise ValueError("not an MPQ archive")
        self.base = off
        (_, hsize, _, ver, shift, ht_off, bt_off, ht_n, bt_n) = struct.unpack_from("<4sIIHHIIII", self.data, off)
        self.sector = 512 << shift
        ht = _crypt(self.data[off + ht_off: off + ht_off + ht_n * 16], _hash("(hash table)", 3), True)
        bt = _crypt(self.data[off + bt_off: off + bt_off + bt_n * 16], _hash("(block table)", 3), True)
        self.hashes = [struct.unpack_from("<IIHHI", ht, i * 16) for i in range(ht_n)]
        self.blocks = [struct.unpack_from("<IIII", bt, i * 16) for i in range(bt_n)]

    def _find(self, name):
        n = len(self.hashes)
        a, b = _hash(name, 1), _hash(name, 2)
        i = _hash(name, 0) & (n - 1)
        for _ in range(n):
            na, nb, _loc, _plat, blk = self.hashes[i]
            if blk == 0xFFFFFFFF:
                return None
            if na == a and nb == b and blk != 0xFFFFFFFE:
                return blk
            i = (i + 1) % n
        return None

    def read(self, name):
        bi = self._find(name)
        if bi is None:
            return None
        offset, csize, fsize, flags = self.blocks[bi]
        if not flags & EXISTS:
            return None
        if flags & ENCRYPTED:
            raise ValueError(f"{name} is encrypted")
        start = self.base + offset
        raw = self.data[start: start + csize]
        if flags & SINGLE or not flags & (COMPRESS | IMPLODE):
            return _decompress(raw, fsize) if flags & COMPRESS and csize < fsize else raw[:fsize]
        n = (fsize + self.sector - 1) // self.sector
        offs = struct.unpack_from(f"<{n + 1}I", raw, 0)
        out = bytearray()
        for k in range(n):
            chunk = raw[offs[k]:offs[k + 1]]
            want = min(self.sector, fsize - k * self.sector)
            out += chunk if len(chunk) == want else _decompress(chunk, want)
        return bytes(out)

    def names(self):
        lf = self.read("(listfile)")
        if not lf:
            return []
        return [x for x in lf.decode("latin1").replace("\r", "\n").replace(";", "\n").split("\n") if x.strip()]


def _decompress(chunk, want):
    mask, body = chunk[0], chunk[1:]
    if mask == 0x02:
        return zlib.decompress(body)
    if mask == 0x10:
        return bz2.decompress(body)
    raise ValueError(f"MPQ compression {mask:#x} isn't supported here")


def write(path, files, sector_shift=3):
    """``files``: {archive name: bytes}. Writes a fresh archive with a (listfile)."""
    sector = 512 << sector_shift
    names = sorted(files, key=str.lower)
    lst = "\r\n".join(names).encode("latin1") + b"\r\n"
    entries = [(n, files[n]) for n in names] + [("(listfile)", lst)]
    body = bytearray()
    blocks = []
    for name, data in entries:
        n = max(1, (len(data) + sector - 1) // sector) if data else 0
        if not data:
            blocks.append((32 + len(body), 0, 0, EXISTS))
            continue
        sectors = []
        for k in range(n):
            part = data[k * sector:(k + 1) * sector]
            z = b"\x02" + zlib.compress(part, 9)
            sectors.append(z if len(z) < len(part) else part)
        table = [4 * (n + 1)]
        for s in sectors:
            table.append(table[-1] + len(s))
        blob = struct.pack(f"<{n + 1}I", *table) + b"".join(sectors)
        blocks.append((32 + len(body), len(blob), len(data), EXISTS | COMPRESS))
        body += blob
    ht_n = 16
    while ht_n < len(entries) * 2:
        ht_n *= 2
    hashes = [(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFF, 0xFFFF, 0xFFFFFFFF)] * ht_n
    for bi, (name, _) in enumerate(entries):
        i = _hash(name, 0) & (ht_n - 1)
        while hashes[i][4] != 0xFFFFFFFF:
            i = (i + 1) % ht_n
        hashes[i] = (_hash(name, 1), _hash(name, 2), 0, 0, bi)
    ht = b"".join(struct.pack("<IIHHI", *h) for h in hashes)
    bt = b"".join(struct.pack("<IIII", *b) for b in blocks)
    ht_off = 32 + len(body)
    bt_off = ht_off + len(ht)
    total = bt_off + len(bt)
    header = struct.pack("<4sIIHHIIII", b"MPQ\x1a", 32, total, 0, sector_shift, ht_off, bt_off, ht_n, len(blocks))
    out = header + bytes(body) + _crypt(ht, _hash("(hash table)", 3), False) + _crypt(bt, _hash("(block table)", 3), False)
    tmp = path + ".tmp"
    _writeb(tmp, out)
    import os
    os.replace(tmp, path)
    return len(out)
