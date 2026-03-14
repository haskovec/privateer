"""Deep analysis of MFD (CMFD, CHUD, DIAL) chunks from cockpit IFF files."""
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
        f.seek(TRE_LBA * SECTOR + 8 + i * ENTRY_SIZE)
        raw = f.read(ENTRY_SIZE)
        path_bytes = raw[1:66]
        null = path_bytes.find(b'\x00')
        path = path_bytes[:null].decode('ascii') if null >= 0 else path_bytes.decode('ascii', errors='replace')
        offset = struct.unpack_from('<I', raw, 66)[0]
        size = struct.unpack_from('<I', raw, 70)[0]
        entries.append((path, offset, size))
    return entries


def read_file_data(f, offset, size):
    f.seek(TRE_LBA * SECTOR + offset)
    return f.read(size)


def hex_dump(data, indent=""):
    for i in range(0, len(data), 16):
        hex_str = ' '.join(f'{b:02X}' for b in data[i:i+16])
        ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[i:i+16])
        print(f'{indent}{i:04X}: {hex_str:<48s}  {ascii_str}')


def parse_iff_tree(data, offset=0, end=None, depth=0):
    """Parse IFF into a proper tree structure."""
    if end is None:
        end = len(data)
    children = []
    pos = offset
    while pos + 8 <= end:
        tag = data[pos:pos+4]
        if not all(32 <= b < 127 for b in tag):
            break
        tag_str = tag.decode('ascii')
        size = struct.unpack_from('>I', data, pos+4)[0]
        chunk_data_start = pos + 8
        chunk_data_end = min(pos + 8 + size, end)

        if tag_str in ('FORM', 'CAT ', 'LIST') and size >= 4:
            subtype = data[pos+8:pos+12].decode('ascii', errors='replace')
            sub_children = parse_iff_tree(data, pos+12, chunk_data_end, depth+1)
            children.append({
                'tag': tag_str, 'size': size, 'subtype': subtype,
                'offset': pos, 'children': sub_children
            })
        else:
            children.append({
                'tag': tag_str, 'size': size, 'subtype': None,
                'offset': pos, 'data': data[chunk_data_start:chunk_data_end],
                'children': []
            })
        pos = chunk_data_end
        if size % 2 == 1:
            pos += 1
    return children


def print_tree(node, indent=""):
    if node['subtype']:
        print(f"{indent}FORM:{node['subtype']} (size={node['size']}) @ {node['offset']}")
    else:
        print(f"{indent}{node['tag']} (size={node['size']}) @ {node['offset']}")
        if node['size'] <= 128 and 'data' in node:
            hex_dump(node['data'], indent + "  ")
        elif 'data' in node and node['size'] > 128:
            print(f"{indent}  [first 64 bytes:]")
            hex_dump(node['data'][:64], indent + "  ")
    for child in node['children']:
        print_tree(child, indent + "  ")


def find_form(children, subtype):
    for c in children:
        if c.get('subtype') == subtype:
            return c
    return None


def find_chunk(children, tag):
    for c in children:
        if c['tag'] == tag and c['subtype'] is None:
            return c
    return None


def analyze_info_rect(data, label=""):
    """Parse INFO chunk as 4x u16 LE rectangle (x1, y1, x2, y2)."""
    if len(data) >= 8:
        x1, y1, x2, y2 = struct.unpack_from('<HHHH', data, 0)
        w, h = x2 - x1, y2 - y1
        print(f"    {label}rect: ({x1}, {y1}) - ({x2}, {y2})  [{w}x{h} pixels]")
        if len(data) > 8:
            print(f"    {label}extra bytes: {' '.join(f'{b:02X}' for b in data[8:])}")


def analyze_view_form(view_form, label=""):
    """Analyze FORM:VIEW which contains gauge graphics."""
    for child in view_form['children']:
        if child['tag'] == 'INFO' and 'data' in child:
            print(f"    {label}VIEW INFO ({len(child['data'])} bytes):")
            analyze_info_rect(child['data'], label + "  ")
        elif child['subtype']:
            print(f"    {label}VIEW sub: FORM:{child['subtype']} (size={child['size']})")
        elif 'data' in child:
            print(f"    {label}VIEW {child['tag']} ({len(child['data'])} bytes)")


def main():
    with open(GAME_DAT, 'rb') as f:
        entries = load_tre(f)

        cockpit_iffs = [
            ('Tarsus', 'CLUNKCK.IFF'),
            ('Centurion', 'FIGHTCK.IFF'),
            ('Galaxy', 'MERCHCK.IFF'),
            ('Orion', 'TUGCK.IFF'),
        ]

        for ship_name, iff_name in cockpit_iffs:
            for path, offset, size in entries:
                if path.upper().endswith(iff_name):
                    data = read_file_data(f, offset, size)
                    tree = parse_iff_tree(data)
                    if not tree:
                        continue
                    root = tree[0]
                    if root.get('subtype') != 'COCK':
                        continue

                    print(f"\n{'='*70}")
                    print(f"=== {ship_name} ({iff_name}) - {size} bytes ===")
                    print(f"{'='*70}")

                    # Print full tree structure
                    print(f"\n--- Full structure ---")
                    print_tree(root)

                    # Analyze CMFD
                    cmfd = find_form(root['children'], 'CMFD')
                    if cmfd:
                        print(f"\n--- CMFD Analysis ---")
                        for child in cmfd['children']:
                            if child.get('subtype') == 'AMFD':
                                print(f"  AMFD:")
                                info = find_chunk(child['children'], 'INFO')
                                if info and 'data' in info:
                                    print(f"    INFO ({len(info['data'])} bytes):")
                                    analyze_info_rect(info['data'], "    ")
                                soft = find_chunk(child['children'], 'SOFT')
                                if soft and 'data' in soft:
                                    print(f"    SOFT: {soft['data'].decode('ascii', errors='replace')}")
                            elif child['tag'] == 'SOFT' and 'data' in child:
                                print(f"  SOFT: {child['data'].decode('ascii', errors='replace')}")

                    # Analyze CHUD
                    chud = find_form(root['children'], 'CHUD')
                    if chud:
                        print(f"\n--- CHUD Analysis ---")
                        hinf = find_chunk(chud['children'], 'HINF')
                        if hinf and 'data' in hinf:
                            print(f"  HINF ({len(hinf['data'])} bytes):")
                            hex_dump(hinf['data'], "    ")
                            if len(hinf['data']) >= 8:
                                vals = struct.unpack_from('<HHHH', hinf['data'], 0)
                                print(f"    As u16 LE: {vals}")
                                if len(hinf['data']) >= 10:
                                    extra = struct.unpack_from('<H', hinf['data'], 8)[0]
                                    print(f"    [8..10] u16: {extra}")

                        hsft = find_form(chud['children'], 'HSFT')
                        if hsft:
                            print(f"  HSFT (HUD-shift modes): {len(hsft['children'])} sub-forms")
                            for sub in hsft['children']:
                                if sub.get('subtype'):
                                    print(f"    FORM:{sub['subtype']} (size={sub['size']})")
                                    for inner in sub['children']:
                                        if inner.get('subtype'):
                                            print(f"      FORM:{inner['subtype']} (size={inner['size']})")
                                        elif 'data' in inner:
                                            print(f"      {inner['tag']} ({len(inner['data'])} bytes)")
                                            if len(inner['data']) <= 64:
                                                hex_dump(inner['data'], "        ")

                    # Analyze DIAL
                    dial = find_form(root['children'], 'DIAL')
                    if dial:
                        print(f"\n--- DIAL Analysis ---")
                        for sub in dial['children']:
                            if sub.get('subtype'):
                                print(f"  FORM:{sub['subtype']} (size={sub['size']})")
                                for inner in sub['children']:
                                    if inner['tag'] == 'INFO' and 'data' in inner:
                                        analyze_info_rect(inner['data'], "")
                                    elif inner['tag'] == 'DATA' and 'data' in inner:
                                        print(f"    DATA ({len(inner['data'])} bytes):")
                                        hex_dump(inner['data'][:64], "      ")
                                    elif inner['tag'] == 'SHAP' and 'data' in inner:
                                        print(f"    SHAP ({len(inner['data'])} bytes)")
                                    elif inner.get('subtype') == 'VIEW':
                                        print(f"    FORM:VIEW (size={inner['size']})")
                                        analyze_view_form(inner, "  ")

                    # Analyze DAMG and CDMG
                    damg = find_form(root['children'], 'DAMG')
                    if damg:
                        print(f"\n--- DAMG Analysis ---")
                        for inner in damg['children']:
                            if 'data' in inner:
                                print(f"  {inner['tag']} ({len(inner['data'])} bytes):")
                                hex_dump(inner['data'], "    ")

                    cdmg = find_form(root['children'], 'CDMG')
                    if cdmg:
                        print(f"\n--- CDMG Analysis ---")
                        for inner in cdmg['children']:
                            if 'data' in inner:
                                print(f"  {inner['tag']} ({len(inner['data'])} bytes):")
                                hex_dump(inner['data'], "    ")

                    break


if __name__ == '__main__':
    main()
