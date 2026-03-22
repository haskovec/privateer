# Implementation Plan

## Methodology: Test-Driven Development (Red/Green/Refactor)

Every feature follows the TDD cycle:
1. **RED** - Write a failing test that defines the expected behavior
2. **GREEN** - Write the minimum code to make the test pass
3. **REFACTOR** - Clean up the code while keeping tests green

We use Zig's built-in `test` blocks for unit tests and build a separate integration
test harness that validates against known-good data from the original game files.

### Test Categories
- **Unit tests:** Pure logic (format parsers, math, game rules) - no I/O dependencies
- **Integration tests:** Read real game files and verify parsed output
- **Golden tests:** Compare rendered output against reference screenshots
- **Gameplay tests:** Automated scripts that verify game state transitions

### Test Infrastructure (built first)
- Test runner with colored output (red/green)
- Test data fixtures (small hand-crafted binary blobs for format tests)
- Assertion helpers for binary data, floating point, and game state comparison
- Integration test mode that points to the real game data directory

---

## Priority Order

Items are ordered by dependency and importance. Each phase builds on the previous.
No phase should start until its dependencies are complete and tested green.

---

## Phase 0: Project Setup & Test Infrastructure
*Everything else depends on this.*

- [x] **0.1 Initialize Zig project structure**
  - Create `build.zig` with build configuration
  - Directory layout: `src/`, `tests/`, `tools/`, `docs/`, `assets/`
  - RED: Write a test that imports the main module and asserts true
  - GREEN: Create the main module
  - Configure debug/release build modes

- [x] **0.2 SDL3 integration**
  - Add SDL3 as a dependency (Zig package or system lib)
  - RED: Test that SDL3 initializes and shuts down without error
  - GREEN: Write SDL3 init/shutdown wrapper
  - Verify builds on Windows (macOS deferred until core works)

- [x] **0.3 Test harness & fixtures**
  - Build test fixture system for binary test data
  - Create helper functions: `expectBytes()`, `expectSlice()`, `expectApproxEq()`
  - RED: Test that fixture loading works with a hand-crafted 16-byte file
  - GREEN: Implement fixture loader
  - Configure `zig build test` to run all test suites

- [x] **0.4 Configuration system**
  - Define paths: original game data dir, mod dir, output dir
  - RED: Test config loading from a TOML/JSON file
  - GREEN: Implement config parser (or use a minimal embedded format)
  - Support command-line overrides for data paths

---

## Phase 1: Data Format Parsers (Critical Path)
*Must be rock-solid before any game logic. Every parser gets thorough tests.*

- [x] **1.1 ISO 9660 reader**
  - RED: Test reading GAME.DAT primary volume descriptor, expect "CD001" signature
  - GREEN: Implement ISO PVD parser
  - RED: Test reading root directory, expect 6 entries including PRIV.TRE
  - GREEN: Implement directory record parser
  - RED: Test reading PRIV.TRE file data at correct LBA offset
  - GREEN: Implement file extraction by name
  - Integration test: Verify PRIV.TRE size = 89,486,108 bytes

- [x] **1.2 TRE archive reader**
  - RED: Test parsing TRE header, expect count=832, toc_size=86688
  - GREEN: Implement header parser
  - RED: Test parsing entry 0, expect path="..\\..\\DATA\\AIDS\\ATTITUDE.IFF",
    offset=7139031, size=256
  - GREEN: Implement 74-byte fixed-size entry parser
  - RED: Test extracting file data, expect first 4 bytes = "FORM"
  - GREEN: Implement file data extraction (TRE_START + offset)
  - RED: Test listing all 832 entries with correct paths
  - GREEN: Implement full directory enumeration
  - Integration test: Verify all 832 files can be read and have valid data

- [x] **1.3 IFF chunk parser**
  - RED: Test parsing FORM container from ATTITUDE.IFF (type="ATTD", size=248)
  - GREEN: Implement FORM/CAT/LIST container parsing
  - RED: Test parsing leaf chunks (AROW, DISP, FLNG, THRD, CNST from ATTITUDE.IFF)
  - GREEN: Implement leaf chunk parser with big-endian size field
  - RED: Test nested FORM parsing (QUADRANT.IFF has UNIV > QUAD > SYST nesting)
  - GREEN: Implement recursive chunk tree parser
  - RED: Test IFF padding (odd-sized chunks should pad to even boundary)
  - GREEN: Handle padding byte
  - Integration test: Parse every IFF file in the TRE without errors

- [x] **1.4 PAL palette loader**
  - RED: Test loading PCMAIN.PAL, expect 256 RGB entries
  - GREEN: Implement PAL parser (4-byte header + 768 bytes of RGB data)
  - RED: Test VGA 6-bit to 8-bit color conversion (multiply by 4)
  - GREEN: Implement color space conversion
  - RED: Test SPACE.PAL first entry is black (0,0,0)
  - GREEN: Verify with real palette data
  - Integration test: Load all 4 palette files

- [x] **1.5 RLE sprite decoder**
  - RED: Test parsing sprite header (8 bytes: X2, X1, Y1, Y2 extents)
  - GREEN: Implement sprite header parser
  - RED: Test even-key RLE decoding (raw pixel runs)
  - GREEN: Implement even-key decoder
  - RED: Test odd-key RLE decoding (sub-encoded repeat/literal)
  - GREEN: Implement odd-key decoder with even/odd sub-byte branching
  - RED: Test full sprite decode produces correct pixel dimensions
  - GREEN: Integrate header + RLE decoder
  - Golden test: Decode a known sprite and compare pixel-by-pixel to reference

- [x] **1.6 SHP font/shape loader**
  - RED: Test parsing SHP offset table from CONVFONT.SHP
  - GREEN: Implement SHP offset table parser
  - RED: Test extracting individual glyphs/shapes by index
  - GREEN: Implement shape extraction
  - Integration test: Load all 11 SHP files

- [x] **1.7 PAK resource unpacker**
  - RED: Test parsing PAK header (4-byte file length)
  - GREEN: Implement PAK header reader
  - RED: Test L1 offset table parsing (3-byte offset + 1-byte marker C1/E0)
  - GREEN: Implement L1 table parser
  - RED: Test extracting a resource from COCKMISC.PAK
  - GREEN: Implement full PAK extraction
  - Integration test: Unpack all 32 PAK files

- [x] **1.8 VOC audio loader**
  - RED: Test parsing VOC header ("Creative Voice File" signature)
  - GREEN: Implement VOC header parser
  - RED: Test extracting PCM data block (type 1, 8-bit unsigned, 11025 Hz)
  - GREEN: Implement VOC data block extraction
  - Integration test: Load all 17 VOC files, verify sample rates

- [x] **1.9 VPK/VPF voice pack decompressor**
  - RED: Test parsing VPK header (offset table)
  - GREEN: Implement VPK offset table parser
  - RED: Test LZW decompression of a VPK entry produces valid VOC data
  - GREEN: Implement LZW decompressor
  - Integration test: Decompress first entry from 5 random VPK files

- [x] **1.10 Music format loaders (ADL/GEN/XMIDI)**
  - RED: Test parsing XMIDI XDIR/XMID/TIMB chunks from IFF
  - GREEN: Implement XMIDI chunk reader
  - RED: Test ADL file identification
  - GREEN: Implement ADL header reader
  - RED: Test GEN (General MIDI) file parsing
  - GREEN: Implement GEN loader
  - Integration test: Load all 10 music files (5 ADL + 5 GEN)

---

## Phase 2: Asset Pipeline & Verification Tool
*Build a CLI tool that proves we can read every asset. Catches format bugs early.*

- [x] **2.1 Asset extraction CLI**
  - Command: `privateer-tools extract --data-dir <path> --output <dir>`
  - Extracts all 832 files from TRE to a directory tree
  - RED: Test extraction produces correct file count and sizes
  - GREEN: Implement extraction pipeline

- [x] **2.2 Sprite renderer (to PNG)**
  - Decode RLE sprites and write to PNG files for visual verification
  - RED: Test rendering ATTITUDE.IFF sprites produces non-empty PNG
  - GREEN: Implement sprite-to-PNG pipeline (using stb_image_write or similar)
  - Batch mode: render all sprites from APPEARNC/ directory

- [x] **2.3 Palette viewer**
  - Render all 4 palettes as color swatch images
  - RED: Test palette rendering produces 256-color grid PNG
  - GREEN: Implement palette visualizer

- [x] **2.4 Data validation suite**
  - Run all integration tests against the real game data
  - Report: number of files parsed, errors, warnings
  - RED: Test that validation reports 0 errors on known-good data
  - GREEN: Wire up all parsers into validation pipeline
  - **This is the gate for Phase 3** - must be 100% green

---

## Phase 3: Core Rendering Engine
*Get pixels on screen. Everything visual depends on this.*

- [x] **3.1 Window creation & main loop**
  - SDL3 window at 1280x960 (4x base resolution)
  - 60fps game loop with fixed timestep
  - RED: Test window creates at correct size
  - GREEN: Implement window + event loop
  - Support fullscreen toggle (Alt+Enter)

- [x] **3.2 Palette-based software renderer**
  - 320x200 internal framebuffer (8-bit indexed color)
  - Palette lookup to produce 32-bit RGBA for display
  - RED: Test filling framebuffer with palette index 0 produces black screen
  - GREEN: Implement framebuffer + palette lookup + SDL texture upload
  - RED: Test drawing a single pixel at (160,100) with color index 15
  - GREEN: Implement pixel plotting

- [x] **3.3 Sprite upscaling pipeline**
  - Implement xBRZ or HQ4x upscaling algorithm
  - 320x200 -> 1280x800 (4x) as base upscale
  - RED: Test upscaling a 4x4 test sprite produces 16x16 output
  - GREEN: Implement upscaler
  - RED: Test upscaled edges are smooth (no raw pixel doubling)
  - GREEN: Tune upscaling algorithm parameters
  - Support configurable scale factor (2x, 3x, 4x)

- [x] **3.4 Sprite rendering with scaling**
  - Draw decoded RLE sprites at arbitrary positions and scales
  - Distance-based scaling for space objects
  - RED: Test sprite renders at correct position
  - GREEN: Implement sprite blitter
  - RED: Test scaled sprite at 50% produces half-size output
  - GREEN: Implement scaling

- [x] **3.5 Widescreen viewport**
  - Compute pillarbox/letterbox for non-4:3 displays
  - Space flight: extend viewport to fill width
  - Landing screens: center at 4:3 with decorative borders
  - RED: Test 16:9 viewport calculates correct margins
  - GREEN: Implement viewport math
  - RED: Test scene renders centered with correct borders
  - GREEN: Implement border rendering

- [x] **3.6 Text rendering**
  - Load SHP font files and render text strings
  - RED: Test rendering "CREDITS: 1000" produces correct pixel output
  - GREEN: Implement font renderer using SHP glyph data
  - Support all 6 game fonts

---

## Phase 4: Scene System & Landing Screens
*Base navigation is the core game loop outside of combat.*

- [x] **4.1 Scene data loader**
  - Parse GAMEFLOW.IFF (FORM:GAME > FORM:MISS > FORM:SCEN > FORM:SPRT)
  - RED: Test loading gameflow IFF produces rooms with scenes and sprite hotspots
  - GREEN: Implement scene parser (GameFlow, Room, Scene, SceneSprite types)
  - Integration test: Parse real GAMEFLOW.IFF, verify rooms have scenes with sprites

- [x] **4.2 Scene renderer**
  - Render background, foreground overlay, sprites, clickable regions
  - RED: Test rendering a scene produces non-black framebuffer
  - GREEN: Implement scene rendering pipeline

- [x] **4.3 Click region / interaction system**
  - Sprite EFCT data defines actions (scene transitions, merchant, conversation, etc.)
  - RED: Test clicking coordinates inside a region returns correct region ID
  - GREEN: Implement hit-testing against region rects
  - Parse EFCT action types and connect to scene transitions (room to room)

- [x] **4.4 Game state machine**
  - States: TITLE, SPACE_FLIGHT, LANDED, CONVERSATION, COMBAT, DEAD, LOADING
  - RED: Test state transitions (SPACE_FLIGHT -> LANDED on successful landing)
  - GREEN: Implement state machine
  - RED: Test invalid transitions are rejected
  - GREEN: Add transition validation

- [x] **4.5 Landing/Launch sequences**
  - Load MIDGAMES/ animation data
  - Play landing approach and launch sequences
  - RED: Test landing sequence loads correct frames
  - GREEN: Implement animation playback from PAK data

---

## Phase 5: Universe & Navigation
*The player needs to go places.*

- [x] **5.1 Universe data loader**
  - Parse QUADRANT.IFF (UNIV > QUAD > SYST hierarchy)
  - Parse SECTORS.IFF, BASES.IFF, TEAMS.IFF
  - RED: Test loading universe produces 4 quadrants
  - GREEN: Implement universe parser
  - RED: Test each quadrant contains correct number of systems
  - GREEN: Validate against known Gemini Sector layout

- [x] **5.2 Sector/system data model**
  - Represent systems, nav points, jump connections, bases
  - RED: Test system lookup by name returns correct quadrant/coordinates
  - GREEN: Implement system data model
  - RED: Test jump connectivity (system A connects to system B)
  - GREEN: Implement nav graph from TABLE.DAT

- [x] **5.3 Nav map display**
  - Parse NMAP form data (GRID, BTTN, QUAD, etc.)
  - Render sector map with systems, connections, player position
  - RED: Test nav map renders all systems in correct positions
  - GREEN: Implement nav map renderer
  - RED: Test clicking a system on the nav map sets autopilot destination
  - GREEN: Implement nav map interaction

- [x] **5.4 Space flight physics**
  - Player ship movement: thrust, rotation, velocity, momentum
  - RED: Test applying thrust increases velocity in facing direction
  - GREEN: Implement basic Newtonian physics
  - RED: Test maximum speed is capped per ship type
  - GREEN: Implement speed limiter
  - RED: Test afterburner temporarily increases max speed
  - GREEN: Implement afterburner

- [x] **5.5 Autopilot system**
  - Navigate to selected nav point automatically
  - Interrupt on hostile contact
  - RED: Test autopilot moves ship toward target nav point
  - GREEN: Implement autopilot steering
  - RED: Test autopilot disengages when enemy detected
  - GREEN: Implement threat detection interrupt

- [x] **5.6 Jump drive**
  - Inter-system travel at jump points
  - Jump sequence animation
  - RED: Test jumping at a jump point transitions to connected system
  - GREEN: Implement jump logic
  - RED: Test jumping without a jump drive fails
  - GREEN: Implement equipment requirement check

---

## Phase 6: Cockpit & HUD
*The player's primary interface during flight.*

- [x] **6.1 Cockpit renderer**
  - Load cockpit IFF/PAK for current ship type (Tarsus/Fighter/Merchant)
  - Render cockpit frame around viewport
  - RED: Test cockpit loads correct frame for Tarsus
  - GREEN: Implement cockpit loader + renderer
  - Handle widescreen extension of cockpit edges

- [x] **6.2 MFD (Multi-Function Display) system**
  - Parse CMFD, CHUD, DIAL chunks
  - Render left/right MFDs with cycling content
  - RED: Test MFD displays target info when target is selected
  - GREEN: Implement MFD rendering with data binding

- [x] **6.3 Radar display**
  - Parse RADR form data
  - Render radar blips for nearby objects
  - RED: Test radar shows friendly as green, hostile as red
  - GREEN: Implement radar renderer with faction coloring

- [x] **6.4 Damage display**
  - Ship damage diagram showing shield/armor status per facing
  - RED: Test damage display shows full shields when undamaged
  - GREEN: Implement damage diagram renderer

- [x] **6.5 Targeting system**
  - Target selection (nearest hostile, cycle targets)
  - ITTS (In-flight Targeting and Tracking System) reticle
  - RED: Test targeting nearest hostile selects correct ship
  - GREEN: Implement target selection logic
  - RED: Test ITTS lead indicator shows correct offset for moving target
  - GREEN: Implement ITTS calculation

- [x] **6.6 In-flight messages**
  - Message display area for communications, status, warnings
  - RED: Test "No Missiles" message displays when firing with none
  - GREEN: Implement message queue and renderer

---

## Phase 7: Combat
*The most complex game system. Depends on rendering, physics, and ship data.*

- [x] **7.1 Weapon system**
  - Parse WEAPONS.IFF, BEAMTYPE.IFF, TORPTYPE.IFF
  - Load weapon stats (damage, range, speed, energy cost)
  - RED: Test firing gun creates projectile with correct velocity
  - GREEN: Implement gun firing
  - RED: Test missile launch creates tracking projectile
  - GREEN: Implement missile launcher
  - RED: Test torpedo launch
  - GREEN: Implement torpedo system

- [x] **7.2 Projectile physics**
  - Projectile movement, lifetime, collision detection
  - RED: Test projectile moves in fired direction at weapon speed
  - GREEN: Implement projectile update
  - RED: Test projectile despawns after max range
  - GREEN: Implement lifetime/range check
  - RED: Test projectile-ship collision detection
  - GREEN: Implement bounding-sphere collision

- [x] **7.3 Damage model**
  - Shield absorption, armor penetration, component damage
  - RED: Test gun hit reduces target shield on hit facing
  - GREEN: Implement shield damage
  - RED: Test hit on depleted shield damages armor
  - GREEN: Implement armor damage
  - RED: Test ship destruction at zero armor
  - GREEN: Implement destruction trigger

- [x] **7.4 AI flight behavior**
  - Parse AIDS/*.IFF maneuver data
  - Implement AI state machine: patrol, attack, flee, escort
  - RED: Test hostile AI turns toward player
  - GREEN: Implement pursuit maneuver
  - RED: Test AI fires weapons when in range
  - GREEN: Implement engagement logic
  - RED: Test AI flees when shields critical
  - GREEN: Implement flee behavior with threshold from CNST data

- [x] **7.5 NPC spawning**
  - Spawn NPC ships based on sector data and faction presence
  - RED: Test pirate sector spawns pirate ships
  - GREEN: Implement sector-based spawning
  - RED: Test Confed patrol spawns in Confed systems
  - GREEN: Implement faction spawn rules

- [x] **7.6 Explosions & debris**
  - Parse EXPLTYPE.IFF, TRSHTYPE.IFF
  - Animate explosion sequences
  - Spawn debris on destruction
  - RED: Test ship destruction plays explosion animation
  - GREEN: Implement explosion system

- [x] **7.7 Tractor beam & cargo**
  - Collect floating cargo with tractor beam
  - RED: Test tractor beam pulls cargo toward ship
  - GREEN: Implement tractor beam
  - RED: Test cargo collection adds to cargo hold
  - GREEN: Implement cargo pickup

---

## Phase 8: Economy & Trading
*The other half of the gameplay loop.*

- [x] **8.1 Commodity system**
  - Parse COMODTYP.IFF for commodity types and base prices
  - RED: Test loading commodity data produces correct number of types
  - GREEN: Implement commodity data loader
  - RED: Test price calculation with base type modifier
  - GREEN: Implement price formula

- [x] **8.2 Commodity exchange UI**
  - Buy/sell interface at bases
  - RED: Test buying commodity reduces credits and adds to cargo
  - GREEN: Implement buy transaction
  - RED: Test selling commodity increases credits and removes from cargo
  - GREEN: Implement sell transaction
  - RED: Test insufficient credits prevents purchase
  - GREEN: Implement credit validation

- [x] **8.3 Ship dealer**
  - Parse SHIPSTUF.IFF for equipment
  - Buy/sell ships and equipment
  - RED: Test buying Centurion with sufficient credits succeeds
  - GREEN: Implement ship purchase
  - RED: Test equipment installation respects hardpoint compatibility
  - GREEN: Implement equipment system

- [x] **8.4 Landing fees**
  - Parse LANDFEE.IFF
  - Deduct landing fee on landing
  - RED: Test landing at agricultural base deducts correct fee
  - GREEN: Implement landing fee

- [x] **8.5 Faction reputation system**
  - Parse ATTITUDE.IFF for faction relationships
  - Track player standing with each faction
  - RED: Test killing pirate improves Confed reputation
  - GREEN: Implement reputation changes
  - RED: Test low reputation makes faction hostile
  - GREEN: Implement hostility threshold

---

## Phase 9: Mission System
*Gives the gameplay purpose and progression.*

- [x] **9.1 Random mission generator**
  - Parse SKELETON.IFF and RNDM*.IFF templates
  - Generate missions based on current location and faction standings
  - RED: Test mission generator produces valid mission at agricultural base
  - GREEN: Implement mission generation
  - RED: Test mission types match available types for base type
  - GREEN: Implement type filtering

- [x] **9.2 Mission computer UI**
  - Display available missions with briefing, destination, reward
  - Accept/decline missions
  - RED: Test accepting mission adds it to active missions
  - GREEN: Implement mission acceptance

- [x] **9.3 Mission tracking & completion**
  - Track mission objectives (deliver cargo, kill target, patrol nav points)
  - RED: Test completing patrol mission at all nav points triggers success
  - GREEN: Implement objective tracking
  - RED: Test failing mission (cargo destroyed) triggers failure
  - GREEN: Implement failure conditions

- [x] **9.4 Plot mission scripting engine**
  - Parse SCRP/PROG/FLAG/CAST chunks from mission IFF files
  - Execute scripted sequences for plot missions
  - RED: Test loading S0MA.IFF parses all script commands
  - GREEN: Implement script parser
  - RED: Test script execution triggers correct events
  - GREEN: Implement script interpreter

- [x] **9.5 Plot missions (Series 0-7)**
  - Implement all plot mission series from MISSIONS/ directory
  - RED: Test each mission can be loaded and script is valid
  - GREEN: Implement per-mission verification
  - Gameplay test: Automated walkthrough of plot mission chain

---

## Phase 10: Conversation System
*NPCs, bar scenes, plot advancement through dialogue.*

- [x] **10.1 Conversation data loader**
  - Parse CONV/*.IFF rumor/info tables (FORM:RUMR TABL records, FORM:INFO)
  - Parse CONV/*.PFC dialogue scripts (null-separated 7-string groups)
  - Parse OPTIONS/COMPTEXT.IFF (FORM:COMP guild text: MRCH/MERC/AUTO)
  - Parse OPTIONS/COMMTXT.IFF (FORM:STRG exchange string table)
  - Parse RUMORS.IFF CHNC chance weights
  - RED: Test loading produces valid tables, scripts, and text
  - GREEN: Implement all conversation parsers
  - Integration test: Parse all 19 CONV IFF files and PFC scripts without errors

- [x] **10.2 Conversation UI**
  - Display NPC portraits, dialogue text, player response choices
  - RED: Test conversation displays correct NPC text
  - GREEN: Implement conversation renderer
  - RED: Test selecting a response advances to correct next node
  - GREEN: Implement dialogue tree navigation

- [x] **10.3 Conversation audio**
  - Decompress VPK/VPF voice packs
  - Play speech during conversations
  - RED: Test VPK decompression produces playable audio
  - GREEN: Wire VPK audio to conversation system

- [x] **10.4 Bar/fixer encounters**
  - Special NPC interactions that advance the plot
  - RED: Test fixer appears at correct base when plot conditions are met
  - GREEN: Implement fixer spawn logic

- [x] **10.5 Rumors system**
  - Parse RUMR forms from conversation data
  - Display context-appropriate rumors at bars
  - RED: Test rumor selection matches current game state
  - GREEN: Implement rumor system

---

## Phase 11: Audio System
*Sound brings the game to life.*

- [x] **11.1 SDL3 audio initialization**
  - Set up audio device and mixer
  - RED: Test audio device opens with correct format (44100 Hz, 16-bit, stereo)
  - GREEN: Implement audio init

- [x] **11.2 VOC playback**
  - Play Creative Voice files for speech and effects
  - Resample from 11025 Hz to device rate
  - RED: Test VOC file plays audible audio
  - GREEN: Implement VOC decoder + playback

- [x] **11.3 Sound effects system**
  - Procedural waveform synthesis (sine, square, sawtooth, noise) for all effect types
  - Sound bank with 24 effect types (weapons, combat, flight, UI)
  - Multi-channel mixer (8 channels) for simultaneous playback via SDL3 AudioStreams
  - Event-to-sound mapping (gun type → sound, explosion size → sound)
  - RED: Test synthesis produces correct waveforms and sample counts
  - GREEN: Implement SoundBank, SoundMixer, and event dispatch

- [x] **11.4 Music playback**
  - Convert XMIDI/GEN to standard MIDI or synthesize directly
  - Play background music (base tune, combat, credits, opening, victory)
  - RED: Test base music plays when landed
  - GREEN: Implement music state machine
  - RED: Test combat music triggers on hostile engagement
  - GREEN: Implement music transitions

---

## Phase 12: Save/Load & Persistence

- [x] **12.1 Save game format**
  - Design save format (JSON or binary with versioning)
  - Capture: player ship, location, credits, cargo, equipment, reputation,
    mission state, plot flags, kill stats
  - RED: Test saving and loading produces identical game state
  - GREEN: Implement serialization/deserialization

- [x] **12.2 Save/Load UI**
  - Save game slots with metadata (date, location, credits)
  - RED: Test save menu shows available slots
  - GREEN: Implement save/load menu

- [x] **12.3 Auto-save**
  - Auto-save on landing at a base
  - RED: Test landing triggers auto-save
  - GREEN: Implement auto-save hook

---

## Phase 13: Modding Support

- [x] **13.1 Mod directory loading**
  - Check `mods/<modname>/` before loading from TRE
  - RED: Test loose file in mod dir overrides TRE file
  - GREEN: Implement mod file priority system

- [x] **13.2 Config override files**
  - JSON/TOML files for game balance values (ship stats, prices, weapon damage)
  - RED: Test config override changes ship max speed
  - GREEN: Implement config overlay system

- [x] **13.3 Asset hot-reloading (dev mode)**
  - Watch mod directory for changes and reload assets
  - RED: Test modifying a sprite file updates the display
  - GREEN: Implement file watcher + reload

---

## Phase 14: Polish & Release

- [x] **14.1 Options menu**
  - Graphics: resolution (2x/3x/4x), fullscreen toggle, viewport mode (4:3/fill)
  - Audio: SFX volume, music volume (0-100% with visual bars)
  - Settings persistence via JSON (settings.json)
  - Options state in game state machine (accessible from title and landed)
  - RED: Test settings defaults, serialization, menu navigation, value adjustments
  - GREEN: Implement Settings, OptionsMenu, JSON round-trip, state transitions

- [x] **14.2 Joystick support**
  - SDL3 game controller API (auto-detect, hot-plug via SDL_EVENT_GAMEPAD_ADDED/REMOVED)
  - Left stick for yaw/pitch with configurable deadzone and smooth rescaling
  - Right trigger for throttle (0-1), shoulder buttons for fire/afterburner
  - Face buttons for missile fire, target cycle, autopilot, nav map (edge-detected)
  - Persistent deadzone setting in settings.json
  - RED: Test axis normalization, deadzone, button edge detection, trigger mapping
  - GREEN: Implement Joystick module, integrate with Window event loop

- [x] **14.3 Performance optimization**
  - Profile rendering pipeline
  - Optimize sprite upscaling (cache upscaled sprites)
  - Optimize IFF loading (memory-map TRE file)
  - Target: 60fps at 4K resolution

- [x] **14.4 macOS build**
  - Cross-compile Zig to macOS (aarch64-macos + x86_64-macos)
  - Test SDL3 on macOS
  - Create .app bundle
  - RED: Test game launches on macOS
  - GREEN: Fix platform-specific issues

- [ ] **14.5 Gameplay verification**
  - Complete playthrough of all plot missions
  - Verify all base types, commodities, ships, equipment
  - Verify faction reputation system
  - Verify random mission generation
  - Compare game behavior against original (running in DOSBox alongside)

- [x] **14.6 README & distribution**
  - User-facing GETTING_STARTED.md with install instructions and controls reference
  - How to point at your game data directory
  - Build instructions for contributors
  - License considerations (engine is ours, data is EA's)

- [x] **14.7 Sprite viewer CLI tool**
  - `privateer-sprite list` to scan GAME.DAT and list all sprite-containing files (SHP/IFF/PAK)
  - `privateer-sprite view` to decode and display sprites inline via Kitty graphics protocol
  - Format detection by extension with magic-byte sniffing fallback
  - Palette auto-detection (embedded PAK palette, same-directory PAL, default PCMAIN.PAL)
  - Recursive PAK→IFF→SHAP sprite extraction (SHAP chunks parsed as scene packs with offset tables)
  - `privateer-sprite view --data-dir <path>` dumps all sprites from every file in GAME.DAT
  - Scale2x/3x/4x upscaling with side-by-side comparison mode
  - PNG export (`--save`)
  - Kitty graphics protocol encoder (`src/render/kitty_graphics.zig`): raw RGBA (f=32) with cell-based sizing (c/r), cursor hiding, and q=2 quiet mode for Ghostty/Kitty/WezTerm/Konsole compatibility

---

## Phase 15: Title Screen & Main Menu
*Match the original game's title screen: correct background, palette, and 4-option menu.*

The original title screen is a single pre-rendered 320x200 sprite stored in
OPTSHPS.PAK scene pack 181 (L1 entry 181, 38KB). It contains the complete
composited scene: planet, Galaxy-class ship with projectiles, "PRIVATEER"
metallic title text, metallic frame/border, purple nebula background, and the
bottom menu bar (NEW / LOAD / OPTIONS / QUIT).

The correct palette is OPTPALS.PAK index 39, which has a distinctive dark purple
color 0 (VGA 6-bit 4,0,4 → RGB 16,0,16) rather than black. This was identified
by extracting pixel indices from a DOSBox reference screenshot and binary-searching
for matching byte sequences across all game data files.

- [x] **15.1 Fix title screen background**
  - Load OPTSHPS.PAK scene pack 181 as the title background
  - Apply OPTPALS.PAK palette 39 (dark purple title palette)
  - RED: Test that scene pack 181 sprite 0 decodes to 320x200, and palette 39
    has dark purple color 0 (R=16, G=0, B=16)
  - GREEN: Change `loadSceneBackground` call to resource index 181, load palette 39

- [x] **15.2 Fix title menu to match original**
  - Menu text (NEW/LOAD/OPTIONS/QUIT) is pre-rendered in the title screen image
  - Wire keyboard shortcuts: N=New, L=Load, O=Options, Q/Escape=Quit
  - Wire mouse click regions in bottom strip for all 4 menu items
  - RED: Test that the title state accepts 4 input actions
  - GREEN: Update `updateTitle()` input handling with click regions and hotkeys

- [x] **15.3 Title screen fade-in**
  - Implement palette fade-in effect (ramp palette from black to full over ~1s)
  - The original fades the title screen in from black after the intro movie
  - RED: Test fade generates intermediate palettes between black and target
  - GREEN: Implement palette interpolation in updateTitle()

---

## Phase 16: Intro Movie System (FORM:MOVI)
*Play the opening cinematic before the title screen, matching the original game.*

The original game plays a ~2-minute cinematic on startup: a text crawl over a
planet scene, then a scripted sequence of cockpit views, character encounters,
and asteroid fields. The data lives in MIDGAMES/ and uses a FORM:MOVI IFF
scripting format to control frame-by-frame animation with sprite overlays.

The intro has a full audio mix of three layers: background music, voice dialog,
and sound effects. Analysis of a DOSBox capture (134s, PCM 22050 Hz stereo)
shows this timeline:
- 0:00–0:19 — Silence (text crawl over planet)
- 0:19–0:50 — Music + SFX (cockpit/flight with engine hum, weapon fire)
- 0:50–0:53 — Brief silence (scene transition)
- 0:54–1:55 — Music + Voice dialog + SFX (pirate encounter with spoken lines)
- 1:55–2:14 — Silence (fade to title screen)

### Data Architecture (reverse-engineered)

#### Visual Data
- `GFMIDGAM.IFF`: FORM:MIDG with TABL+FNAM entries mapping type indices to
  control files (index 2 = OPENING.PAK = the intro sequence)
- `OPENING.PAK`: PAK file whose string resources list the scene sequence:
  mid1a → mid1b → mid1c1-c4 → mid1d → mid1e1-e4 → mid1f
- `MID1A.IFF` through `MID1F.IFF`: FORM:MOVI scripts, each containing:
  - `CLRC` (2 bytes) — clear screen flag
  - `SPED` (2 bytes) — frame speed/timing (ticks per frame)
  - `FILE` (variable) — indexed file references:
    - File 0: `..\..\data\midgames\mid1.pak` (sprite frames)
    - File 1: `..\..\data\midgames\midtext.pak` (text strings)
    - File 2: `..\..\data\fonts\demofont.shp` (font for text rendering)
    - File 4: `..\..\data\sound\opening` (music track)
  - `FORM:ACTS` blocks containing:
    - `FILD` — field/frame display commands (sprite index, file ref, position)
    - `SPRI` — sprite positioning/animation commands (index, coords, timing)
    - `BFOR` — background/foreground layer ordering
- `MID1.PAK`: 80 resources with 1501 sprite frames (resource 0 = palette,
  resources 1-79 = scene packs with delta-encoded sprites)
- `MIDTEXT.PAK` / `MID1TXT.PAK`: PAK files with null-terminated text strings:
  - "2669, GEMINI SECTOR, TROY SYSTEM..."
  - "THE TERRAN FRONTIER..."
  - "BETWEEN THE KILRATHI EMPIRE..."
  - "...AND THE UNKNOWN."
  - Plus dialogue lines for the pirate encounter

#### Audio Data
- `OPENING.ADL` / `OPENING.GEN`: Background music tracks for the intro
  (IFF-wrapped XMIDI, already parseable by `src/formats/music.zig`)
- `SPEECH/MID01/PC_1MG1.VOC` through `PC_1MG8.VOC`: Player character voice
  lines for the pirate encounter scene (8 Creative Voice files, 8-bit PCM
  11025 Hz, already parseable by `src/formats/voc.zig`)
- `SPEECH/MID01/PIR1MG1.VOC` through `PIR1MG9.VOC`: Pirate voice lines for
  the encounter scene (9 Creative Voice files, same format)
- `SOUND/SOUNDFX.PAK`: Sound effects bank used across the game (engine hum,
  weapon fire, explosions — PAK format with indexed sound entries)
- `SOUND/COMBAT.DAT`: Combat event → sound effect index mapping table (1,896
  bytes, maps events like "gun fire" or "explosion" to SOUNDFX.PAK indices)

- [x] **16.1 FORM:MOVI IFF parser**
  - Parse FORM:MOVI container with CLRC, SPED, FILE, FORM:ACTS chunks
  - Parse ACTS sub-chunks: FILD (field commands), SPRI (sprite commands),
    BFOR (layer ordering)
  - Resolve FILE chunk paths to TRE entries (strip `..\..\data\` prefix,
    normalize backslashes)
  - RED: Test parsing MID1A.IFF produces correct FILE references, SPED value,
    and ACTS command counts
  - GREEN: Implement MovieScript struct and IFF parser in `src/formats/movie.zig`
  - Integration test: Parse all 12 MID1*.IFF files without errors

- [x] **16.2 Opening sequence playlist parser**
  - Parse OPENING.PAK as a string-list PAK (null-terminated scene names)
  - Map scene names to MID1*.IFF files in the TRE (e.g., "mid1a" → "MIDGAMES/MID1A.IFF")
  - Parse GFMIDGAM.IFF FORM:MIDG to identify the opening sequence file
  - RED: Test OPENING.PAK produces scene list ["mid1a", "mid1b", "mid1c1", ...]
  - GREEN: Implement OpeningSequence loader

- [x] **16.3 Movie text overlay system**
  - Parse MIDTEXT.PAK as a string-list PAK (same format as OPENING.PAK)
  - Render text strings centered on screen using DEMOFONT.SHP
  - Support timed display (text appears and disappears per ACTS commands)
  - RED: Test MIDTEXT.PAK entry 0 = "2669, GEMINI SECTOR, TROY SYSTEM..."
  - GREEN: Implement text extraction and overlay rendering

- [x] **16.4 Movie sprite renderer**
  - Load MID1.PAK sprite frames with embedded palette (resource 0)
  - Render sprites at positions specified by SPRI commands
  - Support delta/incremental frame compositing (each frame updates a
    persistent 320x200 framebuffer, not full redraws)
  - CLRC command clears the framebuffer between scenes
  - RED: Test MID1.PAK resource 0 is a valid 772-byte palette
  - GREEN: Implement MovieRenderer that executes ACTS commands frame-by-frame

- [x] **16.5 Movie music playback**
  - Load OPENING.ADL or OPENING.GEN from TRE via existing `music.zig` parser
  - Decode XMIDI events and render to PCM using existing `MusicPlayer`
  - Start music when FILE chunk index 4 is referenced by the movie script
  - Music plays continuously across scene transitions (mid1a → mid1f)
  - Stop music on movie completion or Escape skip
  - RED: Test OPENING.GEN parses to valid XMIDI sequence with EVNT data
  - GREEN: Wire MusicPlayer.playPcm() into movie player, triggered by FILE ref

- [x] **16.6 Movie voice dialog playback**
  - Load VOC files from SPEECH/MID01/ in the TRE:
    - `PC_1MG1.VOC`–`PC_1MG8.VOC` (8 player character lines)
    - `PIR1MG1.VOC`–`PIR1MG9.VOC` (9 pirate lines)
  - Parse using existing `voc.zig` parser (8-bit unsigned PCM, 11025 Hz)
  - Play voice clips at script-specified times during the pirate encounter
    scenes (mid1c*, mid1d, mid1e*) using `AudioPlayer.play()`
  - Voice plays layered over music (requires concurrent audio streams)
  - RED: Test loading PC_1MG1.VOC produces valid PCM with sample rate 11025
  - RED: Test loading PIR1MG1.VOC produces valid PCM with sample rate 11025
  - GREEN: Implement VOC loader for SPEECH/MID01/ files, wire into movie
    script executor to play voice at ACTS-specified trigger points

- [x] **16.7 Movie sound effects**
  - Parse SOUNDFX.PAK from DATA/SOUND/ to extract indexed sound effect samples
  - Parse COMBAT.DAT (1,896 bytes) to map event types to SOUNDFX.PAK indices
  - Play sound effects (engine hum, weapon fire, explosions) during flight
    scenes (mid1b, mid1c*, mid1e*) as triggered by ACTS commands
  - Layer SFX over music and voice using `SoundMixer` (8-channel mixer)
  - RED: Test SOUNDFX.PAK can be opened and contains indexed sound resources
  - RED: Test COMBAT.DAT maps at least one event to a valid SOUNDFX index
  - GREEN: Implement SOUNDFX.PAK loader and event-to-sound dispatch during
    movie playback, using SoundMixer for concurrent multi-channel output

- [x] **16.8 Movie player integration**
  - Add `State.intro_movie` to the game state machine
  - On startup: transition to intro_movie state, play OPENING sequence
  - Execute scenes in order (mid1a → mid1f), advancing per SPED timing
  - Coordinate all three audio layers: music (MusicPlayer), voice (AudioPlayer),
    and SFX (SoundMixer) — all play concurrently via separate SDL3 AudioStreams
  - Escape key skips the intro (stops all audio) and transitions to title screen
  - On completion: fade to black, stop music, transition to title state with fade-in
  - RED: Test state machine supports intro_movie → title transition
  - GREEN: Wire movie player into main.zig startup flow with full audio

- [x] **16.9 Scene variant selection**
  - OPENING.PAK lists variant groups (mid1c1-c4, mid1e1-e4)
  - Select one variant randomly per playthrough (matching original behavior)
  - RED: Test variant selection always picks one from each group
  - GREEN: Implement random variant picker using Zig's PRNG

---

## Phase 17: FORM:MOVI Parser & Renderer Rewrite
*The Phase 16 movie system assumed a simple draw-command model. Reverse engineering
of real game data (via analyze_movi.py) revealed a scene-graph composition architecture.
The FILE, FILD, SPRI, and BFOR chunk formats are all different from what was implemented.*

- [x] **17.1 Fix FILE chunk parser (slot-indexed references)**
  - Current parser splits on null bytes (wrong) — real format is `[slot_id: u16 LE][path\0]` pairs
  - Slot IDs can be sparse (e.g., 0, 1, 2, 4 — slot 3 skipped)
  - RED: Test FILE parser with real MID1A.IFF data: expect slot 0=mid1.pak, 1=midtext.pak, 2=demofont.shp, 4=opening
  - GREEN: Rewrite parseFileReferences to read `[u16 LE slot_id][null-terminated path]` pairs
  - Return a slot map (sparse array or hash map) instead of a dense array
  - Update test fixtures to match real FILE chunk format

- [x] **17.2 Fix FILD chunk parser (packed 10-byte records)**
  - Current parser reads one command per FILD chunk with u8+BE fields (wrong)
  - Real format: packed 10-byte records `[object_id: u16 LE][file_ref: u16 LE][3 x u16 LE params]`
  - A single FILD chunk contains multiple records (e.g., 96 bytes = ~10 records)
  - RED: Test FILD parser with real MID1A.IFF data: expect 10 records, first has object_id=23 file_ref=0
  - GREEN: Rewrite FILD parsing to iterate 10-byte records within a single chunk
  - Update FieldCommand struct to use u16 LE fields

- [x] **17.3 Fix SPRI chunk parser (packed variable-length records)**
  - Current parser reads one command per SPRI chunk (wrong)
  - Real format: [object_id: u16 LE][ref: u16 LE][0x8000 sentinel: u16 LE][type: u16 LE][params: N × u16 LE]
  - Record length determined by type field: 0,1→3 params (14B), 3,11→5 params (18B), 12→6 params (20B), 18→7 params (22B), 4,19,20→9 params (26B)
  - RED: Test SPRI parser with real MID1A.IFF data: expect 12 records with correct sizes
  - GREEN: Implement variable-length record reader with type→param_count lookup
  - Updated SpriteCommand struct to use u16 LE fields with object_id, ref, sprite_type, params[9], param_count
  - Verified against all 26 SPRI chunks across 22 MOVI files (intro + victory + misc)

- [x] **17.4 Parse BFOR chunk (packed 24-byte composition commands)**
  - Current parser extracts only a u16 value from BFOR (wrong)
  - Real format: packed 24-byte records defining composition/render order
  - BFOR references object IDs from FILD/SPRI to drive actual rendering
  - RED: Test BFOR parser with real MID1A.IFF data: expect 8 records from 192-byte chunk
  - GREEN: Implement BFOR record parser with object_id, flags, and parameter fields
  - Replaced LayerOrder (2-byte) with BforRecord (24-byte) struct
  - Renamed layer_orders → composition_cmds throughout codebase
  - Verified against real MID1A.IFF: 8 records, flags=0x7FFF for layers, object refs for FILD links

- [x] **17.5 Rewrite MovieRenderer for scene-graph composition**
  - Current renderer directly blits from FILD/SPRI commands (wrong model)
  - Real model: FILD/SPRI define objects, BFOR drives rendering order
  - Build an object table from FILD+SPRI definitions (keyed by object_id)
  - BFOR commands reference object_ids to composite the frame
  - BFOR records with flags=0x7FFF are layer/clip commands (viewport regions in params[0..3])
  - BFOR records with flags != 0x7FFF reference FILD/SPRI objects by object_id
  - SPRI type 0/1 renders referenced FILD sprite at (params[0], params[1]) position
  - Falls back to direct FILD rendering when no BFOR commands present
  - RED: Test BFOR-driven rendering, BFOR skip unreferenced objects, SPRI type 0 positioning
  - GREEN: Implement ObjectEntry union, executeComposition, findFild/findSpri lookups
  - Verified palette extraction still works, integration test produces non-black pixels

- [x] **17.6 Wire movie audio layers**
  - movie_music.zig, movie_voice.zig, movie_sfx.zig exist but are not connected
  - Load OPENING.GEN music at movie start, play concurrently
  - Trigger voice clips and SFX based on ACTS block timing or BFOR commands
  - Stop all audio on skip (Escape) or movie completion
  - RED: Test music starts playing when MoviePlayer initializes
  - GREEN: Import and wire audio modules into MoviePlayer
  - Added MovieAudio struct encapsulating music/voice/SFX lifecycle
  - MoviePlayer.initAudio() loads from TRE, opens SDL devices, starts music
  - Voice clips triggered on dialogue scene transitions (mid1c/d/e)
  - All audio stopped on skip() and movie completion (fade-out)

- [x] **17.7 Update test fixtures and integration tests**
  - Replace hand-crafted MOVI test fixtures with data matching real format
  - Update all existing movie unit tests to work with new parser
  - Add integration test that renders MID1A.IFF and verifies non-black pixels
  - Verify full 6-scene playback sequence loads and renders without errors

- [x] **17.8 Fix movie rendering, text, and audio**
  - Polymorphic file slot loading (PAK/SHP/VOC detection by extension)
  - Implement SPRI types 3/4/11/12/18/19/20 rendering (text overlays, animated sprites)
  - Render unreferenced SPRI objects not in BFOR composition chain
  - Wire SFX playback via SfxBank during multi-ACTS combat scenes
  - Fix voice clip interleaving (pirate/player alternation per dialogue scene)

- [x] **17.9 Fix FILD resource index, opaque backgrounds, and render-once**
  - CRITICAL: FILD param1 is a type indicator (2=bg, 3=overlay), NOT resource index.
    Actual sprite resource = param3 + 1 (skip palette at resource 0).
    This single fix changed pixel count from 2,359 to 230,623 across all scenes.
  - Opaque background blit: backgrounds (param1=2) write ALL pixels including
    palette index 0 (black), fixing cockpit bleed-through on scene transitions.
  - Render-once optimization: each ACTS block renders once to framebuffer instead
    of re-decoding sprites 60 times/second. Eliminates ~59 redundant PAK decodes/sec.
  - Per-scene voice clips: voice system reads VOC filenames from each scene's FILE
    slots instead of sequential indexing (mid1c1 plays pir1mg1-3, mid1c2 plays pc_1mg1-2, etc.)
  - Self-ref SPRI type 4 skipped (animation keyframes need interpolation, static
    rendering at wrong position overwrites background)

- [x] **17.10 Fix text overlays and render-once optimization**
  - Text string index formula: `params[3] - font_fild.param3` indexes into MIDTEXT.PAK
    (verified: MID1A params[3]=31 - font p3=31 = entry 0 = "2669, GEMINI SECTOR...",
    MID1E1 params[3]=176 - font p3=163 = entry 13 = "What is it, that flies so good?")
  - Track text_pak_slot in MovieRenderer, set from MIDTEXT.PAK FILE reference
  - Render-once: each ACTS block renders to framebuffer once, not 60 times/sec

---

## Phase 18: Quine 4000 Computer Terminal (New Game Screen)
*Add the original game's "Quine 4000" registration screen shown when starting a new game.*

In the original Wing Commander: Privateer, clicking "New Game" on the title screen displays
the Quine 4000 — a PDA-like computer terminal where the player registers their name and
callsign before gameplay begins. The current reimplementation skips this entirely, jumping
straight to the first base scene (producing a garbled display). This phase adds the Quine 4000
registration screen and wires up the correct new-game flow.

The Quine 4000 screen features:
- A pre-rendered computer device background (320x200) from OPTSHPS.PAK
- Left panel: text display with prompts ("Please register your new Quine 4000", "Enter Name!", "Enter Callsign!")
- Right panel: decorative buttons (SAVE, LOAD, MISSIONS, FIN, MAN, PWR) and "QUINE 4000" branding
- Keyboard text input for name and callsign
- After registration: game starts at the first base (Troy system, New Detroit)

- [x] **18.1 Identify Quine 4000 background resource**
  - **Found in OPTIONS/LOADSAVE.SHP** sprite 0: 320x200 pre-rendered Quine 4000
    PDA device with green screen, buttons, and QUINE 4000 branding. Uses PCMAIN palette.
  - LOADSAVE.SHP contains 12 sprites total (see sprite inventory below).
  - CUBICLE.PAK/IFF is a MOVI composition used for the in-game encyclopedia viewer,
    NOT the registration screen. CUBICLE.PAK resource 8 = cockpit viewscreen frame,
    resource 9 = encyclopedia text screen.

- [x] **18.2 Add `registration` state to game state machine**
  - Add `registration` to the `State` enum in `src/game/game_state.zig` — append at end
    (after `options`, ordinal 10) to preserve existing save file ordinal values
  - Update `canTransition` to allow: `title → registration`, `registration → loading`,
    `registration → title` (cancel via Escape)
  - `isBaseState` does NOT include `registration` — no room/scene context needed
  - RED: Test registration state transitions (title→registration, registration→loading,
    registration→title, and invalid transitions rejected)
  - GREEN: Add enum variant and transition rules

- [x] **18.3 Expose key modifier state from Window**
  - Add `key_mod: u16 = 0` field to Window struct in `src/render/window.zig`
  - Capture `key.mod` alongside `key_pressed` in the `SDL_EVENT_KEY_DOWN` handler
  - Reset to 0 in `pollEvents` alongside `key_pressed`
  - This lets the Quine terminal detect Shift for uppercase input

- [x] **18.4 Create Quine terminal UI module**
  - New file: `src/ui/quine_terminal.zig` following the `options_menu.zig` pattern
  - `QuineTerminal` struct with phase (enter_name/enter_callsign/done),
    name/callsign buffers (max 16/12 chars), and cursor blink counter
  - `handleKeyPress(key, key_mod) → Result` (.continue_input / .cancelled / .completed):
    A-Z keys → append letter (Shift-aware uppercase), 0-9 → digits, Space → space,
    Backspace → delete, Enter → advance phase, Escape → cancel
  - `render(fb, font)`: clear framebuffer, blit Quine background (or draw procedurally),
    render text prompts with `Font.drawTextColored`, blinking cursor (toggle every 30 frames)
  - RED: Test phase progression, char append/delete, max length enforcement,
    empty name rejected, Escape cancels
  - GREEN: Implement struct with init/handleKeyPress/render methods
  - Export from `src/root.zig`

- [x] **18.5 Add player name and callsign to save data**
  - Add to `SaveGameData` in `src/persistence/save_game.zig`:
    `player_name: [16]u8`, `player_name_len: u8`,
    `player_callsign: [12]u8`, `player_callsign_len: u8`
  - Bump `FORMAT_VERSION` to 2, update `SAVE_SIZE` (360 → 390 bytes)
  - Update `serialize`/`deserialize` for new fields
  - Backward compatibility: `deserialize` accepts version 1 saves (empty name/callsign)
  - RED: Round-trip test with name/callsign, version 1 backward compat test
  - GREEN: Implement serialization and version detection

- [x] **18.6 Integrate into game loop**
  - Add `quine_terminal: ?QuineTerminal` to `GameState` struct in `src/main.zig` (init null)
  - Modify title screen "New Game" handler: `title → registration` + init QuineTerminal
    (instead of current `title → loading → landed`)
  - Add `updateRegistration` function: render Quine screen, handle key input, on completion
    copy name/callsign to save data then `loading → landed → loadLandingScene`
  - Hook into update dispatcher (`switch state_machine.state { .registration => ... }`)
  - "Load Game" flow stays unchanged (bypasses registration)

- [x] **18.7 Initialize default new-game state**
  - On registration completion, set up default save data: starting credits, Tarsus ship,
    Troy system, New Detroit base, copy name/callsign from QuineTerminal
  - Store in a `current_save` field on GameState for later save operations

---

## Future Considerations (Not in Current Scope)

### Righteous Fire Expansion
The EA release does not include Righteous Fire expansion data. If RF data is
obtained in the future, adding support would involve:
- Loading RF-specific TRE or overlay data
- RF story missions, conversations, and new fixer encounters
- RF ships and equipment additions
- The data-driven architecture should make this straightforward

### Enhanced Audio
- Re-recorded soundtrack with modern instruments
- Higher quality speech audio
- The swappable audio system (designed in Phase 11) supports drop-in replacement

### AI-Upscaled Graphics
- Use AI super-resolution on original sprites for even higher quality upscaling
- Alternatively, recreate sprites from the original 3D models (.3DS files exist
  in community archives)

### Multiplayer
- Co-op wingman mode
- Competitive trading/combat
- Not planned, but if desired later, the single-player architecture would need
  significant rework for networked state synchronization
