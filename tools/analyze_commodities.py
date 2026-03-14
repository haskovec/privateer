"""Deep analysis of commodity data files from PRIV.TRE."""
import struct

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


def parse_chunks(data, start, end, indent=0):
    """Recursively parse IFF chunks."""
    results = []
    pos = start
    prefix = '  ' * indent
    while pos + 8 <= end:
        tag = data[pos:pos+4]
        if not all(32 <= b < 127 for b in tag):
            break
        tag_str = tag.decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]

        if tag_str in ('FORM', 'CAT ', 'LIST'):
            sub_type = data[pos+8:pos+12].decode('ascii', errors='replace')
            print(f'{prefix}{tag_str} [{sub_type}] ({size} bytes) @ {pos}')
            results.append({
                'tag': tag_str, 'sub_type': sub_type, 'size': size,
                'offset': pos, 'data': data[pos+12:pos+8+size]
            })
            parse_chunks(data, pos + 12, pos + 8 + size, indent + 1)
        else:
            cdata = data[pos+8:pos+8+size]
            print(f'{prefix}{tag_str} ({size} bytes) @ {pos}:')
            print(hex_dump(cdata, max_bytes=128))
            results.append({
                'tag': tag_str, 'size': size, 'offset': pos, 'data': cdata
            })

        pos += 8 + size
        if size % 2 == 1:
            pos += 1
    return results


def main():
    with open(GAME_DAT, 'rb') as f:
        f.seek(TRE_START)
        toc = f.read(TOC_SIZE)
        entries = get_all_tre_entries(toc)

        # ================================================================
        # COMODTYP.IFF - Commodity type definitions
        # ================================================================
        e = find_entry(entries, 'COMODTYP.IFF')
        if not e:
            print("COMODTYP.IFF not found!")
            return

        print(f"=== {e['path']} ({e['size']} bytes) ===")
        f.seek(e['abs_pos'])
        data = f.read(e['size'])

        # Full recursive parse
        print("\n--- Full structure ---")
        parse_chunks(data, 0, len(data))

        # Count specific chunk types
        print("\n--- Chunk type counts ---")
        chunk_counts = {}
        pos = 0
        all_chunks = []

        def count_chunks(data, start, end):
            pos = start
            while pos + 8 <= end:
                tag = data[pos:pos+4]
                if not all(32 <= b < 127 for b in tag):
                    break
                tag_str = tag.decode('ascii')
                size = struct.unpack_from('>I', data, pos+4)[0]
                chunk_counts[tag_str] = chunk_counts.get(tag_str, 0) + 1

                if tag_str in ('FORM', 'CAT ', 'LIST'):
                    sub_type = data[pos+8:pos+12].decode('ascii', errors='replace')
                    all_chunks.append({'tag': tag_str, 'sub': sub_type, 'size': size, 'pos': pos})
                    count_chunks(data, pos + 12, pos + 8 + size)
                else:
                    all_chunks.append({'tag': tag_str, 'size': size, 'pos': pos,
                                       'data': data[pos+8:pos+8+size]})
                pos += 8 + size
                if size % 2 == 1:
                    pos += 1

        count_chunks(data, 0, len(data))
        for tag, count in sorted(chunk_counts.items()):
            print(f"  {tag}: {count}")

        # ================================================================
        # Also check LANDFEE.IFF and LIMITS.IFF
        # ================================================================
        for name in ['LANDFEE.IFF', 'LIMITS.IFF']:
            e = find_entry(entries, name)
            if e:
                print(f"\n\n=== {e['path']} ({e['size']} bytes) ===")
                f.seek(e['abs_pos'])
                data = f.read(e['size'])
                print("\n--- Full structure ---")
                parse_chunks(data, 0, len(data))


if __name__ == '__main__':
    main()
