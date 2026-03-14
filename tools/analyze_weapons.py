"""Deep analysis of weapon data files from PRIV.TRE."""
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


def hex_dump(data, max_bytes=64):
    lines = []
    for i in range(0, min(len(data), max_bytes), 16):
        row = data[i:i+16]
        hex_part = ' '.join(f'{b:02x}' for b in row)
        ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in row)
        lines.append(f'  {i:04x}: {hex_part:<48s} {ascii_part}')
    if len(data) > max_bytes:
        lines.append(f'  ... ({len(data)} bytes total)')
    return '\n'.join(lines)


def main():
    with open(GAME_DAT, 'rb') as f:
        f.seek(TRE_START)
        toc = f.read(TOC_SIZE)
        entries = get_all_tre_entries(toc)

        # ================================================================
        # GUNS.IFF - Gun type definitions
        # ================================================================
        e = find_entry(entries, 'TYPES\\GUNS.IFF')
        print(f"=== {e['path']} ({e['size']} bytes) ===")
        f.seek(e['abs_pos'])
        data = f.read(e['size'])

        # FORM header: "FORM" + u32BE size + "GUNS"
        form_tag = data[0:4].decode('ascii')
        form_size = struct.unpack_from('>I', data, 4)[0]
        form_type = data[8:12].decode('ascii')
        print(f"  {form_tag} [{form_type}] ({form_size} bytes)")

        # TABL chunk at offset 12
        tabl_tag = data[12:16].decode('ascii')
        tabl_size = struct.unpack_from('>I', data, 16)[0]
        print(f"  {tabl_tag} ({tabl_size} bytes)")

        # Parse TABL as array of u32 LE offsets
        tabl_data = data[20:20+tabl_size]
        num_guns = tabl_size // 4
        print(f"  {num_guns} gun entries:")
        offsets = []
        for i in range(num_guns):
            off = struct.unpack_from('<I', tabl_data, i*4)[0]
            offsets.append(off)
            print(f"    Gun[{i:2d}] offset = 0x{off:04x} ({off})")

        # After TABL, there should be the actual gun data
        # The offsets appear to be from start of file? or from FORM content?
        # TABL ends at byte 20 + tabl_size = 64 = 0x40 which matches first offset
        # So offsets are from start of file (from byte 0)
        print(f"\n  TABL ends at byte {20 + tabl_size}")
        print(f"  First gun offset = {offsets[0]}")

        # Dump each gun type
        for i in range(num_guns):
            start = offsets[i]
            end = offsets[i+1] if i + 1 < num_guns else len(data)
            gun_data = data[start:end]
            print(f"\n  Gun[{i}] @ 0x{start:04x} ({end - start} bytes):")
            print(hex_dump(gun_data, max_bytes=64))

            # Try to parse the gun chunk
            if len(gun_data) >= 8:
                chunk_tag = gun_data[0:4].decode('ascii', errors='replace')
                chunk_size = struct.unpack_from('>I', gun_data, 4)[0]
                print(f"    Chunk: {chunk_tag} ({chunk_size} bytes)")
                if chunk_tag == 'FORM' and len(gun_data) >= 12:
                    sub_type = gun_data[8:12].decode('ascii', errors='replace')
                    print(f"    SubType: {sub_type}")
                    # Parse INFO chunk inside
                    pos = 12
                    while pos + 8 <= len(gun_data):
                        ctag = gun_data[pos:pos+4].decode('ascii', errors='replace')
                        csz = struct.unpack_from('>I', gun_data, pos+4)[0]
                        cdata = gun_data[pos+8:pos+8+csz]
                        print(f"    {ctag} ({csz} bytes):")
                        print(hex_dump(cdata, max_bytes=64))
                        if ctag == 'INFO':
                            # Try to interpret as weapon stats
                            if len(cdata) >= 14:
                                print(f"      As u16 LE:")
                                for j in range(0, min(len(cdata), 14), 2):
                                    val = struct.unpack_from('<H', cdata, j)[0]
                                    print(f"        [{j:2d}] = {val:5d} (0x{val:04x})")
                        pos += 8 + csz
                        if csz % 2 == 1:
                            pos += 1

        # ================================================================
        # WEAPONS.IFF (TYPES version, 318 bytes)
        # ================================================================
        e = find_entry(entries, 'TYPES\\WEAPONS.IFF')
        if e:
            print(f"\n\n=== {e['path']} ({e['size']} bytes) ===")
            f.seek(e['abs_pos'])
            data = f.read(e['size'])
            print(hex_dump(data, max_bytes=400))

            # Parse full structure
            form_tag = data[0:4].decode('ascii')
            form_size = struct.unpack_from('>I', data, 4)[0]
            form_type = data[8:12].decode('ascii')
            print(f"\n  {form_tag} [{form_type}] ({form_size} bytes)")

            # Parse child chunks
            pos = 12
            while pos + 8 <= len(data):
                tag = data[pos:pos+4]
                if not all(32 <= b < 127 for b in tag):
                    break
                tag_str = tag.decode('ascii')
                size = struct.unpack_from('>I', data, pos+4)[0]

                if tag_str in ('FORM', 'CAT ', 'LIST'):
                    sub_type = data[pos+8:pos+12].decode('ascii', errors='replace')
                    print(f"  {tag_str} [{sub_type}] ({size} bytes) @ {pos}")
                    # Parse inner chunks
                    inner_pos = pos + 12
                    inner_end = pos + 8 + size
                    while inner_pos + 8 <= inner_end:
                        itag = data[inner_pos:inner_pos+4]
                        if not all(32 <= b < 127 for b in itag):
                            break
                        itag_str = itag.decode('ascii')
                        isz = struct.unpack_from('>I', data, inner_pos+4)[0]
                        if itag_str in ('FORM', 'CAT ', 'LIST'):
                            isub = data[inner_pos+8:inner_pos+12].decode('ascii', errors='replace')
                            print(f"    {itag_str} [{isub}] ({isz} bytes) @ {inner_pos}")
                            # Parse UNIT chunks inside
                            unit_pos = inner_pos + 12
                            unit_end = inner_pos + 8 + isz
                            while unit_pos + 8 <= unit_end:
                                utag = data[unit_pos:unit_pos+4].decode('ascii', errors='replace')
                                usz = struct.unpack_from('>I', data, unit_pos+4)[0]
                                udata = data[unit_pos+8:unit_pos+8+usz]
                                print(f"      {utag} ({usz} bytes):")
                                print(hex_dump(udata, max_bytes=64))
                                unit_pos += 8 + usz
                                if usz % 2 == 1:
                                    unit_pos += 1
                        else:
                            idata = data[inner_pos+8:inner_pos+8+isz]
                            print(f"    {itag_str} ({isz} bytes):")
                            print(hex_dump(idata, max_bytes=64))
                        inner_pos += 8 + isz
                        if isz % 2 == 1:
                            inner_pos += 1
                else:
                    cdata = data[pos+8:pos+8+size]
                    print(f"  {tag_str} ({size} bytes) @ {pos}:")
                    print(hex_dump(cdata, max_bytes=64))

                pos += 8 + size
                if size % 2 == 1:
                    pos += 1

        # ================================================================
        # LASRTYPE.IFF - Known weapon with 14 byte INFO
        # ================================================================
        for name in ['LASRTYPE.IFF']:
            e = find_entry(entries, name)
            if e:
                print(f"\n\n=== {e['path']} ({e['size']} bytes) ===")
                f.seek(e['abs_pos'])
                data = f.read(e['size'])
                # Parse FORM:REAL > FORM:LINR > INFO
                # Offset 12: FORM:LINR
                # Offset 24: INFO chunk
                if len(data) >= 38:
                    info_start = 24  # After FORM:REAL header + FORM:LINR header
                    info_tag = data[info_start:info_start+4].decode('ascii', errors='replace')
                    info_size = struct.unpack_from('>I', data, info_start+4)[0]
                    info_data = data[info_start+8:info_start+8+info_size]
                    print(f"  INFO ({info_size} bytes):")
                    print(hex_dump(info_data, max_bytes=64))
                    print(f"  As u16 LE pairs:")
                    for j in range(0, info_size, 2):
                        if j + 2 <= info_size:
                            val = struct.unpack_from('<H', info_data, j)[0]
                            print(f"    [{j:2d}] = {val:5d} (0x{val:04x})")

        # ================================================================
        # SHIPSTUF.IFF - Equipment shop data
        # ================================================================
        e = find_entry(entries, 'SHIPSTUF.IFF')
        if e:
            print(f"\n\n=== {e['path']} ({e['size']} bytes) ===")
            f.seek(e['abs_pos'])
            data = f.read(e['size'])

            # Parse top-level
            form_tag = data[0:4].decode('ascii')
            form_size = struct.unpack_from('>I', data, 4)[0]
            form_type = data[8:12].decode('ascii')
            print(f"  {form_tag} [{form_type}] ({form_size} bytes)")

            # Look for gun-related forms
            pos = 12
            while pos + 8 <= len(data):
                tag = data[pos:pos+4]
                if not all(32 <= b < 127 for b in tag):
                    break
                tag_str = tag.decode('ascii')
                size = struct.unpack_from('>I', data, pos+4)[0]
                if tag_str == 'FORM':
                    sub = data[pos+8:pos+12].decode('ascii', errors='replace')
                    print(f"  {tag_str} [{sub}] ({size} bytes) @ {pos}")
                    # Only dump weapon-related forms
                    if sub in ('GUNS', 'WEAP', 'MISL', 'LNCH', 'AMMO', 'ARMR', 'SHLD', 'TYPE'):
                        inner_data = data[pos+12:pos+8+size]
                        print(hex_dump(inner_data, max_bytes=128))
                else:
                    cdata = data[pos+8:pos+8+size]
                    print(f"  {tag_str} ({size} bytes) @ {pos}")
                    if size <= 64:
                        print(hex_dump(cdata, max_bytes=64))
                pos += 8 + size
                if size % 2 == 1:
                    pos += 1


if __name__ == '__main__':
    main()
