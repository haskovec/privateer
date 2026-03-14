import struct

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
TRE_START = TRE_LBA * SECTOR
TOC_SIZE = 86688

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)

    count = struct.unpack_from('<I', toc, 0)[0]
    entries = []
    for i in range(count):
        entry_start = 8 + i * 74
        flag = toc[entry_start]
        null_pos = toc.find(b'\x00', entry_start + 1)
        path = toc[entry_start+1:null_pos].decode('ascii', errors='replace')
        file_offset = struct.unpack_from('<I', toc, entry_start + 66)[0]
        file_size = struct.unpack_from('<I', toc, entry_start + 70)[0]
        entries.append({'path': path, 'offset': file_offset, 'size': file_size})

    # Focus on failing PAK files
    problem_names = ['MIDTEXT', 'MID1TXT', 'OPENING', 'VICTLIST', 'VICTTXT',
                     'JUMP', 'LANDINGS', 'TAKEOFFS', 'VICTORY', 'SPEECH.PAK']
    pak_files = [e for e in entries if e['path'].endswith('.PAK')]

    for e in pak_files:
        parts = e['path'].replace('\\', '/')
        name = parts.split('/')[-1]
        if not any(p in name for p in problem_names):
            continue
        abs_pos = TRE_START + e['offset']
        f.seek(abs_pos)
        data = f.read(min(64, e['size']))
        print(f'{name} ({e["size"]} bytes):')
        for i in range(0, len(data), 16):
            hex_str = ' '.join(f'{b:02X}' for b in data[i:i+16])
            ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[i:i+16])
            print(f'  {i:04X}: {hex_str:48s} {ascii_str}')
        print()
