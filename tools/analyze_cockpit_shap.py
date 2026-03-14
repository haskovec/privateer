"""Analyze SHAP chunk data from cockpit IFF to understand the sprite format."""
import struct

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
ENTRY_SIZE = 74

def load_tre(f):
    f.seek(TRE_LBA * SECTOR)
    count = struct.unpack('<I', f.read(4))[0]
    toc_size = struct.unpack('<I', f.read(4))[0]
    entries = []
    for i in range(count):
        entry_start = TRE_LBA * SECTOR + 8 + i * ENTRY_SIZE
        f.seek(entry_start)
        raw = f.read(ENTRY_SIZE)
        flag = raw[0]
        path_bytes = raw[1:66]
        null = path_bytes.find(b'\x00')
        path = path_bytes[:null].decode('ascii', errors='replace') if null >= 0 else path_bytes.decode('ascii', errors='replace')
        offset = struct.unpack_from('<I', raw, 66)[0]
        size = struct.unpack_from('<I', raw, 70)[0]
        entries.append((path, offset, size))
    return entries, toc_size

def read_file_data(f, offset, size):
    abs_offset = TRE_LBA * SECTOR + offset
    f.seek(abs_offset)
    return f.read(size)

def hex_dump(data, max_bytes=128):
    for i in range(0, min(len(data), max_bytes), 16):
        hex_str = ' '.join(f'{b:02X}' for b in data[i:i+16])
        ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[i:i+16])
        print(f'  {i:04X}: {hex_str:<48s}  {ascii_str}')

def main():
    with open(GAME_DAT, 'rb') as f:
        entries, toc_size = load_tre(f)

        # Find CLUNKCK.IFF
        for path, offset, size in entries:
            if 'CLUNKCK.IFF' in path:
                data = read_file_data(f, offset, size)
                break
        else:
            print("CLUNKCK.IFF not found")
            return

        # Parse the IFF to find the FRNT SHAP chunk
        # FORM:COCK starts at offset 0
        # FORM header: 8 bytes (FORM + size)
        # COCK type: 4 bytes
        # FORM:FRNT at offset 12
        pos = 12  # after FORM:COCK header + "COCK"
        tag = data[pos:pos+4].decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]
        print(f"First child: {tag} size={size}")
        assert tag == "FORM"

        form_type = data[pos+8:pos+12].decode('ascii')
        print(f"Form type: {form_type}")
        assert form_type == "FRNT"

        # SHAP chunk is inside FRNT
        shap_pos = pos + 12  # after FORM:FRNT header + "FRNT"
        shap_tag = data[shap_pos:shap_pos+4].decode('ascii')
        shap_size = struct.unpack_from('>I', data, shap_pos+4)[0]
        print(f"\nSHAP chunk: tag={shap_tag} size={shap_size}")

        shap_data = data[shap_pos+8:shap_pos+8+shap_size]

        # Parse as RLE sprite header: x2, x1, y1, y2 (all i16 LE)
        x2 = struct.unpack_from('<h', shap_data, 0)[0]
        x1 = struct.unpack_from('<h', shap_data, 2)[0]
        y1 = struct.unpack_from('<h', shap_data, 4)[0]
        y2 = struct.unpack_from('<h', shap_data, 6)[0]
        print(f"\nSprite header: x2={x2} x1={x1} y1={y1} y2={y2}")
        print(f"Dimensions: width={x1+x2} height={y1+y2}")

        print(f"\nFirst 128 bytes of SHAP data:")
        hex_dump(shap_data, 128)

        # Try to parse the RLE data after the header
        print(f"\nFirst few RLE records (starting at offset 8):")
        rle_pos = 8
        for i in range(10):
            if rle_pos + 2 > len(shap_data):
                break
            key = struct.unpack_from('<H', shap_data, rle_pos)[0]
            if key == 0:
                print(f"  [{i}] Terminator (key=0) at offset {rle_pos}")
                break
            pixel_count = key // 2
            encoding = "odd (sub-encoded)" if key % 2 else "even (raw)"
            if rle_pos + 6 <= len(shap_data):
                x_off = struct.unpack_from('<h', shap_data, rle_pos+2)[0]
                y_off = struct.unpack_from('<h', shap_data, rle_pos+4)[0]
                print(f"  [{i}] key={key} ({pixel_count} pixels, {encoding}), x_off={x_off}, y_off={y_off}")
                # Compute the size of the payload
                if key % 2 == 0:
                    # Even key: pixel_count raw bytes follow
                    payload_size = pixel_count
                    rle_pos += 6 + payload_size
                else:
                    # Odd key: sub-encoded, need to scan sub-bytes
                    sub_pos = rle_pos + 6
                    total_pixels = 0
                    while total_pixels < pixel_count and sub_pos < len(shap_data):
                        sub_byte = shap_data[sub_pos]
                        sub_count = sub_byte // 2
                        if sub_byte % 2 == 0:
                            # Even sub: literal pixels
                            sub_pos += 1 + sub_count
                        else:
                            # Odd sub: repeat single pixel
                            sub_pos += 2
                        total_pixels += sub_count
                    rle_pos = sub_pos
            else:
                print(f"  [{i}] key={key} ({pixel_count} pixels, {encoding}) - truncated")
                break

        # Also check TPLT data
        tplt_pos = shap_pos + 8 + shap_size
        if shap_size % 2 == 1:
            tplt_pos += 1  # IFF padding
        tplt_tag = data[tplt_pos:tplt_pos+4].decode('ascii')
        tplt_size = struct.unpack_from('>I', data, tplt_pos+4)[0]
        print(f"\n\nTPLT chunk: tag={tplt_tag} size={tplt_size}")
        tplt_data = data[tplt_pos+8:tplt_pos+8+min(tplt_size, 128)]
        print("First 128 bytes of TPLT data:")
        hex_dump(tplt_data, 128)

        # Try to interpret TPLT as array of u16 LE
        print("\nTPLT as u16 LE values:")
        for i in range(min(tplt_size // 2, 32)):
            val = struct.unpack_from('<H', tplt_data, i * 2)[0]
            print(f"  [{i}] = {val} (0x{val:04X})")

if __name__ == '__main__':
    main()
