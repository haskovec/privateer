# Scene System Gaps Analysis

Current state: the game launches, shows a title screen background from OPTSHPS.PAK,
but has no text overlay and cannot properly transition into gameplay scenes.

## Issues

### 1. Title Screen Has No Text

`src/main.zig:updateTitle()` renders the OPTSHPS.PAK background sprite but never
renders any text. The text rendering system (`src/render/text.zig`) exists and works,
but is not called from the title screen. The original game displayed menu options
and/or instructions over this background using DEMOFONT.SHP.

### 2. Landed Scene Shows "Blob of Color"

`src/main.zig:loadLandedBackground()` has hardcoded PAK file names:

```zig
const pak_names = [_][]const u8{
    "LTOBASES.PAK",
    "CU.PAK",
    "OPTSHPS.PAK",
};
```

It always tries resource index 1 from whichever PAK succeeds first. LTOBASES.PAK
resource 1 is likely a small transition frame (not a full scene background), producing
a small sprite in the upper-left corner with the rest of the screen black.

The function completely ignores the GAMEFLOW room/scene data when choosing what to load.

### 3. Click Regions Are All Fullscreen

`src/main.zig:buildClickRegions()` creates every click region as (0, 0, 320, 200):

```zig
try regions.append(allocator, .{
    .x = 0,
    .y = 0,
    .width = 320,
    .height = 200,
    .sprite_id = spr.info,
    .action = action,
});
```

Sprite position data from PAK headers (x1, y1, x2, y2) is never used. Every click
hits every region, and the last region in the list always wins.

### 4. No Room Type ID to PAK File Mapping

This is the core missing piece. GAMEFLOW.IFF defines 60 rooms (FORM:MISS) each with
an INFO byte (room type ID), scenes, and interactive sprites with EFCT action data.
But the visual backgrounds for each room type live in separate PAK files, and the
code has no mapping from room type ID to PAK file name.

The original game had this mapping hardcoded in PRCD.EXE. We need to reverse-engineer
it from the executable.

### 5. Scene Transitions Reload the Same Broken Background

Even when a valid scene transition fires via click regions, `loadLandedBackground()`
always loads the same hardcoded PAK. The room/scene IDs tracked by the state machine
are never used to select which PAK file or resource index to load.

## Reverse Engineering Results (PRCD.EXE Analysis)

### Scene ID = OPTSHPS.PAK L1 Index (Direct Mapping)

The mapping from GAMEFLOW scenes to PAK resources is **direct**: the scene INFO byte
(scene ID) from GAMEFLOW.IFF is used directly as the L1 index into OPTSHPS.PAK.

There is NO separate room-type-to-PAK mapping table. All scene backgrounds live in
a single file: `..\..\DATA\OPTIONS\OPTSHPS.PAK`.

OPTSHPS.PAK contains 226 L1 entries:
- **Entries 0-61**: Scene backgrounds (indexed by scene ID from GAMEFLOW)
- **Entries 62-225**: UI elements, overlays, fonts, and animation frames

Each scene pack entry contains:
- `[0..4]`: Declared resource size (LE uint32)
- `[4..N*4+4]`: Offset table (LE uint32 entries) pointing to sprites within this pack
- `[offsets..]`: Sprite data (8-byte header + RLE pixel data)

Most scene backgrounds (scenes 0-16, 19-20, 23, 25, 35-37, 40-43, 47-48, 50-61)
are single 319x199 full-screen sprites. Others have multiple sprites (overlays).

### Palette Mapping

Palettes are in `..\..\DATA\OPTIONS\OPTPALS.PAK` (42 L1 entries, 772 bytes each).

- **Scene IDs 0-41**: Direct mapping -- palette[scene_id] in OPTPALS.PAK
- **Scene IDs 42+**: Share palette with the first scene of the same room type:
  - Scenes 42-45 (guild, tune=8): Use palette from scene 39
  - Scenes 46-55 (merchant guild, tune=9): Need guild palette (exact index TBD)
  - Scenes 56-57 (finale, tune=2): Need finale palette (exact index TBD)
  - Scenes 59, 61 (bar/conversation): Shared across all rooms -- inherit the
    current room's palette (use the first scene's palette from that room)

### CU.PAK (Close-Up Views)

`..\..\DATA\OPTIONS\CU.PAK` contains 30 L1 entries with E0 markers. Each entry is a
single 319x128 or 319x199 sprite. These are close-up views used for NPC conversations
and character creation, NOT for scene backgrounds. Referenced in the EXE as `cu`/`cu2`
(base game / Righteous Fire variants).

### LTOBASES.PAK (Landing Transitions)

`..\..\DATA\MIDGAMES\LTOBASES.PAK` contains 10 L1 entries with small sprites (82x66
to 140x80). These are landing-to-base transition animation frames, NOT scene backgrounds.

### Click Region Bounds

Sprite bounding boxes come from the PAK sprite headers within each scene pack. Each
sprite in a scene pack has its own header with center-relative extents (x2, x1, y1, y2).
The sprite INFO bytes in GAMEFLOW's FORM:SPRT data correspond to sprite indices within
the scene pack. The click region for sprite N uses the bounds of scene_pack.sprite[N].

### FILES.IFF Registry

`..\..\DATA\OPTIONS\FILES.IFF` (FORM:FILE) contains a registry mapping logical names
to TRE file paths. Key entries:
- `GAMEFIFF` -> `..\..\data\options\gameflow.iff`
- `MISCSHPS` -> `..\..\data\options\optshps.pak`
- `PALTOPTS` -> `..\..\data\options\optpals.pak`

## What Needs To Be Done

### Implementation Fixes Needed

1. **Fix `loadLandedBackground()`** to load from OPTSHPS.PAK using the current scene ID
   as the L1 resource index. The function should:
   - Get the current scene ID from the state machine
   - Parse OPTSHPS.PAK to get the L1 entry at index `scene_id`
   - Parse that resource as a scene pack
   - Decode sprite 0 as the background

2. **Load palette from OPTPALS.PAK** using scene ID (for scenes 0-41) or the room's
   first scene ID (for scenes 42+, 59, 61). Apply the palette before rendering.

3. **Fix `buildClickRegions()`** to use sprite bounds from the scene pack. The sprite
   INFO byte in GAMEFLOW corresponds to a sprite index within the OPTSHPS scene pack.
   Read the sprite header's (x2, x1, y1, y2) to compute the click region bounds.

4. **Add title screen text** using DEMOFONT.SHP and the text renderer, matching the
   original game's title screen layout.

5. **Add proper scene navigation** so that click region actions correctly reload the
   scene background from OPTSHPS.PAK with the new scene ID as the resource index.

## Files Involved

| File | Role |
|------|------|
| `src/main.zig` | Main game loop, scene loading, title screen |
| `src/game/scene.zig` | GAMEFLOW.IFF parser (rooms, scenes, sprites) |
| `src/game/game_state.zig` | State machine (title/loading/landed transitions) |
| `src/game/click_region.zig` | EFCT action parser, hit-testing |
| `src/render/scene_renderer.zig` | PAK sprite compositing |
| `src/render/text.zig` | Text rendering (exists but unused in main loop) |
| `src/game/midgame.zig` | Midgame animation PAK loader (reference for PAK handling) |

## GAMEFLOW Structure Reference

```
FORM:GAME
  FORM:MISS (per room type, 60 total)
    INFO (1 byte: room type ID)
    TUNE (1 byte: music track)
    EFCT (sound effect data)
    FORM:SCEN (per scene in room, 291 total)
      INFO (1 byte: scene ID)
      FORM:SPRT (per interactive sprite/hotspot)
        INFO (1 byte: sprite ID)
        EFCT (action data: 2 bytes = type + param, >2 bytes = scripted)
        [REQU] (optional: access requirements)
```

EFCT action types: 0x01 = scene transition, 0x0E = launch, 0x18 = takeoff,
0x19 = bar conversation, 0x1A = bartender, 0x1B = ship dealer, 0x1C = commodity
exchange, 0x1D = mission computer, 0x1E = equipment dealer.

## OPTSHPS.PAK Scene Index Reference

Scene backgrounds are full-screen 319x199 sprites unless noted. Scene ID is also the
OPTSHPS.PAK L1 index.

| Scene | Sprites | Description | Tune | Notes |
|------:|--------:|-------------|-----:|-------|
| 0 | 1 | Base exterior (mining) | 0 | Small base variant |
| 1 | 1 | Base exterior | 0 | |
| 2 | 1 | Base exterior | 0 | |
| 3 | 1 | Base exterior | 0 | Multiple rooms use this |
| 4 | 1 | Base exterior | 0 | |
| 5 | 1 | Hallway / navigation | 0 | Shared: 16 rooms |
| 6 | 6 | Launch pad (7x13 first) | 0 | Shared: 16 rooms |
| 7 | 1 | Ship/equipment dealer | 0 | Shared: 8 rooms |
| 8 | 1 | Concourse | 4 | |
| 9 | 1 | Concourse variant | 4 | |
| 10 | 1 | Concourse | 4 | |
| 11 | 1 | Concourse | 4 | |
| 13 | 1 | Concourse | 4 | |
| 14 | 1 | Concourse hallway | 4 | Shared: 12 rooms |
| 15 | 1 | Concourse launch pad | 4 | Shared: 12 rooms |
| 16 | 1 | Concourse dealer | 4 | Shared: 6 rooms |
| 17 | 5 | Bar main (145x88) | 1 | Multi-sprite overlay |
| 18 | 4 | Bar hallway (95x87) | 1 | |
| 19 | 1 | Bar dealer | 1 | |
| 20 | 1 | Bar launch | 1 | |
| 21 | 4 | Commodity exchange (47x190) | 3 | |
| 22 | 4 | Exchange hallway (124x66) | 3 | |
| 23 | 1 | Exchange dealer | 3 | |
| 24 | 1 | Exchange launch (143x96) | 3 | |
| 25 | 1 | Ship dealer main | 5 | |
| 26-30 | 236 | Ship dealer sub-views | 5 | |
| 31 | 236 | Mission computer main | 6 | |
| 32-35 | varied | Mission computer views | 6 | |
| 36 | 1 | Landing pad main | 7 | Shared: 5 rooms |
| 37 | 1 | Landing pad nav | 7 | |
| 38 | 3 | Landing pad launch (269x56) | 7 | |
| 39 | 7 | Guild main (281x168) | 8 | |
| 40 | 1 | Guild exterior | 8 | |
| 41 | 1 | Guild exterior | 8 | |
| 42 | 1 | Guild main | 8 | |
| 43 | 1 | Guild navigation | 8 | Shared: 8 rooms |
| 44 | 97 | Guild launch (265x33) | 8 | |
| 45 | 97 | Guild dealer (244x31) | 8 | |
| 46 | 55 | Merchant guild (319x72) | 9 | |
| 47 | 1 | Merchant guild nav | 9 | |
| 49 | 6 | Merchant guild main (105x83) | 9 | |
| 50-52 | 1 | Small base variants | 9 | |
| 53 | 1 | Merchant guild hallway | 9 | Shared: 14 rooms |
| 54 | 1 | Merchant guild launch | 9 | Shared: 14 rooms |
| 55 | 1 | Merchant guild dealer | 9 | Shared: 7 rooms |
| 56 | 1 | Finale scene A | 2 | |
| 57 | 1 | Finale scene B | 2 | |
| 59 | 1 | Bar / bartender | mixed | Shared: 34 rooms |
| 61 | 1 | Bar conversation | mixed | Shared: 46 rooms |
