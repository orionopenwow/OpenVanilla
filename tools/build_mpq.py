"""Pack Open Vanilla Classic+ client files into patch-Z.MPQ with StormLib (ctypes)."""
import ctypes as C, os, sys
lib = C.CDLL(os.environ.get("STORMLIB", "libstorm.so"))  # STORMLIB=/path/to/libstorm.so
H = C.c_void_p
lib.SFileCreateArchive.argtypes = [C.c_char_p, C.c_uint, C.c_uint, C.POINTER(H)]
lib.SFileAddFileEx.argtypes = [H, C.c_char_p, C.c_char_p, C.c_uint, C.c_uint, C.c_uint]
lib.SFileCloseArchive.argtypes = [H]
lib.SFileCompactArchive.argtypes = [H, C.c_char_p, C.c_bool]
MPQ_CREATE_ARCHIVE_V1 = 0x00000000
MPQ_CREATE_LISTFILE = 0x00100000
MPQ_CREATE_ATTRIBUTES = 0x00200000
MPQ_FILE_COMPRESS = 0x00000200
MPQ_FILE_REPLACEEXISTING = 0x80000000
MPQ_COMPRESSION_ZLIB = 0x02

src, out = sys.argv[1], sys.argv[2]
files = []
for root, _, names in os.walk(src):
    for n in names:
        full = os.path.join(root, n)
        files.append((full, os.path.relpath(full, src).replace("/", "\\")))
if os.path.exists(out):
    os.remove(out)
h = H()
# SFileCreateArchive gives (listfile) StormLib's default flags, which ENCRYPT it, and benilla's
# reader refuses encrypted files (so the chain listing — G1's addon discovery and the web's
# /data/__index — would miss every file in the patch). SFileCreateArchive2 lets us store it
# compressed only, and skip (attributes).
class CreateMpq(C.Structure):
    _fields_ = [("cbSize", C.c_uint), ("dwMpqVersion", C.c_uint), ("pvUserData", C.c_void_p),
                ("cbUserData", C.c_uint), ("dwStreamFlags", C.c_uint), ("dwFileFlags1", C.c_uint),
                ("dwFileFlags2", C.c_uint), ("dwFileFlags3", C.c_uint), ("dwAttrFlags", C.c_uint),
                ("dwSectorSize", C.c_uint), ("dwRawChunkSize", C.c_uint), ("dwMaxFileCount", C.c_uint)]
lib.SFileCreateArchive2.argtypes = [C.c_char_p, C.POINTER(CreateMpq), C.POINTER(H)]
info = CreateMpq(cbSize=C.sizeof(CreateMpq), dwMpqVersion=0, dwFileFlags1=MPQ_FILE_COMPRESS,
                 dwFileFlags2=0, dwFileFlags3=0, dwAttrFlags=0, dwSectorSize=0x1000,
                 dwMaxFileCount=max(64, len(files) * 2 + 2))
if not lib.SFileCreateArchive2(out.encode(), C.byref(info), C.byref(h)):
    sys.exit(f"create failed: {C.get_errno()}")
for full, arc in sorted(files, key=lambda f: f[1].lower()):
    if not lib.SFileAddFileEx(h, full.encode(), arc.encode(), MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING,
                              MPQ_COMPRESSION_ZLIB, MPQ_COMPRESSION_ZLIB):
        sys.exit(f"add failed: {arc}")
    print("  +", arc)
lib.SFileCompactArchive(h, None, False)
lib.SFileCloseArchive(h)
print(out, os.path.getsize(out), "bytes,", len(files), "files")
