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

| OPTPALS Index | Resource | Description |
|---------------|----------|-------------|
| 28 | CUBICLE.PAK resource 8 | Quine 4000 registration terminal background |
| 39 | OPTSHPS.PAK resource 181 | Title screen (NEW/LOAD/OPTIONS/QUIT) |

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
| Quine 4000 terminal | OPTPALS.PAK | Index 28 (from CUBICLE.IFF FILD) |
| Space flight | `SPACE.PAL` | Standalone file |
| Intro movie scenes | MID*.PAK resource 0 | Embedded in each scene PAK |
| Sprite viewer default | `PCMAIN.PAL` | Standalone file (fallback) |
| Options/preferences | `PREFMAIN.PAL` | Standalone file |
| Joystick calibration | `JOYCALIB.PAL` | Standalone file |

## How to Find a Palette for an Unknown Resource

1. **Check if the PAK has a 772-byte resource 0** — if yes, that's the palette
2. **Check if there's a matching IFF** (e.g., CUBICLE.IFF for CUBICLE.PAK) — parse
   FILD commands for palette references
3. **If it's a GAMEFLOW scene** — use `room_assets.paletteIndex(scene_id)` with OPTPALS.PAK
4. **Try OPTPALS.PAK indices 0-41** — render with each and inspect visually
5. **Try standalone PAL files** — PCMAIN.PAL is the most common fallback
6. **Use the sprite viewer** with `--palette <path>` to test different palettes
