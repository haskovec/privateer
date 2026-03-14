"""Analyze VPK/VPF file formats from Wing Commander: Privateer."""
import struct
import sys
import io

# Force UTF-8 output
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

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


def parse_vpk_header(data):
    """Parse VPK header: u32 file_size, then offset table entries (u32 with high byte = marker)."""
    file_size = struct.unpack_from('<I', data, 0)[0]
    first_raw = struct.unpack_from('<I', data, 4)[0]
    first_offset = first_raw & 0x00FFFFFF
    entry_count = (first_offset - 4) // 4

    offsets = []
    markers = []
    for i in range(entry_count):
        raw = struct.unpack_from('<I', data, 4 + i * 4)[0]
        off = raw & 0x00FFFFFF
        marker = (raw >> 24) & 0xFF
        offsets.append(off)
        markers.append(marker)

    return file_size, entry_count, offsets, markers


def lzw_decompress(data):
    """LZW decompression (variable-width codes 9-12 bits, LSB packing).
    Each entry has: u32 LE decompressed_size, then LZW data."""
    if len(data) < 4:
        raise ValueError("Entry too small")

    decompressed_size = struct.unpack_from('<I', data, 0)[0]
    lzw_data = data[4:]

    CLEAR = 256
    END = 257
    FIRST_CODE = 258

    bit_pos = 0
    code_size = 9

    def read_code():
        nonlocal bit_pos
        byte_pos = bit_pos // 8
        bit_off = bit_pos % 8
        val = 0
        for i in range(3):
            if byte_pos + i < len(lzw_data):
                val |= lzw_data[byte_pos + i] << (8 * i)
        code = (val >> bit_off) & ((1 << code_size) - 1)
        bit_pos += code_size
        return code

    code = read_code()
    if code != CLEAR:
        raise ValueError(f"Expected clear code (256), got {code}")

    dictionary = {i: bytes([i]) for i in range(256)}
    next_code = FIRST_CODE

    code = read_code()
    if code > 255:
        raise ValueError(f"Expected literal after clear, got {code}")

    output = bytearray(dictionary[code])
    prev_string = dictionary[code]

    while len(output) < decompressed_size:
        if bit_pos // 8 >= len(lzw_data):
            break

        code = read_code()
        if code == END:
            break
        if code == CLEAR:
            dictionary = {i: bytes([i]) for i in range(256)}
            next_code = FIRST_CODE
            code_size = 9
            code = read_code()
            if code == END:
                break
            output.extend(dictionary[code])
            prev_string = dictionary[code]
            continue

        if code in dictionary:
            entry = dictionary[code]
        elif code == next_code:
            entry = prev_string + bytes([prev_string[0]])
        else:
            raise ValueError(f"Bad LZW code: {code} (next={next_code}, code_size={code_size}, output_len={len(output)})")

        output.extend(entry)

        if next_code < 4096:
            dictionary[next_code] = prev_string + bytes([entry[0]])
            next_code += 1
            if next_code > (1 << code_size) - 1 and code_size < 12:
                code_size += 1

        prev_string = entry

    return bytes(output[:decompressed_size]), decompressed_size


with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)
    entries = get_entries(toc)

    vpk_files = [e for e in entries if e['path'].endswith('.VPK')]
    vpf_files = [e for e in entries if e['path'].endswith('.VPF')]
    pfc_files = [e for e in entries if e['path'].endswith('.PFC')]

    print(f"=== VPK Files: {len(vpk_files)}, VPF Files: {len(vpf_files)}, PFC Files: {len(pfc_files)} ===\n")

    # Analyze VPK header structure
    print("=== VPK Header Analysis (first 5) ===\n")
    for e in vpk_files[:5]:
        f.seek(e['abs_pos'])
        data = f.read(min(256, e['size']))
        file_size, entry_count, offsets, markers = parse_vpk_header(data)
        print(f"{e['path']} ({e['size']} bytes)")
        print(f"  file_size={file_size}, entries={entry_count}, markers={set(markers)}")
        print(f"  offsets: {offsets}")
        print()

    # Try LZW decompression on first VPK file's entries
    print("=== LZW Decompression Test ===\n")
    e = vpk_files[0]
    f.seek(e['abs_pos'])
    data = f.read(e['size'])
    file_size, entry_count, offsets, markers = parse_vpk_header(data)

    print(f"File: {e['path']} ({e['size']} bytes, {entry_count} entries)\n")

    for idx in range(min(3, entry_count)):
        start = offsets[idx]
        if idx + 1 < entry_count:
            end = offsets[idx + 1]
        else:
            end = file_size
        entry_data = data[start:end]
        decomp_size = struct.unpack_from('<I', entry_data, 0)[0]
        print(f"Entry {idx}: compressed={len(entry_data)} bytes, decompressed_size={decomp_size}")

        try:
            result, expected_size = lzw_decompress(entry_data)
            print(f"  Decompressed: {len(result)} bytes (expected {expected_size})")
            if result[:20] == b"Creative Voice File\x1a":
                print(f"  *** CONFIRMED: Valid VOC data! ***")
                data_offset = struct.unpack_from('<H', result, 20)[0]
                version = struct.unpack_from('<H', result, 22)[0]
                print(f"  VOC data_offset={data_offset}, version=0x{version:04X}")
                if data_offset < len(result) and result[data_offset] == 1:
                    block_size = result[data_offset+1] | (result[data_offset+2] << 8) | (result[data_offset+3] << 16)
                    freq_div = result[data_offset+4]
                    codec = result[data_offset+5]
                    sr = 1000000 // (256 - freq_div)
                    pcm_bytes = block_size - 2
                    print(f"  VOC sound: sample_rate={sr}, codec={codec}, pcm_bytes={pcm_bytes}")
            else:
                print(f"  First 20 bytes: {result[:20].hex()}")
                print(f"  ASCII: {repr(result[:20].decode('ascii', errors='replace'))}")
        except Exception as ex:
            print(f"  Decompress FAILED: {ex}")
        print()

    # Test decompression on a VPF file too
    print("=== VPF Decompression Test ===\n")
    e = vpf_files[0]
    f.seek(e['abs_pos'])
    data = f.read(e['size'])
    file_size, entry_count, offsets, markers = parse_vpk_header(data)
    print(f"File: {e['path']} ({e['size']} bytes, {entry_count} entries)\n")

    start = offsets[0]
    end = offsets[1] if entry_count > 1 else file_size
    entry_data = data[start:end]
    decomp_size = struct.unpack_from('<I', entry_data, 0)[0]
    print(f"Entry 0: compressed={len(entry_data)} bytes, decompressed_size={decomp_size}")
    try:
        result, expected_size = lzw_decompress(entry_data)
        print(f"  Decompressed: {len(result)} bytes (expected {expected_size})")
        if result[:20] == b"Creative Voice File\x1a":
            print(f"  *** CONFIRMED: Valid VOC data! ***")
    except Exception as ex:
        print(f"  Decompress FAILED: {ex}")

    # Test decompression on 5 random VPK files (all entries)
    print("\n=== Bulk VPK Decompression Test (5 files) ===\n")
    import random
    test_files = random.sample(vpk_files, min(5, len(vpk_files)))
    total_entries = 0
    success_entries = 0
    voc_entries = 0

    for e in test_files:
        f.seek(e['abs_pos'])
        data = f.read(e['size'])
        file_size, entry_count, offsets, markers = parse_vpk_header(data)

        for idx in range(entry_count):
            start = offsets[idx]
            end = offsets[idx + 1] if idx + 1 < entry_count else file_size
            entry_data = data[start:end]
            total_entries += 1
            try:
                result, _ = lzw_decompress(entry_data)
                success_entries += 1
                if result[:20] == b"Creative Voice File\x1a":
                    voc_entries += 1
            except Exception as ex:
                print(f"  FAIL: {e['path']} entry {idx}: {ex}")

    print(f"Results: {success_entries}/{total_entries} decompressed, {voc_entries} valid VOC")

    # PFC analysis
    print("\n=== PFC Analysis ===\n")
    for e in pfc_files[:3]:
        f.seek(e['abs_pos'])
        data = f.read(e['size'])
        parts = data.split(b'\x00')
        parts = [p.decode('ascii', errors='replace') for p in parts if p]
        print(f"{e['path']} ({e['size']} bytes, {len(parts)} strings)")
        for p in parts[:8]:
            print(f"  - {p}")
        print()
