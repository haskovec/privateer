# Privateer

A modern reimplementation of **Wing Commander: Privateer** (Origin Systems, 1993) built
from the ground up in Zig with SDL3. The goal is a standalone, cross-platform game for
Windows 11 and macOS that reads the original game data files -- no DOSBox, no EA Store,
just the game as it was meant to be played.

The original was one of the first open-world space combat and trading games. You fly
your own ship through the Gemini Sector, trading commodities, taking on mercenary
missions, fighting pirates and Kilrathi, and unraveling a plot that spans dozens of
star systems. This project faithfully recreates that experience with enhanced graphics
(4x upscaled sprites), widescreen support, and a moddable, data-driven architecture.

## Tech Stack

- **Language:** Zig 0.15.2
- **Graphics/Input/Audio:** SDL3
- **Rendering:** 320x200 internal resolution upscaled via xBRZ/HQ4x to 1280x800+
- **Tooling:** Python 3.13 (offline asset analysis and extraction scripts)

## Project Status

Phase 0 through Phase 6 complete. Phase 7 (Combat) is next. See the
[Implementation Plan](docs/09-implementation-plan.md) for detailed progress.

## Project Layout

```
privateer/
├── build.zig                  # Zig build configuration (exe, engine module, test suites)
├── build.zig.zon              # Zig package dependencies (SDL3)
├── src/
│   ├── main.zig               # Game executable entry point
│   ├── root.zig               # Engine library root (exports all submodules)
│   ├── config.zig             # JSON configuration system (data paths, settings)
│   ├── sdl.zig                # SDL3 initialization wrapper
│   ├── testing.zig            # Test helpers (fixture loader, binary assertions, BE readers)
│   ├── integration_tests.zig  # Integration tests against real game data
│   │
│   ├── formats/               # Binary file format parsers (read original game data)
│   │   ├── iso9660.zig        # ISO 9660 CD image parser (reads GAME.DAT)
│   │   ├── tre.zig            # TRE archive reader (832-entry PRIV.TRE)
│   │   ├── iff.zig            # IFF chunk parser (FORM/CAT/LIST containers, leaf chunks)
│   │   ├── sprite.zig         # RLE sprite decoder (Origin's proprietary run-length encoding)
│   │   ├── shp.zig            # SHP shape/font file parser (offset table + RLE sprites)
│   │   ├── pak.zig            # PAK resource unpacker (two-level offset tables + resources)
│   │   ├── pal.zig            # PAL palette file parser (256-color VGA palettes)
│   │   ├── voc.zig            # VOC audio loader (Creative Voice File, 8-bit PCM)
│   │   ├── vpk.zig            # VPK/VPF voice pack decompressor (LZW-compressed VOC clips)
│   │   └── music.zig          # Music format loaders (ADL/GEN XMIDI, Standard MIDI)
│   │
│   ├── render/                # Rendering pipeline & display
│   │   ├── framebuffer.zig    # Palette-based software renderer (320x200 indexed → RGBA → SDL texture)
│   │   ├── window.zig         # Window creation, game loop, fullscreen toggle (SDL3)
│   │   ├── upscale.zig        # Edge-aware pixel art upscaler (Scale2x/3x, 2x/3x/4x factors)
│   │   ├── viewport.zig       # Widescreen viewport (4:3 fit with pillarbox/letterbox, fill mode)
│   │   ├── text.zig           # Text rendering engine (SHP font loading, string rendering)
│   │   ├── render.zig         # Sprite rendering pipeline (palette-indexed → RGBA → PNG)
│   │   ├── scene_renderer.zig # Scene renderer (PAK sprite backgrounds, compositing pipeline)
│   │   └── png.zig            # Minimal PNG encoder (RGBA → PNG, uncompressed deflate)
│   │
│   ├── game/                  # World data & game flow
│   │   ├── universe.zig       # Universe data loader (QUADRANT.IFF: quadrants, systems, coordinates, names)
│   │   ├── bases.zig          # Base registry loader (BASES.IFF: base names, types, indices)
│   │   ├── nav_graph.zig      # Navigation graph (TABLE.DAT: 69x69 system distance matrix)
│   │   ├── nav_map.zig        # Nav map display (sector map renderer, hit-testing, autopilot selection)
│   │   ├── scene.zig          # Scene data loader (GAMEFLOW.IFF room/scene navigation graph)
│   │   ├── game_state.zig     # Game state machine (state transitions, action handling, scene tracking)
│   │   ├── click_region.zig   # Click region system (EFCT action parser, hit-testing, scene transitions)
│   │   └── midgame.zig        # Midgame animation sequences (landing/launch/jump/death from PAK data)
│   │
│   ├── flight/                # Real-time flight systems
│   │   ├── flight_physics.zig # Space flight physics (thrust, rotation, velocity, speed capping, afterburner)
│   │   ├── autopilot.zig      # Autopilot system (nav point steering, arrival detection, hostile interruption)
│   │   └── jump_drive.zig     # Jump drive system (inter-system travel, adjacency validation, cooldown)
│   │
│   ├── cockpit/               # Cockpit & HUD displays
│   │   ├── cockpit.zig        # Cockpit renderer (IFF/PAK loader, ship-specific cockpit frames, overlay)
│   │   ├── mfd.zig            # MFD system (CMFD/CHUD/DIAL parsers, gauge rendering, display mode cycling)
│   │   ├── radar.zig          # Radar display (top-down contact rendering, IFF faction coloring, yaw rotation)
│   │   ├── damage_display.zig # Damage display (shield/armor status per facing, color-coded diagram renderer)
│   │   ├── targeting.zig     # Targeting system (nearest hostile selection, target cycling, ITTS lead indicator)
│   │   └── messages.zig     # In-flight message system (categorized message queue, timed expiration, HUD renderer)
│   │
│   └── cli/                   # Offline tools & asset pipelines
│       ├── extract.zig        # Asset extraction pipeline (GAME.DAT → directory tree)
│       ├── extract_cli.zig    # Asset extraction CLI entry point (privateer-extract)
│       ├── validate.zig       # Data validation pipeline (all parsers → error report)
│       └── palette_viewer.zig # Palette viewer (256-color grid → PNG swatch images)
│
├── tests/
│   ├── gen_fixtures.py        # Python script to generate binary test fixtures
│   └── fixtures/              # Binary test data (ISO, TRE, IFF samples)
├── tools/                     # Python reverse-engineering scripts (analysis only)
└── docs/                      # Design documents and specs (see below)
```

### Build Commands

- `zig build` -- build the game executable and tools
- `zig build test` -- run all unit and integration tests
- `zig build run` -- build and run the game
- `zig build extract -- --data-dir <path> --output <dir>` -- extract all game assets from GAME.DAT

## Documentation

All project documentation lives in the `docs/` directory:

| Document | Description |
|----------|-------------|
| [Game Overview](docs/01-game-overview.md) | What the game is, world structure, ships, economy, factions, and how the EA release is packaged |
| [Executable Analysis](docs/02-executable-analysis.md) | Reverse engineering of PRIV.EXE (loader) and PRCD.EXE (game binary) -- compiler, source files, game systems, rendering pipeline |
| [Data Formats](docs/03-data-formats.md) | Specifications for every file format: TRE archives, IFF chunks, PAK resources, VPK/VPF voice packs, VOC audio, SHP sprites, PAL palettes, RLE compression |
| [Data Inventory](docs/04-data-inventory.md) | Complete inventory of all 832 game files across 14 directories with size breakdowns and descriptions |
| [Game Systems](docs/05-game-systems.md) | Architecture of the 10 major game systems: universe, ships, combat, AI, economy, missions, conversations, rendering, saves, audio |
| [Existing Work](docs/06-existing-work.md) | Community projects (Gemini Gold, Confederation), modding tools (wctools, Originator, HCl's tools), and key technical references |
| [Recommendations](docs/07-recommendations.md) | Language/framework evaluation and the rationale for choosing Zig + SDL3 |
| [Design Decisions](docs/08-design-decisions.md) | Locked-in decisions: 4x upscaling, original audio, widescreen, moddability, single-player, Righteous Fire deferred |
| [Implementation Plan](docs/09-implementation-plan.md) | 14-phase plan with checkboxes for progress tracking, ordered by priority, using red/green TDD methodology throughout |

## Original Game Data

This project requires a copy of the original Wing Commander: Privateer game files
(specifically the `GAME.DAT` ISO image containing `PRIV.TRE`). The game engine we
are building is original work; the game data is not included in this repository.

## Tools

The `tools/` directory contains Python scripts used during the reverse engineering phase:

| Script | Purpose |
|--------|---------|
| `parse_tre.py` | Parse and list file entries from the PRIV.TRE archive |
| `full_analysis.py` | Categorize all game files by directory and extension |
| `tre_deep_parse.py` | Analyze TRE entry metadata format (offsets, sizes) |
| `tre_entries.py` | Extract all 832 TRE entries with spacing analysis |
| `find_file_data.py` | Locate actual file data within the TRE using offset hypothesis testing |
| `iff_analysis.py` | Parse IFF chunk structures and catalog all FORM/chunk types |
| `analyze_iff.py` | Deep recursive IFF chunk analysis with data extraction |
| `analyze_sectors.py` | Analyze SECTORS/ files from PRIV.TRE to understand universe data structures |
| `other_formats.py` | Analyze non-IFF formats (PAK, VPK, VPF, VOC, SHP, PAL, DAT) |
| `pak_diag.py` | Diagnose PAK file offset tables and resource layouts |
| `vpk_analysis.py` | Analyze VPK/VPF voice pack file structures and LZW compression |
| `exe_strings.py` | Extract and categorize meaningful strings from PRCD.EXE |
| `check_rf.py` | Check whether Righteous Fire expansion data is present |
| `analyze_cockpits.py` | Analyze cockpit IFF/PAK file structures from PRIV.TRE |
| `analyze_cockpit_shap.py` | Deep analysis of cockpit SHAP sprite format and TPLT layout data |
| `analyze_mfd.py` | Deep analysis of MFD chunks (CMFD, CHUD, DIAL) from cockpit IFF files |
