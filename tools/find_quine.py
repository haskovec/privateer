"""Find the Quine 4000 - render all 320x200 UI-range resources with best palettes."""
import struct
import zlib

GAME_DAT = 'GAME.DAT'
TRE_LBA = 27
SECTOR = 2048
TRE_START = TRE_LBA * SECTOR
TOC_SIZE = 86688
MARKER_DATA = 0xE0
MARKER_SUBTABLE = 0xC1
MARKER_UNUSED = 0xFF
MARKER_END = 0x00


def get_tre_entries(toc):
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
        entries.append({'index': i, 'path': path, 'offset': file_offset,
                       'size': file_size, 'abs_pos': TRE_START + file_offset})
    return entries


def read_offset3(data, pos):
    return data[pos] | (data[pos+1] << 8) | (data[pos+2] << 16)


def collect_pak_offsets(data, table_start, recurse):
    offsets = []
    pos = table_start
    min_offset = len(data)
    while pos + 4 <= len(data) and pos < min_offset:
        marker = data[pos + 3]
        if marker == MARKER_END: break
        offset = read_offset3(data, pos)
        pos += 4
        if marker == MARKER_DATA:
            if offset >= len(data): break
            if offset < min_offset: min_offset = offset
            offsets.append(offset)
        elif marker == MARKER_SUBTABLE:
            if not recurse: break
            if offset >= len(data): break
            if offset < min_offset: min_offset = offset
            sub = collect_pak_offsets(data, offset, False)
            offsets.extend(sub if sub else [offset])
        elif marker == MARKER_UNUSED: pass
        else: break
    return offsets


def parse_pak(data):
    if len(data) < 8: return []
    offsets = collect_pak_offsets(data, 4, True)
    so = sorted(offsets)
    return [(o, next((s for s in so if s > o), len(data)) - o) for o in offsets]


def parse_scene_pack(data):
    if len(data) < 8: return []
    fo = struct.unpack_from('<I', data, 4)[0]
    if fo < 8 or fo > len(data): return []
    n = (fo - 4) // 4
    return [struct.unpack_from('<I', data, 4+i*4)[0] for i in range(n) if 4+i*4+4 <= len(data)]


def decode_sprite_header(data):
    if len(data) < 8: return None
    x2, x1, y1, y2 = struct.unpack_from('<hhhh', data, 0)
    w, h = x1+x2+1, y1+y2+1
    return {'width': w, 'height': h, 'x1': x1, 'x2': x2, 'y1': y1, 'y2': y2} if w > 0 and h > 0 else None


def decode_rle_sprite(data, width, height, x1, y1):
    pixels = bytearray(width * height)
    offset = 8
    while offset + 1 < len(data):
        key = struct.unpack_from('<H', data, offset)[0]; offset += 2
        if key == 0: break
        if offset + 3 >= len(data): break
        x_raw = struct.unpack_from('<h', data, offset)[0]; offset += 2
        y_raw = struct.unpack_from('<h', data, offset)[0]; offset += 2
        bx, by = max(0, min(x_raw + x1, width)), max(0, min(y_raw + y1, height))
        pn = key // 2
        if key & 1 == 0:
            for i in range(pn):
                if offset >= len(data): break
                c = data[offset]; offset += 1
                px = bx + i
                if 0 <= px < width and 0 <= by < height:
                    pixels[by * width + px] = c
        else:
            pw = 0
            while pw < pn:
                if offset >= len(data): break
                sb = data[offset]; offset += 1
                sc = sb // 2
                if sb & 1 == 0:
                    for _ in range(sc):
                        if offset >= len(data): break
                        c = data[offset]; offset += 1
                        px = bx + pw
                        if 0 <= px < width and 0 <= by < height:
                            pixels[by * width + px] = c
                        pw += 1
                else:
                    if offset >= len(data): break
                    c = data[offset]; offset += 1
                    for _ in range(sc):
                        px = bx + pw
                        if 0 <= px < width and 0 <= by < height:
                            pixels[by * width + px] = c
                        pw += 1
    return pixels


def parse_palette(data):
    if len(data) < 772: return None
    return [(min(data[4+i*3]*4,255), min(data[4+i*3+1]*4,255), min(data[4+i*3+2]*4,255)) for i in range(256)]


def save_png(filename, width, height, pixels, palette):
    def mc(ct, d):
        c = ct + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            r, g, b = palette[pixels[y*width+x]]
            rows.extend([r, g, b])
    with open(filename, 'wb') as out:
        out.write(b'\x89PNG\r\n\x1a\n')
        out.write(mc(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)))
        out.write(mc(b'IDAT', zlib.compress(bytes(rows))))
        out.write(mc(b'IEND', b''))


with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_START)
    toc = f.read(TOC_SIZE)
    tre_entries = get_tre_entries(toc)

    optshps = next(e for e in tre_entries if 'OPTSHPS.PAK' in e['path'])
    optpals = next(e for e in tre_entries if 'OPTPALS.PAK' in e['path'])

    f.seek(optshps['abs_pos'])
    pak_data = f.read(optshps['size'])
    resources = parse_pak(pak_data)

    f.seek(optpals['abs_pos'])
    pal_data = f.read(optpals['size'])
    pal_resources = parse_pak(pal_data)

    # Load all palettes
    palettes = {}
    for pi in range(len(pal_resources)):
        po, ps = pal_resources[pi]
        p = parse_palette(pal_data[po:po+ps])
        if p: palettes[pi] = p

    # Render ALL 320x200 resources in range 62-225 with their best palette
    print(f"Rendering all fullscreen UI resources (62-225)...")
    for idx in range(62, min(226, len(resources))):
        off, size = resources[idx]
        if size < 50: continue
        sub = pak_data[off:off+size]
        sp_offs = parse_scene_pack(sub)
        if not sp_offs: continue
        sd = sub[sp_offs[0]:]
        hdr = decode_sprite_header(sd)
        if not hdr or hdr['width'] != 320 or hdr['height'] != 200: continue

        pixels = decode_rle_sprite(sd, 320, 200, hdr['x1'], hdr['y1'])

        # Try palette 39 (title) and palette 0
        for pi in [39, 0]:
            if pi in palettes:
                save_png(f'/tmp/optshps_{idx}_p{pi}.png', 320, 200, pixels, palettes[pi])

        print(f"  {idx}: {len(sp_offs)} sprites, size={size}")
