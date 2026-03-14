import struct

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048

def parse_tre_entries(data):
    """Parse all TRE file entries and their offsets/sizes."""
    count = struct.unpack_from('<I', data, 0)[0]
    toc_size = struct.unpack_from('<I', data, 4)[0]

    entries = []
    search = b"..\\..\\DATA"
    start = 0
    while True:
        idx = data.find(search, start)
        if idx == -1 or idx > toc_size:
            break
        end = data.find(b'\x00', idx)
        if end == -1:
            break
        path = data[idx:end].decode('ascii', errors='replace')
        entries.append((idx, end, path))
        start = end + 1
    return entries, count, toc_size

def read_iff_chunks(data, offset, max_depth=3, depth=0):
    """Recursively parse IFF chunks."""
    chunks = []
    pos = offset
    indent = "  " * depth
    while pos + 8 <= len(data):
        tag = data[pos:pos+4]
        if not all(32 <= b < 127 for b in tag):
            break
        tag_str = tag.decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]

        if tag_str in ('FORM', 'CAT ', 'LIST'):
            if pos + 12 <= len(data):
                subtype = data[pos+8:pos+12].decode('ascii', errors='replace')
                chunks.append((depth, tag_str, size, subtype))
                if depth < max_depth:
                    sub = read_iff_chunks(data, pos+12, max_depth, depth+1)
                    chunks.extend(sub)
        else:
            chunks.append((depth, tag_str, size, None))

        pos += 8 + size
        if size % 2 == 1:
            pos += 1  # IFF padding
    return chunks

with open(GAME_DAT, 'rb') as f:
    # Read TOC
    f.seek(TRE_LBA * SECTOR)
    toc_data = f.read(500000)
    entries, count, toc_size = parse_tre_entries(toc_data)

    # The actual file data starts after the TOC
    data_start = TRE_LBA * SECTOR + toc_size

    # Try to read the first IFF file to understand format
    # We need to figure out how file offsets are stored in the TOC
    # Let's look at the bytes between path entries more carefully
    print("Analyzing TOC entry format:")
    print(f"  Entry count: {count}")
    print(f"  TOC size: {toc_size}")
    print(f"  Data starts at absolute offset: {data_start}")

    # Each entry seems to be exactly toc_size/count bytes
    entry_size = toc_size // count if count > 0 else 0
    print(f"  Estimated entry size: {toc_size / count:.1f} bytes")

    # Let's look at the raw entry data more carefully
    # Entry 0 starts at offset 8 (after count + toc_size header)
    print("\nRaw entry analysis:")
    for i in range(3):
        entry_start = 8 + i * 104  # trying fixed-size entries
        raw = toc_data[entry_start:entry_start+104]

        # Find path in this entry
        path_start = raw.find(b'..')
        if path_start >= 0:
            path_end = raw.find(b'\x00', path_start)
            path = raw[path_start:path_end].decode('ascii')

            pre = raw[:path_start]
            post = raw[path_end+1:]

            print(f"\n  Entry {i}: {path}")
            print(f"    Pre-path ({len(pre)} bytes): {pre.hex()}")
            print(f"    Post-path ({len(post)} bytes): {post.hex()}")

            # The pre-path byte seems to be flags
            # Post-path has file metadata
            if len(post) >= 32:
                # Try different interpretations
                vals = []
                for j in range(0, min(len(post), 32), 4):
                    val = struct.unpack_from('<I', post, j)[0]
                    vals.append(val)
                print(f"    Post as LE uint32s: {vals}")

    # Now try to find where file data actually starts
    # Look for IFF FORM signature after the TOC
    print("\nSearching for IFF data after TOC...")
    f.seek(data_start)
    probe = f.read(256)
    for i in range(len(probe) - 4):
        if probe[i:i+4] == b'FORM':
            size = struct.unpack_from('>I', probe, i+4)[0]
            subtype = probe[i+8:i+12].decode('ascii', errors='replace')
            print(f"  Found FORM at data_start+{i}: size={size}, type={subtype}")

            # Read and parse this IFF file
            f.seek(data_start + i)
            iff_data = f.read(min(size + 8, 100000))
            chunks = read_iff_chunks(iff_data, 0, max_depth=2)
            print(f"  IFF structure:")
            for depth, tag, sz, sub in chunks:
                prefix = "    " + "  " * depth
                if sub:
                    print(f"{prefix}{tag} ({sz} bytes) -> {sub}")
                else:
                    print(f"{prefix}{tag} ({sz} bytes)")
            break
