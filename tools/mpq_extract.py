"""Extract every file of an MPQ (e.g. realm/classicplus/patch-Z.MPQ) into a folder, with StormLib.

    python3 tools/mpq_extract.py realm/classicplus/patch-Z.MPQ build/patch-Z
    STORMLIB=/path/to/libstorm.so python3 tools/mpq_extract.py ...

The folder can then be edited and packed again with tools/build_mpq.py.
"""
import ctypes as C
import os
import sys

lib = C.CDLL(os.environ.get("STORMLIB", "libstorm.so"))
H = C.c_void_p
lib.SFileOpenArchive.argtypes = [C.c_char_p, C.c_uint, C.c_uint, C.POINTER(H)]
lib.SFileExtractFile.argtypes = [H, C.c_char_p, C.c_char_p, C.c_uint]
lib.SFileCloseArchive.argtypes = [H]
lib.SFileOpenFileEx.argtypes = [H, C.c_char_p, C.c_uint, C.POINTER(H)]
lib.SFileReadFile.argtypes = [H, C.c_void_p, C.c_uint, C.POINTER(C.c_uint), C.c_void_p]
lib.SFileGetFileSize.argtypes = [H, C.POINTER(C.c_uint)]
lib.SFileGetFileSize.restype = C.c_uint
lib.SFileCloseFile.argtypes = [H]


def read(h, name):
    f = H()
    if not lib.SFileOpenFileEx(h, name.encode(), 0, C.byref(f)):
        return None
    size = lib.SFileGetFileSize(f, None)
    buf = C.create_string_buffer(size)
    got = C.c_uint()
    lib.SFileReadFile(f, buf, size, C.byref(got), None)
    lib.SFileCloseFile(f)
    return buf.raw[:got.value]


def main(src, dst):
    h = H()
    if not lib.SFileOpenArchive(src.encode(), 0, 0x100, C.byref(h)):  # STREAM_FLAG_READ_ONLY
        sys.exit(f"can't open {src}")
    listing = read(h, "(listfile)") or b""
    names = [n.strip() for n in listing.decode("latin-1").splitlines() if n.strip()]
    for name in names:
        out = os.path.join(dst, *name.split("\\"))
        os.makedirs(os.path.dirname(out), exist_ok=True)
        data = read(h, name)
        if data is None:
            print("  ! missing", name)
            continue
        with open(out, "wb") as f:
            f.write(data)
        print("  -", name, len(data))
    lib.SFileCloseArchive(h)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
