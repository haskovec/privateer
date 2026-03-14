import struct

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_LBA * SECTOR)
    # Read enough for full TOC + some data
    raw = f.read(200000)

count = struct.unpack_from('<I', raw, 0)[0]
toc_size = struct.unpack_from('<I', raw, 4)[0]
print(f"Count: {count}, TOC size: {toc_size}")

# Dump the first 256 bytes as hex with ASCII for careful analysis
print("\nFirst 384 bytes of TRE (hex+ascii):")
for i in range(0, 384, 16):
    hexstr = ' '.join(f'{raw[j]:02x}' for j in range(i, min(i+16, 384)))
    ascstr = ''.join(chr(raw[j]) if 32 <= raw[j] < 127 else '.' for j in range(i, min(i+16, 384)))
    print(f"  {i:04x}: {hexstr:48s}  {ascstr}")

# Let's figure out the entry structure precisely
# Count distance between consecutive path starts
print("\nPath start offsets and lengths:")
path_search = b"DATA"
positions = []
start = 0
while len(positions) < 20:
    idx = raw.find(path_search, start)
    if idx == -1:
        break
    # Back up to find ".."
    while idx > 0 and raw[idx-1:idx] != b'\x01':
        idx -= 1
    if raw[idx] == 0x01:
        idx += 1  # skip flag byte
    # Find null terminator
    end = raw.find(b'\x00', idx)
    path = raw[idx:end].decode('ascii', errors='replace')
    if path.startswith('..'):
        positions.append((idx, end, path))
        print(f"  Path at {idx}, null at {end}, len={end-idx}: {path}")
    start = end + 1

# Calculate spacing between entries
print("\nEntry spacing:")
for i in range(1, len(positions)):
    prev_start = positions[i-1][0] - 1  # include flag byte
    curr_start = positions[i][0] - 1
    spacing = curr_start - prev_start
    # Metadata bytes between null of prev and flag of curr
    meta_bytes = curr_start - positions[i-1][1] - 1
    print(f"  Entry {i-1}->{i}: spacing={spacing}, metadata after null={meta_bytes}")

# Let's look for any structure in the metadata
# Read metadata after first entry
null0 = positions[0][1]
meta0 = raw[null0+1:positions[1][0]-1]
print(f"\nMetadata after entry 0 ({len(meta0)} bytes):")
print(f"  Hex: {meta0.hex()}")
# Try various interpretations
for word_size, fmt_char, label in [(2, 'H', 'uint16 LE'), (4, 'I', 'uint32 LE')]:
    vals = []
    for j in range(0, len(meta0) - word_size + 1, word_size):
        vals.append(struct.unpack_from(f'<{fmt_char}', meta0, j)[0])
    print(f"  As {label}: {vals}")

# Now let's look for FORM/IFF data right after the TOC
print(f"\nSearching for IFF/FORM data starting at TOC boundary ({toc_size}):")
for search_offset in range(toc_size - 16, toc_size + 32):
    if raw[search_offset:search_offset+4] == b'FORM':
        size = struct.unpack_from('>I', raw, search_offset+4)[0]
        subtype = raw[search_offset+8:search_offset+12].decode('ascii', errors='replace')
        print(f"  FORM at offset {search_offset} (rel to TRE start): size={size}, type={subtype}")
        break
    elif raw[search_offset:search_offset+4] in [b'CAT ', b'LIST']:
        tag = raw[search_offset:search_offset+4].decode('ascii')
        size = struct.unpack_from('>I', raw, search_offset+4)[0]
        subtype = raw[search_offset+8:search_offset+12].decode('ascii', errors='replace')
        print(f"  {tag} at offset {search_offset}: size={size}, type={subtype}")
        break

# Also let's see what's at the exact TOC boundary
boundary = raw[toc_size-8:toc_size+16]
print(f"\nBytes around TOC boundary (offset {toc_size}):")
print(f"  Before: {boundary[:8].hex()}")
print(f"  After:  {boundary[8:].hex()}")
try:
    print(f"  After ASCII: {boundary[8:].decode('ascii', errors='replace')}")
except:
    pass
