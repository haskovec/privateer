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


if __name__ == "__main__":
    print("Generating test fixtures...")
    gen_iso_pvd()
    gen_tre_archive()
    gen_iff_chunks()
    print("Done.")
