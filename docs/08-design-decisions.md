# Design Decisions

## Decisions Made

### 1. Graphics Fidelity: Enhanced with Upscaling
- Original: 320x200, 256 colors
- Target: **4x upscale minimum** (1280x800 base), scaling further to display resolution
- Use **high-quality upscaling algorithms** (e.g., xBRZ, HQx, or EPX) to make
  pixel art sprites look clean at higher resolutions without looking blurry or jagged
- Maintain the original art style - enhance, don't replace
- Aspect ratio: The original was 320x200 displayed on 4:3 monitors, meaning pixels
  were not square (PAR ~1.2:1). We'll correct to square pixels at 320x240 equivalent
  (or 1280x960 at 4x) then letterbox/pillarbox for widescreen

### 2. Audio: Original First, Enhanced Later
- Start with original audio formats (AdLib/General MIDI music, VOC speech)
- Design the audio system to be swappable so enhanced audio can be dropped in later
- Convert XMIDI to standard MIDI for playback via FluidSynth or similar
- VOC files play back as-is (8-bit 11kHz PCM - low quality but authentic)

### 3. Resolution: Widescreen with Faithful Core
- Support widescreen monitors (16:9, 16:10, ultrawide)
- **Space flight:** Expand the viewport horizontally to fill widescreen, showing more
  of space. The cockpit frame gets extended/adapted at the edges.
- **Landing screens:** Render at original aspect ratio, centered, with styled borders
  or a subtle vignette on the sides (these are hand-drawn scenes that can't stretch)
- **UI/menus:** Scale to fit, respecting original proportions
- Integer scaling preferred where possible to avoid sub-pixel artifacts

### 4. Righteous Fire: Deferred (No Data Available)
- The EA release does **NOT** include Righteous Fire expansion data
- Only 1 of 832 TRE entries contains "RF" and it's DUMBFIRE.IFF (a missile type)
- No `rf.cfg` exists on disk
- The executable references RF in strings but the data was not bundled
- **Decision:** Defer RF support to a future phase if/when RF data is obtained
- The data-driven architecture will naturally support RF when data is available

### 5. Multiplayer: Single-Player Only
- No multiplayer support needed
- Simplifies networking, state synchronization, and testing
- All game systems designed for single-player

### 6. Moddability: Yes, with Faithful Default
- **Data-driven design:** All game parameters loaded from data files, not hardcoded
- **Directory-based loading:** Game looks for loose files in a `mods/` directory first,
  falls back to original TRE data. This is the same pattern the original game supports
  (removing the TRE path from PRIV.CFG loads from loose files)
- **JSON/TOML config overrides:** Allow modders to override game balance values
  (prices, ship stats, weapon damage) via human-readable config files
- **Asset replacement:** Drop-in replacement for any sprite, palette, sound, or music
  file by placing it in the mod directory with the matching path
- **The default experience** is the original game, faithfully reproduced

### 7. Language: Zig + SDL3
- **Primary language:** Zig 0.15.2
- **Windowing/Input/Graphics:** SDL3
- **Rendering:** SDL3 GPU API (hardware-accelerated 2D) or SDL3 Renderer
- **Audio:** SDL3 audio subsystem + custom MIDI playback
- **Tooling:** Python for offline asset tools and format analysis
