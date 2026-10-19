import os
import struct

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "wenilla_bg.wasm.orig"), "rb") as f:
    data = bytearray(f.read())

print("Original wasm size:", len(data))

# Base information
FILE_DATA_OFFSET = 78930343
MEM_BASE = 0x100000

def to_lin(file_off):
    return MEM_BASE + (file_off - FILE_DATA_OFFSET)

def to_file(lin_addr):
    return lin_addr - MEM_BASE + FILE_DATA_OFFSET

# 1. Patch addon names array at 79858607
# Old: 124 bytes
OLD_NAMES_OFF = 79858607
OLD_NAMES_LEN = 124
addons = [
    # Each bundled row only puts the addon in the AddOn list (so players can tick it on or off).
    # The real code is streamed in by www/addons-loader.js; these stubs must not define slash
    # commands: the old "Raid" stub set SLASH_RAID2 = '/rally', which turned /rally into raid
    # chat and took /ra away from raid chat for every player.
    ("Meters", "Meters", "Chronicle: damage and healing meter for you and your group.", b"\nMeters = Meters or {}\n"),
    ("Quests", "Quests", "Compass: brass minimap ring, quest pins and coordinates.", b"\nQuests = Quests or {}\n"),
    ("Threat", "Threat", "Vanguard: exact target threat with pull warnings.", b"\nThreat = Threat or {}\n"),
    ("Casting", "Casting", "Castline: exact enemy cast bars for target and nameplates.", b"\nCasting = Casting or {}\n"),
    ("Guilds", "Guilds", "Concord: guild recruitment board with one-click applications.", b"\nGuilds = Guilds or {}\n"),
    ("Bags", "Bags", "Vault: every bag in one window, search, remembered bank.", b"\nBags = Bags or {}\n"),
    ("Prices", "Prices", "Ledger: market and vendor prices on item tooltips.", b"\nPrices = Prices or {}\n"),
    ("Vendor", "Vendor", "Scrapper: one-click grey selling and repairs.", b"\nVendor = Vendor or {}\n"),
    ("Plates", "Plates", "Visage: clean nameplates with your target's debuffs.", b"\nPlates = Plates or {}\n"),
    ("Raid", "Raid", "Rally: raid markers, ready checks and pull timers.", b"\nRaid = Raid or {}\n"),
]

# Build new names string
new_names_bytes = b"".join(n.encode("utf-8") for n, t, d, l in addons)
assert len(new_names_bytes) <= OLD_NAMES_LEN
padded_names = new_names_bytes + b"\x00" * (OLD_NAMES_LEN - len(new_names_bytes))
data[OLD_NAMES_OFF : OLD_NAMES_OFF + OLD_NAMES_LEN] = padded_names

# Record name pointers
name_ptrs = []
curr_name_lin = to_lin(OLD_NAMES_OFF)
for n, t, d, l in addons:
    name_ptrs.append((curr_name_lin, len(n)))
    curr_name_lin += len(n)

# 2. Build payload region (Descriptions, Filenames, Lua chunks, File table entries)
# Region: 79870266 .. 79887549
PAYLOAD_START = 79870266
PAYLOAD_END = 79887549
PAYLOAD_MAX = PAYLOAD_END - PAYLOAD_START

payload_buf = bytearray()

desc_ptrs = []
for n, t, d, l in addons:
    d_bytes = d.encode("utf-8")
    d_lin = to_lin(PAYLOAD_START + len(payload_buf))
    desc_ptrs.append((d_lin, len(d_bytes)))
    payload_buf.extend(d_bytes)

fname_ptrs = []
for n, t, d, l in addons:
    fn_bytes = f"{n}.lua".encode("utf-8")
    fn_lin = to_lin(PAYLOAD_START + len(payload_buf))
    fname_ptrs.append((fn_lin, len(fn_bytes)))
    payload_buf.extend(fn_bytes)

lua_ptrs = []
for n, t, d, l in addons:
    l_lin = to_lin(PAYLOAD_START + len(payload_buf))
    lua_ptrs.append((l_lin, len(l)))
    payload_buf.extend(l)

# File table entries (10 items of 16 bytes each)
file_table_ptrs = []
for i in range(len(addons)):
    ft_lin = to_lin(PAYLOAD_START + len(payload_buf))
    file_table_ptrs.append(ft_lin)
    fn_lin, fn_len = fname_ptrs[i]
    l_lin, l_len = lua_ptrs[i]
    payload_buf.extend(struct.pack("<IIII", fn_lin, fn_len, l_lin, l_len))

print("Total payload bytes:", len(payload_buf), "available:", PAYLOAD_MAX)
assert len(payload_buf) <= PAYLOAD_MAX
padded_payload = payload_buf + b"\x00" * (PAYLOAD_MAX - len(payload_buf))
data[PAYLOAD_START:PAYLOAD_END] = padded_payload

# 3. Patch struct table at 79887567 (15 items * 48 bytes = 720 bytes)
TABLE_OFF = 79887567
for i in range(10):
    n_lin, n_len = name_ptrs[i]
    d_lin, d_len = desc_ptrs[i]
    ft_lin = file_table_ptrs[i]
    # words: [p_name, l_name, p_title, l_title, p_desc, l_desc, 4 (None), 0, ft_lin, 1, 0x2bc0, 1]
    entry = struct.unpack("<12I", struct.pack("<12I",
        n_lin, n_len,
        n_lin, n_len,
        d_lin, d_len,
        4, 0,
        ft_lin, 1,
        0x2bc0, 1
    ))
    data[TABLE_OFF + i * 48 : TABLE_OFF + (i + 1) * 48] = struct.pack("<12I", *entry)

# Items 10..14 blanked
for i in range(10, 15):
    data[TABLE_OFF + i * 48 : TABLE_OFF + (i + 1) * 48] = b"\x00" * 48

# 4. Patch loop bounds at 6409315 - 7 and 15793630 - 7
# Replace 720 (0xd0 0x05) with 480 (0xe0 0x03)
for off in [6409315 - 7, 15793630 - 7]:
    assert data[off:off+2] == b"\xd0\x05"
    data[off:off+2] = b"\xe0\x03"
    print(f"Patched loop bound at {off} to 480 (10 addons)")

# 5. Patch UI Profile buttons in wasm code
# The i64.const values for string lengths start 1 byte after opcode 0x42:
# At 1524749 + 1 (len 11) -> 10 bytes zero
# At 1524866 + 1 (len 6)  -> 10 bytes zero
# At 1524914 + 1 (len 6)  -> 10 bytes zero
# At 1524962 + 1 (len 8)  -> 10 bytes zero
zero_10b = bytes([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00])
for off, old_first in [(1524750, 0x8b), (1524867, 0x86), (1524915, 0x86), (1524963, 0x88)]:
    assert data[off] == old_first
    data[off:off+10] = zero_10b
    print(f"Patched string length to 0 at {off}")

# 6. Patch GlueStrings at 79592616
# Replace "UI Profile:Classic+PuristRaider" (31 chars) with spaces
GLUE_OFF = 79592616
assert data[GLUE_OFF:GLUE_OFF+31] == b"UI Profile:Classic+PuristRaider"
data[GLUE_OFF:GLUE_OFF+31] = b" " * 31
print("Patched GlueStrings at 79592616")

# 7. Patch GameMenuAdapters.xml in wasm
start_xml = data.find(b"<FontString name=\"$parentProfileLabel\"")
end_xml = data.find(b"<!-- Force Out-of-Date Load -->")
xml_len = end_xml - start_xml
assert start_xml != -1 and end_xml != -1
data[start_xml:end_xml] = b"<!-- Native Addons Suite -->" + b" " * (xml_len - len(b"<!-- Native Addons Suite -->"))
print(f"Patched Profile XML buttons ({xml_len} bytes) at {start_xml}")

# Patch ApplyProfile logic in GameMenuAdapters.xml
apply_off = data.find(b"BenillaAddonList_ApplyProfile(profile)")
assert apply_off != -1
b_start = data.find(b"local shouldEnable = false", apply_off)
b_end = data.find(b"if shouldEnable then", apply_off)
b_len = b_end - b_start
assert b_start != -1 and b_end != -1

new_apply_lua = b"local shouldEnable = (profile ~= 'purist')"
assert len(new_apply_lua) <= b_len
data[b_start:b_end] = new_apply_lua + b" " * (b_len - len(new_apply_lua))
print("Patched ApplyProfile logic in wasm")

# Write output wasm
out_wasm = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wenilla_bg.wasm")
with open(out_wasm, "wb") as f:
    f.write(data)
print("Successfully wrote patched wenilla_bg.wasm, size:", len(data))

# Refresh the precompressed copies so they never serve the old binary.
import gzip
with open(out_wasm + ".gz", "wb") as f:
    f.write(gzip.compress(bytes(data), compresslevel=9))
print("wrote", out_wasm + ".gz")
try:
    import brotli
    with open(out_wasm + ".br", "wb") as f:
        f.write(brotli.compress(bytes(data), quality=9))
    print("wrote", out_wasm + ".br")
except ImportError:
    import os
    if os.path.exists(out_wasm + ".br"):
        os.remove(out_wasm + ".br")
        print("removed stale", out_wasm + ".br", "(pip install brotli to regenerate it)")
