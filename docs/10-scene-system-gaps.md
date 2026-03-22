# Scene System Analysis

Documents the scene/room system architecture reverse-engineered from PRCD.EXE, covering
how GAMEFLOW.IFF scenes map to visual resources in OPTSHPS.PAK and OPTPALS.PAK.

## Remaining Issues

None -- all scene system features are implemented.

## Reverse Engineering Results (PRCD.EXE Analysis)

### Scene ID = OPTSHPS.PAK L1 Index (Direct Mapping)

The mapping from GAMEFLOW scenes to PAK resources is **direct**: the scene INFO byte
(scene ID) from GAMEFLOW.IFF is used directly as the L1 index into OPTSHPS.PAK.

There is NO separate room-type-to-PAK mapping table. All scene backgrounds live in
a single file: `..\..\DATA\OPTIONS\OPTSHPS.PAK`.

OPTSHPS.PAK contains 226 L1 entries:
- **Entries 0-61**: Scene backgrounds (indexed by scene ID from GAMEFLOW)
- **Entries 62-225**: UI elements, overlays, fonts, and animation frames
- **Entry 181**: Title screen (pre-rendered 320x200 image with planet, ship,
  "PRIVATEER" text, metallic frame, and NEW/LOAD/OPTIONS/QUIT menu bar).
  Uses OPTPALS.PAK palette 39 (dark purple, color 0 = VGA6 4,0,4).

Each scene pack entry contains:
- `[0..4]`: Declared resource size (LE uint32)
- `[4..N*4+4]`: Offset table (LE uint32 entries) pointing to sprites within this pack
- `[offsets..]`: Sprite data (8-byte header + RLE pixel data)

Most scene backgrounds (scenes 0-16, 19-20, 23, 25, 35-37, 40-43, 47-48, 50-61)
are single 320x200 full-screen sprites. Others have multiple sprites (overlays).

### Palette Mapping

Palettes are in `..\..\DATA\OPTIONS\OPTPALS.PAK` (42 L1 entries, 772 bytes each).

- **Scene IDs 0-41**: Direct mapping -- palette[scene_id] in OPTPALS.PAK
- **Scene IDs 42+**: Share palette with the first scene of the same room type:
  - Scenes 42-45 (guild, tune=8): Use palette 39
  - Scenes 46-55 (merchant guild, tune=9): Use room's first scene palette
  - Scenes 56-57 (finale, tune=2): Use palette 0 (fallback)
  - Scenes 59, 61 (bar/conversation): Shared across all rooms -- inherit the
    current room's palette (use the first scene's palette from that room)

Special non-scene palette entries:
- **Palette 28**: Quine 4000 terminal (CUBICLE.PAK), discovered via CUBICLE.IFF FILD
- **Palette 39**: Title screen (OPTSHPS.PAK resource 181), dark purple theme

See [Palette Mapping Guide](12-palette-mapping.md) for the complete reference.

### CU.PAK (Close-Up Views)

`..\..\DATA\OPTIONS\CU.PAK` contains 30 L1 entries with E0 markers. Each entry is a
single 319x128 or 320x200 sprite. These are close-up views used for NPC conversations
and character creation, NOT for scene backgrounds. Referenced in the EXE as `cu`/`cu2`
(base game / Righteous Fire variants).

### LTOBASES.PAK (Landing Transitions)

`..\..\DATA\MIDGAMES\LTOBASES.PAK` contains 10 L1 entries with small sprites (82x66
to 140x80). These are landing-to-base transition animation frames, NOT scene backgrounds.

### Click Region Bounds (Sprite INFO = Global PAK Resource Index)

Each GAMEFLOW sprite INFO byte is a **global OPTSHPS.PAK resource index**, NOT a per-
scene pack sprite index. Each interactive hotspot has its own separate scene pack in
OPTSHPS.PAK (typically at indices 62-225). Sprite 0 within that pack provides both the
visual image and the click region bounds via its 8-byte RLE header (x2, x1, y1, y2).

For example, scene 0x0D (room concourse) has these GAMEFLOW sprites:
- INFO 0xCE (206) -> PAK[206]: 6-sprite pack, first sprite 47x109 (door hotspot)
- INFO 0xC8 (200) -> PAK[200]: 1 sprite 61x34 (takeoff button)
- INFO 0xCB (203) -> PAK[203]: 3-sprite pack, first sprite 143x96 (concourse area)

Click regions are computed from sprite 0's header: screen position = (-x1, -y1),
dimensions = (x1+x2, y1+y2). This is implemented in `src/main.zig:buildClickRegions()`.

### FILES.IFF Registry

`..\..\DATA\OPTIONS\FILES.IFF` (FORM:FILE) contains a registry mapping logical names
to TRE file paths. Key entries:
- `GAMEFIFF` -> `..\..\data\options\gameflow.iff`
- `MISCSHPS` -> `..\..\data\options\optshps.pak`
- `PALTOPTS` -> `..\..\data\options\optpals.pak`

## Implementation Status

### Completed

1. **Scene backgrounds from OPTSHPS.PAK** -- `loadLandingScene()` uses the scene ID
   directly as the OPTSHPS.PAK resource index. Background is sprite 0 of the scene pack.
   (Replaced the old hardcoded `loadLandedBackground()` that tried LTOBASES.PAK/CU.PAK.)

2. **Palette loading from OPTPALS.PAK** -- `loadScenePalette()` uses the scene ID for
   scenes 0-41, or the room's first scene ID for scenes 42+/59/61.

3. **Click regions with proper bounds** -- `buildClickRegions()` uses each GAMEFLOW
   sprite INFO byte as a global OPTSHPS.PAK resource index, reads sprite 0's header
   from that hotspot's scene pack to get screen position and dimensions.

4. **Scene transitions** -- Click actions reload background, palette, and click regions
   for the target scene. `findRoomForScene()` handles cross-room transitions.

5. **Room assets module** -- `src/game/room_assets.zig` provides the scene-to-resource
   mapping API, palette index logic, and scene type classification.

### Recently Completed

6. **Title screen text** -- DEMOFONT.SHP loaded in `initGameState()` and rendered as
   menu text in `updateTitle()` using the text rendering system.

7. **Overlay sprite rendering** -- `loadOverlaySprites()` decodes hotspot sprites from
   each GAMEFLOW sprite INFO byte (OPTSHPS.PAK resource index) and passes them as
   `PositionedSprite` overlays to `SceneView` in `updateLanded()`. Sprites are rendered
   at center (0,0), with the header encoding screen position.

8. **Conversation return** -- `updateConversation()` renders the current scene and
   transitions back to landed state on click/key press. Room/scene are preserved
   across the conversation round-trip by the state machine.

## Files Involved

| File | Role |
|------|------|
| `src/main.zig` | Main game loop, scene loading, transitions, title screen |
| `src/game/room_assets.zig` | Scene-to-resource mapping API, palette index logic |
| `src/game/scene.zig` | GAMEFLOW.IFF parser (rooms, scenes, sprites) |
| `src/game/game_state.zig` | State machine (title/loading/landed transitions) |
| `src/game/click_region.zig` | EFCT action parser, hit-testing |
| `src/render/scene_renderer.zig` | PAK sprite compositing, getSpriteHeader() |
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

Scene backgrounds are full-screen 320x200 sprites unless noted. Scene ID is also the
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
