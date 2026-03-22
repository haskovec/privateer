# Palette Mapping Guide

Complete reference for which palettes are used with which resources in Wing Commander: Privateer.
Palette discovery is one of the hardest parts of working with the game data because there is no
single global palette index — palettes are referenced implicitly through scene IDs, MOVI FILD
commands, embedded PAK resources, or hardcoded convention.

## Palette Format

All palettes use the same 772-byte format:
```
Offset  Size  Description
0x0000  4     Header/flags (typically ignored)
0x0004  768   RGB data: 256 entries × 3 bytes, VGA 6-bit (0-63) per channel
```

VGA 6-bit to 8-bit conversion: `(value << 2) | (value >> 4)`, producing range 0-255.

Color index 0 is treated as transparent during sprite blitting (except for opaque
full-screen backgrounds where it means black).

## Standalone PAL Files (4 files in TRE)

| File | TRE Path | Purpose | Used By |
|------|----------|---------|---------|
| `PCMAIN.PAL` | `PALETTE/PCMAIN.PAL` | Main game palette | Default fallback, sprite viewer, general gameplay |
| `PREFMAIN.PAL` | `PALETTE/PREFMAIN.PAL` | Preferences/menu palette | Settings screens |
| `SPACE.PAL` | `PALETTE/SPACE.PAL` | Space flight palette | In-flight cockpit and space rendering |
| `JOYCALIB.PAL` | `PALETTE/JOYCALIB.PAL` | Joystick calibration | Joystick setup screen |

## OPTPALS.PAK — Scene Palette Container

**Location:** `DATA/OPTIONS/OPTPALS.PAK` (42 entries, 772 bytes each)

This is the primary palette container for all base/landing scenes and UI screens.
Each resource is a standard 772-byte palette.

### Scene Background Mapping (OPTSHPS.PAK)

Scene backgrounds are in OPTSHPS.PAK. The scene ID from GAMEFLOW.IFF maps directly
to both the OPTSHPS.PAK resource index (for the sprite) and the OPTPALS.PAK index
(for the palette):

| OPTPALS Index | Scene IDs | Description |
|---------------|-----------|-------------|
| 0 | 0 | New Detroit concourse |
| 1 | 1 | Mining base concourse |
| 2-15 | 2-15 | Various base room backgrounds |
| 16-20 | 16-20 | Additional base scenes |
| 23 | 23 | Base scene |
| 25 | 25 | Base scene |
| 28 | — | **Quine 4000 terminal** (used by CUBICLE.PAK) |
| 35-37 | 35-37 | Base scenes |
| 39 | 39, 42-45 | **Title screen / Guild scenes** (dark purple, color 0 = VGA6 4,0,4 → RGB 16,0,16) |
| 40-41 | 40-41, 46-61 | Base scenes (41 is reused for scenes 42+) |

### Palette Inheritance Rules (Scenes 42+)

Scenes above 41 don't have their own palette entry. They inherit from related scenes:

| Scene Range | Tune | Inherits From | Notes |
|-------------|------|---------------|-------|
| 42-45 | 8 (guild) | Palette 39 | Guild hall scenes |
| 46-55 | 9 (merchant guild) | Room's first scene | Merchant guild scenes |
| 56-57 | 2 (finale) | Palette 0 (fallback) | Finale cutscene scenes |
| 59, 61 | — (bar/bartender) | Room's first scene | Shared bar scenes across all base types |

**Implementation:** `src/game/room_assets.zig:paletteIndex()` encodes these rules.

### Special UI Screen Palettes

| Palette | Resource | Description |
|---------|----------|-------------|
| `PCMAIN.PAL` | LOADSAVE.SHP sprite 0 | Quine 4000 PDA device (registration/save/load screen) |
| OPTPALS 28 | CUBICLE.PAK resources | Encyclopedia viewer (MOVI-composed in-game computer) |
| OPTPALS 39 | OPTSHPS.PAK resource 181 | Title screen (NEW/LOAD/OPTIONS/QUIT) |

## Embedded PAK Palettes (Resource 0)

Many PAK files embed their palette as the first flat resource (index 0, exactly 772 bytes).
The MOVI movie system relies on this convention: FILD commands reference sprites at
`param3 + 1` (offset by 1 to skip the palette at resource 0).

### PAK Files with Embedded Palettes

| PAK File | TRE Path | Palette At | Used By |
|----------|----------|------------|---------|
| `MID1.PAK` | `MIDGAMES/MID1.PAK` | Resource 0 | Opening cinematic (scenes mid1a-mid1f) |
| `MIDTEXT.PAK` | `MIDGAMES/MIDTEXT.PAK` | Resource 0 | Movie text overlay strings (24 entries) |
| Scene PAK files | `MIDGAMES/MID*.PAK` | Resource 0 | Individual MOVI scene sprite data |

**Note:** Not all PAK files have embedded palettes. OPTSHPS.PAK, CU.PAK, CUBICLE.PAK,
LTOBASES.PAK, and cockpit PAK files do NOT have resource 0 as a palette — they use
OPTPALS.PAK or standalone PAL files instead.

## MOVI Movie Palette System

FORM:MOVI files (intro cinematics) reference palettes through a multi-level indirection:

1. **FILE chunk** lists PAK file paths by slot index (e.g., slot 0 = `mid1.pak`)
2. **FILD chunk** records reference FILE slots and specify resource indices
3. The first resource (index 0) of each referenced PAK is the palette
4. Sprite resources start at index 1 (`param3 + 1` in FILD records)

### FILD Palette Resolution

```
FILD record: object_id, file_ref, param1 (type), param2, param3 (sprite index)

Palette lookup:
  1. file_ref → FILE slot → PAK file path
  2. Load PAK file from TRE
  3. PAK resource 0 (772 bytes) = palette for this file
  4. Sprite data = PAK resource (param3 + 1)
```

### CUBICLE.IFF Palette Discovery

The Quine 4000 palette was discovered through CUBICLE.IFF's FILD commands:
- FILE slot 1 references `optpals.pak`
- FILD object 3: `file_ref=1, param3=27` → OPTPALS.PAK resource 28

This is the only known case where a FILD references OPTPALS.PAK directly rather
than using an embedded palette.

## Palette Usage Summary

| Context | Palette Source | Index/Mechanism |
|---------|---------------|-----------------|
| Scene backgrounds (0-41) | OPTPALS.PAK | `palette[scene_id]` |
| Scene backgrounds (42+) | OPTPALS.PAK | Inherited from room's first scene |
| Title screen | OPTPALS.PAK | Index 39 (hardcoded) |
| Quine 4000 terminal | `PCMAIN.PAL` | LOADSAVE.SHP sprite 0 (registration/save/load screen) |
| Space flight | `SPACE.PAL` | Standalone file |
| Intro movie scenes | MID*.PAK resource 0 | Embedded in each scene PAK |
| Sprite viewer default | `PCMAIN.PAL` | Standalone file (fallback) |
| Options/preferences | `PREFMAIN.PAL` | Standalone file |
| Joystick calibration | `JOYCALIB.PAL` | Standalone file |

## Sprite File Inventories

Documenting what each sprite in a multi-sprite file is used for, since this
information is not stored in the file format itself.

### OPTIONS/LOADSAVE.SHP (12 sprites, all 320x200, PCMAIN palette)

The Quine 4000 computer terminal — used for new-game registration,
save/load, and in-game computer access.

| Sprite | Description |
|--------|-------------|
| 0 | Full Quine 4000 device (PDA with green screen, buttons, QUINE 4000 branding) |
| 1 | Right button panel only (SAVE/LOAD/MISSIONS/FIN/MAN/PWR overlay) |
| 2 | SAVE button highlight overlay |
| 3 | LOAD button highlight overlay |
| 4 | MISSIONS button highlight overlay |
| 5 | FIN button highlight overlay |
| 6 | MAN button highlight overlay |
| 7 | PWR button highlight overlay |
| 8-11 | D-pad direction highlights / additional UI states |

### OPTIONS/OPTSHPS.PAK (226 resources)

| Resource Range | Description |
|----------------|-------------|
| 0-61 | Scene backgrounds (indexed by GAMEFLOW scene ID) |
| 62-180 | UI overlays, click region hotspots, animation frames |
| 181 | Title screen (planet, ship, PRIVATEER text, menu bar) |
| 182-225 | Additional UI elements and overlays |

### MIDGAMES/CUBICLE.PAK (10 resources, OPTPALS palette 28)

The in-game encyclopedia/computer viewer, composed by CUBICLE.IFF MOVI script.

| Resource | Size | Description |
|----------|------|-------------|
| 0 | 60x78 | PDA device body sprite (small, for MOVI composition) |
| 1 | 60x78 | Screen animation frames (37 sub-sprites) |
| 2 | 49x22 | Button highlight animation frames (37 sub-sprites) |
| 3 | 46x20 | Button text animation frames (37 sub-sprites) |
| 4 | 46x25 | Additional button states (38 sub-sprites) |
| 5 | 53x71 | Screen content animation (37 sub-sprites) |
| 6 | 113x78 | Button panel with text labels (18 sub-sprites) |
| 7 | 117x80 | Device frame/outline template |
| 8 | 320x200 | Cockpit viewscreen frame background |
| 9 | 320x200 | Full composed encyclopedia screen (device + text content) |

## How to Find a Palette for an Unknown Resource

1. **Check if the PAK has a 772-byte resource 0** — if yes, that's the palette
2. **Check if there's a matching IFF** (e.g., CUBICLE.IFF for CUBICLE.PAK) — parse
   FILD commands for palette references
3. **If it's a GAMEFLOW scene** — use `room_assets.paletteIndex(scene_id)` with OPTPALS.PAK
4. **Try OPTPALS.PAK indices 0-41** — render with each and inspect visually
5. **Try standalone PAL files** — PCMAIN.PAL is the most common fallback
6. **Use the sprite viewer** with `--palette <path>` to test different palettes
