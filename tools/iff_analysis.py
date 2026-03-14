import struct
import sys
from collections import defaultdict

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
TRE_START = TRE_LBA * SECTOR
TOC_SIZE = 86688

def parse_iff(data, offset=0, max_depth=4, depth=0, max_pos=None):
    """Recursively parse IFF chunks."""
    chunks = []
    pos = offset
    if max_pos is None:
        max_pos = len(data)
    while pos + 8 <= max_pos:
        tag = data[pos:pos+4]
        if not all(32 <= b < 127 for b in tag):
            break
        tag_str = tag.decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]
        if size > max_pos - pos:
            break

        if tag_str in ('FORM', 'CAT ', 'LIST'):
            if pos + 12 <= max_pos:
                subtype = data[pos+8:pos+12].decode('ascii', errors='replace')
                chunks.append((depth, tag_str, size, subtype, pos - offset))
                if depth < max_depth:
                    sub = parse_iff(data, pos+12, max_depth, depth+1, pos+8+size)
                    chunks.extend(sub)
        else:
            chunks.append((depth, tag_str, size, None, pos - offset))

        pos += 8 + size
        if size % 2 == 1:
            pos += 1  # IFF padding
    return chunks

with open(GAME_DAT, 'rb') as f:
    # Read TOC
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)

    # Parse all 832 entries
    all_entries = []
    for i in range(832):
        entry_start = 8 + i * 74
        if entry_start + 74 > len(toc):
            break
        flag = toc[entry_start]
        null_pos = toc.find(b'\x00', entry_start + 1)
        if null_pos == -1 or null_pos >= entry_start + 74:
            continue
        path = toc[entry_start+1:null_pos].decode('ascii', errors='replace')
        # Offset and size are last 8 bytes
        file_offset = struct.unpack_from('<I', toc, entry_start + 66)[0]
        file_size = struct.unpack_from('<I', toc, entry_start + 70)[0]
        all_entries.append({
            'index': i,
            'path': path,
            'offset': file_offset,
            'size': file_size,
            'abs_pos': TRE_START + file_offset,
        })

    print(f"Parsed {len(all_entries)} TRE entries")
    print(f"TRE data range: {all_entries[0]['offset']} - {all_entries[-1]['offset'] + all_entries[-1]['size']}")

    # Verify first 10 entries are valid IFF
    print("\n=== IFF File Verification (first 10 entries) ===")
    for e in all_entries[:10]:
        f.seek(e['abs_pos'])
        header = f.read(min(16, e['size']))
        tag = header[:4].decode('ascii', errors='replace') if len(header) >= 4 else '???'
        if len(header) >= 8:
            iff_size = struct.unpack_from('>I', header, 4)[0]
        else:
            iff_size = 0
        subtype = header[8:12].decode('ascii', errors='replace') if len(header) >= 12 else '???'
        print(f"  [{e['index']:3d}] {e['path']:45s} offset={e['offset']:8d} size={e['size']:8d} -> {tag}({iff_size}) {subtype}")

    # Analyze several representative IFF files in detail
    sample_files = [
        ('AIDS/ATTITUDE.IFF', 0),
        ('SECTORS/QUADRANT.IFF', None),
        ('TYPES/WEAPONS.IFF', None),
        ('OPTIONS/FILES.IFF', None),
        ('APPEARNC/GALAXY.IFF', None),
        ('COCKPITS/COCKMISC.IFF', None),
    ]

    for sample_name, sample_idx in sample_files:
        if sample_idx is None:
            # Find by name
            for e in all_entries:
                if sample_name.replace('/', '\\') in e['path']:
                    sample_idx = e['index']
                    break
        if sample_idx is None:
            continue

        e = all_entries[sample_idx]
        f.seek(e['abs_pos'])
        file_data = f.read(e['size'])

        print(f"\n=== {e['path']} (size={e['size']}) ===")
        chunks = parse_iff(file_data, 0, max_depth=3)
        for depth, tag, size, subtype, rel_pos in chunks:
            indent = "  " * (depth + 1)
            if subtype:
                print(f"{indent}{tag} [{subtype}] ({size} bytes) @ {rel_pos}")
            else:
                # Show preview of data for leaf chunks
                preview_start = rel_pos + 8
                preview = file_data[preview_start:preview_start+min(24, size)]
                ascii_preview = ''.join(chr(b) if 32 <= b < 127 else '.' for b in preview)
                print(f"{indent}{tag} ({size} bytes) @ {rel_pos}: {preview.hex()[:48]} '{ascii_preview}'")

    # Collect unique chunk types across all files
    print("\n=== Unique IFF Chunk Types Across All Files ===")
    all_chunk_types = defaultdict(int)
    form_types = defaultdict(int)
    for e in all_entries:
        if e['size'] < 12:
            continue
        f.seek(e['abs_pos'])
        file_data = f.read(min(e['size'], 50000))
        try:
            chunks = parse_iff(file_data, 0, max_depth=2)
            for depth, tag, size, subtype, rel_pos in chunks:
                if subtype:
                    form_types[f"{tag}:{subtype}"] += 1
                else:
                    all_chunk_types[tag] += 1
        except:
            pass

    print("\nFORM/CAT types:")
    for key, cnt in sorted(form_types.items(), key=lambda x: -x[1]):
        print(f"  {key:20s}: {cnt}")

    print("\nChunk types:")
    for key, cnt in sorted(all_chunk_types.items(), key=lambda x: -x[1]):
        print(f"  {key:8s}: {cnt}")
