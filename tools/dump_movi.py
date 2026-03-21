#!/usr/bin/env python3
"""Dump complete MOVI scene graph data for all intro movie files."""
import struct, os, sys

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

SPRITE_TYPE_PARAMS = {0: 3, 1: 3, 3: 5, 4: 9, 11: 5, 12: 6, 18: 7, 19: 9, 20: 9}

def parse_spri(data):
    records = []
    pos = 0
    while pos + 8 <= len(data):
        obj_id = struct.unpack_from('<H', data, pos)[0]
        ref = struct.unpack_from('<H', data, pos+2)[0]
        sentinel = struct.unpack_from('<H', data, pos+4)[0]
        stype = struct.unpack_from('<H', data, pos+6)[0]
        nparams = SPRITE_TYPE_PARAMS.get(stype)
        if nparams is None:
            break
        rec_size = 8 + nparams * 2
        if pos + rec_size > len(data):
            break
        params = []
        for i in range(nparams):
            params.append(struct.unpack_from('<h', data, pos + 8 + i*2)[0])
        records.append((obj_id, ref, stype, params))
        pos += rec_size
    return records

game_dat = os.environ.get('PRIVATEER_DATA', '.')
tre_data, entries = read_tre(os.path.join(game_dat, 'GAME.DAT'))

movi_files = ['MID1A.IFF','MID1B.IFF','MID1C1.IFF','MID1C2.IFF','MID1C3.IFF','MID1C4.IFF',
              'MID1D.IFF','MID1E1.IFF','MID1E2.IFF','MID1E3.IFF','MID1E4.IFF','MID1F.IFF']

for fname in movi_files:
    fdata = find_tre_file(tre_data, entries, fname)
    if not fdata:
        continue
    chunks = parse_iff_chunks(fdata)
    if not chunks:
        continue
    root_tag, root_form, root_data_raw, root_children = chunks[0]
    if root_form != 'MOVI':
        continue

    print(f'\n{"="*60}')
    print(f'{fname}')
    print(f'{"="*60}')

    for tag, ft, cd, children in root_children:
        if tag == 'CLRC':
            val = struct.unpack_from('>H', cd, 0)[0] if len(cd) >= 2 else 0
            print(f'  CLRC = {val}')
        elif tag == 'SPED':
            val = struct.unpack_from('>H', cd, 0)[0] if len(cd) >= 2 else 0
            print(f'  SPED = {val}')
        elif tag == 'FILE':
            print(f'  FILE ({len(cd)} bytes):')
            pos = 0
            while pos + 2 < len(cd):
                slot_id = struct.unpack_from('<H', cd, pos)[0]
                pos += 2
                end = cd.index(0, pos) if 0 in cd[pos:] else len(cd)
                path = cd[pos:end].decode('ascii', errors='replace')
                pos = end + 1
                print(f'    slot {slot_id}: {path}')

    acts_idx = 0
    for tag, ft, cd, children in root_children:
        if ft != 'ACTS':
            continue
        print(f'\n  ACTS[{acts_idx}]:')

        for ctag, _, cdata, _ in children:
            if ctag == 'FILD':
                print(f'    FILD ({len(cdata)} bytes, {len(cdata)//10} records):')
                for i in range(0, len(cdata) - 9, 10):
                    oid = struct.unpack_from('<H', cdata, i)[0]
                    fref = struct.unpack_from('<H', cdata, i+2)[0]
                    p1 = struct.unpack_from('<H', cdata, i+4)[0]
                    p2 = struct.unpack_from('<H', cdata, i+6)[0]
                    p3 = struct.unpack_from('<H', cdata, i+8)[0]
                    print(f'      obj={oid:3d} file_ref={fref} p1={p1} p2={p2} p3={p3}')

            elif ctag == 'SPRI':
                recs = parse_spri(cdata)
                print(f'    SPRI ({len(cdata)} bytes, {len(recs)} records):')
                for obj_id, ref, stype, params in recs:
                    ref_str = 'SELF' if ref == 0x8000 else f'FILD:{ref}'
                    ps = ','.join(str(p) for p in params)
                    print(f'      obj={obj_id:3d} ref={ref_str:>8s} type={stype:2d} params=[{ps}]')

            elif ctag == 'BFOR':
                nrecs = len(cdata) // 24
                print(f'    BFOR ({len(cdata)} bytes, {nrecs} records):')
                for i in range(nrecs):
                    off = i * 24
                    oid = struct.unpack_from('<H', cdata, off)[0]
                    flags = struct.unpack_from('<H', cdata, off+2)[0]
                    ps = []
                    for j in range(10):
                        ps.append(struct.unpack_from('<H', cdata, off+4+j*2)[0])
                    ps_str = ','.join(str(p) for p in ps)
                    flag_str = 'LAYER' if flags == 0x7fff else f'OBJ:{flags}'
                    print(f'      obj={oid:3d} flags={flag_str:>10s} (0x{flags:04x}) params=[{ps_str}]')

        acts_idx += 1
