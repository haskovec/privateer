import struct
from collections import defaultdict

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_LBA * SECTOR)
    raw = f.read(200000)

count = struct.unpack_from('<I', raw, 0)[0]
toc_size = struct.unpack_from('<I', raw, 4)[0]

# Find all entries systematically by searching for the flag+path pattern
entries = []
pos = 8  # skip header
while len(entries) < count and pos < toc_size:
    # Each entry starts with a flag byte (01 or 00) followed by a ".." path
    if raw[pos] in (0, 1) and raw[pos+1:pos+3] == b'..':
        flag = raw[pos]
        # Find null terminator
        null_pos = raw.find(b'\x00', pos+1)
        if null_pos == -1 or null_pos > toc_size:
            break
        path = raw[pos+1:null_pos].decode('ascii', errors='replace')
        # Everything from null+1 to next entry is metadata
        entries.append({
            'offset': pos,
            'flag': flag,
            'path': path,
            'path_end': null_pos,
        })
        # Advance past this entry - we need to find the next flag byte
        pos = null_pos + 1
        # Skip metadata bytes until we hit the next entry or end
        while pos < toc_size and not (raw[pos] in (0, 1) and pos+2 < toc_size and raw[pos+1:pos+3] == b'..'):
            pos += 1
    else:
        pos += 1

print(f"Found {len(entries)} entries (expected {count})")
print(f"TOC size: {toc_size}")

# Now analyze entry spacing to find the structure
spacings = defaultdict(int)
for i in range(1, len(entries)):
    spacing = entries[i]['offset'] - entries[i-1]['offset']
    spacings[spacing] += 1

print(f"\nEntry spacings:")
for sp, cnt in sorted(spacings.items()):
    print(f"  {sp} bytes: {cnt} entries")

# Determine the metadata format by finding fixed-size entries
# All entries seem to be 74 bytes with some exceptions
# Let's verify by checking entries that DON'T have 74-byte spacing
print("\nNon-74-byte entries:")
for i in range(1, len(entries)):
    spacing = entries[i]['offset'] - entries[i-1]['offset']
    if spacing != 74:
        print(f"  Entry {i-1}: spacing={spacing}, path='{entries[i-1]['path']}'")

# Now figure out the metadata by looking at fixed-position fields
# For all entries, the metadata starts right after the null terminator
# With a 74-byte fixed entry, the metadata end is at entry_offset + 74
print("\nMetadata analysis (first entry with long path analysis):")
for i in range(min(3, len(entries))):
    e = entries[i]
    entry_end = e['offset'] + 74
    meta_start = e['path_end'] + 1
    meta = raw[meta_start:entry_end]

    print(f"\n  Entry {i}: {e['path']}")
    print(f"    Flag: {e['flag']}")
    print(f"    Meta ({len(meta)} bytes): {meta.hex()}")

    # The metadata should contain: file offset, file size, timestamps, etc.
    # Let's try reading from the END of the metadata block (fixed position)
    # Last 40 bytes of the 74-byte entry
    fixed_meta = raw[e['offset'] + 34:e['offset'] + 74]
    print(f"    Fixed position meta (offset+34 to +74, {len(fixed_meta)} bytes):")
    vals = struct.unpack_from('<10I', fixed_meta, 0)
    print(f"    As 10 x uint32 LE: {vals}")
    for j, v in enumerate(vals):
        print(f"      [{j}] {v:10d} (0x{v:08x})")

# Let's try a different approach - read the actual file data to verify
# The file data should start after the TOC at offset toc_size relative to TRE start
print(f"\n\nSearching for IFF data in the TRE (after offset {toc_size}):")
for search_start in range(toc_size, min(toc_size + 1000, len(raw))):
    tag = raw[search_start:search_start+4]
    if tag == b'FORM':
        size = struct.unpack_from('>I', raw, search_start+4)[0]
        subtype = raw[search_start+8:search_start+12].decode('ascii', errors='replace')
        print(f"  FORM at TRE+{search_start}: size={size}, type={subtype}")

        # Parse its contents
        print(f"  Chunks inside:")
        cpos = search_start + 12
        while cpos < search_start + 8 + size:
            ctag = raw[cpos:cpos+4]
            if not all(32 <= b < 127 for b in ctag):
                break
            csize = struct.unpack_from('>I', raw, cpos+4)[0]
            ctag_str = ctag.decode('ascii')
            if ctag_str in ('FORM', 'CAT '):
                csub = raw[cpos+8:cpos+12].decode('ascii', errors='replace')
                print(f"    {ctag_str} ({csize}) -> {csub}")
            else:
                # Show first few bytes of data
                preview = raw[cpos+8:cpos+8+min(32, csize)]
                print(f"    {ctag_str} ({csize}) data: {preview.hex()}")
            cpos += 8 + csize
            if csize % 2 == 1:
                cpos += 1
        break
