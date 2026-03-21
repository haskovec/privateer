# Game Data Formats

## PRIV.TRE - Main Archive Format

The TRE (Tree) format is Origin Systems' archive container used across Wing Commander
Privateer, Strike Commander, and WC Armada.

### Location
- Stored inside `GAME.DAT` (ISO 9660 CD image) at LBA 27
- Total size: 89,486,108 bytes (~85 MB)
- Referenced in `PRIV.CFG` as `D:priv.tre`

### Header Structure
```
Offset  Size  Description
0x0000  4     Entry count (little-endian uint32) = 832
0x0004  4     TOC size in bytes (little-endian uint32) = 86,688
```

### Entry Format (74 bytes each, fixed size)
```
Offset  Size    Description
+0      1       Flag byte (0x01 = file, 0x00 = observed on some entries)
+1      N       Null-terminated file path (e.g., "..\..\DATA\AIDS\ATTITUDE.IFF")
+N+1    varies  Padding/metadata (DOS timestamps, attributes)
+66     4       File offset from TRE start (little-endian uint32)
+70     4       File size in bytes (little-endian uint32)
```

**Important:** File offsets are relative to the start of the TRE data within the ISO,
which is at `TRE_LBA * 2048 = 55,296` bytes into GAME.DAT. The absolute position of
a file in GAME.DAT is: `55296 + file_offset`.

### Modification Note
Setting `PRIV.CFG` to an empty value (removing `=D:priv.tre`) forces the game to
load from an unpacked `DATA\` folder instead of the TRE archive.

---

## IFF - Interchange File Format

The primary data format used for game content. Origin uses a variant of the EA IFF-85
standard.

### Structure
```
Tag     4 bytes   ASCII chunk identifier (e.g., "FORM", "INFO", "SHAP")
Size    4 bytes   Chunk data size in bytes (BIG-ENDIAN, Motorola byte order)
Data    N bytes   Chunk content
[Pad]   0-1 byte  Padding to even boundary if size is odd
```

### Container Chunks
| Tag | Description |
|-----|-------------|
| `FORM` | Standard container - 4-byte subtype follows, then child chunks |
| `CAT ` | Catalog container - groups multiple FORMs of same type |
| `LIST` | List container - similar to CAT |

### IFF FORM Types (93 unique types found)
Major categories:

**Ship/Combat Types (28):**
APPR, REAL, FITE, ENER, SHLD, DAMG, WEAP, LNCH, MISL, GUNS, CRGO,
MOBI, TRGT, HAZE, PROJ, LINR, MSSL, BEAM, EXPL, ASTR, CDBR, TDBR,
ANSC, DUST, JMPT, NMAP, EMPS, TDBR

**UI/Rendering Types (18):**
SCEN, BMAP, BM3D, SHAP, MFDS, FONT, PLAQ, ITTS, MISC, BACK, EYES,
MEDF, BTTN, WNDW, OBJE, BASN, BASS, STND

**Story/Mission Types (16):**
MSSN, SCRP, PLAY, MISS, PLOT, ACTS, CUBG, MOVI, FMGR, MSNS, MDAT,
ENMY, CORP, MISN, RNDM, RNDF

**Conversation Types (10):**
COMM, RECV, SEND, CONV, FRND, NEUT, HOST, CMBT, TUSR, PUSR, BUSR

**World/Navigation Types (8):**
UNIV, QUAD, SYST, SCTR, BASE, TEAM, ANIM, CAMR

**Economy Types (6):**
MRCH, MERC, FILE, GAME, BANK, RAND

**Ship Config Types (5):**
TYPE, SHIP, COMD, SOFT, JUMP

**Music Types (2):**
XDIR, XMID

### Chunk Types (120+ unique data chunk types found)
Most common:
| Chunk | Count | Description |
|-------|-------|-------------|
| INFO | 397 | General information/metadata |
| SHAP | 105 | Shape/sprite data (RLE compressed) |
| COPY | 70 | Copy/variant data |
| TUNE | 60 | Music tune reference |
| EFCT | 60 | Sound effect reference |
| FNAM | 58 | Filename reference |
| MNUM | 56 | Mission number |
| MSGS | 56 | Message strings |
| MNVR | 50 | Maneuver data (AI behavior) |
| CNST | 45 | Constants/parameters |
| LABL | 42 | Label/name string |
| COST | 42 | Cost/price data |
| AVAL | 42 | Availability flags |
| SKEL | 37 | Skeleton/wireframe data |
| DATA | 33 | Generic data block |
| PALT | 32 | Palette data |
| TABL | 28 | Table/lookup data |
| TEXT | 23 | Text strings |
| CAST | 23 | Character cast list |
| FLAG | 23 | Boolean flags |
| PROG | 23 | Script program |
| PART | 23 | Participant data |

---

## PAK - Packed Resource Format

Used for compressed game resources (cockpit graphics, landing screens, sounds).

### Structure
```
Offset  Size  Description
0x0000  4     Total file length (little-endian uint32)
0x0004  var   Level 1 offset table (3-byte offsets + 1-byte type marker)
```

### Marker Bytes
| Value | Meaning |
|-------|---------|
| 0xC1 | Offset points to a sub-table of offsets |
| 0xE0 | Offset points directly to data |
| 0x00 | End of table / padding |

### Files Using PAK Format (32 files, 23.2 MB total)
- `COCKPITS/*.PAK` - Cockpit overlay graphics
- `MIDGAMES/*.PAK` - Cutscene/landing screen graphics
- `OPTIONS/*.PAK` - UI graphics (OPTSHPS.PAK, OPTPALS.PAK, CU.PAK)
- `APPEARNC/STARS.PAK` - Star field data
- Speech and sound packs

### Scene Pack Sub-Format (OPTSHPS.PAK Resources, IFF SHAP Chunks)

Each L1 resource within OPTSHPS.PAK — and each SHAP chunk in IFF files (e.g. cockpit
files) — is a "scene pack": a self-contained bundle of RLE sprites with its own
internal offset table:

```
Offset  Size  Description
0x0000  4     Declared total size (LE uint32)
0x0004  var   Sprite offset table (LE uint32 entries, relative to start of resource)
[offsets] var  Sprite data (8-byte RLE header + pixel data at each offset)
```

The first offset in the table points to the first sprite. Number of sprites =
(first_offset - 4) / 4.

**Key mapping**: GAMEFLOW.IFF scene ID = OPTSHPS.PAK L1 resource index for the
background. GAMEFLOW sprite INFO bytes = global OPTSHPS.PAK L1 resource indices
for interactive hotspot sprites (typically in the 62-225 range).

Palettes are in OPTPALS.PAK (42 entries, 772 bytes each). Scene IDs 0-41 map
directly; scenes 42+ inherit from the room's first scene.

---

## VPK / VPF - Voice Pack Formats

### VPK Files (193 files, 48.6 MB - largest format by total size)
- LZW-compressed VOC audio data
- Contains conversation speech audio
- Paired with corresponding PFC files
- Header contains offset table to individual voice clips

### VPF Files (59 files, 7.7 MB)
- Same format as VPK but for different content set
- General conversation voice files (GENRUM*.VPF)

### PFC Files (193 files, 0.2 MB)
- Plain text companion files for VPK/VPF
- Contains variable name mappings (NPC names, system names)
- Null-separated string entries
- Example content: `rand_npc`, `normal`, `randcu_3`

---

## VOC - Creative Voice File

Standard Creative Labs voice format for digital audio.

### Properties
- Header: "Creative Voice File" + version info
- 8-bit unsigned PCM
- Mono
- Sample rate: 11,025 Hz (confirmed from header analysis)
- Used for: cutscene speech, in-flight voice clips

### Files (17 files, 0.4 MB)
Located in `DATA/SPEECH/MID01/`:
- `PC_1MG1.VOC` through `PC_1MG8.VOC` - Player character voice lines (intro pirate encounter)
- `PIR1MG1.VOC` through `PIR1MG9.VOC` - Pirate voice lines (intro pirate encounter)
These are used during the opening cinematic's pirate encounter scenes (mid1c*, mid1d, mid1e*).

---

## SHP - Shape/Font File

Simple sprite format with offset table.

### Structure
```
Offset  Size  Description
0x0000  4     Total file size (little-endian uint32)
0x0004  var   Offset table (4-byte entries pointing to sprite data)
...     var   RLE-encoded sprite data
```

Each sprite within the SHP uses the same RLE format and 8-byte header described above.
For font SHP files, each sprite index maps to a character: `glyph_index = char - first_char`.
DEMOFONT.SHP uses `first_char = 0` (glyph index = ASCII code directly). Uppercase letters
start at index 65 ('A'), with glyphs typically 9x12 pixels. Lowercase letters and most
control/punctuation indices are 1x1 stub sprites (no visible content) — only uppercase
A-Z, digits, and select punctuation have real glyphs. The font renderer treats 1x1 stubs
as missing characters and substitutes a space-width gap (half line height).

### Files (11 files, 0.2 MB)
- `FONTS/*.SHP` - Game fonts (CONVFONT, DEMOFONT, MSSGFONT, OPTFONT, PCFONT, PRIVFNT)
- `MOUSE/PNT.SHP` - Mouse cursor sprites

---

## PAL - Palette Files

VGA color palettes (256 colors, 3 bytes per color = 768 bytes + 4-byte header).

### Structure
```
Offset  Size  Description
0x0000  4     Header/flags
0x0004  768   RGB palette data (256 entries x 3 bytes, VGA 6-bit per channel)
```

### Files (4 files)
| File | Purpose |
|------|---------|
| `PCMAIN.PAL` | Main game palette |
| `PREFMAIN.PAL` | Preference/menu palette |
| `SPACE.PAL` | Space flight palette |
| `JOYCALIB.PAL` | Joystick calibration screen palette |

---

## Music Formats

### ADL - AdLib Music (5 files, 0.2 MB)
OPL2/OPL3 FM synthesis music data for AdLib-compatible sound cards.
Tracks: BASETUNE, COMBAT, CREDITS, OPENING, VICTORY

### GEN - General MIDI Music (5 files, 0.3 MB)
Standard MIDI music data for General MIDI compatible devices (Roland MT-32/SC-55).
Same tracks as ADL files.

### DRV - Sound Drivers (4 files)
DOS TSR sound drivers: ADLIB.DRV, PAS.DRV, ROLAND.DRV, SB.DRV

---

## FORM:MOVI - Movie/Cinematic Script Format

IFF-based animation scripting format for intro cinematics and cutscenes.
Each scene (MID1A.IFF through MID1F.IFF) is a FORM:MOVI container that
defines a composited animation frame-by-frame using a scene graph of
background layers, animated sprites, and composition ordering.

### Structure
```
FORM:MOVI
  CLRC (2 bytes)     — Clear screen flag (BE u16, nonzero = clear framebuffer)
  SPED (2 bytes)     — Frame speed in DOS ticks per frame (BE u16, 70 Hz base)
  FILE (variable)    — Indexed file reference table (see below)
  FORM:ACTS (1+)     — Animation action blocks, one per frame/keyframe:
    FILD (variable)  — Background/field sprite definitions (packed records)
    SPRI (variable)  — Animated sprite definitions (packed variable-length records)
    BFOR (variable)  — Composition/render order commands (packed 24-byte records)
```

### FILE Chunk — Indexed File References
NOT null-separated strings. Each entry is a slot ID + null-terminated path:
```
Repeated entries:
  u16 LE   Slot ID (referenced by FILD/SPRI file_ref fields)
  char[]   Null-terminated DOS path (e.g., "..\..\data\midgames\mid1.pak")
```

Example from MID1A.IFF (124 bytes, 4 entries):
```
Slot 0: ..\..\data\midgames\mid1.pak      (sprite PAK — backgrounds, objects)
Slot 1: ..\..\data\midgames\midtext.pak    (text overlay strings)
Slot 2: ..\..\data\fonts\demofont.shp      (font glyphs)
Slot 4: ..\..\data\sound\opening           (audio reference)
```
Slot IDs can be sparse (slot 3 is skipped above).

### FILD Chunk — Field/Background Sprite Definitions
Packed 10-byte records defining background layers. Each record assigns an
object ID to a sprite loaded from a PAK file reference.
```
Offset  Size  Description
+0      2     Object ID (LE u16, unique identifier for BFOR referencing)
+2      2     File reference slot (LE u16, index into FILE slot table)
+4      2     Parameter 1 (LE u16, layer type or sprite sub-index)
+6      2     Parameter 2 (LE u16)
+8      2     Parameter 3 (LE u16, possibly a secondary sprite index)
```
Number of records = chunk size / 10 (final record may be 8 bytes if chunk
size is not evenly divisible by 10).

### SPRI Chunk — Animated Sprite Definitions
Packed variable-length records defining animated or positioned sprites.
Each record starts with a 2-byte object ID and has a variable-length
parameter block.

Observed record sizes: 14, 20, or 26 bytes. The record length appears
to depend on the flags/type at bytes 2-5:
```
Offset  Size  Description
+0      2     Object ID (LE u16)
+2      2     Flags/type word 1 (LE u16, 0x8000 = standalone, else FILD ref)
+4      2     Flags/type word 2 (LE u16, 0x8000 = has extended params)
+6      2     Data length or type indicator (LE u16)
+8      var   Variable parameters (animation keyframes, coordinates, etc.)
```

When words 1-2 are both 0x8000 and word 3 > 0, the record has word 3
additional bytes of keyframe/path data. When word 1 is a small value
(not 0x8000), it references a FILD object ID.

### BFOR Chunk — Composition/Render Order
Packed 24-byte records that define the scene composition order and
drive actual rendering. BFOR references object IDs defined by FILD
and SPRI to compose the final frame.
```
Offset  Size  Description
+0      2     Object ID or command type (LE u16)
+2      2     Flags (LE u16, 0x7FFF = layer command, else object ref)
+4      20    Parameters (coordinates, clip regions, render flags)
```

The rendering model is scene-graph based:
1. FILD defines static sprite resources (assign IDs, load from PAK)
2. SPRI defines animated/dynamic sprites (assign IDs, keyframe data)
3. BFOR drives the actual composition (references IDs, sets draw order)

FILD and SPRI are definition-only — BFOR executes the rendering.

### Files
- `MIDGAMES/MID1A.IFF` through `MID1F.IFF` — Opening intro scenes
- `MIDGAMES/MID1C1-C4.IFF`, `MID1E1-E4.IFF` — Scene variants
- `MIDGAMES/VICTORY1-5.IFF` — Victory cinematics
- Referenced PAK files: `MID1.PAK` (sprites), `MIDTEXT.PAK` (text),
  `MID1TXT.PAK` (additional text)

---

## DAT - Data Tables

### TABLE.DAT (4,761 bytes)
Located in `DATA/SECTORS/` - Navigation/sector lookup table.
Binary format with byte-sized entries representing sector connectivity and properties.

### COMBAT.DAT (1,896 bytes)
Located in `DATA/SOUND/` - Combat sound effect mapping table.
Maps combat events to sound effect indices.

---

## RLE Sprite Compression

Origin's proprietary Run-Length Encoding used for all sprite graphics.

### Image Header (8 bytes)
```
Offset  Size  Description
+0      2     X2 (signed int16 LE, pixels right of center)
+2      2     X1 (signed int16 LE, pixels left of center)
+4      2     Y1 (signed int16 LE, pixels above center)
+6      2     Y2 (signed int16 LE, pixels below center)
```
Coordinates use Cartesian system with (0,0) at image center.
**Width = X1 + X2 + 1** (left extent + center pixel + right extent).
**Height = Y1 + Y2 + 1** (top extent + center pixel + bottom extent).

Full-screen backgrounds use X2=319, X1=0, Y1=0, Y2=199 → 320×200.

### RLE Data Structure
```
2 bytes   Key number (unsigned int16 LE, encoding selector via LSB)
2 bytes   X coordinate offset (signed int16 LE, center-relative)
2 bytes   Y coordinate offset (signed int16 LE, center-relative)
variable  Pixel data
0x0000    Row/segment terminator
```
Coordinates are relative to the sprite center (0,0). To convert to pixel buffer
positions: `buf_x = x_off + X1`, `buf_y = y_off + Y1`. Full-screen sprites
(X1=0, Y1=0) have non-negative offsets. Font glyphs with Y1=11 use negative
y_off values (e.g. y_off=-11 for the top row).

### Decoding Rules
- **Even key (LSB=0):** `key / 2` = pixel count; raw color bytes follow
- **Odd key (LSB=1):** `key / 2` = pixel count; sub-encoded data:
  - Even sub-byte (LSB=0): `byte / 2` = sub-pixel count; individual color bytes follow
  - Odd sub-byte (LSB=1): `byte / 2` = sub-pixel count; single color byte repeats
