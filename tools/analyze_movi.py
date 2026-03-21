#!/usr/bin/env python3
"""Analyze FORM:MOVI IFF files from WC:Privateer intro cinematics.

Dumps the full IFF structure and raw hex of FILD/SPRI/BFOR chunks
to reverse-engineer the command formats.
"""

import struct
import sys
import os

def read_tre(game_dat_path):
    """Read PRIV.TRE from GAME.DAT and return (tre_data, entries)."""
    with open(game_dat_path, 'rb') as f:
        data = f.read()

    # Find PRIV.TRE via ISO9660
    # PVD at sector 16
    pvd = data[16*2048:16*2048+2048]
    assert pvd[1:6] == b'CD001', "Not a valid ISO9660 image"

    # Root directory at LBA from PVD offset 158
    root_lba = struct.unpack_from('<I', pvd, 158)[0]
    root_size = struct.unpack_from('<I', pvd, 166)[0]
    root_data = data[root_lba*2048:root_lba*2048+root_size]

    # Find PRIV.TRE in root directory
    pos = 0
    tre_lba = tre_size = 0
    while pos < len(root_data):
        rec_len = root_data[pos]
        if rec_len == 0:
            break
        name_len = root_data[pos+32]
        name = root_data[pos+33:pos+33+name_len].decode('ascii', errors='replace')
        if name.startswith('PRIV.TRE'):
            tre_lba = struct.unpack_from('<I', root_data, pos+2)[0]
            tre_size = struct.unpack_from('<I', root_data, pos+10)[0]
            break
        pos += rec_len

    assert tre_lba > 0, "PRIV.TRE not found"
    tre_data = data[tre_lba*2048:tre_lba*2048+tre_size]

    # Parse TRE entries
    entry_count = struct.unpack_from('<I', tre_data, 0)[0]
    entries = []
    for i in range(entry_count):
        offset = 8 + i * 74
        # Byte 0 = flag, bytes 1-65 = path, bytes 66-69 = offset, bytes 70-73 = size
        path_raw = tre_data[offset+1:offset+66]
        path = path_raw.split(b'\x00')[0].decode('ascii', errors='replace')
        entry_offset = struct.unpack_from('<I', tre_data, offset+66)[0]
        entry_size = struct.unpack_from('<I', tre_data, offset+70)[0]
        entries.append((path, entry_offset, entry_size))

    return tre_data, entries


def find_tre_file(tre_data, entries, basename):
    """Find a file in TRE by basename (case-insensitive)."""
    for path, offset, size in entries:
        # Handle DOS paths with backslashes
        name = path.replace('\\', '/').split('/')[-1]
        if name.upper() == basename.upper():
            return tre_data[offset:offset+size]
    return None


def parse_iff_chunks(data, offset=0, depth=0):
    """Recursively parse IFF chunks and return a list of (tag, form_type, data, children, depth)."""
    chunks = []
    while offset + 8 <= len(data):
        tag = data[offset:offset+4].decode('ascii', errors='replace')
        size = struct.unpack_from('>I', data, offset+4)[0]
        chunk_data = data[offset+8:offset+8+size]

        form_type = None
        children = []
        if tag in ('FORM', 'CAT ', 'LIST') and size >= 4:
            form_type = chunk_data[0:4].decode('ascii', errors='replace')
            children = parse_iff_chunks(chunk_data, 4, depth+1)
            chunks.append((tag, form_type, chunk_data[4:], children, depth))
        else:
            chunks.append((tag, None, chunk_data, [], depth))

        offset += 8 + size
        if size % 2 == 1:
            offset += 1  # IFF padding

    return chunks


def dump_hex(data, prefix="  "):
    """Dump hex bytes in rows of 16."""
    for i in range(0, len(data), 16):
        row = data[i:i+16]
        hexstr = ' '.join(f'{b:02x}' for b in row)
        ascstr = ''.join(chr(b) if 32 <= b < 127 else '.' for b in row)
        print(f"{prefix}{i:04x}: {hexstr:<48s}  {ascstr}")


def parse_null_strings(data):
    """Split data into null-terminated strings (including empties)."""
    strings = []
    start = 0
    for i, b in enumerate(data):
        if b == 0:
            strings.append(data[start:i].decode('ascii', errors='replace'))
            start = i + 1
    if start < len(data):
        strings.append(data[start:].decode('ascii', errors='replace'))
    return strings


def analyze_fild(data):
    """Analyze a FILD chunk's packed records."""
    print(f"  FILD analysis ({len(data)} bytes):")
    print(f"  As u16 LE words:")
    words = []
    for i in range(0, len(data)-1, 2):
        w = struct.unpack_from('<H', data, i)[0]
        words.append(w)
    for i, w in enumerate(words):
        print(f"    [{i:2d}] {w:5d} (0x{w:04x})")

    # Try 10-byte records
    print(f"\n  Attempt: 10-byte records (sprite_idx:u16LE, file_ref:u16LE, p1:u16LE, p2:u16LE, p3:u16LE):")
    for i in range(0, len(data), 10):
        if i + 8 > len(data):
            remaining = data[i:]
            print(f"    Remaining {len(remaining)} bytes: {' '.join(f'{b:02x}' for b in remaining)}")
            break
        sprite_idx = struct.unpack_from('<H', data, i)[0]
        file_ref = struct.unpack_from('<H', data, i+2)[0]
        p1 = struct.unpack_from('<H', data, i+4)[0]
        p2 = struct.unpack_from('<H', data, i+6)[0]
        p3 = struct.unpack_from('<H', data, i+8)[0] if i+10 <= len(data) else None
        hex_str = ' '.join(f'{b:02x}' for b in data[i:min(i+10, len(data))])
        p3_str = f", p3={p3}" if p3 is not None else ""
        print(f"    sprite={sprite_idx}, file={file_ref}, p1={p1}, p2={p2}{p3_str}  [{hex_str}]")


def analyze_spri(data):
    """Analyze a SPRI chunk's packed records."""
    print(f"  SPRI analysis ({len(data)} bytes):")

    # Look for records starting with sequential sprite indices
    # First pass: identify record boundaries by looking for sprite_index patterns
    pos = 0
    records = []
    while pos < len(data) - 1:
        sprite_idx = struct.unpack_from('<H', data, pos)[0]
        # Find the next record: look for where the next sprite_index starts
        next_pos = None
        for j in range(pos + 6, min(pos + 40, len(data) - 1), 2):
            next_sprite = struct.unpack_from('<H', data, j)[0]
            # Next sprite should be close to current sprite + 1
            if next_sprite == sprite_idx + 1 or (next_sprite > sprite_idx and next_sprite - sprite_idx < 10):
                next_pos = j
                break
        if next_pos is None:
            next_pos = len(data)
        rec_data = data[pos:next_pos]
        records.append((sprite_idx, rec_data))
        pos = next_pos

    print(f"  Found {len(records)} records:")
    for i, (sprite_idx, rec_data) in enumerate(records):
        hex_str = ' '.join(f'{b:02x}' for b in rec_data)
        words = []
        for j in range(0, len(rec_data) - 1, 2):
            w = struct.unpack_from('<H', rec_data, j)[0]
            sw = struct.unpack_from('<h', rec_data, j)[0]
            words.append((w, sw))
        word_str = ', '.join(f'{w}({sw})' for w, sw in words)
        print(f"    [{i}] sprite={sprite_idx}, {len(rec_data)} bytes: {hex_str}")
        print(f"         words: {word_str}")


def analyze_movi(data, name):
    """Analyze a FORM:MOVI file."""
    chunks = parse_iff_chunks(data)
    if not chunks:
        print(f"  No chunks found")
        return

    root_tag, root_form, root_data, root_children, _ = chunks[0]
    print(f"\n=== {name} ===")
    print(f"  Root: {root_tag}:{root_form} ({len(data)} bytes)")

    for tag, form_type, chunk_data, children, depth in root_children:
        indent = "  " * (depth + 1)
        if form_type:
            print(f"{indent}{tag}:{form_type} ({len(chunk_data)+4} bytes)")
            for ctag, cft, cdata, _, cdepth in children:
                cindent = "  " * (cdepth + 1)
                print(f"{cindent}{ctag} ({len(cdata)} bytes)")
                if ctag == 'FILD':
                    analyze_fild(cdata)
                elif ctag == 'SPRI':
                    analyze_spri(cdata)
                elif ctag == 'BFOR':
                    dump_hex(cdata, cindent + "  ")
                else:
                    dump_hex(cdata[:64], cindent + "  ")
        else:
            print(f"{indent}{tag} ({len(chunk_data)} bytes)")
            if tag == 'FILE':
                dump_hex(chunk_data, indent + "  ")
                strings = parse_null_strings(chunk_data)
                for si, s in enumerate(strings):
                    non_empty_idx = sum(1 for x in strings[:si] if x)
                    print(f"{indent}  [{si}] \"{s}\" (non-empty idx: {non_empty_idx if s else '-'})")
            elif tag == 'SPED':
                if len(chunk_data) >= 2:
                    sped = struct.unpack_from('>H', chunk_data, 0)[0]
                    print(f"{indent}  value={sped}")
            elif tag == 'CLRC':
                if len(chunk_data) >= 2:
                    clrc = struct.unpack_from('>H', chunk_data, 0)[0]
                    print(f"{indent}  value={clrc}")
            else:
                dump_hex(chunk_data[:64], indent + "  ")


def main():
    game_dat = os.environ.get('PRIVATEER_DATA', '.')
    game_dat_path = os.path.join(game_dat, 'GAME.DAT')
    if not os.path.exists(game_dat_path):
        print(f"GAME.DAT not found at {game_dat_path}")
        print("Set PRIVATEER_DATA env var to the directory containing GAME.DAT")
        sys.exit(1)

    print(f"Loading {game_dat_path}...")
    tre_data, entries = read_tre(game_dat_path)
    print(f"TRE loaded: {len(entries)} entries")

    # Debug: show some MIDGAMES entries
    for path, offset, size in entries:
        if 'MIDGAME' in path.upper() or 'MID1' in path.upper():
            name = path.replace('\\', '/').split('/')[-1]
            print(f"  TRE: {path!r} -> basename: {name!r} (len={len(name)})")

    # Quick test
    test = find_tre_file(tre_data, entries, 'MID1A.IFF')
    print(f"  Direct find test: {'FOUND' if test else 'NOT FOUND'}")
    # Try matching manually
    for path, offset, size in entries:
        name = path.replace('\\', '/').split('/')[-1]
        if 'MID1A' in name:
            print(f"  Manual match: {name!r} == 'MID1A.IFF' ? {name.upper() == 'MID1A.IFF'}")

    # Analyze MID1A.IFF through MID1F.IFF
    for scene in ['MID1A', 'MID1B']:
        filename = f'{scene}.IFF'
        file_data = find_tre_file(tre_data, entries, filename)
        if file_data:
            analyze_movi(file_data, filename)
        else:
            print(f"\n{filename}: not found in TRE")


if __name__ == '__main__':
    main()
