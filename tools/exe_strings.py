import struct

EXE_PATH = r'C:\progra~1\eagame~1\wingco~1\DATA\PRCD.EXE'

with open(EXE_PATH, 'rb') as f:
    data = f.read()

# Extract meaningful strings (length >= 4)
strings = []
current = []
start_pos = 0
for i, b in enumerate(data):
    if 32 <= b < 127:
        if not current:
            start_pos = i
        current.append(chr(b))
    else:
        if len(current) >= 4:
            s = ''.join(current)
            strings.append((start_pos, s))
        current = []

# Filter to interesting game-related strings
keywords = [
    'mission', 'ship', 'weapon', 'cargo', 'trade', 'pirate', 'kilrathi',
    'confed', 'militia', 'mercenary', 'merchant', 'bounty', 'nav',
    'jump', 'land', 'launch', 'dock', 'base', 'planet', 'system',
    'sector', 'quadrant', 'galaxy', 'universe',
    'gun', 'missile', 'torpedo', 'shield', 'armor', 'engine',
    'radar', 'turret', 'afterburner', 'tractor', 'ecm',
    'credits', 'commodity', 'price', 'buy', 'sell',
    'save', 'load', 'menu', 'option', 'pause',
    'damage', 'repair', 'fuel', 'energy',
    'autopilot', 'communicate', 'eject',
    'centurion', 'galaxy', 'orion', 'tarsus', 'demon', 'drayman',
    'gladius', 'broadsword', 'stiletto', 'talon', 'dralthi', 'gothri',
    '.iff', '.pak', '.vpk', '.vpf', '.shp', '.pal', '.voc',
    'priv', 'error', 'file', 'memory', 'open', 'close', 'read', 'write',
    'keyboard', 'joystick', 'mouse', 'sound', 'music',
    'vga', 'palette', 'sprite', 'animation', 'render',
    'Borland', 'runtime', 'overlay',
]

print("=== PRCD.EXE String Analysis ===")
print(f"Total strings found: {len(strings)}")

# Categorize strings
categories = {
    'Game Mechanics': [],
    'Ships & Combat': [],
    'Trading & Economy': [],
    'Navigation': [],
    'File References': [],
    'UI & Input': [],
    'Technical/Runtime': [],
    'Dialogue/Story': [],
}

# Print ALL meaningful strings
print("\n=== All Meaningful Strings (filtered) ===")
for pos, s in strings:
    s_lower = s.lower()
    # Skip binary garbage patterns
    if s.count('Mn') > 2:
        continue
    if len(set(s)) < 3 and len(s) > 4:
        continue
    # Keep strings that contain interesting keywords or look like real text
    is_interesting = False
    for kw in keywords:
        if kw.lower() in s_lower:
            is_interesting = True
            break
    if not is_interesting:
        # Check if it looks like readable English
        alpha_ratio = sum(1 for c in s if c.isalpha()) / len(s) if s else 0
        if alpha_ratio > 0.7 and len(s) >= 6:
            is_interesting = True

    if is_interesting:
        # Truncate very long strings
        display = s[:120] + ('...' if len(s) > 120 else '')
        print(f"  0x{pos:06x}: {display}")
