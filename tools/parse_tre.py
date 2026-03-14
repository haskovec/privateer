import struct
import sys

with open(r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT', 'rb') as f:
    f.seek(27 * 2048)
    data = f.read(500000)

count = struct.unpack_from('<I', data, 0)[0]
print(f'Entry count: {count}')

val2 = struct.unpack_from('<I', data, 4)[0]
print(f'TOC size/offset: {val2} (0x{val2:08x})')

# Find file paths by looking for ".." pattern in paths
search = b"..\\..\\DATA"
paths = []
start = 0
while True:
    idx = data.find(search, start)
    if idx == -1 or idx > 400000:
        break
    # Find end of string (null terminator)
    end = data.find(b'\x00', idx)
    if end == -1:
        end = idx + 100
    path = data[idx:end].decode('ascii', errors='replace')
    paths.append((idx, path))
    start = end + 1

print(f'Found {len(paths)} file entries')
for i, (offset, path) in enumerate(paths):
    if i < 50 or i >= len(paths) - 5:
        print(f'  [{offset:6d}] {path}')
    elif i == 50:
        print(f'  ... ({len(paths) - 55} more entries) ...')
