"""Analyze cockpit IFF and PAK files from PRIV.TRE to understand their structure."""
import struct

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
ENTRY_SIZE = 74

def load_tre(f):
    """Load TRE index. Entries are 74 bytes: 1 flag + 65 path + 4 offset + 4 size."""
    f.seek(TRE_LBA * SECTOR)
    count = struct.unpack('<I', f.read(4))[0]
    toc_size = struct.unpack('<I', f.read(4))[0]

    entries = []
    for i in range(count):
        entry_start = TRE_LBA * SECTOR + 8 + i * ENTRY_SIZE
        f.seek(entry_start)
        raw = f.read(ENTRY_SIZE)
        flag = raw[0]
        path_bytes = raw[1:66]
        null = path_bytes.find(b'\x00')
        if null >= 0:
            path = path_bytes[:null].decode('ascii', errors='replace')
        else:
            path = path_bytes.decode('ascii', errors='replace')
        offset = struct.unpack_from('<I', raw, 66)[0]
        size = struct.unpack_from('<I', raw, 70)[0]
        entries.append((path, offset, size))
    return entries, toc_size

def read_file_data(f, offset, size):
    """Read file data from TRE. Offset is absolute within PRIV.TRE."""
    abs_offset = TRE_LBA * SECTOR + offset
    f.seek(abs_offset)
    return f.read(size)

def parse_iff_chunks(data, offset=0, max_depth=5, depth=0):
    """Recursively parse IFF chunks."""
    chunks = []
    pos = offset
    while pos + 8 <= len(data):
        tag = data[pos:pos+4]
        if not all(32 <= b < 127 for b in tag):
            break
        tag_str = tag.decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]
        if pos + 8 + size > len(data):
            break
        if tag_str in ('FORM', 'CAT ', 'LIST'):
            if size >= 4:
                subtype = data[pos+8:pos+12].decode('ascii', errors='replace')
                chunks.append((depth, tag_str, size, subtype, pos+8))
                if depth < max_depth:
                    sub = parse_iff_chunks(data, pos+12, max_depth, depth+1)
                    chunks.extend(sub)
        else:
            chunks.append((depth, tag_str, size, None, pos+8))
        pos += 8 + size
        if size % 2 == 1:
            pos += 1
    return chunks

def parse_pak(data):
    """Parse PAK offset tables."""
    if len(data) < 8:
        return [], 0
    file_size = struct.unpack_from('<I', data, 0)[0]
    entries = []
    pos = 4
    min_off = len(data)
    while pos + 4 <= len(data) and pos < min_off:
        off_bytes = data[pos:pos+3]
        marker = data[pos+3]
        offset = off_bytes[0] | (off_bytes[1] << 8) | (off_bytes[2] << 16)
        if marker == 0x00:
            break
        if marker in (0xE0, 0xC1):
            if offset < min_off:
                min_off = offset
            entries.append((offset, marker))
        elif marker == 0xFF:
            pass
        else:
            break
        pos += 4
    return entries, file_size

def hex_dump(data, max_bytes=64):
    """Hex dump first N bytes."""
    for i in range(0, min(len(data), max_bytes), 16):
        hex_str = ' '.join(f'{b:02X}' for b in data[i:i+16])
        ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[i:i+16])
        print(f'    {i:04X}: {hex_str:<48s}  {ascii_str}')

def analyze_cockpit_pak_resource(data, off, end_off):
    """Analyze a single PAK resource at the given offset."""
    res_data = data[off:end_off]
    if len(res_data) < 4:
        return

    # Check if it looks like a scene pack (offset table pointing to sprites)
    decl_size = struct.unpack_from('<I', res_data, 0)[0]
    if len(res_data) >= 8:
        first_off = struct.unpack_from('<I', res_data, 4)[0]
        # If first_off is reasonable and points within the resource
        if 8 <= first_off < len(res_data):
            num_sprites = (first_off - 4) // 4
            print(f"         Looks like scene pack: decl_size={decl_size}, sprites={num_sprites}")
            for si in range(min(num_sprites, 8)):
                soff = struct.unpack_from('<I', res_data, 4 + si * 4)[0]
                if soff + 8 <= len(res_data):
                    # Read sprite header
                    x2 = struct.unpack_from('<H', res_data, soff)[0]
                    x1 = struct.unpack_from('<H', res_data, soff+2)[0]
                    y1 = struct.unpack_from('<H', res_data, soff+4)[0]
                    y2 = struct.unpack_from('<H', res_data, soff+6)[0]
                    w = x1 + x2
                    h = y1 + y2
                    print(f"           sprite[{si}] @ {soff}: x2={x2} x1={x1} y1={y1} y2={y2} ({w}x{h})")
            return

    # Check if it's a palette (772 bytes = 4 header + 768 RGB)
    if len(res_data) == 772:
        print(f"         Looks like palette (772 bytes)")
        return

    # Check if first 4 bytes are IFF tag
    tag = res_data[:4]
    if all(32 <= b < 127 for b in tag):
        print(f"         Starts with IFF tag: {tag.decode('ascii')}")
        chunks = parse_iff_chunks(res_data)
        for depth, tag_c, size_c, subtype, data_offset in chunks:
            indent = "           " + "  " * depth
            if subtype:
                print(f"{indent}{tag_c}:{subtype} (size={size_c})")
            else:
                print(f"{indent}{tag_c} (size={size_c})")
        return

    # Unknown format
    print(f"         Unknown format, first 32 bytes:")
    hex_dump(res_data[:32], 32)

def main():
    with open(GAME_DAT, 'rb') as f:
        entries, toc_size = load_tre(f)

        # Find all COCKPIT files
        print("=== Files in COCKPITS directory ===")
        cockpit_entries = []
        for path, offset, size in entries:
            if 'COCKPIT' in path.upper():
                print(f"  {path} (offset={offset}, size={size})")
                cockpit_entries.append((path, offset, size))

        # Also find ITTS, WEAPONS, etc under COCKPITS if not found above
        for path, offset, size in entries:
            short = path.replace('..\\..\\DATA\\', '')
            if short.upper().startswith('COCKPITS\\'):
                found = any(p == path for p, _, _ in cockpit_entries)
                if not found:
                    print(f"  {path} (offset={offset}, size={size})")
                    cockpit_entries.append((path, offset, size))

        print(f"\nTotal cockpit files: {len(cockpit_entries)}")

        # Analyze each file
        for path, offset, size in cockpit_entries:
            data = read_file_data(f, offset, size)
            print(f"\n{'='*70}")
            print(f"=== {path} ({size} bytes) ===")
            print(f"{'='*70}")

            if path.upper().endswith('.PAK'):
                pak_entries, file_size = parse_pak(data)
                print(f"  PAK file_size: {file_size}")
                print(f"  PAK L1 entries: {len(pak_entries)}")

                # Compute sizes
                all_offsets = sorted(set(off for off, _ in pak_entries))

                for i, (off, marker) in enumerate(pak_entries):
                    marker_name = {0xE0: 'DATA', 0xC1: 'SUBTABLE'}.get(marker, f'0x{marker:02X}')
                    # Find end offset
                    next_offs = [o for o in all_offsets if o > off]
                    end_off = next_offs[0] if next_offs else len(data)
                    res_size = end_off - off
                    print(f"    [{i}] offset={off} size={res_size} marker={marker_name}")

                    if marker == 0xE0:
                        analyze_cockpit_pak_resource(data, off, end_off)
                    elif marker == 0xC1 and off < len(data):
                        # Parse subtable
                        sub_pos = off
                        sub_entries = []
                        sub_min_off = len(data)
                        for j in range(32):
                            if sub_pos + 4 > len(data) or sub_pos >= sub_min_off:
                                break
                            sub_off = data[sub_pos] | (data[sub_pos+1] << 8) | (data[sub_pos+2] << 16)
                            sub_marker = data[sub_pos+3]
                            if sub_marker == 0x00:
                                break
                            if sub_marker == 0xE0:
                                if sub_off < sub_min_off:
                                    sub_min_off = sub_off
                                sub_entries.append((sub_off, sub_marker))
                            sub_pos += 4

                        print(f"         Subtable has {len(sub_entries)} data entries")
                        sub_all_offs = sorted(set(o for o, _ in sub_entries))
                        for j, (sub_off, sub_mk) in enumerate(sub_entries[:4]):
                            next_sub = [o for o in sub_all_offs if o > sub_off]
                            sub_end = next_sub[0] if next_sub else end_off
                            sub_size = sub_end - sub_off
                            print(f"           [{j}] offset={sub_off} size={sub_size}")
                            analyze_cockpit_pak_resource(data, sub_off, sub_end)
                        if len(sub_entries) > 4:
                            print(f"           ... and {len(sub_entries)-4} more")

            else:
                # IFF file
                chunks = parse_iff_chunks(data)
                if not chunks:
                    print("  No IFF chunks found. Raw hex:")
                    hex_dump(data, 128)
                else:
                    for depth, tag, size_c, subtype, data_offset in chunks:
                        indent = "  " * (depth + 1)
                        if subtype:
                            print(f"{indent}{tag}:{subtype} (size={size_c})")
                        else:
                            print(f"{indent}{tag} (size={size_c}) @ offset {data_offset}")
                            # Show data for small chunks
                            if size_c <= 64:
                                chunk_data = data[data_offset:data_offset+size_c]
                                hex_dump(chunk_data)

if __name__ == '__main__':
    main()
