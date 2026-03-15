"""Deep analysis of plot mission IFF files from PRIV.TRE.

Analyzes MISSIONS/*.IFF files to reverse-engineer the binary format of
SCRP, PROG, FLAG, CAST, PART, PLAY, LOAD, CARG, TEXT, and PAYS chunks.
"""
import struct
import sys

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
TRE_START = TRE_LBA * SECTOR
TOC_SIZE = 86688


def get_all_tre_entries(toc):
    entries = []
    for i in range(832):
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
            'index': i,
            'path': path,
            'offset': file_offset,
            'size': file_size,
            'abs_pos': TRE_START + file_offset,
        })
    return entries


def find_entry(entries, fragment):
    for e in entries:
        if fragment.upper() in e['path'].upper():
            return e
    return None


def find_all_entries(entries, fragment):
    return [e for e in entries if fragment.upper() in e['path'].upper()]


def hex_dump(data, max_bytes=256):
    lines = []
    for i in range(0, min(len(data), max_bytes), 16):
        row = data[i:i+16]
        hex_part = ' '.join(f'{b:02x}' for b in row)
        ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in row)
        lines.append(f'  {i:04x}: {hex_part:<48s} {ascii_part}')
    if len(data) > max_bytes:
        lines.append(f'  ... ({len(data)} bytes total)')
    return '\n'.join(lines)


def parse_chunks_flat(data, start, end, depth=0):
    """Recursively parse IFF chunks and return flat list with depth info."""
    results = []
    pos = start
    while pos + 8 <= end:
        tag = data[pos:pos+4]
        if not all(32 <= b < 127 for b in tag):
            break
        tag_str = tag.decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]

        if tag_str in ('FORM', 'CAT ', 'LIST'):
            sub_type = data[pos+8:pos+12].decode('ascii', errors='replace')
            results.append({
                'tag': tag_str, 'sub_type': sub_type, 'size': size,
                'offset': pos, 'depth': depth, 'is_container': True,
            })
            results.extend(parse_chunks_flat(data, pos + 12, pos + 8 + size, depth + 1))
        else:
            cdata = data[pos+8:pos+8+size]
            results.append({
                'tag': tag_str, 'size': size, 'offset': pos, 'depth': depth,
                'is_container': False, 'data': cdata,
            })

        pos += 8 + size
        if size % 2 == 1:
            pos += 1
    return results


def analyze_mission_file(f, entry, verbose=True):
    """Analyze a single mission IFF file."""
    f.seek(entry['abs_pos'])
    data = f.read(entry['size'])
    fname = entry['path'].split('\\')[-1]

    print(f"\n{'='*70}")
    print(f"=== {fname} ({entry['size']} bytes) ===")
    print(f"{'='*70}")

    chunks = parse_chunks_flat(data, 0, len(data))

    # Print structure overview
    for c in chunks:
        indent = '  ' * c['depth']
        if c['is_container']:
            print(f"{indent}{c['tag']}:{c['sub_type']} ({c['size']} bytes)")
        else:
            print(f"{indent}{c['tag']} ({c['size']} bytes)")

    # Detailed analysis of each leaf chunk
    if verbose:
        print(f"\n--- Detailed chunk analysis ---")
        for c in chunks:
            if c['is_container']:
                continue
            indent = '  ' * c['depth']
            tag = c['tag']
            cdata = c['data']
            size = c['size']
            print(f"\n{indent}{tag} ({size} bytes) @ offset {c['offset']}:")

            if tag == 'TEXT':
                # Null-terminated text
                text = cdata.split(b'\x00')[0].decode('ascii', errors='replace')
                print(f"{indent}  Text: {text!r}")
                if len(cdata) > len(text) + 1:
                    print(f"{indent}  Remaining: {hex_dump(cdata[len(text)+1:], 64)}")

            elif tag == 'PAYS':
                if size >= 8:
                    min_r = struct.unpack_from('<i', cdata, 0)[0]
                    max_r = struct.unpack_from('<i', cdata, 4)[0]
                    print(f"{indent}  Min reward: {min_r}, Max reward: {max_r}")
                if size > 8:
                    print(f"{indent}  Extra data: {hex_dump(cdata[8:], 64)}")

            elif tag == 'INFO':
                print(f"{indent}  Raw: {hex_dump(cdata, 64)}")
                if size >= 1:
                    print(f"{indent}  Byte values: {[b for b in cdata[:min(size, 32)]]}")
                if size >= 2:
                    print(f"{indent}  u16 LE[0]: {struct.unpack_from('<H', cdata, 0)[0]}")
                if size >= 4:
                    print(f"{indent}  u32 LE[0]: {struct.unpack_from('<I', cdata, 0)[0]}")

            elif tag == 'SCRP':
                print(f"{indent}  Script data ({size} bytes):")
                print(hex_dump(cdata, 512))
                # Try to identify opcodes / structure
                analyze_scrp(cdata, indent + '  ')

            elif tag == 'PROG':
                print(f"{indent}  Program data ({size} bytes):")
                print(hex_dump(cdata, 512))
                analyze_prog(cdata, indent + '  ')

            elif tag == 'FLAG':
                print(f"{indent}  Flag data ({size} bytes):")
                print(hex_dump(cdata, 256))
                analyze_flag(cdata, indent + '  ')

            elif tag == 'CAST':
                print(f"{indent}  Cast data ({size} bytes):")
                print(hex_dump(cdata, 256))
                analyze_cast(cdata, indent + '  ')

            elif tag == 'PART':
                print(f"{indent}  Participant data ({size} bytes):")
                print(hex_dump(cdata, 256))

            elif tag == 'PLAY':
                print(f"{indent}  Player objectives ({size} bytes):")
                print(hex_dump(cdata, 256))

            elif tag == 'LOAD':
                print(f"{indent}  Load data ({size} bytes):")
                print(hex_dump(cdata, 256))

            elif tag == 'CARG':
                print(f"{indent}  Cargo data ({size} bytes):")
                print(hex_dump(cdata, 256))

            else:
                print(hex_dump(cdata, 128))

    return chunks


def analyze_scrp(data, prefix=''):
    """Try to identify script command structure."""
    if len(data) < 2:
        print(f"{prefix}Too short for script data")
        return

    # Check for common patterns
    # Look for repeating byte patterns that could be opcodes
    byte_freq = {}
    for b in data:
        byte_freq[b] = byte_freq.get(b, 0) + 1

    print(f"{prefix}Byte frequency (top 10):")
    for b, count in sorted(byte_freq.items(), key=lambda x: -x[1])[:10]:
        print(f"{prefix}  0x{b:02x} ({b:3d}): {count} times")

    # Look for u16 pairs that might be opcode+operand
    if len(data) >= 4:
        print(f"{prefix}First 16 u16 LE values: ", end='')
        vals = []
        for i in range(0, min(len(data), 32), 2):
            if i + 2 <= len(data):
                vals.append(struct.unpack_from('<H', data, i)[0])
        print(vals)

    # Look for null-terminated strings embedded
    strings = []
    i = 0
    while i < len(data):
        if 32 <= data[i] < 127:
            start = i
            while i < len(data) and 32 <= data[i] < 127:
                i += 1
            if i - start >= 3:
                s = data[start:i].decode('ascii')
                strings.append((start, s))
        i += 1
    if strings:
        print(f"{prefix}Embedded strings:")
        for off, s in strings:
            print(f"{prefix}  @{off}: {s!r}")


def analyze_prog(data, prefix=''):
    """Analyze PROG chunk structure."""
    if len(data) < 2:
        return
    # Try reading as array of u16 LE
    if len(data) >= 4:
        print(f"{prefix}First 16 u16 LE values: ", end='')
        vals = []
        for i in range(0, min(len(data), 32), 2):
            if i + 2 <= len(data):
                vals.append(struct.unpack_from('<H', data, i)[0])
        print(vals)

    # Try reading as array of u32 LE
    if len(data) >= 4:
        print(f"{prefix}First 8 u32 LE values: ", end='')
        vals = []
        for i in range(0, min(len(data), 32), 4):
            if i + 4 <= len(data):
                vals.append(struct.unpack_from('<I', data, i)[0])
        print(vals)


def analyze_flag(data, prefix=''):
    """Analyze FLAG chunk - likely boolean flags."""
    if len(data) == 0:
        return
    # Show as individual bytes (likely boolean flags)
    print(f"{prefix}Flags as bytes: {[b for b in data]}")
    # Show non-zero flags
    nonzero = [(i, b) for i, b in enumerate(data) if b != 0]
    if nonzero:
        print(f"{prefix}Non-zero flags: {nonzero}")
    else:
        print(f"{prefix}All flags are zero (initial state)")


def analyze_cast(data, prefix=''):
    """Analyze CAST chunk - character/NPC list."""
    if len(data) == 0:
        return
    # Try reading as array of u16 LE (NPC indices?)
    if len(data) >= 2 and len(data) % 2 == 0:
        vals = []
        for i in range(0, len(data), 2):
            vals.append(struct.unpack_from('<H', data, i)[0])
        print(f"{prefix}As u16 LE array: {vals}")
    # Try as byte array
    print(f"{prefix}As byte array: {[b for b in data]}")


def main():
    with open(GAME_DAT, 'rb') as f:
        f.seek(TRE_START)
        toc = f.read(TOC_SIZE)
        entries = get_all_tre_entries(toc)

        # Find all mission files
        mission_entries = find_all_entries(entries, 'MISSIONS\\')
        print(f"Found {len(mission_entries)} mission files:")
        for e in mission_entries:
            fname = e['path'].split('\\')[-1]
            print(f"  {fname:20s} ({e['size']:6d} bytes)")

        print("\n" + "="*70)
        print("ANALYZING ALL MISSION FILES")
        print("="*70)

        # Collect chunk size statistics across all files
        chunk_stats = {}  # tag -> list of sizes

        # Analyze key files in detail
        detail_files = ['S0MA.IFF', 'S1MA.IFF', 'S1MB.IFF', 'S9MA.IFF',
                        'PLOTMSNS.IFF', 'SKELETON.IFF', 'BFILMNGR.IFF']

        for e in mission_entries:
            fname = e['path'].split('\\')[-1]
            verbose = any(fname == df for df in detail_files)
            chunks = analyze_mission_file(f, e, verbose=verbose)
            for c in chunks:
                if not c['is_container']:
                    tag = c['tag']
                    if tag not in chunk_stats:
                        chunk_stats[tag] = []
                    chunk_stats[tag].append(c['size'])

        # Summary statistics
        print("\n" + "="*70)
        print("CHUNK SIZE STATISTICS ACROSS ALL MISSION FILES")
        print("="*70)
        for tag in sorted(chunk_stats.keys()):
            sizes = chunk_stats[tag]
            print(f"  {tag}: count={len(sizes)}, "
                  f"min={min(sizes)}, max={max(sizes)}, "
                  f"avg={sum(sizes)/len(sizes):.1f}, "
                  f"unique_sizes={sorted(set(sizes))}")


if __name__ == '__main__':
    main()
