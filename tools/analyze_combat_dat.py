"""Analyze COMBAT.DAT and sound-related files from PRIV.TRE.

Examines the structure of COMBAT.DAT (1,896 bytes) which maps combat events
to sound effect indices, and catalogs all files in DATA/SOUND/.
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
        flag = toc[entry_start]
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

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)
    entries = get_entries(toc)

    # List all SOUND/ files
    sound_files = [e for e in entries if 'SOUND' in e['path'].upper()]
    print(f"=== DATA/SOUND/ files ({len(sound_files)} total) ===\n")
    for e in sound_files:
        print(f"  {e['path']:30s} {e['size']:>8d} bytes")

    # Look for SOUNDFX anywhere
    sfx_files = [e for e in entries if 'SOUNDFX' in e['path'].upper() or 'SFX' in e['path'].upper()]
    print(f"\n=== Files matching SOUNDFX/SFX ({len(sfx_files)}) ===")
    for e in sfx_files:
        print(f"  {e['path']:30s} {e['size']:>8d} bytes")

    # Analyze COMBAT.DAT
    combat_entries = [e for e in entries if 'COMBAT.DAT' in e['path'].upper()]
    if combat_entries:
        e = combat_entries[0]
        print(f"\n=== COMBAT.DAT Analysis ({e['size']} bytes) ===")
        f.seek(e['abs_pos'])
        data = f.read(e['size'])

        print(f"\nFirst 128 bytes (hex):")
        for row in range(8):
            off = row * 16
            hex_str = ' '.join(f'{b:02x}' for b in data[off:off+16])
            ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[off:off+16])
            print(f"  {off:04x}: {hex_str}  {ascii_str}")

        print(f"\nLast 64 bytes (hex):")
        start = len(data) - 64
        for row in range(4):
            off = start + row * 16
            hex_str = ' '.join(f'{b:02x}' for b in data[off:off+16])
            ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[off:off+16])
            print(f"  {off:04x}: {hex_str}  {ascii_str}")

        # Try to detect structure
        print(f"\nStructural analysis:")
        print(f"  Total size: {len(data)} bytes")
        print(f"  Size / 2 = {len(data) / 2} (u16 entries)")
        print(f"  Size / 4 = {len(data) / 4} (u32 entries)")
        print(f"  Size / 6 = {len(data) / 6:.1f}")
        print(f"  Size / 8 = {len(data) / 8:.1f}")
        print(f"  1896 - 4 = 1892, 1892/4 = {1892/4}")

        # Check if it starts with a count or size header
        u32_le = struct.unpack_from('<I', data, 0)[0]
        u16_le = struct.unpack_from('<H', data, 0)[0]
        u32_be = struct.unpack_from('>I', data, 0)[0]
        u16_be = struct.unpack_from('>H', data, 0)[0]
        print(f"\n  First 4 bytes as u32 LE: {u32_le}")
        print(f"  First 2 bytes as u16 LE: {u16_le}")
        print(f"  First 4 bytes as u32 BE: {u32_be}")
        print(f"  First 2 bytes as u16 BE: {u16_be}")

        # Histogram of byte values
        from collections import Counter
        byte_counts = Counter(data)
        print(f"\n  Unique byte values: {len(byte_counts)}")
        print(f"  Most common bytes: {byte_counts.most_common(10)}")

        # Check for repeating patterns
        print(f"\n  Byte value distribution (first 64 bytes):")
        for i in range(0, min(64, len(data)), 2):
            val = struct.unpack_from('<H', data, i)[0]
            print(f"    [{i:4d}] u16 LE = {val:5d} (0x{val:04x})")

        # Try interpreting as pairs: (event_type, sfx_index)
        print(f"\n  Interpreting as u16 LE pairs (event, sfx_index):")
        for i in range(0, min(128, len(data)), 4):
            evt = struct.unpack_from('<H', data, i)[0]
            idx = struct.unpack_from('<H', data, i + 2)[0]
            print(f"    [{i:4d}] event={evt:5d} sfx_idx={idx:5d}")

    # Analyze .AD file (AdLib sound data)
    ad_files = [e for e in entries if e['path'].upper().endswith('.AD')]
    for e in ad_files:
        print(f"\n=== {e['path']} Analysis ({e['size']} bytes) ===")
        f.seek(e['abs_pos'])
        data = f.read(min(256, e['size']))
        print(f"First 128 bytes:")
        for row in range(8):
            off = row * 16
            hex_str = ' '.join(f'{b:02x}' for b in data[off:off+16])
            ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[off:off+16])
            print(f"  {off:04x}: {hex_str}  {ascii_str}")

    # Also check TABLE.DAT in SOUND/
    table_entries = [e for e in entries if 'SOUND' in e['path'].upper() and 'TABLE' in e['path'].upper()]
    for e in table_entries:
        print(f"\n=== {e['path']} Analysis ({e['size']} bytes) ===")
        f.seek(e['abs_pos'])
        data = f.read(min(256, e['size']))
        print(f"First 128 bytes:")
        for row in range(8):
            off = row * 16
            hex_str = ' '.join(f'{b:02x}' for b in data[off:off+16])
            ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[off:off+16])
            print(f"  {off:04x}: {hex_str}  {ascii_str}")
