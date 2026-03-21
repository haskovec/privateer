#!/usr/bin/env python3
"""Verify SPRI format: [id:u16] [ref:u16] [0x8000:u16] [type:u16] [params...]"""
import struct, os, sys

# Param count per type (derived from manual analysis)
TYPE_PARAMS = {
    0: 3,   # 14 bytes total
    1: 3,   # 14 bytes total
    3: 5,   # 18 bytes total
    4: 9,   # 26 bytes total
    11: 5,  # 18 bytes total
    12: 6,  # 20 bytes total
    18: 7,  # 22 bytes total
    19: 9,  # 26 bytes total
    20: 9,  # 26 bytes total
}

def read_tre(game_dat_path):
    with open(game_dat_path, 'rb') as f:
        data = f.read()
    pvd = data[16*2048:16*2048+2048]
    root_lba = struct.unpack_from('<I', pvd, 158)[0]
    root_size = struct.unpack_from('<I', pvd, 166)[0]
    root_data = data[root_lba*2048:root_lba*2048+root_size]
    pos = 0
    tre_lba = tre_size = 0
    while pos < len(root_data):
        rec_len = root_data[pos]
        if rec_len == 0: break
        name_len = root_data[pos+32]
        name = root_data[pos+33:pos+33+name_len].decode('ascii', errors='replace')
        if name.startswith('PRIV.TRE'):
            tre_lba = struct.unpack_from('<I', root_data, pos+2)[0]
            tre_size = struct.unpack_from('<I', root_data, pos+10)[0]
            break
        pos += rec_len
    tre_data = data[tre_lba*2048:tre_lba*2048+tre_size]
    entry_count = struct.unpack_from('<I', tre_data, 0)[0]
    entries = []
    for i in range(entry_count):
        offset = 8 + i * 74
        path_raw = tre_data[offset+1:offset+66]
        path = path_raw.split(b'\x00')[0].decode('ascii', errors='replace')
        entry_offset = struct.unpack_from('<I', tre_data, offset+66)[0]
        entry_size = struct.unpack_from('<I', tre_data, offset+70)[0]
        entries.append((path, entry_offset, entry_size))
    return tre_data, entries

def find_tre_file(tre_data, entries, basename):
    for path, offset, size in entries:
        name = path.split('\\')[-1]
        if name.upper() == basename.upper():
            return tre_data[offset:offset+size]
    return None

def parse_iff_chunks(data, offset=0):
    chunks = []
    while offset + 8 <= len(data):
        tag = data[offset:offset+4].decode('ascii', errors='replace')
        size = struct.unpack_from('>I', data, offset+4)[0]
        chunk_data = data[offset+8:offset+8+size]
        form_type = None
        children = []
        if tag in ('FORM', 'CAT ', 'LIST') and size >= 4:
            form_type = chunk_data[0:4].decode('ascii', errors='replace')
            children = parse_iff_chunks(chunk_data, 4)
        chunks.append((tag, form_type, chunk_data, children))
        offset += 8 + size
        if size % 2 == 1:
            offset += 1
    return chunks

game_dat = os.environ.get('PRIVATEER_DATA', '.')
tre_data, entries = read_tre(os.path.join(game_dat, 'GAME.DAT'))

# Check ALL MOVI files in the TRE
movi_files = ['MID1A.IFF','MID1B.IFF','MID1C1.IFF','MID1C2.IFF','MID1C3.IFF','MID1C4.IFF',
              'MID1D.IFF','MID1E1.IFF','MID1E2.IFF','MID1E3.IFF','MID1E4.IFF','MID1F.IFF',
              'VICTORY1.IFF','VICTORY2.IFF','VICTORY3.IFF','VICTORY4.IFF','VICTORY5.IFF',
              'DEATHAPR.IFF','CUBICLE.IFF','LANDINGS.IFF','TAKEOFFS.IFF','JUMP.IFF']

all_ok = True
types_seen = set()

for fname in movi_files:
    fdata = find_tre_file(tre_data, entries, fname)
    if not fdata:
        continue
    if len(fdata) < 12 or fdata[0:4] != b'FORM' or fdata[8:12] != b'MOVI':
        continue

    chunks = parse_iff_chunks(fdata)
    if not chunks:
        continue
    root_tag, root_form, root_data, root_children = chunks[0]
    if root_form != 'MOVI':
        continue

    acts_idx = 0
    for tag, ft, cd, children in root_children:
        if ft == 'ACTS':
            for ctag, _, cdata, _ in children:
                if ctag == 'SPRI':
                    pos = 0
                    rec_num = 0
                    while pos + 8 <= len(cdata):
                        obj_id = struct.unpack_from('<H', cdata, pos)[0]
                        ref = struct.unpack_from('<H', cdata, pos+2)[0]
                        sentinel = struct.unpack_from('<H', cdata, pos+4)[0]
                        typ = struct.unpack_from('<H', cdata, pos+6)[0]

                        if sentinel != 0x8000:
                            print(f'{fname} ACTS[{acts_idx}] rec[{rec_num}] at offset {pos}: sentinel={sentinel:#06x} != 0x8000!')
                            all_ok = False
                            break

                        types_seen.add(typ)
                        if typ not in TYPE_PARAMS:
                            print(f'{fname} ACTS[{acts_idx}] rec[{rec_num}] at offset {pos}: unknown type={typ}')
                            all_ok = False
                            break

                        param_count = TYPE_PARAMS[typ]
                        rec_size = 8 + param_count * 2

                        if pos + rec_size > len(cdata):
                            print(f'{fname} ACTS[{acts_idx}] rec[{rec_num}] at offset {pos}: rec_size={rec_size} exceeds chunk ({len(cdata)} bytes)')
                            all_ok = False
                            break

                        pos += rec_size
                        rec_num += 1

                    if pos != len(cdata):
                        print(f'{fname} ACTS[{acts_idx}] SPRI ({len(cdata)}B): MISMATCH pos={pos} != len={len(cdata)}')
                        all_ok = False
                    else:
                        print(f'{fname} ACTS[{acts_idx}] SPRI ({len(cdata)}B): OK {rec_num} records')
            acts_idx += 1

print(f'\nTypes seen: {sorted(types_seen)}')
if all_ok:
    print('ALL SPRI chunks parsed correctly!')
else:
    print('ERRORS found!')
    sys.exit(1)
