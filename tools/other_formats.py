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

    # Analyze non-IFF formats
    print("=== Non-IFF File Format Analysis ===\n")

    # PAK files
    pak_files = [e for e in entries if e['path'].endswith('.PAK')]
    print(f"PAK files ({len(pak_files)} total):")
    for e in pak_files[:3]:
        f.seek(e['abs_pos'])
        data = f.read(min(64, e['size']))
        print(f"  {e['path']} ({e['size']} bytes)")
        print(f"    Header: {data[:32].hex()}")

    # VPK files (likely voice pack)
    vpk_files = [e for e in entries if e['path'].endswith('.VPK')]
    print(f"\nVPK files ({len(vpk_files)} total):")
    for e in vpk_files[:3]:
        f.seek(e['abs_pos'])
        data = f.read(min(64, e['size']))
        print(f"  {e['path']} ({e['size']} bytes)")
        print(f"    Header: {data[:32].hex()}")

    # PFC files (likely palette/face/conversation)
    pfc_files = [e for e in entries if e['path'].endswith('.PFC')]
    print(f"\nPFC files ({len(pfc_files)} total):")
    for e in pfc_files[:3]:
        f.seek(e['abs_pos'])
        data = f.read(min(64, e['size']))
        print(f"  {e['path']} ({e['size']} bytes)")
        print(f"    Header: {data[:32].hex()}")

    # VPF files
    vpf_files = [e for e in entries if e['path'].endswith('.VPF')]
    print(f"\nVPF files ({len(vpf_files)} total):")
    for e in vpf_files[:3]:
        f.seek(e['abs_pos'])
        data = f.read(min(64, e['size']))
        print(f"  {e['path']} ({e['size']} bytes)")
        print(f"    Header: {data[:32].hex()}")

    # VOC files (Sound Blaster voice)
    voc_files = [e for e in entries if e['path'].endswith('.VOC')]
    print(f"\nVOC files ({len(voc_files)} total):")
    for e in voc_files[:3]:
        f.seek(e['abs_pos'])
        data = f.read(min(64, e['size']))
        header_str = data[:20].decode('ascii', errors='replace')
        print(f"  {e['path']} ({e['size']} bytes)")
        print(f"    Header: {data[:32].hex()}")
        print(f"    ASCII: {header_str}")

    # SHP files (shape/sprite)
    shp_files = [e for e in entries if e['path'].endswith('.SHP')]
    print(f"\nSHP files ({len(shp_files)} total):")
    for e in shp_files[:3]:
        f.seek(e['abs_pos'])
        data = f.read(min(64, e['size']))
        print(f"  {e['path']} ({e['size']} bytes)")
        print(f"    Header: {data[:32].hex()}")

    # ADL files (Adlib music)
    adl_files = [e for e in entries if e['path'].endswith('.ADL')]
    print(f"\nADL files ({len(adl_files)} total):")
    for e in adl_files:
        print(f"  {e['path']} ({e['size']} bytes)")

    # GEN files (General MIDI)
    gen_files = [e for e in entries if e['path'].endswith('.GEN')]
    print(f"\nGEN files ({len(gen_files)} total):")
    for e in gen_files:
        print(f"  {e['path']} ({e['size']} bytes)")

    # PAL files
    pal_files = [e for e in entries if e['path'].endswith('.PAL')]
    print(f"\nPAL files ({len(pal_files)} total):")
    for e in pal_files:
        f.seek(e['abs_pos'])
        data = f.read(min(16, e['size']))
        print(f"  {e['path']} ({e['size']} bytes) header: {data.hex()}")

    # DRV files (drivers)
    drv_files = [e for e in entries if e['path'].endswith('.DRV')]
    print(f"\nDRV files ({len(drv_files)} total):")
    for e in drv_files:
        print(f"  {e['path']} ({e['size']} bytes)")

    # DAT files
    dat_files = [e for e in entries if e['path'].endswith('.DAT')]
    print(f"\nDAT files ({len(dat_files)} total):")
    for e in dat_files:
        f.seek(e['abs_pos'])
        data = f.read(min(128, e['size']))
        print(f"  {e['path']} ({e['size']} bytes)")
        print(f"    Header: {data[:64].hex()}")

    # Overall size statistics
    print("\n=== Size Statistics ===")
    total_size = sum(e['size'] for e in entries)
    by_ext = {}
    for e in entries:
        ext = e['path'].rsplit('.', 1)[-1] if '.' in e['path'] else 'NONE'
        by_ext.setdefault(ext, {'count': 0, 'size': 0})
        by_ext[ext]['count'] += 1
        by_ext[ext]['size'] += e['size']

    print(f"Total data size: {total_size:,} bytes ({total_size/1024/1024:.1f} MB)")
    print(f"\nBy extension:")
    for ext, stats in sorted(by_ext.items(), key=lambda x: -x[1]['size']):
        print(f"  .{ext:4s}: {stats['count']:4d} files, {stats['size']:12,} bytes ({stats['size']/1024/1024:.1f} MB)")
