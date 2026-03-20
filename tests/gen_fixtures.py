"""Generate binary test fixtures for ISO 9660 and TRE parser tests."""
import struct
import os

FIXTURES = os.path.dirname(os.path.abspath(__file__)) + "/fixtures"

def write(name, data):
    path = os.path.join(FIXTURES, name)
    with open(path, "wb") as f:
        f.write(data)
    print(f"  wrote {path} ({len(data)} bytes)")


def gen_iso_pvd():
    """Generate a minimal ISO 9660 Primary Volume Descriptor at sector 16."""
    # Sector size = 2048 bytes
    # PVD is at LBA 16 (offset 32768)
    # We create a minimal image: 16 empty sectors + PVD sector
    data = bytearray(b'\x00' * 2048 * 16)  # sectors 0-15 (system area)

    # PVD at sector 16
    pvd = bytearray(2048)
    pvd[0] = 0x01  # type = Primary Volume Descriptor
    pvd[1:6] = b'CD001'  # standard identifier
    pvd[6] = 0x01  # version
    # System identifier (32 bytes at offset 8)
    pvd[8:8+32] = b'TEST SYSTEM'.ljust(32)
    # Volume identifier (32 bytes at offset 40)
    pvd[40:40+32] = b'PRIVATEER_TEST'.ljust(32)
    # Volume space size (both-endian uint32 at offset 80)
    total_sectors = 50
    struct.pack_into('<I', pvd, 80, total_sectors)  # LE
    struct.pack_into('>I', pvd, 84, total_sectors)  # BE
    # Logical block size (both-endian uint16 at offset 128)
    struct.pack_into('<H', pvd, 128, 2048)
    struct.pack_into('>H', pvd, 130, 2048)
    # Root directory record at offset 156, 34 bytes
    root_rec = make_dir_record(b'\x00', lba=20, size=2048, is_dir=True)
    pvd[156:156+34] = root_rec[:34]

    data += pvd

    # Sectors 17-19: padding
    data += b'\x00' * 2048 * 3

    # Sector 20: Root directory with entries
    root_dir = bytearray(2048)
    pos = 0
    # "." entry
    dot = make_dir_record(b'\x00', lba=20, size=2048, is_dir=True)
    root_dir[pos:pos+len(dot)] = dot
    pos += len(dot)
    # ".." entry
    dotdot = make_dir_record(b'\x01', lba=20, size=2048, is_dir=True)
    root_dir[pos:pos+len(dotdot)] = dotdot
    pos += len(dotdot)
    # PRIV.TRE file at LBA 27, size 1024 (test size)
    tre_rec = make_dir_record(b'PRIV.TRE;1', lba=27, size=1024, is_dir=False)
    root_dir[pos:pos+len(tre_rec)] = tre_rec
    pos += len(tre_rec)
    # LICENSE.TXT
    lic_rec = make_dir_record(b'LICENSE.TXT;1', lba=25, size=100, is_dir=False)
    root_dir[pos:pos+len(lic_rec)] = lic_rec
    pos += len(lic_rec)

    data += root_dir

    # Sectors 21-26: padding
    data += b'\x00' * 2048 * 6

    # Sector 27: Start of PRIV.TRE mock data (just 1024 bytes of pattern)
    tre_data = bytes(range(256)) * 4  # 1024 bytes
    data += tre_data

    write("test_iso.bin", bytes(data))


def make_dir_record(name_bytes, lba, size, is_dir):
    """Build an ISO 9660 directory record."""
    name_len = len(name_bytes)
    # Record length must be even
    rec_len = 33 + name_len
    if rec_len % 2 == 1:
        rec_len += 1  # padding byte

    rec = bytearray(rec_len)
    rec[0] = rec_len  # length of directory record
    rec[1] = 0  # extended attribute record length
    # Location of extent (both-endian)
    struct.pack_into('<I', rec, 2, lba)
    struct.pack_into('>I', rec, 6, lba)
    # Data length (both-endian)
    struct.pack_into('<I', rec, 10, size)
    struct.pack_into('>I', rec, 14, size)
    # Recording date/time (7 bytes at offset 18) - zeros
    # File flags at offset 25
    if is_dir:
        rec[25] = 0x02  # directory flag
    # File unit size (26), interleave gap (27) = 0
    # Volume sequence number (both-endian uint16 at 28)
    struct.pack_into('<H', rec, 28, 1)
    struct.pack_into('>H', rec, 30, 1)
    # File identifier length at offset 32
    rec[32] = name_len
    # File identifier
    rec[33:33+name_len] = name_bytes
    return rec


def gen_tre_archive():
    """Generate a minimal TRE archive with 3 test entries."""
    entry_count = 3
    entry_size = 74
    toc_size = 8 + entry_count * entry_size  # header + entries

    paths = [
        b"..\\..\\DATA\\AIDS\\ATTITUDE.IFF",
        b"..\\..\\DATA\\AIDS\\BEHAVIOR.IFF",
        b"..\\..\\DATA\\APPEARNC\\GALAXY.PAK",
    ]

    # File data for each entry
    file_data = [
        b"FORM" + struct.pack('>I', 8) + b"ATTD" + b"\xDE\xAD\xBE\xEF",  # 16 bytes
        b"FORM" + struct.pack('>I', 4) + b"BEHV",  # 12 bytes
        b"\x20\x00\x00\x00" + b"\xFF" * 28,  # PAK-like: 32 bytes
    ]

    # Calculate offsets (from start of TRE data, so toc_size + cumulative)
    offsets = []
    current = toc_size  # file data starts after TOC
    for d in file_data:
        offsets.append(current)
        current += len(d)

    # Build TRE
    data = bytearray()
    # Header
    data += struct.pack('<I', entry_count)
    data += struct.pack('<I', toc_size)

    # Entries (74 bytes each)
    for i in range(entry_count):
        entry = bytearray(74)
        entry[0] = 0x01  # flag: file
        path = paths[i]
        entry[1:1+len(path)] = path
        # offset at +66 (LE uint32)
        struct.pack_into('<I', entry, 66, offsets[i])
        # size at +70 (LE uint32)
        struct.pack_into('<I', entry, 70, len(file_data[i]))
        data += entry

    # File data
    for d in file_data:
        data += d

    write("test_tre.bin", bytes(data))


def gen_iff_chunks():
    """Generate a test IFF file with nested FORMs, leaf chunks, and odd-size padding.

    Structure:
        FORM (type=ATTD)
            AROW chunk (4 bytes data: 0x01020304)
            DISP chunk (3 bytes data: 0x050607 + 1 pad byte) -- tests odd-size padding
            FORM (type=NEST)
                INFO chunk (4 bytes data: 0x08090A0B)
    """
    # Inner FORM children
    info_chunk = b"INFO" + struct.pack('>I', 4) + b"\x08\x09\x0A\x0B"  # 12 bytes

    inner_form_data = b"NEST" + info_chunk  # 4 + 12 = 16 bytes
    inner_form = b"FORM" + struct.pack('>I', len(inner_form_data)) + inner_form_data  # 8 + 16 = 24 bytes

    # Outer FORM children
    arow_chunk = b"AROW" + struct.pack('>I', 4) + b"\x01\x02\x03\x04"  # 12 bytes
    disp_chunk = b"DISP" + struct.pack('>I', 3) + b"\x05\x06\x07" + b"\x00"  # 12 bytes (3 data + 1 pad)

    outer_form_data = b"ATTD" + arow_chunk + disp_chunk + inner_form  # 4 + 12 + 12 + 24 = 52
    outer_form = b"FORM" + struct.pack('>I', len(outer_form_data)) + outer_form_data  # 8 + 52 = 60

    write("test_iff.bin", outer_form)

    # Also generate a CAT container test
    # CAT containing two FORMs
    form1_data = b"TYPX" + b"DATA" + struct.pack('>I', 2) + b"\xAA\xBB" + b"\x00"  # odd pad
    form1 = b"FORM" + struct.pack('>I', len(form1_data)) + form1_data  # 8 + 15 = 23 bytes + 1 pad = 24 total in cat
    form2_data = b"TYPY" + b"DATA" + struct.pack('>I', 4) + b"\xCC\xDD\xEE\xFF"
    form2 = b"FORM" + struct.pack('>I', len(form2_data)) + form2_data  # 8 + 12 = 20 bytes

    # CAT size includes subtype + children (account for padding of form1 which is odd-sized: 8+15=23, pad to 24)
    cat_data = b"TYPX" + form1 + b"\x00" + form2  # subtype + form1(23) + pad(1) + form2(20) = 4+23+1+20 = 48
    cat = b"CAT " + struct.pack('>I', len(cat_data)) + cat_data

    write("test_iff_cat.bin", cat)


def gen_pal_file():
    """Generate a test PAL file (4-byte header + 768 bytes of 6-bit RGB data).

    Layout:
        Entry 0: black (0, 0, 0)
        Entry 1: bright red (63, 0, 0)
        Entry 2: bright green (0, 63, 0)
        Entry 3: bright blue (0, 0, 63)
        Entry 4: medium gray (32, 32, 32)
        Entries 5-254: black (0, 0, 0)
        Entry 255: white (63, 63, 63)
    """
    data = bytearray()
    # 4-byte header/flags
    data += b'\x00\x01\x00\x00'

    # 256 RGB entries (3 bytes each, VGA 6-bit values 0-63)
    colors = [(0, 0, 0)] * 256
    colors[0] = (0, 0, 0)       # black
    colors[1] = (63, 0, 0)      # bright red
    colors[2] = (0, 63, 0)      # bright green
    colors[3] = (0, 0, 63)      # bright blue
    colors[4] = (32, 32, 32)    # medium gray
    colors[255] = (63, 63, 63)  # white

    for r, g, b in colors:
        data += bytes([r, g, b])

    assert len(data) == 772, f"PAL file should be 772 bytes, got {len(data)}"
    write("test_pal.bin", bytes(data))


def gen_sprite_rle():
    """Generate test RLE sprite fixtures.

    Fixture 1: test_sprite_even.bin - 4x4 sprite using only even-key (raw) encoding.
    Header: X2=3, X1=0, Y1=0, Y2=3 => width=0+3+1=4, height=0+3+1=4
    All 4 rows use even-key encoding (raw pixel runs).
    Expected pixels (row-major):
        Row 0: [1, 2, 3, 4]
        Row 1: [5, 6, 7, 8]
        Row 2: [9, 10, 11, 12]
        Row 3: [13, 14, 15, 16]

    Fixture 2: test_sprite_odd.bin - 4x4 sprite using odd-key (sub-encoded) runs.
    Header: X2=3, X1=0, Y1=0, Y2=3 => width=0+3+1=4, height=0+3+1=4
    Row 0: odd key with repeat sub-byte (4 pixels of color 5)
    Row 1: odd key with literal sub-byte (4 individual colors)
    Row 2: odd key with mixed sub-bytes (2 literal + 2 repeat)
    Row 3: odd key with repeat sub-byte (4 pixels of color 20)
    Expected pixels:
        Row 0: [5, 5, 5, 5]
        Row 1: [10, 11, 12, 13]
        Row 2: [30, 31, 40, 40]
        Row 3: [20, 20, 20, 20]

    Fixture 3: test_sprite_offset.bin - 6x2 sprite with non-zero X offsets (sparse).
    Header: X2=5, X1=0, Y1=0, Y2=1 => width=0+5+1=6, height=0+1+1=2
    Row 0: 3 pixels starting at x=1
    Row 1: 2 pixels starting at x=2
    Expected pixels:
        Row 0: [0, 15, 16, 17, 0, 0]
        Row 1: [0, 0, 20, 21, 0, 0]
    """
    # --- Fixture 1: Even-key only ---
    data = bytearray()
    # Header: X2=3, X1=0, Y1=0, Y2=3 (all i16 LE) → width=4, height=4
    data += struct.pack('<hhhh', 3, 0, 0, 3)
    # Row 0: even key=8 (8/2=4 pixels), x=0, y=0, raw pixels [1,2,3,4]
    data += struct.pack('<HHH', 8, 0, 0) + bytes([1, 2, 3, 4])
    # Row 1: even key=8, x=0, y=1, raw pixels [5,6,7,8]
    data += struct.pack('<HHH', 8, 0, 1) + bytes([5, 6, 7, 8])
    # Row 2: even key=8, x=0, y=2, raw pixels [9,10,11,12]
    data += struct.pack('<HHH', 8, 0, 2) + bytes([9, 10, 11, 12])
    # Row 3: even key=8, x=0, y=3, raw pixels [13,14,15,16]
    data += struct.pack('<HHH', 8, 0, 3) + bytes([13, 14, 15, 16])
    # Terminator
    data += struct.pack('<H', 0)
    write("test_sprite_even.bin", bytes(data))

    # --- Fixture 2: Odd-key (sub-encoded) ---
    data = bytearray()
    # Header: X2=3, X1=0, Y1=0, Y2=3 → width=4, height=4
    data += struct.pack('<hhhh', 3, 0, 0, 3)
    # Row 0: odd key=9 (9/2=4 pixels), x=0, y=0
    #   Sub: odd byte 9 (9/2=4 repeat), color 5 => [5,5,5,5]
    data += struct.pack('<HHH', 9, 0, 0) + bytes([9, 5])
    # Row 1: odd key=9 (9/2=4 pixels), x=0, y=1
    #   Sub: even byte 8 (8/2=4 literal), colors [10,11,12,13]
    data += struct.pack('<HHH', 9, 0, 1) + bytes([8, 10, 11, 12, 13])
    # Row 2: odd key=9 (9/2=4 pixels), x=0, y=2
    #   Sub: even byte 4 (4/2=2 literal), colors [30,31]
    #   Sub: odd byte 5 (5/2=2 repeat), color 40
    data += struct.pack('<HHH', 9, 0, 2) + bytes([4, 30, 31, 5, 40])
    # Row 3: odd key=9 (9/2=4 pixels), x=0, y=3
    #   Sub: odd byte 9 (9/2=4 repeat), color 20 => [20,20,20,20]
    data += struct.pack('<HHH', 9, 0, 3) + bytes([9, 20])
    # Terminator
    data += struct.pack('<H', 0)
    write("test_sprite_odd.bin", bytes(data))

    # --- Fixture 3: Sparse with X offsets ---
    data = bytearray()
    # Header: X2=5, X1=0, Y1=0, Y2=1 → width=6, height=2
    data += struct.pack('<hhhh', 5, 0, 0, 1)
    # Row 0: even key=6 (6/2=3 pixels), x=1, y=0, raw [15,16,17]
    data += struct.pack('<HHH', 6, 1, 0) + bytes([15, 16, 17])
    # Row 1: even key=4 (4/2=2 pixels), x=2, y=1, raw [20,21]
    data += struct.pack('<HHH', 4, 2, 1) + bytes([20, 21])
    # Terminator
    data += struct.pack('<H', 0)
    write("test_sprite_offset.bin", bytes(data))


def gen_shp_file():
    """Generate test SHP (shape/font) file fixtures.

    SHP format:
        Offset 0x0000: u32 LE - total file size
        Offset 0x0004: var   - offset table (u32 LE entries pointing to sprite data)
        ...           : var   - RLE-encoded sprite data

    Number of sprites = (first_offset - 4) / 4

    Fixture 1: test_shp.bin - SHP with 3 sprites
        Sprite 0: 4x4 even-key sprite with pixels [1..16]
        Sprite 1: 2x2 even-key sprite with pixels [0xAA,0xBB,0xCC,0xDD]
        Sprite 2: 3x2 even-key sprite with pixels in specific pattern
    """
    # Build sprite data first, then compute offsets

    # Sprite 0: 4x4 even-key (same pattern as test_sprite_even.bin)
    s0 = bytearray()
    s0 += struct.pack('<hhhh', 3, 0, 0, 3)  # header: width=4, height=4
    s0 += struct.pack('<HHH', 8, 0, 0) + bytes([1, 2, 3, 4])
    s0 += struct.pack('<HHH', 8, 0, 1) + bytes([5, 6, 7, 8])
    s0 += struct.pack('<HHH', 8, 0, 2) + bytes([9, 10, 11, 12])
    s0 += struct.pack('<HHH', 8, 0, 3) + bytes([13, 14, 15, 16])
    s0 += struct.pack('<H', 0)  # terminator

    # Sprite 1: 2x2 even-key
    s1 = bytearray()
    s1 += struct.pack('<hhhh', 1, 0, 0, 1)  # header: width=0+1+1=2, height=0+1+1=2
    s1 += struct.pack('<HHH', 4, 0, 0) + bytes([0xAA, 0xBB])
    s1 += struct.pack('<HHH', 4, 0, 1) + bytes([0xCC, 0xDD])
    s1 += struct.pack('<H', 0)  # terminator

    # Sprite 2: 3x2 even-key
    s2 = bytearray()
    s2 += struct.pack('<hhhh', 2, 0, 0, 1)  # header: width=0+2+1=3, height=0+1+1=2
    s2 += struct.pack('<HHH', 6, 0, 0) + bytes([10, 20, 30])
    s2 += struct.pack('<HHH', 6, 0, 1) + bytes([40, 50, 60])
    s2 += struct.pack('<H', 0)  # terminator

    # Layout: [file_size(4)] [off0(4)] [off1(4)] [off2(4)] [s0] [s1] [s2]
    header_size = 4 + 3 * 4  # file_size + 3 offsets = 16 bytes
    off0 = header_size
    off1 = off0 + len(s0)
    off2 = off1 + len(s1)
    total_size = off2 + len(s2)

    data = bytearray()
    data += struct.pack('<I', total_size)
    data += struct.pack('<I', off0)
    data += struct.pack('<I', off1)
    data += struct.pack('<I', off2)
    data += s0 + s1 + s2

    assert len(data) == total_size, f"SHP size mismatch: {len(data)} != {total_size}"
    write("test_shp.bin", bytes(data))

    # Fixture 2: test_shp_single.bin - SHP with just 1 sprite (edge case)
    s_single = bytearray()
    s_single += struct.pack('<hhhh', 1, 0, 0, 1)  # width=0+1+1=2, height=0+1+1=2
    s_single += struct.pack('<HHH', 4, 0, 0) + bytes([0xFF, 0xFE])
    s_single += struct.pack('<HHH', 4, 0, 1) + bytes([0xFD, 0xFC])
    s_single += struct.pack('<H', 0)

    single_header = 4 + 1 * 4  # file_size + 1 offset = 8 bytes
    single_off = single_header
    single_total = single_off + len(s_single)

    data2 = bytearray()
    data2 += struct.pack('<I', single_total)
    data2 += struct.pack('<I', single_off)
    data2 += s_single

    assert len(data2) == single_total
    write("test_shp_single.bin", bytes(data2))


def gen_pak_file():
    """Generate test PAK file fixtures.

    PAK format:
        Offset 0x0000: u32 LE - total file size
        Offset 0x0004: var   - offset table (3-byte LE offset + 1-byte marker each)
        ...           : var   - resource data

    Marker bytes: 0xE0 = data, 0xC1 = sub-table, 0x00 = end of table

    Fixture 1: test_pak.bin - PAK with 3 direct (E0) resources
        Resource 0: 8 bytes [0x01..0x08]
        Resource 1: 6 bytes [0xAA..0xAF]
        Resource 2: 6 bytes [0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA]

    Fixture 2: test_pak_l2.bin - PAK with L2 sub-tables
        L1 entry 0: C1 sub-table with 2 sub-resources
        L1 entry 1: E0 direct resource
    """
    # --- Fixture 1: Simple PAK, 3 direct E0 entries ---
    # Layout: [file_size(4)] [3 entries(12)] [terminator(4)] [res0(8)] [res1(6)] [res2(6)]
    # Offsets:  0              4               16              20        28        34
    # Total: 40 bytes
    data = bytearray()
    data += struct.pack('<I', 40)                          # file_size = 40
    data += bytes([20, 0, 0, 0xE0])                        # entry 0: offset=20, E0
    data += bytes([28, 0, 0, 0xE0])                        # entry 1: offset=28, E0
    data += bytes([34, 0, 0, 0xE0])                        # entry 2: offset=34, E0
    data += bytes([0, 0, 0, 0])                            # terminator
    data += bytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])  # resource 0
    data += bytes([0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF])              # resource 1
    data += bytes([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA])              # resource 2

    assert len(data) == 40, f"PAK size mismatch: {len(data)} != 40"
    write("test_pak.bin", bytes(data))

    # --- Fixture 2: PAK with L2 sub-tables ---
    # Layout: [file_size(4)] [2 L1 entries(8)] [terminator(4)]
    #         [2 L2 entries(8)] [terminator(4)]
    #         [sub-res0(8)] [sub-res1(4)] [direct-res(12)]
    # Offsets:  0             4              12
    #           16            16              24
    #           28            36              40
    # Total: 52 bytes
    data = bytearray()
    data += struct.pack('<I', 52)                          # file_size = 52
    data += bytes([16, 0, 0, 0xC1])                        # L1 entry 0: sub-table at 16
    data += bytes([40, 0, 0, 0xE0])                        # L1 entry 1: data at 40
    data += bytes([0, 0, 0, 0])                            # L1 terminator
    # Sub-table at offset 16:
    data += bytes([28, 0, 0, 0xE0])                        # L2 entry 0: data at 28
    data += bytes([36, 0, 0, 0xE0])                        # L2 entry 1: data at 36
    data += bytes([0, 0, 0, 0])                            # L2 terminator
    # Resource data:
    data += bytes([0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])  # sub-res 0 (8 bytes)
    data += bytes([0x21, 0x22, 0x23, 0x24])                            # sub-res 1 (4 bytes)
    data += bytes([0x31, 0x32, 0x33, 0x34, 0x35, 0x36,                # direct res (12 bytes)
                   0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C])

    assert len(data) == 52, f"PAK L2 size mismatch: {len(data)} != 52"
    write("test_pak_l2.bin", bytes(data))


def gen_pak_noend():
    """Generate PAK file with no explicit 0x00 end marker.

    Many real PAK files have offset tables that butt directly against data,
    with no terminator. The table ends when pos reaches the first data offset.

    Fixture: test_pak_noend.bin - 3 E0 entries, no 0x00 terminator
        Table: [off0 E0][off1 E0][off2 E0] -> data starts immediately after
    """
    # Layout: [file_size(4)] [3 entries(12)] [res0(6)] [res1(4)] [res2(8)]
    # Offsets:  0              4               16        22        26
    # Total: 34 bytes
    data = bytearray()
    data += struct.pack('<I', 34)                          # file_size = 34
    data += bytes([16, 0, 0, 0xE0])                        # entry 0: offset=16, E0
    data += bytes([22, 0, 0, 0xE0])                        # entry 1: offset=22, E0
    data += bytes([26, 0, 0, 0xE0])                        # entry 2: offset=26, E0
    # No terminator! Data starts right here at offset 16
    data += bytes([0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6])   # resource 0 (6 bytes)
    data += bytes([0xB1, 0xB2, 0xB3, 0xB4])                # resource 1 (4 bytes)
    data += bytes([0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8])  # resource 2 (8 bytes)

    assert len(data) == 34, f"PAK noend size mismatch: {len(data)} != 34"
    write("test_pak_noend.bin", bytes(data))


def gen_pak_ff_marker():
    """Generate PAK file with 0xFF unused/sentinel markers.

    SPEECH.PAK uses 0xFF markers for unused slots that should be skipped.

    Fixture: test_pak_ff.bin - E0 entries with FF entries interspersed
    """
    # Layout: [file_size(4)] [off0 E0][off1 FF][off2 E0][terminator] [res0(4)] [res1(4)]
    # Offsets:  0              4        8        12       16           20        24
    # Total: 28 bytes
    data = bytearray()
    data += struct.pack('<I', 28)                          # file_size = 28
    data += bytes([20, 0, 0, 0xE0])                        # entry 0: offset=20, E0
    data += bytes([20, 0, 0, 0xFF])                        # entry 1: offset=20, FF (unused)
    data += bytes([24, 0, 0, 0xE0])                        # entry 2: offset=24, E0
    data += bytes([0, 0, 0, 0])                            # terminator
    data += bytes([0xD1, 0xD2, 0xD3, 0xD4])                # resource 0 (4 bytes)
    data += bytes([0xE1, 0xE2, 0xE3, 0xE4])                # resource 1 (4 bytes)

    assert len(data) == 28, f"PAK FF size mismatch: {len(data)} != 28"
    write("test_pak_ff.bin", bytes(data))


def gen_voc_file():
    """Generate test VOC (Creative Voice File) fixtures.

    VOC format:
        Offset 0x0000: 19 bytes - "Creative Voice File" + 0x1A
        Offset 0x0014: u16 LE  - data offset (from start of file to first data block)
        Offset 0x0016: u16 LE  - version number (e.g. 0x010A = 1.10)
        Offset 0x0018: u16 LE  - validity check (~version + 0x1234)
        Data blocks follow:
            Type 0x00: Terminator
            Type 0x01: Sound data
                3 bytes LE: block size (not counting type+size bytes)
                1 byte: frequency divisor (sr = 1000000 / (256 - divisor))
                1 byte: codec (0 = 8-bit unsigned PCM)
                N bytes: PCM audio data
            Type 0x02: Sound data continuation
                3 bytes LE: block size
                N bytes: PCM audio data

    Fixture 1: test_voc.bin - Simple VOC with one sound data block
        11025 Hz, 8-bit unsigned PCM, 16 samples of a simple waveform

    Fixture 2: test_voc_multi.bin - VOC with two sound data blocks
        Block 1: 8 samples of PCM data
        Block 2 (continuation): 8 more samples
    """
    # --- Fixture 1: Simple single-block VOC ---
    data = bytearray()
    # Header
    data += b"Creative Voice File\x1a"       # 20 bytes: signature
    data += struct.pack('<H', 26)             # data offset = 26 (standard)
    data += struct.pack('<H', 0x010A)         # version 1.10
    data += struct.pack('<H', (~0x010A + 0x1234) & 0xFFFF)  # validity check

    # Sound data block (type 1)
    pcm_samples = bytes([128, 160, 192, 224, 255, 224, 192, 160,
                         128, 96, 64, 32, 0, 32, 64, 96])   # 16 samples
    block_size = 2 + len(pcm_samples)  # freq_divisor(1) + codec(1) + samples
    data += bytes([0x01])                                    # block type
    data += struct.pack('<I', block_size)[:3]                # 3-byte LE size
    # Frequency divisor: sr = 1000000 / (256 - divisor) => divisor = 256 - 1000000/11025 ≈ 165
    freq_divisor = 256 - (1000000 // 11025)                  # = 165
    data += bytes([freq_divisor])                            # frequency divisor
    data += bytes([0x00])                                    # codec = 8-bit unsigned PCM
    data += pcm_samples

    # Terminator
    data += bytes([0x00])

    write("test_voc.bin", bytes(data))

    # --- Fixture 2: Multi-block VOC (type 1 + type 2 continuation) ---
    data = bytearray()
    # Header
    data += b"Creative Voice File\x1a"
    data += struct.pack('<H', 26)
    data += struct.pack('<H', 0x010A)
    data += struct.pack('<H', (~0x010A + 0x1234) & 0xFFFF)

    # Block 1: Sound data (type 1) with 8 samples
    pcm1 = bytes([128, 160, 192, 224, 255, 224, 192, 160])
    block1_size = 2 + len(pcm1)
    data += bytes([0x01])
    data += struct.pack('<I', block1_size)[:3]
    data += bytes([freq_divisor])
    data += bytes([0x00])
    data += pcm1

    # Block 2: Sound continuation (type 2) with 8 more samples
    pcm2 = bytes([128, 96, 64, 32, 0, 32, 64, 96])
    block2_size = len(pcm2)
    data += bytes([0x02])
    data += struct.pack('<I', block2_size)[:3]
    data += pcm2

    # Terminator
    data += bytes([0x00])

    write("test_voc_multi.bin", bytes(data))


def lzw_compress(raw_data):
    """LZW compress data using the same variant as WC:Privateer VPK files.

    9-12 bit variable-width codes, LSB-first packing.
    Code 256 = clear, 257 = end.
    """
    CLEAR = 256
    END = 257
    FIRST_CODE = 258

    # Initialize dictionary with single-byte entries
    dictionary = {bytes([i]): i for i in range(256)}
    next_code = FIRST_CODE
    code_size = 9

    codes = [CLEAR]  # always start with clear code

    w = b""
    for byte in raw_data:
        wc = w + bytes([byte])
        if wc in dictionary:
            w = wc
        else:
            codes.append(dictionary[w])
            if next_code < 4096:
                dictionary[wc] = next_code
                next_code += 1
                if next_code > (1 << code_size) - 1 and code_size < 12:
                    code_size += 1
            w = bytes([byte])
    if w:
        codes.append(dictionary[w])
    codes.append(END)

    # Pack codes into bytes (LSB-first bit packing)
    output = bytearray()
    bit_buf = 0
    bits_in_buf = 0
    code_size = 9
    next_code = FIRST_CODE

    for code in codes:
        if code == CLEAR:
            # Reset code size for encoding
            code_size = 9
            next_code = FIRST_CODE
            bit_buf |= (code << bits_in_buf)
            bits_in_buf += code_size
            while bits_in_buf >= 8:
                output.append(bit_buf & 0xFF)
                bit_buf >>= 8
                bits_in_buf -= 8
            continue
        if code == END:
            bit_buf |= (code << bits_in_buf)
            bits_in_buf += code_size
            while bits_in_buf > 0:
                output.append(bit_buf & 0xFF)
                bit_buf >>= 8
                bits_in_buf -= 8
            break

        bit_buf |= (code << bits_in_buf)
        bits_in_buf += code_size
        while bits_in_buf >= 8:
            output.append(bit_buf & 0xFF)
            bit_buf >>= 8
            bits_in_buf -= 8

        # Track dictionary growth for code_size changes
        if next_code < 4096:
            next_code += 1
            if next_code > (1 << code_size) - 1 and code_size < 12:
                code_size += 1

    return bytes(output)


def gen_vpk_file():
    """Generate test VPK (voice pack) file fixtures.

    VPK format:
        Offset 0x0000: u32 LE - total file size
        Offset 0x0004: var   - offset table (u32 LE: low 24 bits = offset, high 8 bits = 0x20 marker)
        ...           : var   - entry data (u32 LE decompressed_size + LZW compressed data)

    Number of entries = (first_data_offset - 4) / 4

    Each entry decompresses to a Creative Voice File (VOC).

    Fixture 1: test_vpk.bin - VPK with 2 entries
        Entry 0: short VOC (8 samples)
        Entry 1: short VOC (4 samples)

    Fixture 2: test_vpk_single.bin - VPK with 1 entry (edge case)
    """
    def make_voc(pcm_samples):
        """Build a minimal VOC file from raw PCM samples."""
        voc = bytearray()
        voc += b"Creative Voice File\x1a"
        voc += struct.pack('<H', 26)          # data_offset
        voc += struct.pack('<H', 0x010A)      # version 1.10
        voc += struct.pack('<H', (~0x010A + 0x1234) & 0xFFFF)  # validity
        # Sound data block (type 1)
        block_size = 2 + len(pcm_samples)
        voc += bytes([0x01])
        voc += struct.pack('<I', block_size)[:3]
        freq_divisor = 256 - (1000000 // 11025)  # = 165
        voc += bytes([freq_divisor, 0x00])    # freq_div, codec=PCM
        voc += pcm_samples
        voc += bytes([0x00])                  # terminator
        return bytes(voc)

    # --- Fixture 1: VPK with 2 entries ---
    voc0 = make_voc(bytes([128, 160, 192, 224, 255, 224, 192, 160]))
    voc1 = make_voc(bytes([64, 96, 128, 96]))

    compressed0 = lzw_compress(voc0)
    compressed1 = lzw_compress(voc1)

    # Entry data: u32 decompressed_size + compressed bytes
    entry0_data = struct.pack('<I', len(voc0)) + compressed0
    entry1_data = struct.pack('<I', len(voc1)) + compressed1

    # Layout: [file_size(4)] [offset0(4)] [offset1(4)] [entry0] [entry1]
    header_size = 4 + 2 * 4  # file_size + 2 offsets = 12
    off0 = header_size
    off1 = off0 + len(entry0_data)
    total_size = off1 + len(entry1_data)

    data = bytearray()
    data += struct.pack('<I', total_size)
    data += struct.pack('<I', off0 | (0x20 << 24))  # offset with 0x20 marker
    data += struct.pack('<I', off1 | (0x20 << 24))
    data += entry0_data
    data += entry1_data

    assert len(data) == total_size, f"VPK size mismatch: {len(data)} != {total_size}"
    write("test_vpk.bin", bytes(data))

    # --- Fixture 2: VPK with 1 entry ---
    voc_single = make_voc(bytes([128, 255, 128, 0, 128, 255]))
    compressed_single = lzw_compress(voc_single)
    entry_single = struct.pack('<I', len(voc_single)) + compressed_single

    single_header_size = 4 + 1 * 4  # file_size + 1 offset = 8
    single_off = single_header_size
    single_total = single_off + len(entry_single)

    data2 = bytearray()
    data2 += struct.pack('<I', single_total)
    data2 += struct.pack('<I', single_off | (0x20 << 24))
    data2 += entry_single

    assert len(data2) == single_total
    write("test_vpk_single.bin", bytes(data2))


def make_iff_chunk(tag, data):
    """Build an IFF leaf chunk with odd-byte padding."""
    chunk = tag + struct.pack('>I', len(data)) + data
    if len(data) % 2 == 1:
        chunk += b'\x00'  # pad to even boundary
    return chunk


def gen_xmidi_file():
    """Generate XMIDI (Extended MIDI) test fixtures.

    XMIDI structure (IFF-wrapped):
        FORM:XDIR
          INFO  (u16 LE: sequence count)
          CAT :XMID
            FORM:XMID  (per sequence)
              TIMB  (u16 LE: timbre count + count * {u8 patch, u8 bank})
              EVNT  (raw XMIDI event bytes)

    Fixture 1: test_xmidi.bin - Single-sequence XMIDI with 2 timbres
    Fixture 2: test_xmidi_multi.bin - Two-sequence XMIDI
    Fixture 3: test_xmidi_no_timb.bin - Single-sequence XMIDI without TIMB chunk
    Fixture 4: test_midi.bin - Standard MIDI file (MThd + MTrk)
    """
    # --- Fixture 1: Single-sequence XMIDI ---
    # EVNT data: minimal XMIDI events (end-of-track meta event)
    evnt_data = bytes([0xFF, 0x2F, 0x00])
    evnt_chunk = make_iff_chunk(b"EVNT", evnt_data)

    # TIMB data: 2 timbres (patch, bank pairs)
    timb_data = struct.pack('<H', 2) + bytes([0, 0, 10, 1])  # patch 0/bank 0, patch 10/bank 1
    timb_chunk = make_iff_chunk(b"TIMB", timb_data)

    # FORM:XMID
    xmid_content = b"XMID" + timb_chunk + evnt_chunk
    xmid_form = b"FORM" + struct.pack('>I', len(xmid_content)) + xmid_content

    # CAT:XMID
    cat_content = b"XMID" + xmid_form
    cat_chunk = b"CAT " + struct.pack('>I', len(cat_content)) + cat_content

    # INFO chunk (1 sequence, u16 LE)
    info_data = struct.pack('<H', 1)
    info_chunk = make_iff_chunk(b"INFO", info_data)

    # FORM:XDIR (root)
    xdir_content = b"XDIR" + info_chunk + cat_chunk
    root = b"FORM" + struct.pack('>I', len(xdir_content)) + xdir_content

    write("test_xmidi.bin", root)

    # --- Fixture 2: Multi-sequence XMIDI ---
    evnt2_data = bytes([0x90, 48, 80, 24, 0xFF, 0x2F, 0x00])
    evnt2_chunk = make_iff_chunk(b"EVNT", evnt2_data)
    timb2_data = struct.pack('<H', 1) + bytes([5, 0])
    timb2_chunk = make_iff_chunk(b"TIMB", timb2_data)

    xmid2_content = b"XMID" + timb2_chunk + evnt2_chunk
    xmid2_form = b"FORM" + struct.pack('>I', len(xmid2_content)) + xmid2_content

    # CAT:XMID with 2 sequences
    cat2_content = b"XMID" + xmid_form + xmid2_form
    cat2 = b"CAT " + struct.pack('>I', len(cat2_content)) + cat2_content

    info2_data = struct.pack('<H', 2)
    info2_chunk = make_iff_chunk(b"INFO", info2_data)

    xdir2_content = b"XDIR" + info2_chunk + cat2
    root2 = b"FORM" + struct.pack('>I', len(xdir2_content)) + xdir2_content

    write("test_xmidi_multi.bin", root2)

    # --- Fixture 3: XMIDI without TIMB ---
    evnt3_chunk = make_iff_chunk(b"EVNT", bytes([0xFF, 0x2F, 0x00]))
    xmid3_content = b"XMID" + evnt3_chunk
    xmid3_form = b"FORM" + struct.pack('>I', len(xmid3_content)) + xmid3_content
    cat3_content = b"XMID" + xmid3_form
    cat3 = b"CAT " + struct.pack('>I', len(cat3_content)) + cat3_content
    info3_chunk = make_iff_chunk(b"INFO", struct.pack('<H', 1))
    xdir3_content = b"XDIR" + info3_chunk + cat3
    root3 = b"FORM" + struct.pack('>I', len(xdir3_content)) + xdir3_content

    write("test_xmidi_no_timb.bin", root3)

    # --- Fixture 4: Standard MIDI file ---
    # MThd: format=1, tracks=1, division=120 ticks/quarter-note
    mthd_data = struct.pack('>HHH', 1, 1, 120)
    mthd = b"MThd" + struct.pack('>I', len(mthd_data)) + mthd_data
    # MTrk: delta=0 + end-of-track meta event
    mtrk_events = bytes([0x00, 0xFF, 0x2F, 0x00])
    mtrk = b"MTrk" + struct.pack('>I', len(mtrk_events)) + mtrk_events

    write("test_midi.bin", mthd + mtrk)


def gen_font_file():
    """Generate test font SHP file fixture for text rendering.

    A minimal font with 3 glyphs mapped to 'A'=65, 'B'=66, 'C'=67.
    Each glyph uses color index 1 for opaque pixels, 0 for transparent.

    Glyph 'A' (3x3):
        .#.    Row 0: [0, 1, 0]
        ###    Row 1: [1, 1, 1]
        #.#    Row 2: [1, 0, 1]

    Glyph 'B' (2x3):
        ##     Row 0: [1, 1]
        #.     Row 1: [1, 0]
        ##     Row 2: [1, 1]

    Glyph 'C' (4x3):
        ####   Row 0: [1, 1, 1, 1]
        #...   Row 1: [1, 0, 0, 0]
        ####   Row 2: [1, 1, 1, 1]
    """
    # Glyph A: 3x3 (x2=2, x1=0 -> w=0+2+1=3; y1=0, y2=2 -> h=0+2+1=3)
    ga = bytearray()
    ga += struct.pack('<hhhh', 2, 0, 0, 2)
    ga += struct.pack('<HHH', 6, 0, 0) + bytes([0, 1, 0])
    ga += struct.pack('<HHH', 6, 0, 1) + bytes([1, 1, 1])
    ga += struct.pack('<HHH', 6, 0, 2) + bytes([1, 0, 1])
    ga += struct.pack('<H', 0)

    # Glyph B: 2x3 (x2=1, x1=0 -> w=0+1+1=2; y1=0, y2=2 -> h=0+2+1=3)
    gb = bytearray()
    gb += struct.pack('<hhhh', 1, 0, 0, 2)
    gb += struct.pack('<HHH', 4, 0, 0) + bytes([1, 1])
    gb += struct.pack('<HHH', 4, 0, 1) + bytes([1, 0])
    gb += struct.pack('<HHH', 4, 0, 2) + bytes([1, 1])
    gb += struct.pack('<H', 0)

    # Glyph C: 4x3 (x2=3, x1=0 -> w=0+3+1=4; y1=0, y2=2 -> h=0+2+1=3)
    gc = bytearray()
    gc += struct.pack('<hhhh', 3, 0, 0, 2)
    gc += struct.pack('<HHH', 8, 0, 0) + bytes([1, 1, 1, 1])
    gc += struct.pack('<HHH', 8, 0, 1) + bytes([1, 0, 0, 0])
    gc += struct.pack('<HHH', 8, 0, 2) + bytes([1, 1, 1, 1])
    gc += struct.pack('<H', 0)

    # SHP: [file_size(4)] [off0(4)] [off1(4)] [off2(4)] [ga] [gb] [gc]
    header_size = 4 + 3 * 4  # 16
    off0 = header_size
    off1 = off0 + len(ga)
    off2 = off1 + len(gb)
    total = off2 + len(gc)

    data = bytearray()
    data += struct.pack('<I', total)
    data += struct.pack('<I', off0)
    data += struct.pack('<I', off1)
    data += struct.pack('<I', off2)
    data += ga + gb + gc

    assert len(data) == total, f"Font SHP size mismatch: {len(data)} != {total}"
    write("test_font.bin", bytes(data))


def make_iff_form(form_type, children_bytes):
    """Build an IFF FORM container with correct size calculation."""
    body = form_type + children_bytes
    return b"FORM" + struct.pack('>I', len(body)) + body


def gen_gameflow_file():
    """Generate test GAMEFLOW fixture (FORM:GAME with FORM:MISS rooms).

    GAMEFLOW.IFF structure:
        FORM:GAME
          FORM:MISS  (per room type)
            INFO (1 byte: room type ID)
            TUNE (1 byte: music track)
            EFCT (2 bytes: sound effects)
            FORM:SCEN  (per scene in room)
              INFO (1 byte: scene ID)
              FORM:SPRT  (per interactive sprite)
                INFO (1 byte: sprite ID)
                EFCT (N bytes: effect data)
                [REQU] (optional: requirements)

    Fixture: test_gameflow.bin - 2 rooms, 3 scenes, 5 sprites
        Room 0 (type=0x01): 2 scenes
          Scene 0: 2 sprites (IDs 1, 2)
          Scene 1: 1 sprite (ID 3)
        Room 1 (type=0x02): 1 scene
          Scene 0: 2 sprites (ID 4, ID 5 with requirements)
    """
    # Build from inside out

    # --- Room 0, Scene 0: 2 sprites ---
    sprt0_0 = make_iff_form(b"SPRT",
               make_iff_chunk(b"INFO", bytes([0x01]))
               + make_iff_chunk(b"EFCT", bytes([0x10, 0x20])))
    sprt0_1 = make_iff_form(b"SPRT",
               make_iff_chunk(b"INFO", bytes([0x02]))
               + make_iff_chunk(b"EFCT", bytes([0x30, 0x40])))
    scen0_0 = make_iff_form(b"SCEN",
               make_iff_chunk(b"INFO", bytes([0x00])) + sprt0_0 + sprt0_1)

    # --- Room 0, Scene 1: 1 sprite ---
    sprt1_0 = make_iff_form(b"SPRT",
               make_iff_chunk(b"INFO", bytes([0x03]))
               + make_iff_chunk(b"EFCT", bytes([0x50])))
    scen0_1 = make_iff_form(b"SCEN",
               make_iff_chunk(b"INFO", bytes([0x01])) + sprt1_0)

    miss0 = make_iff_form(b"MISS",
              make_iff_chunk(b"INFO", bytes([0x01]))
              + make_iff_chunk(b"TUNE", bytes([0x03]))
              + make_iff_chunk(b"EFCT", bytes([0x05, 0x0A]))
              + scen0_0 + scen0_1)

    # --- Room 1, Scene 0: 2 sprites (one with requirements) ---
    sprt2_0 = make_iff_form(b"SPRT",
               make_iff_chunk(b"INFO", bytes([0x04]))
               + make_iff_chunk(b"EFCT", bytes([0x60, 0x70])))
    sprt2_1 = make_iff_form(b"SPRT",
               make_iff_chunk(b"INFO", bytes([0x05]))
               + make_iff_chunk(b"EFCT", bytes([0x80, 0x90]))
               + make_iff_chunk(b"REQU", bytes([0x01, 0x02, 0x03, 0x04])))
    scen1_0 = make_iff_form(b"SCEN",
               make_iff_chunk(b"INFO", bytes([0x00])) + sprt2_0 + sprt2_1)

    miss1 = make_iff_form(b"MISS",
              make_iff_chunk(b"INFO", bytes([0x02]))
              + make_iff_chunk(b"TUNE", bytes([0x07]))
              + make_iff_chunk(b"EFCT", bytes([0x0B, 0x0C]))
              + scen1_0)

    # --- Root FORM:GAME ---
    root = make_iff_form(b"GAME", miss0 + miss1)

    write("test_gameflow.bin", root)


def gen_midgame_pak():
    """Generate test midgame animation PAK fixture.

    A PAK file with 3 resources representing animation frames.
    Each resource is a minimal scene pack (4-byte size + offset table + sprite).
    This simulates a landing/launch sequence with 3 frames.

    Frame 0: 2x2 sprite with pixels [10, 11, 12, 13]
    Frame 1: 2x2 sprite with pixels [20, 21, 22, 23]
    Frame 2: 2x2 sprite with pixels [30, 31, 32, 33]
    """
    def make_scene_pack_frame(pixels):
        """Build a minimal scene pack with one 2x2 sprite."""
        # Sprite: header(8) + row0(8) + row1(8) + terminator(2) = 26 bytes
        sprite = bytearray()
        sprite += struct.pack('<hhhh', 1, 0, 0, 1)  # width=0+1+1=2, height=0+1+1=2
        sprite += struct.pack('<HHH', 4, 0, 0) + bytes([pixels[0], pixels[1]])
        sprite += struct.pack('<HHH', 4, 0, 1) + bytes([pixels[2], pixels[3]])
        sprite += struct.pack('<H', 0)  # terminator

        # Scene pack: size(4) + offset(4) + sprite data
        pack = bytearray()
        sprite_offset = 8  # after size + 1 offset entry
        total_size = 4 + 4 + len(sprite)
        pack += struct.pack('<I', total_size)       # declared size
        pack += struct.pack('<I', sprite_offset)    # offset to sprite 0
        pack += sprite
        return bytes(pack)

    frame0 = make_scene_pack_frame([10, 11, 12, 13])
    frame1 = make_scene_pack_frame([20, 21, 22, 23])
    frame2 = make_scene_pack_frame([30, 31, 32, 33])

    # PAK: [file_size(4)] [3 E0 entries(12)] [terminator(4)] [frame0] [frame1] [frame2]
    header_size = 4 + 3 * 4 + 4  # file_size + 3 entries + terminator = 20
    off0 = header_size
    off1 = off0 + len(frame0)
    off2 = off1 + len(frame1)
    total = off2 + len(frame2)

    data = bytearray()
    data += struct.pack('<I', total)
    data += bytes([off0 & 0xFF, (off0 >> 8) & 0xFF, (off0 >> 16) & 0xFF, 0xE0])
    data += bytes([off1 & 0xFF, (off1 >> 8) & 0xFF, (off1 >> 16) & 0xFF, 0xE0])
    data += bytes([off2 & 0xFF, (off2 >> 8) & 0xFF, (off2 >> 16) & 0xFF, 0xE0])
    data += bytes([0, 0, 0, 0])  # terminator
    data += frame0 + frame1 + frame2

    assert len(data) == total, f"Midgame PAK size mismatch: {len(data)} != {total}"
    write("test_midgame.bin", bytes(data))


def gen_quadrant_file():
    """Generate test QUADRANT.IFF fixture (FORM:UNIV with FORM:QUAD > FORM:SYST).

    Real QUADRANT.IFF format (from original game data analysis):
        FORM:UNIV
          INFO (1 byte: number of quadrants)
          FORM:QUAD (per quadrant)
            INFO (4+ bytes: x(i16 LE), y(i16 LE), name(null-terminated))
            FORM:SYST (per star system)
              INFO (5+ bytes: index(u8), x(i16 LE), y(i16 LE), name(null-terminated))
              [BASE] (optional: list of base indices, one byte each)

    Fixture: test_quadrant.bin - 2 quadrants, 5 systems total
        Quadrant 0 "Alpha" at (-50, 50): 3 systems
          System idx=0 "Troy" at (-30, 40), bases [0, 1]
          System idx=1 "Palan" at (-60, 20), no base
          System idx=2 "Oxford" at (-40, 70), base [2]
        Quadrant 1 "Beta" at (50, -50): 2 systems
          System idx=3 "Perry" at (30, -40), base [3]
          System idx=4 "Junction" at (60, -20), no base
    """
    def make_syst(index, x, y, name, base_indices=None):
        """Build a FORM:SYST with INFO and optional BASE chunk."""
        # INFO: index(u8), x(i16 LE), y(i16 LE), name(null-terminated)
        info_data = bytes([index])
        info_data += struct.pack('<h', x)  # i16 LE
        info_data += struct.pack('<h', y)  # i16 LE
        info_data += name.encode('ascii') + b'\x00'
        info = make_iff_chunk(b"INFO", info_data)
        children = info
        if base_indices is not None:
            # BASE: list of base indices (one byte each)
            children += make_iff_chunk(b"BASE", bytes(base_indices))
        return make_iff_form(b"SYST", children)

    def make_quad(x, y, name, systems_bytes):
        """Build a FORM:QUAD with INFO and SYST children."""
        # INFO: x(i16 LE), y(i16 LE), name(null-terminated)
        info_data = struct.pack('<h', x) + struct.pack('<h', y)
        info_data += name.encode('ascii') + b'\x00'
        info = make_iff_chunk(b"INFO", info_data)
        return make_iff_form(b"QUAD", info + systems_bytes)

    # Quadrant 0 "Alpha": 3 systems
    q0_systems = (
        make_syst(0, -30, 40, "Troy", base_indices=[0, 1]) +
        make_syst(1, -60, 20, "Palan") +
        make_syst(2, -40, 70, "Oxford", base_indices=[2])
    )
    quad0 = make_quad(-50, 50, "Alpha", q0_systems)

    # Quadrant 1 "Beta": 2 systems
    q1_systems = (
        make_syst(3, 30, -40, "Perry", base_indices=[3]) +
        make_syst(4, 60, -20, "Junction")
    )
    quad1 = make_quad(50, -50, "Beta", q1_systems)

    # Universe root: INFO + 2 quadrants
    univ_info = make_iff_chunk(b"INFO", bytes([0x02]))  # 2 quadrants
    root = make_iff_form(b"UNIV", univ_info + quad0 + quad1)

    write("test_quadrant.bin", root)


def gen_bases_file():
    """Generate test BASES.IFF fixture (FORM:BASE with DATA + INFO entries).

    Real BASES.IFF format:
        FORM:BASE
          DATA (N bytes: counts per base type)
          INFO (per base: index(u8), type(u8), name(null-terminated))

    Fixture: test_bases.bin - 4 bases
        Base 0: "Achilles" type 3 (mining)
        Base 1: "Helen" type 4 (refinery)
        Base 2: "Oxford" type 6 (unique)
        Base 3: "Perry Naval Base" type 6 (unique)
    """
    def make_base_info(index, base_type, name):
        data = bytes([index, base_type])
        data += name.encode('ascii') + b'\x00'
        return make_iff_chunk(b"INFO", data)

    # DATA chunk: 6 bytes (counts per base type 0-5, we just put placeholder)
    data_chunk = make_iff_chunk(b"DATA", bytes([0, 0, 0, 1, 1, 0]))

    bases = (
        make_base_info(0, 3, "Achilles") +
        make_base_info(1, 4, "Helen") +
        make_base_info(2, 6, "Oxford") +
        make_base_info(3, 6, "Perry Naval Base")
    )

    root = make_iff_form(b"BASE", data_chunk + bases)
    write("test_bases.bin", root)


def gen_nav_table():
    """Generate test TABLE.DAT fixture (distance matrix).

    Real TABLE.DAT format: N*N byte matrix where entry[i*N+j] is the
    jump distance from system i to system j. 0=self, 1=adjacent, 0xFF=unreachable.

    Fixture: test_table.bin - 5x5 matrix for 5 test systems
        System 0 (Troy) <-> System 1 (Palan): distance 1 (adjacent)
        System 0 (Troy) <-> System 2 (Oxford): distance 2
        System 1 (Palan) <-> System 2 (Oxford): distance 1 (adjacent)
        System 2 (Oxford) <-> System 3 (Perry): distance 1 (adjacent)
        System 3 (Perry) <-> System 4 (Junction): distance 1 (adjacent)
        System 0 <-> System 3: distance 3
        System 0 <-> System 4: distance 4
        System 1 <-> System 3: distance 2
        System 1 <-> System 4: distance 3
        System 2 <-> System 4: distance 2
    """
    N = 5
    # Initialize with 0xFF (unreachable) then fill in
    matrix = [0xFF] * (N * N)

    def set_dist(a, b, d):
        matrix[a * N + b] = d
        matrix[b * N + a] = d

    # Self distances
    for i in range(N):
        matrix[i * N + i] = 0

    # Adjacent pairs (distance 1)
    set_dist(0, 1, 1)  # Troy <-> Palan
    set_dist(1, 2, 1)  # Palan <-> Oxford
    set_dist(2, 3, 1)  # Oxford <-> Perry
    set_dist(3, 4, 1)  # Perry <-> Junction

    # Derived distances
    set_dist(0, 2, 2)  # Troy -> Palan -> Oxford
    set_dist(0, 3, 3)  # Troy -> Palan -> Oxford -> Perry
    set_dist(0, 4, 4)  # Troy -> ... -> Junction
    set_dist(1, 3, 2)  # Palan -> Oxford -> Perry
    set_dist(1, 4, 3)  # Palan -> Oxford -> Perry -> Junction
    set_dist(2, 4, 2)  # Oxford -> Perry -> Junction

    write("test_table.bin", bytes(matrix))


def gen_teams_file():
    """Generate test TEAMS.IFF fixture (FORM:TEAM with FRMN chunks).

    Real TEAMS.IFF format:
        FORM:TEAM
          FRMN (per faction: inter-faction disposition values as i16 LE pairs)

    Fixture: test_teams.bin - 3 factions (simplified)
        Faction 0 (Confed): neutral to self, friendly to Militia, hostile to Pirates
        Faction 1 (Militia): friendly to Confed, neutral to self, hostile to Pirates
        Faction 2 (Pirates): hostile to Confed, hostile to Militia, neutral to self
    """
    # Each FRMN chunk has pairs of i16 LE values for faction relationships
    # Format appears to be: disposition values toward each other faction
    def make_frmn(values):
        data = b''
        for v in values:
            data += struct.pack('<h', v)
        return make_iff_chunk(b"FRMN", data)

    frmn0 = make_frmn([0, 0, 0])       # Confed: neutral baseline
    frmn1 = make_frmn([800, 0, 0])      # Militia: friendly to Confed
    frmn2 = make_frmn([-800, -800, 0])  # Pirates: hostile to both

    root = make_iff_form(b"TEAM", frmn0 + frmn1 + frmn2)
    write("test_teams.bin", root)


def gen_cockpit_file():
    """Generate a minimal cockpit IFF fixture (FORM:COCK).

    Structure:
        FORM:COCK
          FORM:FRNT  (front view)
            SHAP  (4x4 RLE sprite - cockpit frame with transparent viewport)
            TPLT  (template: viewport rect as 4x u16 LE: x, y, w, h)
          FORM:RITE  (right view)
            SHAP  (4x4 RLE sprite)
            TPLT  (template)
          FORM:BACK  (rear view)
            SHAP  (4x4 RLE sprite)
            TPLT  (template)
          FORM:LEFT  (left view)
            SHAP  (4x4 RLE sprite)
            TPLT  (template)

    The SHAP chunk contains raw RLE sprite data (8-byte header + RLE data).
    The sprite is 4x4 with a transparent center pixel (simulating viewport).
    """
    def make_cockpit_sprite(color):
        """Build a 4x4 RLE sprite in scene pack format (size + offset table + sprite data)."""
        # First build the raw RLE sprite
        # Header: x2=1, x1=2, y1=2, y2=1 => width=2+1+1=4, height=2+1+1=4 (center-relative)
        # RLE coordinates are center-relative: x from -2 to +1, y from -2 to +1
        sprite = struct.pack('<hhhh', 1, 2, 2, 1)
        # Row 0 (y=-2): all opaque
        sprite += struct.pack('<Hhh', 8, -2, -2) + bytes([color, color, color, color])
        # Row 1 (y=-1): opaque, transparent, transparent, opaque
        sprite += struct.pack('<Hhh', 8, -2, -1) + bytes([color, 0, 0, color])
        # Row 2 (y=0): opaque, transparent, transparent, opaque
        sprite += struct.pack('<Hhh', 8, -2, 0) + bytes([color, 0, 0, color])
        # Row 3 (y=+1): all opaque
        sprite += struct.pack('<Hhh', 8, -2, 1) + bytes([color, color, color, color])
        # Terminator
        sprite += struct.pack('<H', 0)

        # Wrap in scene pack format: [declared_size:4][first_offset:4][sprite_data]
        first_offset = 8  # offset to sprite data within the scene pack
        declared_size = 4 + 4 + len(sprite)  # size + offset + sprite
        scene_pack = struct.pack('<II', declared_size, first_offset) + sprite
        return scene_pack

    # TPLT: viewport rectangle as 4x u16 LE (x=1, y=1, w=2, h=2)
    tplt_data = struct.pack('<HHHH', 1, 1, 2, 2)

    # Build views with different colors
    views = [
        (b"FRNT", 10),
        (b"RITE", 20),
        (b"BACK", 30),
        (b"LEFT", 40),
    ]

    children = b""
    for view_type, color in views:
        shap = make_iff_chunk(b"SHAP", make_cockpit_sprite(color))
        tplt = make_iff_chunk(b"TPLT", tplt_data)
        view = make_iff_form(view_type, shap + tplt)
        children += view

    root = make_iff_form(b"COCK", children)
    write("test_cockpit.bin", root)


def gen_mfd_file():
    """Generate a cockpit IFF with MFD data (CMFD, DIAL, CHUD) for MFD parser tests.

    Structure:
        FORM:COCK
          FORM:FRNT (minimal view with 4x4 sprite)
            SHAP
            TPLT
          FONT "PRIVFNT\\0"
          FORM:CMFD
            FORM:AMFD (left MFD)
              INFO (11 bytes): rect(36,6,115,70) + index=0, 0x1A, 0x6C
            FORM:AMFD (right MFD)
              INFO (11 bytes): rect(180,6,259,70) + index=1, 0x1A, 0x6C
            SOFT "SOFTWARE"
          FORM:CHUD
            HINF (17 bytes)
            FORM:HSFT
              FORM:TRGT
                INFO (7 bytes)
              FORM:CRSS
                SHAP (minimal 3x3 RLE crosshair)
              FORM:NAVI
                SHAP (minimal 3x3 RLE nav indicator)
          FORM:DIAL
            FORM:RADR
              INFO (8 bytes): rect(90,126,138,162)
            FORM:SHLD
              INFO (8 bytes): rect(170,126,218,162)
            FORM:ENER
              FORM:VIEW
                INFO (8 bytes): rect(155,35,168,59)
            FORM:FUEL
              FORM:VIEW
                INFO (8 bytes): rect(143,3,180,8)
            FORM:AUTO
              INFO (8 bytes): rect(146,14,177,19)
            FORM:SSPD
              INFO (8 bytes): rect(50,130,81,135)
              DATA (10 bytes): 00 00 00 00 "SET \\0" + pad
            FORM:ASPD
              INFO (8 bytes): rect(50,140,81,144)
              DATA (10 bytes): 00 00 00 00 "KPS \\0" + pad
          FORM:DAMG
            DAMG (4 bytes)
          FORM:CDMG
            EXPL (2 bytes)
    """
    # Minimal front view sprite (same as cockpit fixture)
    def make_cockpit_sprite(color):
        sprite = struct.pack('<hhhh', 1, 2, 2, 1)  # 4x4 center-relative
        sprite += struct.pack('<Hhh', 8, -2, -2) + bytes([color]*4)
        sprite += struct.pack('<Hhh', 8, -2, -1) + bytes([color, 0, 0, color])
        sprite += struct.pack('<Hhh', 8, -2, 0) + bytes([color, 0, 0, color])
        sprite += struct.pack('<Hhh', 8, -2, 1) + bytes([color]*4)
        sprite += struct.pack('<H', 0)
        first_offset = 8
        declared_size = 4 + 4 + len(sprite)
        return struct.pack('<II', declared_size, first_offset) + sprite

    # Minimal 3x3 RLE sprite for crosshair/nav indicators
    def make_tiny_sprite(color):
        sprite = struct.pack('<hhhh', 1, 1, 1, 1)  # 3x3 centered
        sprite += struct.pack('<Hhh', 6, -1, -1) + bytes([0, color, 0])
        sprite += struct.pack('<Hhh', 6, -1, 0) + bytes([color, color, color])
        sprite += struct.pack('<Hhh', 6, -1, 1) + bytes([0, color, 0])
        sprite += struct.pack('<H', 0)
        first_offset = 8
        declared_size = 4 + 4 + len(sprite)
        return struct.pack('<II', declared_size, first_offset) + sprite

    # Build front view
    tplt_data = struct.pack('<HHHH', 1, 1, 2, 2)
    frnt = make_iff_form(b"FRNT",
        make_iff_chunk(b"SHAP", make_cockpit_sprite(10)) +
        make_iff_chunk(b"TPLT", tplt_data))

    # FONT
    font = make_iff_chunk(b"FONT", b"PRIVFNT\x00")

    # CMFD: two MFD display areas
    amfd_left = make_iff_form(b"AMFD",
        make_iff_chunk(b"INFO",
            struct.pack('<HHHH', 36, 6, 115, 70) + bytes([0, 0x1A, 0x6C])))
    amfd_right = make_iff_form(b"AMFD",
        make_iff_chunk(b"INFO",
            struct.pack('<HHHH', 180, 6, 259, 70) + bytes([1, 0x1A, 0x6C])))
    cmfd = make_iff_form(b"CMFD",
        amfd_left + amfd_right +
        make_iff_chunk(b"SOFT", b"SOFTWARE"))

    # CHUD: HUD info and shift modes
    hinf_data = bytes([0x3B, 0x00, 0x00, 0x39, 0x00, 0x06, 0x01, 0x90,
                       0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    trgt_info = bytes([0x0C, 0x22, 0x29, 0xAA, 0x40, 0x05, 0x00])
    trgt = make_iff_form(b"TRGT", make_iff_chunk(b"INFO", trgt_info))
    crss = make_iff_form(b"CRSS", make_iff_chunk(b"SHAP", make_tiny_sprite(0x3C)))
    navi = make_iff_form(b"NAVI", make_iff_chunk(b"SHAP", make_tiny_sprite(0x40)))
    hsft = make_iff_form(b"HSFT", trgt + crss + navi)
    chud = make_iff_form(b"CHUD",
        make_iff_chunk(b"HINF", hinf_data) + hsft)

    # DIAL: instrument gauges
    radr = make_iff_form(b"RADR",
        make_iff_chunk(b"INFO", struct.pack('<HHHH', 90, 126, 138, 162)))
    shld = make_iff_form(b"SHLD",
        make_iff_chunk(b"INFO", struct.pack('<HHHH', 170, 126, 218, 162)))
    ener_view = make_iff_form(b"VIEW",
        make_iff_chunk(b"INFO", struct.pack('<HHHH', 155, 35, 168, 59)))
    ener = make_iff_form(b"ENER", ener_view)
    fuel_view = make_iff_form(b"VIEW",
        make_iff_chunk(b"INFO", struct.pack('<HHHH', 143, 3, 180, 8)))
    fuel = make_iff_form(b"FUEL", fuel_view)
    auto = make_iff_form(b"AUTO",
        make_iff_chunk(b"INFO", struct.pack('<HHHH', 146, 14, 177, 19)))
    sspd = make_iff_form(b"SSPD",
        make_iff_chunk(b"INFO", struct.pack('<HHHH', 50, 130, 81, 135)) +
        make_iff_chunk(b"DATA", b"\x00\x00\x00\x00kSET \x00"))
    aspd = make_iff_form(b"ASPD",
        make_iff_chunk(b"INFO", struct.pack('<HHHH', 50, 140, 81, 144)) +
        make_iff_chunk(b"DATA", b"\x00\x00\x00\x00kKPS \x00"))
    dial = make_iff_form(b"DIAL",
        radr + shld + ener + fuel + auto + sspd + aspd)

    # DAMG / CDMG (minimal)
    damg = make_iff_form(b"DAMG",
        make_iff_chunk(b"DAMG", struct.pack('<HH', 100, 2)))
    cdmg = make_iff_form(b"CDMG",
        make_iff_chunk(b"EXPL", struct.pack('<H', 0)))

    root = make_iff_form(b"COCK",
        frnt + font + cmfd + chud + dial + damg + cdmg)
    write("test_mfd.bin", root)


def gen_guns_file():
    """Generate test GUNS.IFF fixture (FORM:GUNS with TABL + UNIT records).

    GUNS.IFF structure:
        FORM:GUNS
          TABL (N * 4 bytes: u32 LE offsets from file start to each gun record)
          Gun records (each: u32 LE record_data_size + UNIT IFF chunk)

    Each UNIT chunk data (39 bytes):
        short_name (null-terminated, variable)
        type_filename (8 bytes, DOS 8.3 name)
        display_name (null-terminated, padded to fill 21 total string bytes)
        stats (18 bytes):
            u16 LE: velocity_factor
            u8: 0
            u16 LE: projectile_speed
            u8: 0
            u16 LE: range
            u8: 0
            u8: 0
            u16 LE: energy_cost
            u8: 0
            u8: 0
            u8: refire_delay
            u8: 0
            u16 LE: damage
    """
    def make_gun_unit(short_name, type_file, display_name, speed, damage, energy, refire, vel_factor=370, gun_range=870):
        """Build a gun UNIT chunk with 21-byte string section + 18-byte stats."""
        # Build string section (exactly 21 bytes, zero-padded)
        strings = short_name.encode('ascii') + b'\x00'
        strings += type_file.encode('ascii')  # 8 bytes, not null-terminated
        strings += display_name.encode('ascii') + b'\x00'
        # Pad to 21 bytes
        assert len(strings) <= 21, f"String section too long: {len(strings)}"
        strings += b'\x00' * (21 - len(strings))

        # Build stats (18 bytes)
        stats = struct.pack('<H', vel_factor)    # velocity factor
        stats += b'\x00'                         # padding
        stats += struct.pack('<H', speed)        # projectile speed
        stats += b'\x00'                         # padding
        stats += struct.pack('<H', gun_range)    # range
        stats += b'\x00\x00'                     # padding
        stats += struct.pack('<H', energy)       # energy cost
        stats += b'\x00\x00'                     # padding
        stats += bytes([refire])                 # refire delay
        stats += b'\x00'                         # padding
        stats += struct.pack('<H', damage)       # damage

        unit_data = strings + stats
        assert len(unit_data) == 39, f"UNIT data size wrong: {len(unit_data)}"

        # Wrap as IFF UNIT chunk
        unit_chunk = b'UNIT' + struct.pack('>I', len(unit_data)) + unit_data
        # Pad UNIT chunk to even if needed
        if len(unit_data) % 2 == 1:
            unit_chunk += b'\x00'

        # Record: u32 LE record_data_size + unit_chunk
        record_data_size = len(unit_chunk)
        return struct.pack('<I', record_data_size) + unit_chunk

    # Build 3 test guns: Laser, Mass Driver, Plasma
    guns = [
        make_gun_unit("Lasr", "LASRTYPE", "LASER",     speed=1400, damage=20, energy=76,  refire=4,  vel_factor=370),
        make_gun_unit("Mass", "MASSTYPE", "MASS",      speed=1100, damage=26, energy=89,  refire=5,  vel_factor=380),
        make_gun_unit("Plas", "PLSMTYPE", "PLASMA",     speed=940,  damage=72, energy=184, refire=19, vel_factor=500),
    ]

    # Calculate offsets: FORM header(12) + TABL header(8) + TABL data(3*4=12) = 32
    tabl_data_size = len(guns) * 4
    form_header_size = 12  # "FORM" + size + "GUNS"
    tabl_total = 8 + tabl_data_size  # "TABL" + size + data
    first_gun_offset = form_header_size + tabl_total

    offsets = []
    current_offset = first_gun_offset
    for gun in guns:
        offsets.append(current_offset)
        current_offset += len(gun)

    # Build TABL chunk
    tabl_data = b''
    for off in offsets:
        tabl_data += struct.pack('<I', off)
    tabl_chunk = b'TABL' + struct.pack('>I', len(tabl_data)) + tabl_data

    # Build FORM:GUNS
    form_body = b'GUNS' + tabl_chunk
    for gun in guns:
        form_body += gun
    data = b'FORM' + struct.pack('>I', len(form_body)) + form_body

    write("test_guns.bin", data)


def gen_weapons_file():
    """Generate test WEAPONS.IFF fixture (FORM:WEAP with LNCH and MISL).

    WEAPONS.IFF structure:
        FORM:WEAP
          FORM:LNCH  (launcher types)
            UNIT (7 bytes each for simple launchers)
          FORM:MISL  (missile types)
            UNIT (35 bytes each)

    Launcher UNIT (7 bytes):
        byte 0: launcher type ID
        byte 1-2: u16 LE value1
        byte 3-4: u16 LE value2
        byte 5-6: padding (0x0000)

    Missile UNIT (35 bytes):
        byte 0: missile type ID
        byte 1-8: short name (8 chars)
        byte 9-16: type filename (8 chars)
        byte 17-24: display name (8 chars, null-padded)
        byte 25-26: u16 LE speed
        byte 27: lock_type
        byte 28: padding
        byte 29-30: u16 LE lock_range
        byte 31-32: u16 LE damage
        byte 33: tracking_type
        byte 34: padding
    """
    # Launcher UNITs
    def make_launcher_unit(type_id, val1, val2):
        data = bytes([type_id]) + struct.pack('<HH', val1, val2) + b'\x00\x00'
        return make_iff_chunk(b'UNIT', data)

    lnch_units = (
        make_launcher_unit(0x32, 360, 640) +   # Missile launcher
        make_launcher_unit(0x33, 350, 76)       # Torpedo launcher
    )
    lnch_form = make_iff_form(b'LNCH', lnch_units)

    # Missile UNITs
    def make_missile_unit(type_id, short_name, type_file, display_name,
                          speed, lock_type, lock_range, damage, tracking):
        data = bytes([type_id])
        # Short name: 8 bytes, padded
        sn = short_name.encode('ascii')
        data += sn + b'\x00' * (8 - len(sn))
        # Type file: 8 bytes
        tf = type_file.encode('ascii')
        data += tf + b'\x00' * (8 - len(tf))
        # Display name: 8 bytes, null-padded
        dn = display_name.encode('ascii')
        data += dn + b'\x00' * (8 - len(dn))
        # Stats
        data += struct.pack('<H', speed)
        data += bytes([lock_type, 0])
        data += struct.pack('<H', lock_range)
        data += struct.pack('<H', damage)
        data += bytes([tracking, 0])
        assert len(data) == 35, f"Missile UNIT data size: {len(data)}"
        return make_iff_chunk(b'UNIT', data)

    misl_units = (
        make_missile_unit(1, "PrtnTorp", "TORPTYPE", "TORPEDO",
                          speed=1200, lock_type=3, lock_range=0, damage=200, tracking=5) +
        make_missile_unit(2, "HeatSeek", "MSSLTYPE", "HEATSEEK",
                          speed=800, lock_type=9, lock_range=3000, damage=160, tracking=2) +
        make_missile_unit(4, "DumbFire", "MSSLTYPE", "DUMBFIRE",
                          speed=1000, lock_type=8, lock_range=0, damage=130, tracking=1)
    )
    misl_form = make_iff_form(b'MISL', misl_units)

    root = make_iff_form(b'WEAP', lnch_form + misl_form)
    write("test_weapons.bin", root)


def gen_expltype_file():
    """Generate test EXPLTYPE.IFF fixture (FORM:EXPL with explosion type UNITs).

    EXPLTYPE.IFF structure:
        FORM:EXPL
          UNIT (per explosion type, 17 bytes each)

    Explosion UNIT (17 bytes):
        byte 0: explosion type ID
        byte 1-8: name (8 chars, null-padded)
        byte 9-10: u16 LE duration_ms
        byte 11-12: u16 LE num_frames
        byte 13-14: u16 LE radius
        byte 15: spawn_debris flag (0 or 1)
        byte 16: num_debris particles to spawn
    """
    def make_expl_unit(type_id, name, duration_ms, num_frames, radius,
                       spawn_debris, num_debris):
        data = bytes([type_id])
        n = name.encode('ascii')
        data += n + b'\x00' * (8 - len(n))
        data += struct.pack('<HH', duration_ms, num_frames)
        data += struct.pack('<H', radius)
        data += bytes([1 if spawn_debris else 0, num_debris])
        assert len(data) == 17, f"EXPL UNIT data size: {len(data)}"
        return make_iff_chunk(b'UNIT', data)

    units = (
        make_expl_unit(0, "BIGEXPL", duration_ms=1500, num_frames=15,
                       radius=80, spawn_debris=True, num_debris=12) +
        make_expl_unit(1, "MEDEXPL", duration_ms=1000, num_frames=10,
                       radius=50, spawn_debris=True, num_debris=8) +
        make_expl_unit(2, "SMLEXPL", duration_ms=600, num_frames=6,
                       radius=25, spawn_debris=True, num_debris=4) +
        make_expl_unit(3, "DETHEXPL", duration_ms=2000, num_frames=20,
                       radius=100, spawn_debris=True, num_debris=16)
    )

    root = make_iff_form(b'EXPL', units)
    write("test_expltype.bin", root)


def gen_trshtype_file():
    """Generate test TRSHTYPE.IFF fixture (FORM:TRSH with debris type UNITs).

    TRSHTYPE.IFF structure:
        FORM:TRSH
          UNIT (per debris type, 17 bytes each)

    Debris UNIT (17 bytes):
        byte 0: debris type ID
        byte 1-8: name (8 chars, null-padded)
        byte 9-10: u16 LE speed_min
        byte 11-12: u16 LE speed_max
        byte 13-14: u16 LE lifetime_ms
        byte 15-16: u16 LE spin_rate (degrees per second)
    """
    def make_trsh_unit(type_id, name, speed_min, speed_max, lifetime_ms,
                       spin_rate):
        data = bytes([type_id])
        n = name.encode('ascii')
        data += n + b'\x00' * (8 - len(n))
        data += struct.pack('<HH', speed_min, speed_max)
        data += struct.pack('<HH', lifetime_ms, spin_rate)
        assert len(data) == 17, f"TRSH UNIT data size: {len(data)}"
        return make_iff_chunk(b'UNIT', data)

    units = (
        make_trsh_unit(0, "CDBRTYPE", speed_min=20, speed_max=80,
                       lifetime_ms=3000, spin_rate=180) +
        make_trsh_unit(1, "BODYPRT1", speed_min=10, speed_max=50,
                       lifetime_ms=4000, spin_rate=90) +
        make_trsh_unit(2, "BODYPRT2", speed_min=10, speed_max=50,
                       lifetime_ms=4000, spin_rate=120)
    )

    root = make_iff_form(b'TRSH', units)
    write("test_trshtype.bin", root)


def gen_commodities_file():
    """Generate test COMODTYP.IFF fixture (FORM:COMD with FORM:COMM entries).

    Real COMODTYP.IFF format:
        FORM:COMD
          FORM:COMM (per commodity)
            INFO (4 bytes: id(u16 LE) + category(u16 LE))
            LABL (N bytes: null-terminated name)
            COST (38 bytes: base_price(i16 LE) + 9 x {base_type_id(i16 LE), modifier(i16 LE)})
            AVAL (38 bytes: base_avail(i16 LE) + 9 x {base_type_id(i16 LE), quantity(i16 LE)})

    Fixture: test_commodities.bin - 3 commodities
        Commodity 0: "Grain" category 0 (food), base_cost 20
        Commodity 5: "Iron" category 1 (raw materials), base_cost 50
        Commodity 34: "Tobacco" category 6 (contraband), base_cost 100
    """
    # The 9 base type IDs used in COST/AVAL entries (from real game data)
    BASE_TYPE_IDS = [0x1f, 0x20, 0x27, 0x29, 0x03, 0x02, 0x04, 0x01, 0x05]

    def make_cost(base_price, modifiers):
        """Build a 38-byte COST chunk data.
        modifiers: list of 9 i16 values, one per base type."""
        data = struct.pack('<h', base_price)
        for i in range(9):
            data += struct.pack('<hh', BASE_TYPE_IDS[i], modifiers[i])
        return data

    def make_avail(base_avail, quantities):
        """Build a 38-byte AVAL chunk data.
        quantities: list of 9 i16 values (-1 = unavailable)."""
        data = struct.pack('<h', base_avail)
        for i in range(9):
            data += struct.pack('<hh', BASE_TYPE_IDS[i], quantities[i])
        return data

    def make_commodity(commodity_id, category, name, base_price, cost_mods, base_avail, avail_qtys):
        info = make_iff_chunk(b"INFO", struct.pack('<HH', commodity_id, category))
        labl = make_iff_chunk(b"LABL", name.encode('ascii') + b'\x00')
        cost = make_iff_chunk(b"COST", make_cost(base_price, cost_mods))
        aval = make_iff_chunk(b"AVAL", make_avail(base_avail, avail_qtys))
        return make_iff_form(b"COMM", info + labl + cost + aval)

    # Commodity 0: Grain (food)
    grain = make_commodity(
        commodity_id=0, category=0, name="Grain",
        base_price=20,
        cost_mods=[3, 10, -13, 3, 7, 7, -15, 3, 10],
        base_avail=50,
        avail_qtys=[-1, -1, 20, -1, -1, -1, 60, -1, -1],
    )

    # Commodity 5: Iron (raw materials)
    iron = make_commodity(
        commodity_id=5, category=1, name="Iron",
        base_price=50,
        cost_mods=[-15, 15, -5, -15, -25, 15, -5, -15, -15],
        base_avail=50,
        avail_qtys=[-1, -25, -1, -1, 60, -25, -1, -1, -1],
    )

    # Commodity 34: Tobacco (contraband)
    tobacco = make_commodity(
        commodity_id=34, category=6, name="Tobacco",
        base_price=100,
        cost_mods=[-1, 50, -1, -1, 20, 20, 20, 20, -20],
        base_avail=30,
        avail_qtys=[-1, -1, -1, -1, -1, -1, -1, -1, 50],
    )

    root = make_iff_form(b"COMD", grain + iron + tobacco)
    write("test_commodities.bin", root)


def gen_shipstuf_file():
    """Generate test SHIPSTUF.IFF fixture (FORM:SHPS).

    Ship dealer data with ships and equipment for purchase.

    Structure:
      FORM:SHPS
        FORM:SHPC (ship catalog)
          FORM:SHIP (per ship)
            INFO (4 bytes: id(u16 LE) + ship_class(u16 LE))
            LABL (null-terminated name)
            COST (4 bytes: price(i32 LE))
            STAT (12 bytes: speed(u16 LE) + shields(u16 LE) + armor(u16 LE) +
                  cargo(u16 LE) + gun_mounts(u8) + missile_mounts(u8) +
                  turret_mounts(u8) + pad(u8))
        FORM:EQPC (equipment catalog)
          FORM:EQUP (per equipment)
            INFO (4 bytes: id(u16 LE) + category(u16 LE))
            LABL (null-terminated name)
            COST (4 bytes: price(i32 LE))
            CMPT (N bytes: number of compatible ship IDs (u8) + ship_id(u16 LE) each)

    Fixture: test_shipstuf.bin - 3 ships + 4 equipment items
        Ship 0: "Tarsus" class 0 (scout), 20000 cr, speed 200, 2 guns, 1 launcher
        Ship 1: "Galaxy" class 1 (merchant), 70000 cr, speed 180, 2 guns, 2 launchers, 1 turret
        Ship 2: "Centurion" class 2 (fighter), 200000 cr, speed 300, 4 guns, 2 launchers
        Equipment 0: "Laser" category 0 (gun), 5000 cr, compatible with all ships
        Equipment 1: "Plasma Gun" category 0 (gun), 40000 cr, compatible with Centurion only
        Equipment 2: "Shield Level 3" category 1 (shield), 15000 cr, compatible with Galaxy + Centurion
        Equipment 3: "Repair Droid" category 3 (software), 10000 cr, compatible with all ships
    """
    def make_ship(ship_id, ship_class, name, price, speed, shields, armor, cargo,
                  gun_mounts, missile_mounts, turret_mounts):
        info = make_iff_chunk(b"INFO", struct.pack('<HH', ship_id, ship_class))
        labl = make_iff_chunk(b"LABL", name.encode('ascii') + b'\x00')
        cost = make_iff_chunk(b"COST", struct.pack('<i', price))
        stat = make_iff_chunk(b"STAT", struct.pack('<HHHHBBBx',
            speed, shields, armor, cargo,
            gun_mounts, missile_mounts, turret_mounts))
        return make_iff_form(b"SHIP", info + labl + cost + stat)

    def make_equipment(equip_id, category, name, price, compatible_ship_ids):
        info = make_iff_chunk(b"INFO", struct.pack('<HH', equip_id, category))
        labl = make_iff_chunk(b"LABL", name.encode('ascii') + b'\x00')
        cost = make_iff_chunk(b"COST", struct.pack('<i', price))
        cmpt_data = struct.pack('B', len(compatible_ship_ids))
        for sid in compatible_ship_ids:
            cmpt_data += struct.pack('<H', sid)
        cmpt = make_iff_chunk(b"CMPT", cmpt_data)
        return make_iff_form(b"EQUP", info + labl + cost + cmpt)

    # Ships
    tarsus = make_ship(0, 0, "Tarsus", 20000,
                       200, 80, 60, 20, 2, 1, 0)
    galaxy = make_ship(1, 1, "Galaxy", 70000,
                       180, 120, 100, 75, 2, 2, 1)
    centurion = make_ship(2, 2, "Centurion", 200000,
                          300, 200, 150, 10, 4, 2, 0)

    ship_catalog = make_iff_form(b"SHPC", tarsus + galaxy + centurion)

    # Equipment
    laser = make_equipment(0, 0, "Laser", 5000, [0, 1, 2])
    plasma = make_equipment(1, 0, "Plasma Gun", 40000, [2])
    shield3 = make_equipment(2, 1, "Shield Level 3", 15000, [1, 2])
    repair = make_equipment(3, 3, "Repair Droid", 10000, [0, 1, 2])

    equip_catalog = make_iff_form(b"EQPC", laser + plasma + shield3 + repair)

    root = make_iff_form(b"SHPS", ship_catalog + equip_catalog)
    write("test_shipstuf.bin", root)


def gen_landfee_file():
    """Generate test LANDFEE.IFF fixture (FORM:LFEE).

    Simple structure: single DATA chunk with a landing fee value (i32 LE).

    Structure:
      FORM:LFEE
        DATA (4 bytes: fee(i32 LE))

    Fixture: test_landfee.bin - landing fee of 50 credits
    """
    data_chunk = make_iff_chunk(b"DATA", struct.pack('<i', 50))
    root = make_iff_form(b"LFEE", data_chunk)
    write("test_landfee.bin", root)


def gen_attitude_file():
    """Generate test ATTITUDE.IFF fixture (FORM:ATTD).

    Faction reputation system data with initial dispositions, kill effects,
    and hostility threshold.

    Factions (indexed 0-5):
      0 = Confed, 1 = Militia, 2 = Merchants, 3 = Pirates, 4 = Kilrathi, 5 = Retro

    Structure:
      FORM:ATTD
        DISP (12 bytes: initial disposition per faction, 6 x i16 LE)
        KMAT (36 bytes: kill matrix, 6x6 i8 values)
              kmat[killed_faction][affected_faction] = reputation change
        THRS (2 bytes: hostility threshold, i16 LE)

    Fixture: test_attitude.bin
        Initial dispositions: Confed=25, Militia=25, Merchants=0, Pirates=-50, Kilrathi=-75, Retro=-50
        Kill matrix (when you kill row faction, column faction rep changes):
          Kill Pirate:   Confed+5, Militia+3, Merchant+2, Pirate-10, Kilrathi 0, Retro 0
          Kill Kilrathi: Confed+5, Militia+5, Merchant+3, Pirate 0, Kilrathi-10, Retro 0
          Kill Confed:   Confed-10, Militia-5, Merchant-3, Pirate+3, Kilrathi+2, Retro+2
          Kill Militia:  Confed-5, Militia-10, Merchant-2, Pirate+2, Kilrathi 0, Retro+1
          Kill Merchant: Confed-3, Militia-2, Merchant-10, Pirate+1, Kilrathi 0, Retro+1
          Kill Retro:    Confed+3, Militia+3, Merchant+2, Pirate 0, Kilrathi 0, Retro-10
        Hostility threshold: -30 (below this, faction is hostile to player)
    """
    # Initial dispositions: Confed, Militia, Merchants, Pirates, Kilrathi, Retro
    disp_data = b''
    for val in [25, 25, 0, -50, -75, -50]:
        disp_data += struct.pack('<h', val)
    disp = make_iff_chunk(b"DISP", disp_data)

    # Kill matrix: 6 rows (killed faction) x 6 columns (affected faction), i8 each
    kmat_rows = [
        # When you kill: Confed  Militia  Merchant  Pirate  Kilrathi  Retro
        # Kill Confed:
        [-10, -5, -3, 3, 2, 2],
        # Kill Militia:
        [-5, -10, -2, 2, 0, 1],
        # Kill Merchant:
        [-3, -2, -10, 1, 0, 1],
        # Kill Pirate:
        [5, 3, 2, -10, 0, 0],
        # Kill Kilrathi:
        [5, 5, 3, 0, -10, 0],
        # Kill Retro:
        [3, 3, 2, 0, 0, -10],
    ]
    kmat_data = b''
    for row in kmat_rows:
        for val in row:
            kmat_data += struct.pack('b', val)
    kmat = make_iff_chunk(b"KMAT", kmat_data)

    # Hostility threshold
    thrs = make_iff_chunk(b"THRS", struct.pack('<h', -30))

    root = make_iff_form(b"ATTD", disp + kmat + thrs)
    write("test_attitude.bin", root)


def gen_mission_templates_file():
    """Generate test mission templates fixture (FORM:RNDM with FORM:MISN entries).

    Random mission template data for the mission computer.

    Structure:
        FORM:RNDM
          FORM:MISN (per mission template)
            INFO (4 bytes: type(u8), difficulty(u8), base_type_mask(u16 LE))
                 type: 0=patrol, 1=scout, 2=defend, 3=attack, 4=bounty, 5=cargo
                 difficulty: 1-5
                 base_type_mask: bit mask of base types that offer this mission
                   bit 0 = agricultural (type 1)
                   bit 1 = mining (type 2)
                   bit 2 = refinery (type 3)
                   bit 3 = pleasure (type 4)
                   bit 4 = pirate (type 5)
                   bit 5 = military (type 6)
            TEXT (null-terminated briefing template string)
            PAYS (8 bytes: min_reward(i32 LE), max_reward(i32 LE))

    Fixture: test_mission_templates.bin - 4 mission templates
        Template 0: Patrol, difficulty 1, all base types (mask=0x3F)
                    reward 5000-15000
        Template 1: Cargo delivery, difficulty 1, agricultural/mining/refinery (mask=0x07)
                    reward 3000-10000
        Template 2: Bounty hunt, difficulty 3, pirate/military (mask=0x30)
                    reward 10000-25000
        Template 3: Defend, difficulty 2, agricultural/mining/military (mask=0x23)
                    reward 8000-20000
    """
    def make_mission_template(mission_type, difficulty, base_type_mask, text, min_reward, max_reward):
        info = make_iff_chunk(b"INFO", struct.pack('<BBH', mission_type, difficulty, base_type_mask))
        text_chunk = make_iff_chunk(b"TEXT", text.encode('ascii') + b'\x00')
        pays = make_iff_chunk(b"PAYS", struct.pack('<ii', min_reward, max_reward))
        return make_iff_form(b"MISN", info + text_chunk + pays)

    # Template 0: Patrol - available at all base types
    patrol = make_mission_template(
        mission_type=0, difficulty=1, base_type_mask=0x3F,
        text="Patrol the designated nav points in the sector.",
        min_reward=5000, max_reward=15000,
    )

    # Template 1: Cargo delivery - agricultural, mining, refinery
    cargo = make_mission_template(
        mission_type=5, difficulty=1, base_type_mask=0x07,
        text="Deliver cargo to the specified destination.",
        min_reward=3000, max_reward=10000,
    )

    # Template 2: Bounty hunt - pirate and military bases
    bounty = make_mission_template(
        mission_type=4, difficulty=3, base_type_mask=0x30,
        text="Track down and destroy the target.",
        min_reward=10000, max_reward=25000,
    )

    # Template 3: Defend - agricultural, mining, military
    defend = make_mission_template(
        mission_type=2, difficulty=2, base_type_mask=0x23,
        text="Defend the convoy from hostile attackers.",
        min_reward=8000, max_reward=20000,
    )

    root = make_iff_form(b"RNDM", patrol + cargo + bounty + defend)
    write("test_mission_templates.bin", root)


def gen_plot_mission_file():
    """Generate test plot mission fixture (FORM:MSSN).

    Plot mission structure (from analysis of real S0MA.IFF etc.):
        FORM:MSSN
          [CARG] (3 bytes: commodity_id(u8), byte1(u8), byte2(u8)) - optional
          TEXT   (null-terminated briefing string)
          PAYS   (4 bytes: reward(i32 LE))
          [JUMP] (2 bytes: system_id(u8), nav_point(u8)) - optional
          FORM:SCRP (script container)
            CAST (N*8 bytes: array of 8-byte null-padded NPC names)
            FLAG (N bytes: boolean flag array, initially all zero)
            PROG (variable: script bytecode)
            PART (N*45 bytes: array of 45-byte participant records)
            FORM:PLAY (objectives)
              SCEN (variable: 9-byte header + u16 LE participant indices)

    Fixture: test_plot_mission.bin - One plot mission with cargo delivery
        - Cargo: commodity 22 (Iron)
        - Briefing: deliver cargo
        - Reward: 15000 credits
        - 2 cast members: PLAYER, PIR_AA
        - 2 flags (both zero)
        - 12 bytes PROG (minimal bytecode)
        - 2 PART records (PLAYER + 1 NPC)
        - 2 SCEN objectives (start scene + encounter)
    """
    # CARG: commodity_id=22 (Iron), 0x31, 0x0A (matches real data pattern)
    carg = make_iff_chunk(b"CARG", bytes([22, 0x31, 0x0A]))

    # TEXT: briefing
    briefing = b"\nDeliver cargo of Iron to the refinery.\n\nPays 15000 credits.\x00"
    text = make_iff_chunk(b"TEXT", briefing)

    # PAYS: 4 bytes, reward as i32 LE
    pays = make_iff_chunk(b"PAYS", struct.pack('<i', 15000))

    # CAST: 2 entries of 8-byte null-padded names
    cast_data = b"PLAYER\x00\x00" + b"PIR_AA\x00\x00"
    cast = make_iff_chunk(b"CAST", cast_data)

    # FLAG: 2 bytes, both zero
    flag = make_iff_chunk(b"FLAG", bytes([0, 0]))

    # PROG: 12 bytes minimal bytecode (matches S0MA pattern)
    prog_data = bytes([
        0x47, 0x01, 0x00, 0x00,  # header word
        0xe0, 0x20, 0x09, 0x03,  # destination system/nav/base
        0xd1, 0x16, 0x00, 0x00,  # cargo delivery (commodity 0x16=22)
    ])
    prog = make_iff_chunk(b"PROG", prog_data)

    # PART: 2 records of 45 bytes each
    # Record 0: PLAYER (mostly zeros and 0xff as in real data)
    player_part = bytearray(45)
    for i in range(20, 32):
        player_part[i] = 0xFF
    player_part[32:37] = bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    player_part[37:44] = bytes([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    player_part[44] = 0x00

    # Record 1: NPC (pirate) - simplified from real data
    npc_part = bytearray(45)
    struct.pack_into('<H', npc_part, 0, 1)  # index = 1
    npc_part[2:16] = b"talntypetalpi\x00"  # talent strings (14 bytes)
    struct.pack_into('<H', npc_part, 16, 0)  # flags
    npc_part[18] = 0x01  # nav_point
    npc_part[19] = 0x29  # system_id = 41
    npc_part[20] = 0x00
    struct.pack_into('<i', npc_part, 21, 500)  # x coordinate
    struct.pack_into('<i', npc_part, 25, -5500)  # y coordinate
    struct.pack_into('<i', npc_part, 29, -650)  # z coordinate
    npc_part[33] = 0x2D  # faction
    npc_part[34:37] = bytes([0x00, 0x01, 0x05])
    npc_part[37:39] = bytes([0x00, 0x02])
    npc_part[39:45] = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])

    part = make_iff_chunk(b"PART", bytes(player_part) + bytes(npc_part))

    # SCEN objectives inside FORM:PLAY
    # SCEN 0: starting scene (11 bytes: type=1, nav=ff, sys=ff, 00 00, ff ff ff ff, participant 0)
    scen0 = make_iff_chunk(b"SCEN", bytes([
        0x01, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00,  # participant index 0 (PLAYER)
    ]))
    # SCEN 1: encounter (15 bytes: type=1, nav=0, sys=0x29, ff ff, ff ff ff ff, participants 1,0,0)
    scen1 = make_iff_chunk(b"SCEN", bytes([
        0x01, 0x00, 0x29, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x01, 0x00,  # participant index 1 (PIR_AA)
        0x00, 0x00,  # participant index 0 (filler)
        0x00, 0x00,  # participant index 0 (filler)
    ]))

    play_form = make_iff_form(b"PLAY", scen0 + scen1)
    scrp_form = make_iff_form(b"SCRP", cast + flag + prog + part + play_form)
    root = make_iff_form(b"MSSN", carg + text + pays + scrp_form)
    write("test_plot_mission.bin", root)


def gen_plot_mission_list_file():
    """Generate test plot mission list fixture (FORM:MSNS with TABL chunk).

    PLOTMSNS.IFF structure:
        FORM:MSNS
          TABL (N*4 bytes: array of u32 LE offsets into TRE for each mission)

    Fixture: test_plot_mission_list.bin - List with 3 mission offsets
    """
    # TABL: 3 mission file offsets (u32 LE)
    tabl_data = struct.pack('<III', 0x74, 0x8A, 0xA0)
    tabl = make_iff_chunk(b"TABL", tabl_data)
    root = make_iff_form(b"MSNS", tabl)
    write("test_plot_mission_list.bin", root)


def gen_rumor_table_file():
    """Generate test rumor table fixture (FORM:RUMR with TABL).

    Rumor tables in CONV/*.IFF map indices to conversation file references.
    Each TABL entry is a u32 LE offset within the file pointing to a 20-byte record:
        u32 LE   data_size    (16 for standard records, 0 for null/empty)
        [4]u8    category     ("CONV" or "BASE")
        u32 LE   name_length  (always 8)
        [8]u8    name         (null-padded conversation filename)

    Fixture: test_rumor_table.bin - 3 conversation references
    """
    # Build 3 records
    rec0 = struct.pack('<I', 16) + b"CONV" + struct.pack('<I', 8) + b"agrrum1\x00"
    rec1 = struct.pack('<I', 16) + b"CONV" + struct.pack('<I', 8) + b"agrrum2\x00"
    rec2 = struct.pack('<I', 16) + b"CONV" + struct.pack('<I', 8) + b"agrrum3\x00"

    # TABL contains u32 LE offsets to each record within the file
    # File layout: FORM header (8) + form_type (4) + TABL header (8) + TABL data (12) = 32
    # Records start at offset 32
    tabl_data = struct.pack('<III', 32, 52, 72)
    tabl = make_iff_chunk(b"TABL", tabl_data)

    # Build FORM:RUMR - TABL chunk followed by raw record data
    body = b"RUMR" + tabl + rec0 + rec1 + rec2
    root = b"FORM" + struct.pack('>I', len(body)) + body
    write("test_rumor_table.bin", root)


def gen_rumor_chances_file():
    """Generate test rumor chances fixture (FORM:RUMR with CHNC).

    RUMORS.IFF uses a CHNC chunk instead of TABL, containing u16 LE
    chance weights for rumor category selection.

    Fixture: test_rumor_chances.bin - 4 chance weights
    """
    chnc_data = struct.pack('<HHHH', 20, 40, 40, 40)
    chnc = make_iff_chunk(b"CHNC", chnc_data)
    root = make_iff_form(b"RUMR", chnc)
    write("test_rumor_chances.bin", root)


def gen_base_rumor_table_file():
    """Generate test base-type rumor table fixture (FORM:RUMR with BASE refs).

    BASERUMR.IFF maps base type indices to other RUMR IFF files.
    First entry can be null (data_size=0).

    Fixture: test_base_rumor_table.bin - 1 null + 2 BASE references
    """
    rec0 = struct.pack('<I', 0)  # null entry (4 bytes)
    rec1 = struct.pack('<I', 16) + b"BASE" + struct.pack('<I', 8) + b"agrirumr"
    rec2 = struct.pack('<I', 16) + b"BASE" + struct.pack('<I', 8) + b"minerumr"

    # Offsets within file: FORM(8) + RUMR(4) + TABL header(8) + TABL data(12) = 32
    tabl_data = struct.pack('<III', 32, 36, 56)
    tabl = make_iff_chunk(b"TABL", tabl_data)

    body = b"RUMR" + tabl + rec0 + rec1 + rec2
    root = b"FORM" + struct.pack('>I', len(body)) + body
    write("test_base_rumor_table.bin", root)


def gen_pfc_file():
    """Generate test PFC (conversation script) fixture.

    PFC files contain null-separated strings in groups of 7:
        [0] speaker type (e.g., "rand_npc")
        [1] mood/animation (e.g., "normal")
        [2] costume reference (e.g., "randcu_3")
        [3] unknown ("?")
        [4] unknown ("?")
        [5] dialogue text
        [6] unknown ("?")

    Fixture: test_conv.pfc - 2 dialogue lines
    """
    strings = [
        # Line 0
        b"rand_npc", b"normal", b"randcu_3", b"?", b"?",
        b"I just heard that the fleet was lost around Midgard...",
        b"?",
        # Line 1
        b"rand_npc", b"normal", b"randcu_3", b"?", b"?",
        b"Gone! The Kilrathi must've destroyed them!",
        b"?",
    ]
    data = b"\x00".join(strings) + b"\x00"
    write("test_conv.pfc", data)


def gen_comptext_file():
    """Generate test computer text fixture (FORM:COMP - COMPTEXT.IFF).

    Contains guild-specific text for the mission computer UI.
    Each guild is a FORM with text chunks named by message type.

    Fixture: test_comptext.bin - Merchant guild with key text chunks
    """
    join = make_iff_chunk(b"JOIN", b"You must first join\nthe Merchants' Guild.\x00")
    welc = make_iff_chunk(b"WELC", b"Welcome to the\nMerchants' Guild.\x00")
    unav = make_iff_chunk(b"UNAV", b"Mission not available.\x00")
    scan = make_iff_chunk(b"SCAN", b"Scanning for missions.\x00")
    nrom = make_iff_chunk(b"NROM", b"Schedule full.\x00")
    boun = make_iff_chunk(b"BOUN", b"BOUNTY MISSION (%d of %d)\x00")
    crgo = make_iff_chunk(b"CRGO", b"CARGO MISSION (%d of %d)\x00")
    acpt = make_iff_chunk(b"ACPT", b"Mission accepted.\x00")

    mrch = make_iff_form(b"MRCH", join + welc + unav + scan + nrom + boun + crgo + acpt)
    root = make_iff_form(b"COMP", mrch)
    write("test_comptext.bin", root)


def gen_commtxt_file():
    """Generate test communication text fixture (FORM:STRG - COMMTXT.IFF).

    String table with SNUM (count) and DATA (null-separated strings).

    Fixture: test_commtxt.bin - 3 exchange text strings
    """
    snum = make_iff_chunk(b"SNUM", struct.pack('<H', 3))
    data_strings = b"Price: \x00Quantity: \x00Cost: \x00"
    data = make_iff_chunk(b"DATA", data_strings)
    root = make_iff_form(b"STRG", snum + data)
    write("test_commtxt.bin", root)


if __name__ == "__main__":
    print("Generating test fixtures...")
    gen_iso_pvd()
    gen_tre_archive()
    gen_iff_chunks()
    gen_pal_file()
    gen_sprite_rle()
    gen_shp_file()
    gen_pak_file()
    gen_pak_noend()
    gen_pak_ff_marker()
    gen_voc_file()
    gen_vpk_file()
    gen_xmidi_file()
    gen_font_file()
    gen_gameflow_file()
    gen_midgame_pak()
    gen_quadrant_file()
    gen_bases_file()
    gen_nav_table()
    gen_teams_file()
    gen_cockpit_file()
    gen_mfd_file()
    gen_guns_file()
    gen_weapons_file()
    gen_expltype_file()
    gen_trshtype_file()
    gen_commodities_file()
    gen_shipstuf_file()
    gen_landfee_file()
    gen_attitude_file()
    gen_mission_templates_file()
    gen_plot_mission_file()
    gen_plot_mission_list_file()
    gen_rumor_table_file()
    gen_rumor_chances_file()
    gen_base_rumor_table_file()
    gen_pfc_file()
    gen_comptext_file()
    gen_commtxt_file()
    print("Done.")
