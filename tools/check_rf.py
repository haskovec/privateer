import struct, sys, os
os.environ['PYTHONIOENCODING'] = 'utf-8'

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
TRE_START = TRE_LBA * 2048

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_START)
    toc = f.read(86688)

    count = struct.unpack_from('<I', toc, 0)[0]
    rf_entries = []
    all_paths = []

    for i in range(count):
        entry_start = 8 + i * 74
        if entry_start + 74 > len(toc):
            break
        null_pos = toc.find(b'\x00', entry_start + 1)
        if null_pos == -1 or null_pos >= entry_start + 74:
            continue
        path = toc[entry_start+1:null_pos].decode('ascii', errors='replace')
        all_paths.append(path)

    # Check for RF content
    for p in all_paths:
        p_upper = p.upper()
        if 'RF' in p_upper.split('\\')[-1] or 'FIRE' in p_upper or 'RIGHTEOUS' in p_upper:
            rf_entries.append(p)

    # Also check exe for RF references
    print(f"Total TRE entries: {len(all_paths)}")
    print(f"Potential RF entries: {len(rf_entries)}")
    for p in rf_entries:
        print(f"  {p}")

    # Check if rf.cfg exists on disk
    rf_cfg = r'C:\progra~1\eagame~1\wingco~1\DATA\rf.cfg'
    print(f"\nrf.cfg exists: {os.path.exists(rf_cfg)}")
