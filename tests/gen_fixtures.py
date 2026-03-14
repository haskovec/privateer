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
    Header: X2=2, X1=2, Y1=2, Y2=2 => width=4, height=4
    All 4 rows use even-key encoding (raw pixel runs).
    Expected pixels (row-major):
        Row 0: [1, 2, 3, 4]
        Row 1: [5, 6, 7, 8]
        Row 2: [9, 10, 11, 12]
        Row 3: [13, 14, 15, 16]

    Fixture 2: test_sprite_odd.bin - 4x4 sprite using odd-key (sub-encoded) runs.
    Header: X2=2, X1=2, Y1=2, Y2=2 => width=4, height=4
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
    Header: X2=3, X1=3, Y1=1, Y2=1 => width=6, height=2
    Row 0: 3 pixels starting at x=1
    Row 1: 2 pixels starting at x=2
    Expected pixels:
        Row 0: [0, 15, 16, 17, 0, 0]
        Row 1: [0, 0, 20, 21, 0, 0]
    """
    # --- Fixture 1: Even-key only ---
    data = bytearray()
    # Header: X2=2, X1=2, Y1=2, Y2=2 (all i16 LE)
    data += struct.pack('<hhhh', 2, 2, 2, 2)
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
    # Header: X2=2, X1=2, Y1=2, Y2=2
    data += struct.pack('<hhhh', 2, 2, 2, 2)
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
    # Header: X2=3, X1=3, Y1=1, Y2=1 => width=6, height=2
    data += struct.pack('<hhhh', 3, 3, 1, 1)
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
    s0 += struct.pack('<hhhh', 2, 2, 2, 2)  # header: width=4, height=4
    s0 += struct.pack('<HHH', 8, 0, 0) + bytes([1, 2, 3, 4])
    s0 += struct.pack('<HHH', 8, 0, 1) + bytes([5, 6, 7, 8])
    s0 += struct.pack('<HHH', 8, 0, 2) + bytes([9, 10, 11, 12])
    s0 += struct.pack('<HHH', 8, 0, 3) + bytes([13, 14, 15, 16])
    s0 += struct.pack('<H', 0)  # terminator

    # Sprite 1: 2x2 even-key
    s1 = bytearray()
    s1 += struct.pack('<hhhh', 1, 1, 1, 1)  # header: width=2, height=2
    s1 += struct.pack('<HHH', 4, 0, 0) + bytes([0xAA, 0xBB])
    s1 += struct.pack('<HHH', 4, 0, 1) + bytes([0xCC, 0xDD])
    s1 += struct.pack('<H', 0)  # terminator

    # Sprite 2: 3x2 even-key
    s2 = bytearray()
    s2 += struct.pack('<hhhh', 2, 1, 1, 1)  # header: width=3, height=2
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
    s_single += struct.pack('<hhhh', 1, 1, 1, 1)  # 2x2
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
    # Glyph A: 3x3 (x2=2, x1=1 -> w=3; y1=2, y2=1 -> h=3)
    ga = bytearray()
    ga += struct.pack('<hhhh', 2, 1, 2, 1)
    ga += struct.pack('<HHH', 6, 0, 0) + bytes([0, 1, 0])
    ga += struct.pack('<HHH', 6, 0, 1) + bytes([1, 1, 1])
    ga += struct.pack('<HHH', 6, 0, 2) + bytes([1, 0, 1])
    ga += struct.pack('<H', 0)

    # Glyph B: 2x3 (x2=1, x1=1 -> w=2; y1=2, y2=1 -> h=3)
    gb = bytearray()
    gb += struct.pack('<hhhh', 1, 1, 2, 1)
    gb += struct.pack('<HHH', 4, 0, 0) + bytes([1, 1])
    gb += struct.pack('<HHH', 4, 0, 1) + bytes([1, 0])
    gb += struct.pack('<HHH', 4, 0, 2) + bytes([1, 1])
    gb += struct.pack('<H', 0)

    # Glyph C: 4x3 (x2=2, x1=2 -> w=4; y1=2, y2=1 -> h=3)
    gc = bytearray()
    gc += struct.pack('<hhhh', 2, 2, 2, 1)
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
        sprite += struct.pack('<hhhh', 1, 1, 1, 1)  # 2x2 sprite
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

    QUADRANT.IFF structure:
        FORM:UNIV
          INFO (universe metadata)
          FORM:QUAD (per quadrant)
            INFO (quadrant metadata)
            FORM:SYST (per star system)
              INFO (system properties: coordinates, faction, hazard level)
              [BASE] (optional: base present at this system)

    Fixture: test_quadrant.bin - 2 quadrants, 5 systems total
        Quadrant 0: 3 systems
          System 0: coords (10, 20), faction 1, hazard 2, has base (type 3)
          System 1: coords (30, 40), faction 2, hazard 1, no base
          System 2: coords (50, 60), faction 1, hazard 3, has base (type 1)
        Quadrant 1: 2 systems
          System 0: coords (70, 80), faction 3, hazard 1, no base
          System 1: coords (90, 100), faction 2, hazard 2, has base (type 2)
    """
    def make_syst(x, y, faction, hazard, base_type=None):
        """Build a FORM:SYST with INFO and optional BASE chunk."""
        # INFO: 4 bytes - x(u8), y(u8), faction(u8), hazard(u8)
        info = make_iff_chunk(b"INFO", bytes([x, y, faction, hazard]))
        children = info
        if base_type is not None:
            # BASE: 1 byte - base type
            children += make_iff_chunk(b"BASE", bytes([base_type]))
        return make_iff_form(b"SYST", children)

    def make_quad(systems_bytes):
        """Build a FORM:QUAD with INFO and SYST children."""
        # Count systems by scanning for FORM headers with SYST type
        # INFO: just a placeholder byte for quadrant metadata
        info = make_iff_chunk(b"INFO", bytes([0x00]))
        return make_iff_form(b"QUAD", info + systems_bytes)

    # Quadrant 0: 3 systems
    q0_systems = (
        make_syst(10, 20, 1, 2, base_type=3) +
        make_syst(30, 40, 2, 1) +
        make_syst(50, 60, 1, 3, base_type=1)
    )
    quad0 = make_quad(q0_systems)

    # Quadrant 1: 2 systems
    q1_systems = (
        make_syst(70, 80, 3, 1) +
        make_syst(90, 100, 2, 2, base_type=2)
    )
    quad1 = make_quad(q1_systems)

    # Universe root: INFO + 2 quadrants
    univ_info = make_iff_chunk(b"INFO", bytes([0x02]))  # 2 quadrants
    root = make_iff_form(b"UNIV", univ_info + quad0 + quad1)

    write("test_quadrant.bin", root)


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
    print("Done.")
