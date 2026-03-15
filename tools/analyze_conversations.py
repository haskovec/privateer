"""Deep analysis of conversation IFF files from PRIV.TRE.

Analyzes CONV/*.IFF files to reverse-engineer the binary format of
RECV, SEND, COMM, and other conversation chunks.
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


def find_all_entries(entries, fragment):
    return [e for e in entries if fragment.upper() in e['path'].upper()]


def hex_dump(data, max_bytes=128):
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
                'data': data[pos+8:pos+8+size],
            })
            results.extend(parse_chunks_flat(data, pos + 12, pos + 8 + size, depth + 1))
        else:
            cdata = data[pos+8:pos+8+size]
            results.append({
                'tag': tag_str, 'size': size, 'offset': pos, 'depth': depth,
                'is_container': False, 'data': cdata,
            })
        # Advance to next chunk (pad to even boundary)
        pos = pos + 8 + size + (size % 2)
    return results


def analyze_conv_file(data, name):
    """Analyze a single CONV IFF file."""
    print(f"\n{'='*70}")
    print(f"FILE: {name} ({len(data)} bytes)")
    print(f"{'='*70}")

    chunks = parse_chunks_flat(data, 0, len(data))
    for c in chunks:
        indent = '  ' * c['depth']
        if c.get('is_container'):
            print(f"{indent}FORM:{c['sub_type']} (size={c['size']}, offset={c['offset']})")
        else:
            print(f"{indent}{c['tag']} (size={c['size']}, offset={c['offset']})")
            # Print data details for small chunks
            if c['size'] <= 64:
                print(hex_dump(c['data'], 64))
            else:
                # For larger chunks, show first 64 bytes
                print(hex_dump(c['data'], 64))

    return chunks


def collect_chunk_stats(all_files_chunks):
    """Collect statistics about chunk types across all files."""
    stats = {}
    for fname, chunks in all_files_chunks:
        for c in chunks:
            if c.get('is_container'):
                key = f"FORM:{c['sub_type']}"
            else:
                key = c['tag']
            if key not in stats:
                stats[key] = {'count': 0, 'sizes': [], 'files': set()}
            stats[key]['count'] += 1
            stats[key]['sizes'].append(c['size'])
            stats[key]['files'].add(fname)
    return stats


def main():
    with open(GAME_DAT, 'rb') as f:
        f.seek(TRE_START)
        toc = f.read(TOC_SIZE)

    entries = get_all_tre_entries(toc)
    conv_entries = find_all_entries(entries, 'CONV\\')
    iff_entries = [e for e in conv_entries if e['path'].upper().endswith('.IFF')]

    print(f"Found {len(conv_entries)} CONV entries ({len(iff_entries)} IFF files)")

    # Sort by path for consistent output
    iff_entries.sort(key=lambda e: e['path'])

    all_chunks = []

    with open(GAME_DAT, 'rb') as f:
        # Analyze first few files in detail
        detail_count = min(5, len(iff_entries))
        for entry in iff_entries[:detail_count]:
            f.seek(entry['abs_pos'])
            data = f.read(entry['size'])
            chunks = analyze_conv_file(data, entry['path'])
            all_chunks.append((entry['path'], chunks))

        # Collect stats from ALL IFF files
        print(f"\n\n{'='*70}")
        print(f"ANALYZING ALL {len(iff_entries)} CONV IFF FILES FOR STATISTICS...")
        print(f"{'='*70}")

        for entry in iff_entries[detail_count:]:
            f.seek(entry['abs_pos'])
            data = f.read(entry['size'])
            try:
                chunks = parse_chunks_flat(data, 0, len(data))
                all_chunks.append((entry['path'], chunks))
            except Exception as e:
                print(f"  ERROR parsing {entry['path']}: {e}")

    # Print statistics
    stats = collect_chunk_stats(all_chunks)
    print(f"\n{'='*70}")
    print(f"CHUNK TYPE STATISTICS (across {len(all_chunks)} files)")
    print(f"{'='*70}")
    for key in sorted(stats.keys()):
        s = stats[key]
        min_sz = min(s['sizes'])
        max_sz = max(s['sizes'])
        avg_sz = sum(s['sizes']) / len(s['sizes'])
        print(f"  {key:12s}: count={s['count']:4d}, size min={min_sz:6d} max={max_sz:6d} avg={avg_sz:8.1f}, in {len(s['files'])} files")

    # Print root form types
    print(f"\n{'='*70}")
    print(f"ROOT FORM TYPES")
    print(f"{'='*70}")
    root_types = {}
    for fname, chunks in all_chunks:
        if chunks and chunks[0].get('is_container'):
            rt = chunks[0]['sub_type']
            root_types.setdefault(rt, []).append(fname)
    for rt, files in sorted(root_types.items()):
        print(f"  FORM:{rt}: {len(files)} files")
        for fn in files[:3]:
            print(f"    {fn}")
        if len(files) > 3:
            print(f"    ... and {len(files)-3} more")

    # Print unique tree structures (tag paths)
    print(f"\n{'='*70}")
    print(f"UNIQUE CHUNK STRUCTURES (tag nesting)")
    print(f"{'='*70}")
    structures = {}
    for fname, chunks in all_chunks:
        struct_key = []
        for c in chunks:
            indent = '  ' * c['depth']
            if c.get('is_container'):
                struct_key.append(f"{indent}FORM:{c['sub_type']}")
            else:
                struct_key.append(f"{indent}{c['tag']}({c['size']})")
        sk = '\n'.join(struct_key)
        structures.setdefault(sk, []).append(fname)

    # Show top unique structures
    for sk, files in sorted(structures.items(), key=lambda x: -len(x[1])):
        print(f"\n  [{len(files)} files]:")
        for fn in files[:3]:
            print(f"    {fn}")
        if len(files) > 3:
            print(f"    ... and {len(files)-3} more")
        # Show structure with generic sizes
        lines = sk.split('\n')
        for line in lines:
            print(f"    {line}")

    # Also look at COMMTXT.IFF and COMMSTUF.IFF from OPTIONS
    print(f"\n{'='*70}")
    print(f"ANALYZING OPTIONS/COMMTXT.IFF AND COMMSTUF.IFF")
    print(f"{'='*70}")
    for pattern in ['COMMTXT', 'COMMSTUF', 'COMPTEXT']:
        opts = find_all_entries(entries, pattern)
        if opts:
            with open(GAME_DAT, 'rb') as f:
                for entry in opts:
                    f.seek(entry['abs_pos'])
                    data = f.read(entry['size'])
                    analyze_conv_file(data, entry['path'])


if __name__ == '__main__':
    main()
