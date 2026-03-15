# Setup Guide

This guide explains how to configure the original Wing Commander: Privateer game
data for building, testing, and running the Privateer engine.

## Prerequisites

- **Zig 0.15.2** (or later)
- **Original game files**: A copy of Wing Commander: Privateer containing `GAME.DAT`
  (the ISO 9660 image with `PRIV.TRE` inside)

## 1. Locate Your Game Data

You need the directory that contains `GAME.DAT`. Common locations:

- **Windows (EA/GOG):** `C:\Program Files\EA Games\Wing Commander Privateer\DATA`
- **macOS (manual install):** wherever you placed the game files, e.g. `~/Games/privateer`
- **Linux:** e.g. `~/games/privateer`

The directory must contain `GAME.DAT` directly (not inside a subdirectory).

## 2. Set the PRIVATEER_DATA Environment Variable

All integration tests and the game runtime use the `PRIVATEER_DATA` environment
variable to find the game data.

### Temporary (current shell session)

**bash / zsh (macOS, Linux, Git Bash on Windows):**
```bash
export PRIVATEER_DATA="/path/to/directory/containing/GAME.DAT"
```

**PowerShell (Windows):**
```powershell
$env:PRIVATEER_DATA = "C:\Program Files\EA Games\Wing Commander Privateer\DATA"
```

### Persistent

**macOS / Linux** -- add to your `~/.bashrc`, `~/.zshrc`, or `~/.profile`:
```bash
export PRIVATEER_DATA="$HOME/Games/privateer"
```

**Windows** -- set via System Properties > Environment Variables, or:
```powershell
[Environment]::SetEnvironmentVariable("PRIVATEER_DATA", "C:\Program Files\EA Games\Wing Commander Privateer\DATA", "User")
```

## 3. Build and Test

```bash
# Build the engine and tools
zig build

# Run unit tests only (no game data needed)
zig build test

# Run all tests including integration tests (requires PRIVATEER_DATA)
PRIVATEER_DATA=/path/to/data zig build test
```

If `PRIVATEER_DATA` is not set, integration tests are skipped automatically.
Unit tests always run regardless.

## 4. Extract Game Assets (Optional)

The `privateer-extract` CLI tool extracts all 832 files from `GAME.DAT` into a
directory tree for inspection or modding:

```bash
zig build extract -- --data-dir /path/to/directory/containing/GAME.DAT --output ./extracted
```

This produces a directory tree mirroring the original TRE archive structure:
```
extracted/
  AIDS/        -- AI behavior data (ATTITUDE.IFF, etc.)
  APPEARNC/    -- Ship appearance sprites
  COCKPITS/    -- Cockpit frame graphics
  CONV/        -- Conversation scripts and data
  MIDGAMES/    -- Landing/launch/jump animations
  MISSIONS/    -- Plot mission scripts
  OPTIONS/     -- Menu and UI resources
  SECTORS/     -- Sector/system data
  ...
```

## 5. Run the Game

```bash
zig build run
```

The game reads `PRIVATEER_DATA` (or `config.json` in the working directory) to
locate `GAME.DAT` at startup.
