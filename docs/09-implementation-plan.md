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
