import struct

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
TRE_START = TRE_LBA * SECTOR  # 55296
TOC_SIZE = 86688

with open(GAME_DAT, 'rb') as f:
    # Read TOC
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)

    # Parse first few entries
    # Entry 0 starts at offset 8 in TOC, path at offset 9
    # Entry is 74 bytes total
    entries = []
    for i in range(5):
        entry_start = 8 + i * 74
        flag = toc[entry_start]
        # Find path
        null_pos = toc.find(b'\x00', entry_start + 1)
        path = toc[entry_start+1:null_pos].decode('ascii')
        # Last 8 bytes of the 74-byte entry
        offset_val = struct.unpack_from('<I', toc, entry_start + 74 - 8)[0]
        size_val = struct.unpack_from('<I', toc, entry_start + 74 - 4)[0]
        entries.append((path, offset_val, size_val))
        print(f"Entry {i}: {path}")
        print(f"  Candidate offset: {offset_val}, size: {size_val}")

    # Try several hypotheses for file location
    print("\n--- Hypothesis testing ---")
    for hyp_name, base_calc in [
        ("TRE_START + offset", lambda o: TRE_START + o),
        ("TRE_START + TOC_SIZE + offset", lambda o: TRE_START + TOC_SIZE + o),
        ("offset (absolute in ISO)", lambda o: o),
        ("offset * SECTOR", lambda o: o * SECTOR),
    ]:
        print(f"\nHypothesis: {hyp_name}")
        for i, (path, offset_val, size_val) in enumerate(entries[:3]):
            abs_pos = base_calc(offset_val)
            if abs_pos < 0 or abs_pos + 16 > 90269696:
                print(f"  Entry {i}: position {abs_pos} - out of range")
                continue
            f.seek(abs_pos)
            data = f.read(16)
            tag = data[:4]
            is_form = (tag == b'FORM')
            is_iff = all(32 <= b < 127 for b in tag[:4]) if len(tag) >= 4 else False
            ascii_tag = tag.decode('ascii', errors='replace') if len(tag) >= 4 else '???'
            print(f"  Entry {i}: pos={abs_pos}, tag='{ascii_tag}', is_FORM={is_form}, hex={data[:8].hex()}")

    # Let's also try interpreting the metadata differently
    # Maybe the offset/size aren't the last 8 bytes
    print("\n--- Trying different metadata positions ---")
    entry0_start = 8
    meta = toc[entry0_start:entry0_start+74]
    # Try every possible 4-byte position as an offset
    print(f"Entry 0 full hex: {meta.hex()}")
    print(f"Path: {entries[0][0]}")
    null_rel = meta.find(b'\x00', 1)
    print(f"Null at relative offset {null_rel}")
    print(f"Metadata bytes after null:")
    for j in range(null_rel+1, 74, 4):
        if j + 4 <= 74:
            val = struct.unpack_from('<I', meta, j)[0]
            # Check if this could be a valid offset
            for base_name, base in [("TRE_START+", TRE_START), ("TOC_SIZE+TRE_START+", TRE_START+TOC_SIZE)]:
                abs_pos = base + val
                if 0 < abs_pos < 90269696:
                    f.seek(abs_pos)
                    check = f.read(4)
                    is_form = (check == b'FORM')
                    if is_form:
                        f.seek(abs_pos)
                        full = f.read(16)
                        sub = full[8:12].decode('ascii', errors='replace')
                        print(f"  ** FOUND FORM ** at meta byte {j}, val={val}, base={base_name}, abs={abs_pos}, subtype={sub}")

    # Also search brute-force for first FORM after TOC
    print("\n--- Scanning for first FORM after TOC ---")
    f.seek(TRE_START + TOC_SIZE)
    scan_data = f.read(100000)
    for i in range(len(scan_data) - 8):
        if scan_data[i:i+4] == b'FORM':
            size = struct.unpack_from('>I', scan_data, i+4)[0]
            if size > 0 and size < 10000000:
                sub = scan_data[i+8:i+12].decode('ascii', errors='replace')
                abs_pos = TRE_START + TOC_SIZE + i
                print(f"  FORM at scan+{i} (abs {abs_pos}): size={size}, type='{sub}'")
                if len([1 for c in sub if 32 <= ord(c) < 127]) == 4:
                    break
