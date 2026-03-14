import struct
import os
from collections import defaultdict

GAME_DAT = r'C:\progra~1\eagame~1\wingco~1\DATA\GAME.DAT'
TRE_LBA = 27
SECTOR = 2048

with open(GAME_DAT, 'rb') as f:
    f.seek(TRE_LBA * SECTOR)
    data = f.read(500000)

count = struct.unpack_from('<I', data, 0)[0]
toc_size = struct.unpack_from('<I', data, 4)[0]

# Extract all file paths with their metadata
search = b"..\\..\\DATA"
paths = []
start = 0
while True:
    idx = data.find(search, start)
    if idx == -1 or idx > 400000:
        break
    end = data.find(b'\x00', idx)
    if end == -1:
        end = idx + 100
    path = data[idx:end].decode('ascii', errors='replace')
    paths.append((idx, path))
    start = end + 1

# Categorize by directory
dirs = defaultdict(list)
extensions = defaultdict(int)
for _, path in paths:
    # Normalize path
    parts = path.replace("..\\..\\DATA\\", "").split("\\")
    dirname = parts[0] if len(parts) > 1 else "ROOT"
    filename = parts[-1]
    ext = os.path.splitext(filename)[1].upper()
    dirs[dirname].append(filename)
    extensions[ext] += 1

print("=" * 70)
print("WING COMMANDER: PRIVATEER - GAME DATA ANALYSIS")
print("=" * 70)
print(f"\nTotal files in PRIV.TRE: {len(paths)}")
print(f"TOC size: {toc_size} bytes")
print(f"\nFile extensions:")
for ext, cnt in sorted(extensions.items(), key=lambda x: -x[1]):
    print(f"  {ext:10s}: {cnt:4d} files")

print(f"\nDirectory structure ({len(dirs)} directories):")
for dirname in sorted(dirs.keys()):
    files = dirs[dirname]
    print(f"\n  {dirname}/ ({len(files)} files)")
    for fn in sorted(files)[:10]:
        print(f"    {fn}")
    if len(files) > 10:
        print(f"    ... and {len(files) - 10} more")

# Now analyze a sample IFF file to understand the format
print("\n" + "=" * 70)
print("IFF FILE FORMAT ANALYSIS")
print("=" * 70)

# Parse the TRE entry format to find file offsets
# Each entry appears to be: [path_offset] [null-term path] [metadata bytes]
# Let's look at the bytes between entries
print("\nTRE Entry format analysis (first 5 entries):")
for i in range(min(5, len(paths))):
    idx, path = paths[i]
    # Look at bytes before the path
    if idx >= 8:
        pre_bytes = data[idx-8:idx]
    else:
        pre_bytes = data[0:idx]
    # Look at bytes after null terminator
    end = data.find(b'\x00', idx)
    post_bytes = data[end+1:end+41]

    print(f"\n  Entry {i}: {path}")
    print(f"    Pre-path bytes: {pre_bytes.hex()}")
    print(f"    Post-null bytes: {post_bytes.hex()}")

    # Try to interpret post-null bytes
    if len(post_bytes) >= 20:
        vals = struct.unpack_from('<5I', post_bytes, 0)
        print(f"    As uint32 LE: {vals}")
        vals_be = struct.unpack_from('>5I', post_bytes, 0)
        print(f"    As uint32 BE: {vals_be}")
