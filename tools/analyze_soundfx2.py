"""Deep analysis of SOUNDFX.PAK inner PAK structure."""
import struct

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
TRE_START = TRE_LBA * SECTOR
TOC_SIZE = 86688

def get_entries(toc):
    entries = []
    count = struct.unpack_from('<I', toc, 0)[0]
    for i in range(count):
        entry_start = 8 + i * 74
        if entry_start + 74 > len(toc):
            break
        null_pos = toc.find(b'\x00', entry_start + 1)
        if null_pos == -1 or null_pos >= entry_start + 74:
            continue
        path = toc[entry_start+1:null_pos].decode('ascii', errors='replace')
        file_offset = struct.unpack_from('<I', toc, entry_start + 66)[0]
        file_size = struct.unpack_from('<I', toc, entry_start + 70)[0]
        entries.append({
            'index': i, 'path': path,
            'offset': file_offset, 'size': file_size,
            'abs_pos': TRE_START + file_offset,
        })
    return entries

def read_offset3(data, pos):
    return data[pos] | (data[pos+1] << 8) | (data[pos+2] << 16)

def parse_pak_flat(data):
    """Parse PAK offset table, return list of data offsets."""
    offsets = []
    file_size = struct.unpack_from('<I', data, 0)[0]
    pos = 4
    min_offset = len(data)
    while pos + 4 <= len(data) and pos < min_offset:
        offset = read_offset3(data, pos)
        marker = data[pos + 3]
        if marker == 0x00:
            break
        pos += 4
        if marker == 0xE0:
            if offset < min_offset:
                min_offset = offset
            offsets.append(offset)
        elif marker == 0xC1:
            if offset < min_offset:
                min_offset = offset
            # Parse sub-table
            sub_pos = offset
            sub_min = len(data)
            while sub_pos + 4 <= len(data) and sub_pos < sub_min:
                sub_off = read_offset3(data, sub_pos)
                sub_marker = data[sub_pos + 3]
                if sub_marker == 0x00:
                    break
                sub_pos += 4
                if sub_marker == 0xE0:
                    if sub_off < sub_min:
                        sub_min = sub_off
                    offsets.append(sub_off)
                elif sub_marker == 0xFF:
                    pass
                else:
                    break
        elif marker == 0xFF:
            pass
        else:
            break
    return offsets, file_size

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)
    entries = get_entries(toc)

    sfx_entry = [e for e in entries if 'SOUNDFX.PAK' in e['path'].upper()][0]
    f.seek(sfx_entry['abs_pos'])
    sfx_data = f.read(sfx_entry['size'])

    # The outer PAK wraps an inner PAK at offset 8
    # Let's parse the inner PAK directly
    inner_data = sfx_data[8:]  # Skip outer PAK header (file_size + 1 E0 entry)
    print(f"=== SOUNDFX.PAK Inner PAK ({len(inner_data)} bytes) ===\n")

    inner_offsets, inner_file_size = parse_pak_flat(inner_data)
    print(f"Inner file_size header: {inner_file_size}")
    print(f"Inner data resources: {len(inner_offsets)}")

    # Sort and compute sizes
    sorted_offs = sorted(set(inner_offsets))
    resources = []
    for i, off in enumerate(sorted_offs):
        next_off = sorted_offs[i + 1] if i + 1 < len(sorted_offs) else len(inner_data)
        resources.append((off, next_off - off))

    print(f"\nAll {len(resources)} resources:")
    for i, (off, size) in enumerate(resources):
        header = inner_data[off:off+min(26, size)]
        # Check for Creative Voice File header
        is_voc = len(header) >= 19 and header[:19] == b'Creative Voice File'
        # Check first bytes for patterns
        hex_str = ' '.join(f'{b:02x}' for b in header[:min(20, len(header))])
        fmt = 'VOC' if is_voc else 'RAW'
        print(f"  [{i:3d}] offset={off:6d} size={size:6d} fmt={fmt}  {hex_str}")

    # Actually, let's try parsing the WHOLE sfx_data with the proper PAK parser
    # treating it as a regular PAK (possibly with C1 sub-tables)
    print(f"\n=== Parsing entire SOUNDFX.PAK as standard PAK ===")
    all_offsets, file_size = parse_pak_flat(sfx_data)
    print(f"File size: {file_size}")
    print(f"Total offsets: {len(all_offsets)}")
    if all_offsets:
        sorted_all = sorted(set(all_offsets))
        all_resources = []
        for i, off in enumerate(sorted_all):
            next_off = sorted_all[i + 1] if i + 1 < len(sorted_all) else len(sfx_data)
            all_resources.append((off, next_off - off))
        print(f"All resources from standard parse:")
        for i, (off, size) in enumerate(all_resources[:10]):
            header = sfx_data[off:off+min(20, size)]
            hex_str = ' '.join(f'{b:02x}' for b in header)
            print(f"  [{i:3d}] offset={off:6d} size={size:6d}  {hex_str}")

    # Let me also try: maybe the entire file IS a single-level PAK
    # where offset 8 is a C1 subtable base, not E0 data
    # Let me manually check what's at the inner offsets relative to the full file
    print(f"\n=== Resources relative to full file (inner_offset + 8) ===")
    for i, (off, size) in enumerate(resources[:5]):
        abs_off = off + 8  # Relative to full file
        header = sfx_data[abs_off:abs_off+min(26, size)]
        is_voc = len(header) >= 19 and header[:19] == b'Creative Voice File'
        hex_str = ' '.join(f'{b:02x}' for b in header[:min(20, len(header))])
        fmt = 'VOC' if is_voc else 'RAW'
        print(f"  [{i:3d}] abs_offset={abs_off:6d} size={size:6d} fmt={fmt}  {hex_str}")

    # Summary statistics
    sizes = [s for _, s in resources]
    if sizes:
        print(f"\n=== Resource Size Statistics ===")
        print(f"Count: {len(sizes)}")
        print(f"Min size: {min(sizes)}")
        print(f"Max size: {max(sizes)}")
        print(f"Avg size: {sum(sizes) / len(sizes):.0f}")
        print(f"Total: {sum(sizes)}")
