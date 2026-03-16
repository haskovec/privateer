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

## What Needs To Be Done

### Reverse-Engineer PRCD.EXE

Analyze the original game executable to extract:

1. **Room type ID to PAK file name mapping** - Which PAK file contains the background
   sprites for each GAMEFLOW room type (concourse, bar, commodity exchange, ship
   dealer, mission computer, etc.)

2. **Resource index selection** - How the game determines which resource within a PAK
   file to use for a given scene. It may be a direct mapping from the scene INFO byte
   to a PAK resource index.

3. **Click region bounds** - Whether sprite bounding boxes come from PAK sprite headers,
   from GAMEFLOW data, or are hardcoded per room type.

4. **Title screen flow** - What text/menu options appear on the title screen and how
   the original intro sequence works (title -> character creation/load -> landing).

Look for string references to PAK file names near room-loading code. The mapping may
be a table of filename pointers indexed by room type ID.

### Implementation Fixes Needed

Once the mapping is known:

1. **Build a room type to PAK lookup table** in a new module (e.g., `src/game/room_assets.zig`)
   that maps room INFO bytes to TRE file paths and resource indices.

2. **Fix `loadLandedBackground()`** to use the state machine's current_room and
   current_scene to look up the correct PAK file and resource index.

3. **Fix `buildClickRegions()`** to use actual sprite bounds. These may come from:
   - The PAK sprite headers (x1, y1, x2, y2 in the 8-byte RLE header)
   - A separate region table in GAMEFLOW or the room's PAK file
   - Hardcoded tables in PRCD.EXE

4. **Add title screen text** using DEMOFONT.SHP and the text renderer, matching the
   original game's title screen layout.

5. **Add proper scene navigation** so that click region actions drive PAK file loading
   through the room asset lookup table.

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
