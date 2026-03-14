"""Analyze SECTORS/ files from PRIV.TRE to understand universe data structures."""
import struct
import sys

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
HEADER_SIZE = 8
ENTRY_SIZE = 74

def read_tre(f):
    """Read TRE header and entries."""
    f.seek(TRE_LBA * SECTOR)
    header = f.read(HEADER_SIZE)
    count, toc_size = struct.unpack_from('<II', header, 0)

    entries = []
    for i in range(count):
        raw = f.read(ENTRY_SIZE)
        flag = raw[0]
        path_bytes = raw[1:66]
        nul = path_bytes.find(0)
        path = path_bytes[:nul].decode('ascii') if nul >= 0 else path_bytes.decode('ascii')
        offset = struct.unpack_from('<I', raw, 66)[0]
        size = struct.unpack_from('<I', raw, 70)[0]
        entries.append((flag, path, offset, size))

    return entries, toc_size

def extract_file(f, entry):
    """Extract file data from TRE. Offset is relative to TRE start."""
    flag, path, offset, size = entry
    abs_offset = TRE_LBA * SECTOR + offset
    f.seek(abs_offset)
    return f.read(size)

def hex_dump(data, offset=0, max_bytes=128):
    """Hex dump of binary data."""
    lines = []
    for i in range(0, min(len(data) - offset, max_bytes), 16):
        o = offset + i
        hex_part = ' '.join(f'{b:02x}' for b in data[o:o+16])
        ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[o:o+16])
        lines.append(f'  {o:04x}: {hex_part:<48s} {ascii_part}')
    if len(data) - offset > max_bytes:
        lines.append(f'  ... ({len(data)} bytes total)')
    return '\n'.join(lines)

def parse_iff_chunks(data, offset=0, end=None, depth=0):
    """Recursively parse IFF chunks."""
    if end is None:
        end = len(data)
    results = []
    pos = offset
    while pos + 8 <= end:
        tag = data[pos:pos+4]
        if not all(32 <= b < 127 for b in tag):
            break
        tag_str = tag.decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]

        if tag_str in ('FORM', 'CAT ', 'LIST'):
            if pos + 12 <= end:
                subtype = data[pos+8:pos+12].decode('ascii', errors='replace')
                results.append((depth, tag_str, size, subtype, pos))
                sub = parse_iff_chunks(data, pos+12, pos+8+size, depth+1)
                results.extend(sub)
        else:
            chunk_data = data[pos+8:pos+8+size] if pos+8+size <= end else b''
            results.append((depth, tag_str, size, chunk_data, pos))

        pos += 8 + size
        if size % 2 == 1:
            pos += 1
    return results

# --- Main ---
with open(GAME_DAT, 'rb') as f:
    entries, toc_size = read_tre(f)

    # Find SECTORS/ files
    sector_files = [(i, e) for i, e in enumerate(entries) if 'SECTORS' in e[1].upper()]

    for idx, entry in sector_files:
        flag, path, offset, size = entry
        data = extract_file(f, entry)
        filename = path.split('\\')[-1]

        print(f"\n{'='*70}")
        print(f"=== {filename} ({size} bytes) ===")
        print(f"{'='*70}")

        if filename == 'TABLE.DAT':
            print(f"\nFull hex dump (first 512 bytes):")
            print(hex_dump(data, max_bytes=512))

            print(f"\nSize: {size} = 69 * 69 = {69*69}")
            print(f"Interpreting as 69x69 matrix (one row per system):")
            # Show as a matrix-like view
            for row in range(min(10, size // 69)):
                row_data = data[row*69:(row+1)*69]
                print(f"  System {row:2d}:", ' '.join(f'{b:02x}' for b in row_data[:20]), '...')

            # Analyze the separator-like sequences
            print(f"\nLooking for structural patterns:")
            for i in range(size - 3):
                if data[i] == 0x1d and data[i+1] == 0x00 and data[i+2] == 0x9f:
                    print(f"  Marker at offset {i} (0x{i:03x}): {' '.join(f'{b:02x}' for b in data[i:i+10])}")
                elif data[i] == 0x1b and data[i+1] == 0x00 and data[i+2] == 0x9f:
                    print(f"  Marker at offset {i} (0x{i:03x}): {' '.join(f'{b:02x}' for b in data[i:i+10])}")

            # Value frequency analysis
            from collections import Counter
            freq = Counter(data)
            print(f"\nByte value frequencies (top 20):")
            for val, cnt in freq.most_common(20):
                desc = f"'{chr(val)}'" if 32 <= val < 127 else f"0x{val:02x}"
                print(f"  {val:3d} ({desc:>5s}): {cnt} times")

        else:
            # Show raw first bytes to understand format
            print(f"\nFirst 64 bytes raw:")
            print(hex_dump(data, max_bytes=64))

            # Try IFF parsing
            if data[:4] in (b'FORM', b'CAT ', b'LIST'):
                chunks = parse_iff_chunks(data)
                print(f"\nIFF structure ({len(chunks)} chunks):")
                for depth, tag, size, extra, pos in chunks:
                    indent = "  " * depth
                    if isinstance(extra, str):
                        print(f"  {indent}{tag}:{extra} (size={size}, offset={pos})")
                    else:
                        print(f"  {indent}{tag} (size={size}, offset={pos})")
                        if isinstance(extra, bytes) and len(extra) > 0 and len(extra) <= 128:
                            print(hex_dump(extra, max_bytes=64))
            else:
                # Not standard IFF - maybe it's a CAT file or different format
                print(f"\nNOT standard IFF. First 4 bytes: {data[:4]}")
                print(f"Trying as raw data format...")
                print(f"\nFull hex dump (first 512 bytes):")
                print(hex_dump(data, max_bytes=512))

                # Check if there might be an offset before IFF data
                for start in range(0, min(32, len(data)-4)):
                    if data[start:start+4] in (b'FORM', b'CAT ', b'LIST'):
                        print(f"\nFound IFF marker at offset {start}!")
                        chunks = parse_iff_chunks(data, start)
                        print(f"IFF structure ({len(chunks)} chunks):")
                        for depth, tag, size, extra, pos in chunks[:30]:
                            indent = "  " * depth
                            if isinstance(extra, str):
                                print(f"  {indent}{tag}:{extra} (size={size}, offset={pos})")
                            else:
                                print(f"  {indent}{tag} (size={size}, offset={pos})")
                                if isinstance(extra, bytes) and len(extra) > 0 and len(extra) <= 64:
                                    print(hex_dump(extra, max_bytes=64))
                        break
