"""Analyze SOUNDFX.PAK from PRIV.TRE.

Examines the PAK structure and identifies the format of sound resources inside.
"""
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

def parse_pak_entries(data):
    """Parse PAK offset table, return list of (offset, marker) tuples."""
    entries = []
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
            entries.append((offset, marker))
        elif marker == 0xC1:
            if offset < min_offset:
                min_offset = offset
            entries.append((offset, marker))
        elif marker == 0xFF:
            pass  # skip
        else:
            break
    return entries, file_size

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)
    entries = get_entries(toc)

    sfx_entry = [e for e in entries if 'SOUNDFX.PAK' in e['path'].upper()][0]
    print(f"=== SOUNDFX.PAK Analysis ({sfx_entry['size']} bytes) ===\n")

    f.seek(sfx_entry['abs_pos'])
    sfx_data = f.read(sfx_entry['size'])

    pak_entries, file_size = parse_pak_entries(sfx_data)
    print(f"File size header: {file_size}")
    print(f"L1 entries: {len(pak_entries)}")

    # For each entry, check if it's a sub-table (C1) or direct data (E0)
    all_data_offsets = []
    for i, (offset, marker) in enumerate(pak_entries):
        marker_name = {0xE0: 'DATA', 0xC1: 'SUBTABLE'}.get(marker, f'0x{marker:02x}')
        if marker == 0xC1:
            # Parse sub-table
            sub_entries = []
            sub_pos = offset
            sub_min = len(sfx_data)
            while sub_pos + 4 <= len(sfx_data) and sub_pos < sub_min:
                sub_offset = read_offset3(sfx_data, sub_pos)
                sub_marker = sfx_data[sub_pos + 3]
                if sub_marker == 0x00:
                    break
                sub_pos += 4
                if sub_marker == 0xE0:
                    if sub_offset < sub_min:
                        sub_min = sub_offset
                    sub_entries.append(sub_offset)
                elif sub_marker == 0xFF:
                    pass
                else:
                    break
            if sub_entries:
                print(f"  [{i:3d}] {marker_name} @ {offset:6d} → {len(sub_entries)} sub-entries")
                all_data_offsets.extend(sub_entries)
            else:
                print(f"  [{i:3d}] {marker_name} @ {offset:6d} (empty sub-table, treating as data)")
                all_data_offsets.append(offset)
        else:
            print(f"  [{i:3d}] {marker_name} @ {offset:6d}")
            all_data_offsets.append(offset)

    print(f"\nTotal data resources: {len(all_data_offsets)}")

    # Sort offsets and compute sizes
    sorted_offsets = sorted(set(all_data_offsets))
    resources = []
    for i, off in enumerate(sorted_offsets):
        next_off = sorted_offsets[i + 1] if i + 1 < len(sorted_offsets) else len(sfx_data)
        size = next_off - off
        resources.append((off, size))

    print(f"\nFirst 20 resources:")
    for i, (off, size) in enumerate(resources[:20]):
        header = sfx_data[off:off+min(26, size)]
        # Check for VOC header
        is_voc = header[:19] == b'Creative Voice File'
        # Check for IFF FORM
        is_iff = header[:4] == b'FORM'
        fmt = 'VOC' if is_voc else ('IFF' if is_iff else 'RAW')
        hex_str = ' '.join(f'{b:02x}' for b in header[:16])
        print(f"  [{i:3d}] offset={off:6d} size={size:6d} format={fmt} header={hex_str}")

    print(f"\nLast 5 resources:")
    for i in range(max(0, len(resources)-5), len(resources)):
        off, size = resources[i]
        header = sfx_data[off:off+min(26, size)]
        is_voc = header[:19] == b'Creative Voice File'
        is_iff = header[:4] == b'FORM'
        fmt = 'VOC' if is_voc else ('IFF' if is_iff else 'RAW')
        hex_str = ' '.join(f'{b:02x}' for b in header[:16])
        print(f"  [{i:3d}] offset={off:6d} size={size:6d} format={fmt} header={hex_str}")

    # Check if resource 0 is a palette (772 bytes)
    if resources:
        off0, size0 = resources[0]
        print(f"\nResource 0: offset={off0}, size={size0}")
        if size0 == 772:
            print("  -> Looks like a PAL palette (772 bytes)")
        else:
            print(f"  -> Not a palette (expected 772, got {size0})")

    # Analyze COMBAT.DAT more carefully
    combat_entry = [e for e in entries if 'COMBAT.DAT' in e['path'].upper()][0]
    f.seek(combat_entry['abs_pos'])
    combat_data = f.read(combat_entry['size'])

    print(f"\n=== COMBAT.DAT Deep Analysis ===")
    # It starts like a PAK: file_size=1896, then entry at offset 8 marker E0
    # The data at offset 8 is 1888 bytes
    # Let's see if the data at offset 8 is structured as byte arrays

    data_start = 8
    content = combat_data[data_start:]

    # First few bytes look like they could be offsets into the content
    print(f"\nData region: {len(content)} bytes (offsets 8-{len(combat_data)})")

    # The first 6 bytes of data: 09 2a 09 4a 0d 3f
    # These could be 6 little-endian u16 values: 0x2a09, 0x4a09, 0x3f0d, ...
    # Or they could be byte-level data
    # Or offsets into the data region

    # Try interpreting first N bytes as table offsets
    print("\nTrying: first bytes as sub-region offsets within data:")
    for i in range(0, 20):
        val = content[i]
        print(f"  content[{i}] = {val:3d} (0x{val:02x})")

    # Maybe the structure is:
    # [count or header bytes] [groups of sound indices separated by 0xFF]
    print("\nLooking for 0xFF separators in first 128 bytes:")
    groups = []
    current = []
    for i, b in enumerate(content[:128]):
        if b == 0xFF:
            if current:
                groups.append(current)
            current = []
        else:
            current.append((i, b))
    if current:
        groups.append(current)

    for gi, group in enumerate(groups):
        vals = [f"{v}" for _, v in group]
        offsets = [f"{o}" for o, _ in group]
        print(f"  Group {gi}: values=[{', '.join(vals)}] at content offsets [{', '.join(offsets)}]")

    # Maybe COMBAT.DAT isn't a PAK at all - maybe it's a raw data file
    # where the first 4 bytes happen to be the file size
    print(f"\n\nAlternative: treating COMBAT.DAT as raw data (not PAK):")
    # Try as array of fixed-size records
    for record_size in [2, 3, 4, 6, 8, 12]:
        num_records = len(combat_data) / record_size
        if num_records == int(num_records):
            print(f"  {record_size}-byte records: {int(num_records)} entries")
