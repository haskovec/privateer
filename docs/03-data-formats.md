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

VGA 6-bit to 8-bit conversion: `(value << 2) | (value >> 4)`, producing range 0-255.

### Standalone PAL Files (4 files)
| File | Purpose |
|------|---------|
| `PCMAIN.PAL` | Main game palette (default fallback) |
| `PREFMAIN.PAL` | Preference/menu palette |
| `SPACE.PAL` | Space flight palette |
| `JOYCALIB.PAL` | Joystick calibration screen palette |

### OPTPALS.PAK — Scene Palette Container
42 palettes (indices 0-41), 772 bytes each. Scene IDs 0-41 map directly to
palette indices. Scenes 42+ inherit from the room's first scene.

Special entries: **palette 28** = Quine 4000 terminal, **palette 39** = title screen.

### Embedded PAK Palettes
Many PAK files (especially MOVI scene PAKs like MID1.PAK) embed a palette as
resource 0 (772 bytes). FILD commands in MOVI files reference sprites at
`param3 + 1` to skip the palette resource.

See [Palette Mapping Guide](12-palette-mapping.md) for the complete mapping of
which palettes go with which resources.

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

### FILE Chunk — Polymorphic Indexed File References
Each entry is a slot ID + null-terminated path. Slots reference different
file types — the loader must detect by extension:
```
Repeated entries:
  u16 LE   Slot ID (referenced by FILD file_ref fields)
  char[]   Null-terminated DOS path (e.g., "..\..\data\midgames\mid1.pak")
```

File types referenced by FILE slots:
- `.PAK` → Sprite/resource PAKs (MID1.PAK, MIDTEXT.PAK) — loaded into renderer
- `.SHP` → Font files (DEMOFONT.SHP, CONVFONT.SHP) — loaded as Font objects
- `.VOC` → Voice clips (PIR1MG*.VOC, PC_1MG*.VOC) — specify which clips to play
- No extension → Sound directory references (e.g., "opening") — skip for rendering

VOC slots specify per-scene voice clips. Each dialogue scene embeds its
exact voice files:
```
MID1C1: slots 61-63 = pir1mg1-3.voc  (pirate lines 1-3)
MID1C2: slots 94-95 = pc_1mg1-2.voc  (player lines 1-2)
MID1C3: slots 116-117 = pir1mg4-5.voc
MID1C4: slots 138-139 = pc_1mg3-4.voc
MID1E1: slots 160-161 = pir1mg6-7.voc
MID1E2: slot 182 = pc_1mg5.voc
MID1E3: slots 193-194 = pir1mg8-9.voc
MID1E4: slots 215-217 = pc_1mg6-8.voc
```

Slot IDs can be sparse and very large (up to 217+).

### FILD Chunk — Field/Background Sprite Definitions
Packed 10-byte records defining sprite objects. Each record assigns an
object ID to a sprite resource loaded from a PAK file reference.
```
Offset  Size  Description
+0      2     Object ID (LE u16, unique identifier for BFOR/SPRI referencing)
+2      2     File reference slot (LE u16, index into FILE slot table)
+4      2     Param1 / type (LE u16): 2=background, 3=overlay. NOT a resource index.
+6      2     Param2 (LE u16): typically 2 (palette mode constant)
+8      2     Param3 / sprite index (LE u16): PAK resource index (0-based).
              Actual PAK resource = param3 + 1 (resource 0 is always the palette).
```

**CRITICAL**: param1 is a TYPE indicator (2=background, 3=overlay), NOT the PAK
resource index. The sprite resource index is `param3 + 1` (offset by 1 to skip
the 772-byte palette at PAK resource 0).

Number of records = chunk size / 10 (trailing bytes are padding).

For font FILDs (file_ref pointing to .SHP slot): params have different meanings
(font glyph references, not sprite indices).

### SPRI Chunk — Sprite Command Definitions
Packed variable-length records defining positioned, animated, or text sprites.
```
Offset  Size  Description
+0      2     Object ID (LE u16, unique for BFOR referencing)
+2      2     Reference (LE u16): FILD object_id, or 0x8000 = self-defined
+4      2     Sentinel (LE u16, always 0x8000)
+6      2     Sprite type (LE u16, determines param count)
+8      var   Parameters (N × u16 LE, count from type table below)
```

Sprite type → parameter count:
| Type | Params | Size  | Purpose                                     |
|------|--------|-------|---------------------------------------------|
| 0    | 3      | 14 B  | Simple positioned sprite (x, y, flags)      |
| 1    | 3      | 14 B  | Positioned sprite variant                   |
| 3    | 5      | 18 B  | Extended positioned sprite (x, y, ?, ?, ?)  |
| 4    | 9      | 26 B  | Animation keyframe path (self-ref)          |
| 11   | 5      | 18 B  | Extended positioned variant                 |
| 12   | 6      | 20 B  | Text overlay (x, y, ?, text_ref, font_ref, color) |
| 18   | 7      | 22 B  | Extended animation variant                  |
| 19   | 9      | 26 B  | Animation + audio trigger                   |
| 20   | 9      | 26 B  | Animation + audio trigger variant           |

For non-self-ref records (ref != 0x8000): ref is a FILD object_id that
provides the PAK file/resource for the sprite data.

For type 0/1 with FILD ref: params[0]=x, params[1]=y (signed i16).
For type 3/11: params[0]=x, params[1]=y, params[3-4]=additional control.
For type 20 with FILD ref: params[0]=x, params[1]=y (used for combat sprites).
For type 12 (text): params[3]=text FILD ref, params[4]=font FILD ref, params[5]=color.
For type 4 self-ref: animation keyframe data (not yet fully decoded).

### BFOR Chunk — Composition/Render Order
Packed 24-byte records that define the scene composition order and
drive actual rendering. BFOR references object IDs defined by FILD
and SPRI to compose the final frame.
```
Offset  Size  Description
+0      2     Object ID or command type (LE u16)
+2      2     Flags (LE u16): 0x7FFF = layer/control command, else FILD/SPRI object ref
+4      20    Parameters (10 × u16 LE: coordinates, clip regions, render flags)
```

Observed BFOR command patterns across all 12 intro scenes:
```
obj= 7 flags=LAYER  — Starfield background layer (always present)
obj= 8 flags=LAYER  — Second background layer
obj=28 flags=LAYER  — Third background layer
obj=10 flags=LAYER params=[0,25,319,152,...] — Main viewport clip region
obj=11 flags=LAYER params=[0,25,319,152,...] — Main viewport duplicate
obj=12 flags=LAYER params=[0,153,319,199,...] — Bottom text region
obj= 9 flags=OBJ:X  — Render background FILD (flags = FILD object_id with p1=2)
obj=14 flags=OBJ:X params=[Y,...] — Render overlay SPRI X, base context SPRI Y
obj= 6 flags=OBJ:X  — Render foreground SPRI X
obj=42 flags=LAYER params=[N,...] — Control/timing command
```

The rendering model:
1. FILD defines sprite resources (object_ids → PAK file + resource index)
2. SPRI defines how sprites are positioned/animated (references FILD objects)
3. BFOR drives the actual rendering in order:
   - LAYER commands define clip regions and control state
   - Non-LAYER commands reference FILD or SPRI objects to render
   - BFOR obj=9 always renders the full-screen background
   - BFOR obj=14 renders overlay sprites (ships, objects)
   - BFOR obj=6 renders the foreground layer

### Scene Architecture — Intro Movie Flow
The 6 scenes (after variant selection from 12 files) work as follows:

**mid1a** (1 ACTS): Opening — planet with text overlays ("2669, GEMINI SECTOR...").
SPED=512. Has type 4 self-ref SPRI (scrolling star animation keyframes) and
type 12 SPRI (text overlays). Text references MIDTEXT.PAK strings + DEMOFONT.SHP font.

**mid1b** (3 ACTS): Ship approach — 3 animation frames showing the ship cockpit.
Each ACTS block has completely different FILD object_ids and sprite resources
(p3 values advance: 0,4,5 → 6,7,8,9 → 10,11,12). Delta compositing: frames
build on each other.

**mid1c1-c4** (1 ACTS, EMPTY): Dialogue scenes — NO FILD, SPRI, or BFOR data.
The previous scene's framebuffer persists (CLRC=0). FILE slots specify VOC
clips for pirate or player voice lines. mid1c1/c3 = pirate lines, mid1c2/c4 = player.

**mid1d** (9 ACTS): Combat sequence — 9 animation frames of ships, laser fire,
explosions. Largest scene. FILD p3 values range from 22 to 64 (43 different
sprite resources from MID1.PAK). SPRI types include 0, 1, 3, 20 (combat
animations with FILD references).

**mid1e1-e4** (1 ACTS each): Post-combat dialogue with character portraits.
Has FILD/SPRI/BFOR for cockpit views + text overlays (type 12) +
portrait rendering (type 11). FILE slots specify per-scene VOC clips.

**mid1f** (3 ACTS): Victory/finale — ships flying away, ending sequence.

### Files
- `MIDGAMES/MID1A.IFF` through `MID1F.IFF` — Opening intro scenes
- `MIDGAMES/MID1C1-C4.IFF`, `MID1E1-E4.IFF` — Scene variants
- `MIDGAMES/VICTORY1-5.IFF` — Victory cinematics
- `MIDGAMES/MID1.PAK` — Sprite data (65+ resources: palette + sprite packs)
- `MIDGAMES/MIDTEXT.PAK` — 24 text strings for intro overlays
- `FONTS/DEMOFONT.SHP`, `FONTS/CONVFONT.SHP` — Cinematic fonts
- `SPEECH/MID01/PC_1MG1-8.VOC` — 8 player voice clips
- `SPEECH/MID01/PIR1MG1-9.VOC` — 9 pirate voice clips

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
