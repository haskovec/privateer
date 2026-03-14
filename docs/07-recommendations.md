# Reimplementation Recommendations

## Goal
Rebuild Wing Commander: Privateer as a standalone game for Windows 11 and macOS,
reading the original game data files where possible, with no dependency on DOSBox
or the EA Store.

## Language/Framework Evaluation

### Option A: Zig + SDL2/SDL3 (Recommended)
**Pros:**
- Cross-platform (Windows, macOS, Linux) with single codebase
- C ABI compatibility means easy integration with SDL, OpenGL, audio libraries
- No garbage collector - predictable performance for real-time rendering
- Excellent for bit-level data parsing (packed structs, pointer arithmetic)
- Compiles to native code on both platforms
- You already have Zig 0.15.2 installed
- Small binary size, no runtime dependencies
- Can directly port C algorithms from existing community tools (HCl's RLE decoder, etc.)

**Cons:**
- Smaller ecosystem than C/C++
- Fewer game-specific libraries

### Option B: Go + SDL2 (via go-sdl2)
**Pros:**
- Fast compilation, good tooling
- Cross-compilation to Windows/macOS
- You have Go 1.26.1 installed
- Good standard library for file I/O and data parsing

**Cons:**
- Garbage collector can cause frame stutters (problematic for 60fps rendering)
- CGo overhead for SDL/OpenGL calls
- Not ideal for low-level bit manipulation needed for format parsing
- Less common for game development

### Option C: C# / .NET 10 + MonoGame or Raylib
**Pros:**
- You have .NET 10 installed
- MonoGame is a mature 2D/3D game framework (used by Stardew Valley, etc.)
- Strong tooling (Visual Studio integration)
- Good cross-platform support via .NET

**Cons:**
- GC pauses (though .NET 10's GC is quite good)
- Heavier runtime
- MonoGame content pipeline may not align well with custom format parsing

### Option D: Java 25 + LWJGL or LibGDX
**Pros:**
- You have Java 25 installed
- LibGDX is a mature cross-platform game framework
- Large ecosystem

**Cons:**
- JVM overhead and GC pauses
- Not ideal for bit-level binary parsing
- Feels heavyweight for a retro game port

### Option E: C/C++ + SDL2
**Pros:**
- Most community tools are in C/C++ - direct code reuse
- Maximum performance
- Most game engines are C/C++

**Cons:**
- You'd need to install a C/C++ toolchain (MSVC is available per README)
- Memory safety concerns
- Slower development iteration

### Option F: Python + Pygame (for prototyping only)
**Pros:**
- Fastest development speed
- Python 3.13 installed
- Excellent for prototyping format parsers

**Cons:**
- Too slow for real-time rendering at scale
- Not suitable for final product
- Good for tools, not for the game itself

## Recommended Architecture

### Primary: Zig + SDL3
Given the tools available and the project goals, I recommend **Zig with SDL3** as the
primary implementation language. Here's why:

1. **Binary parsing is first-class** - Zig's packed structs and pointer casting make
   parsing TRE/IFF/PAK formats natural
2. **C interop** - Can directly call into SDL3, OpenAL/OpenAL Soft for audio, and
   stb_image for image handling
3. **Cross-platform** - Single codebase compiles natively for Windows and macOS
4. **Performance** - No GC, no runtime overhead, suitable for 60fps rendering
5. **Community code reuse** - Can port C algorithms (RLE decoder, XMIDI parser) trivially

### Supporting: Python for Tools
Use Python for offline tooling:
- Asset extraction and verification scripts (we've already started these)
- Format analysis and debugging
- Build pipeline helpers

## Phased Implementation Plan

### Phase 1: Data Foundation
- Build TRE archive reader
- Build IFF chunk parser
- Build PAK unpacker
- Build RLE sprite decoder
- Build PAL palette loader
- Extract and verify all game assets can be read
- **Deliverable:** Command-line tool that extracts and previews all game data

### Phase 2: Rendering Engine
- Initialize SDL3 window (320x200 scaled to modern resolution)
- Implement palette-based rendering (256-color with palette swapping)
- Render sprites with RLE decompression
- Implement sprite scaling (distance-based)
- Render cockpit overlay
- Implement scene rendering (landing screens with clickable regions)
- **Deliverable:** Static scene viewer that can display any game screen

### Phase 3: Core Game Loop
- Implement game state machine (space flight, landed, conversation, combat)
- Implement player ship physics (thrust, rotation, velocity)
- Implement basic space rendering (star field, ships, nav points)
- Implement input handling (keyboard, mouse, joystick)
- Implement cockpit MFD displays
- **Deliverable:** Flyable ship in an empty sector

### Phase 4: Universe & Navigation
- Load and represent the Gemini Sector (quadrants, systems, nav points)
- Implement nav map display
- Implement autopilot to nav points
- Implement jump drive (inter-system travel)
- Implement landing/launching at bases
- **Deliverable:** Navigate the full Gemini Sector

### Phase 5: Combat
- Implement weapon systems (guns, missiles, torpedoes)
- Implement projectile physics
- Implement shield/armor/damage model
- Implement AI flight behavior (from AIDS/*.IFF maneuver data)
- Implement NPC ship spawning per sector definitions
- Implement explosions and debris
- Implement tractor beam (cargo collection)
- **Deliverable:** Full space combat

### Phase 6: Economy & Trading
- Implement commodity system (buying/selling with price modifiers)
- Implement ship dealer (purchase ships, equipment upgrades)
- Implement credits/inventory management
- Implement cargo hold mechanics
- **Deliverable:** Full trading loop

### Phase 7: Story & Missions
- Implement mission computer (random mission generation)
- Implement mission scripting engine (SCRP/PROG/FLAG system)
- Implement plot missions (S0-S9 series)
- Implement conversation system with branching dialogue
- Implement fixer encounters in bars
- **Deliverable:** Complete plot playthrough

### Phase 8: Audio
- Implement VOC playback for speech
- Implement XMIDI music playback (or convert to standard MIDI/OGG)
- Implement sound effects system
- Implement VPK/VPF voice pack decompression
- **Deliverable:** Full audio

### Phase 9: Save/Load & Polish
- Implement save/load game state
- Implement options/preferences menu
- Implement joystick calibration
- Resolution scaling and fullscreen support
- Performance optimization
- Bug fixes and gameplay balance verification
- **Deliverable:** Release candidate

## Open Questions for Discussion

Before proceeding to implementation, I'd like to clarify:

1. **Fidelity vs. Enhancement:** Should we aim for pixel-perfect reproduction of the
   original 320x200 graphics (scaled up), or would you prefer enhanced graphics
   (e.g., using the original 3D models that exist, or AI-upscaled sprites)?

2. **Audio Approach:** Should we use the original AdLib/MIDI music, or would you
   prefer re-recorded/enhanced music tracks?

3. **Resolution:** Should the game run in a fixed aspect ratio window (4:3 like the
   original) with integer scaling, or should it adapt to widescreen?

4. **Righteous Fire:** Should we include Righteous Fire expansion support from the
   start, or add it later? (The executable references it but the data may need
   separate extraction.)

5. **Multiplayer:** The original had no multiplayer. Any interest in adding it, or
   keep it single-player only?

6. **Modding Support:** Should we design the engine to be moddable (loading data
   from directories, config files for game balance), or keep it focused on the
   original game?
