"""Read an MPQ (version 1) in pure Python: enough for patch-Z.MPQ checks, no StormLib needed.

    from mpqread import MPQ
    m = MPQ("realm/classicplus/patch-Z.MPQ")
    m.names()                 -> every name in (listfile)
    m.read("Interface\\AddOns\\Persona\\Persona.toc") -> bytes

Supports what Open Vanilla's archives use: hash/block tables, sectored files compressed with zlib
(and stored / single-unit files). Encrypted files are not supported (ours never are).
"""
import struct
import zlib

_CRYPT = []


def _table():
    seed = 0x00100001
    t = [0] * 0x500
    for i in range(0x100):
        j = i
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            a = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t[j] = a | (seed & 0xFFFF)
            j += 0x100
    return t


def _hash(name, kind):
    global _CRYPT
    if not _CRYPT:
        _CRYPT = _table()
    s1, s2 = 0x7FED7FED, 0xEEEEEEEE
    for ch in name.upper().encode("latin-1"):
        s1 = (_CRYPT[(kind << 8) + ch] ^ (s1 + s2)) & 0xFFFFFFFF
        s2 = (ch + s1 + s2 + (s2 << 5) + 3) & 0xFFFFFFFF
    return s1


def _decrypt(data, key):
    if not _CRYPT:
        _hash("", 0)
    out = bytearray()
    seed = 0xEEEEEEEE
    for (v,) in struct.iter_unpack("<I", data):
        seed = (seed + _CRYPT[0x400 + (key & 0xFF)]) & 0xFFFFFFFF
        d = (v ^ (key + seed)) & 0xFFFFFFFF
        key = ((((~key) << 0x15) + 0x11111111) | (key >> 0x0B)) & 0xFFFFFFFF
        seed = (d + seed + (seed << 5) + 3) & 0xFFFFFFFF
        out += struct.pack("<I", d)
    return bytes(out)


class MPQ:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        off = 0
        while self.data[off:off + 4] != b"MPQ\x1a":
            off += 0x200
            if off > len(self.data):
                raise ValueError("not an MPQ")
        self.base = off
        (_, hsize, _, _, sshift, ht, bt, hn, bn) = struct.unpack_from("<4sIIHHIIII", self.data, off)
        self.sector = 512 << sshift
        raw = self.data[off + ht: off + ht + hn * 16]
        self.hashes = list(struct.iter_unpack("<IIHHI", _decrypt(raw, _hash("(hash table)", 3))))
        raw = self.data[off + bt: off + bt + bn * 16]
        self.blocks = list(struct.iter_unpack("<IIII", _decrypt(raw, _hash("(block table)", 3))))

    def _block(self, name):
        n = len(self.hashes)
        i = _hash(name, 0) % n
        a, b = _hash(name, 1), _hash(name, 2)
        for _ in range(n):
            ha, hb, _, _, blk = self.hashes[i]
            if blk == 0xFFFFFFFF:
                return None
            if ha == a and hb == b and blk != 0xFFFFFFFE:
                return self.blocks[blk]
            i = (i + 1) % n
        return None

    def exists(self, name):
        return self._block(name) is not None

    def read(self, name):
        blk = self._block(name)
        if blk is None:
            raise KeyError(name)
        pos, csize, size, flags = blk
        if flags & 0x10000:
            raise ValueError(f"{name}: encrypted files are not supported")
        start = self.base + pos
        raw = self.data[start:start + csize]
        compressed = flags & 0x200 or flags & 0x100
        if not compressed or csize == size:
            return raw[:size]
        if flags & 0x1000000:  # single unit
            return self._unpack(raw, size)
        nsec = (size + self.sector - 1) // self.sector
        offs = struct.unpack_from("<%dI" % (nsec + 1), raw)
        out = bytearray()
        for k in range(nsec):
            want = min(self.sector, size - k * self.sector)
            out += self._unpack(raw[offs[k]:offs[k + 1]], want)
        return bytes(out)

    @staticmethod
    def _unpack(chunk, want):
        if len(chunk) == want:
            return chunk
        kind = chunk[0]
        if kind == 0x02:
            return zlib.decompress(chunk[1:])
        raise ValueError(f"unsupported compression 0x{kind:02x}")

    def names(self):
        if not self.exists("(listfile)"):
            return []
        txt = self.read("(listfile)").decode("latin-1")
        return [n.strip() for n in txt.replace(";", "\n").splitlines() if n.strip()]
