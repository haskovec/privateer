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

## 2. Configuration

The engine uses a single config file `privateer.json` in the working directory.
Copy the example and edit it with your game data path:

```bash
cp privateer.json.example privateer.json
```

The full set of options:

```json
{
  "data_dir": "/path/to/directory/containing/GAME.DAT",
  "mod_dir": "mods",
  "output_dir": "output",
  "graphics": {
    "scale_factor": 4,
    "fullscreen": false,
    "viewport_mode": "fit_4_3"
  },
  "audio": {
    "sfx_volume": 1.0,
    "music_volume": 0.7
  },
  "input": {
    "joystick_deadzone": 0.15
  }
}
```

Only `data_dir` is required — all other fields have sensible defaults and can
be omitted. A minimal config is just:

```json
{
  "data_dir": "/path/to/directory/containing/GAME.DAT"
}
```

### Configuration precedence

Settings are resolved in this order (highest priority first):

1. **CLI arguments**: `--data-dir`, `--mod-dir`, `--output-dir`
2. **PRIVATEER_DATA environment variable**: overrides `data_dir` only
3. **`privateer.json`** config file
4. **Built-in defaults**

### PRIVATEER_DATA environment variable

As an alternative to (or override for) `privateer.json`, you can set the
`PRIVATEER_DATA` environment variable. This is especially useful for integration
tests and CI where you don't want a config file checked in.

**bash / zsh (macOS, Linux, Git Bash on Windows):**
```bash
export PRIVATEER_DATA="/path/to/directory/containing/GAME.DAT"
```

**PowerShell (Windows):**
```powershell
$env:PRIVATEER_DATA = "C:\Program Files\EA Games\Wing Commander Privateer\DATA"
```

To persist across sessions, add the export to `~/.bashrc` / `~/.zshrc` or set
it via System Properties > Environment Variables on Windows.

## 3. Build and Test

```bash
# Build the engine and tools
zig build

# Run unit tests only (no game data needed)
zig build test

# Run all tests including integration tests (requires PRIVATEER_DATA or privateer.json)
PRIVATEER_DATA=/path/to/data zig build test
```

If neither `PRIVATEER_DATA` nor a valid `privateer.json` `data_dir` is set,
integration tests are skipped automatically. Unit tests always run regardless.

## 4. Extract Game Assets (Optional)

The `privateer-extract` CLI tool extracts all 832 files from `GAME.DAT` into a
directory tree for inspection or modding:

```bash
zig build extract -- --output ./extracted
```

If `data_dir` is not set in `privateer.json` or `PRIVATEER_DATA`, pass it explicitly:

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

## 5. Repack Modded Assets (Optional)

After extracting and modifying game assets (sprites, data files, etc.), you can
repack them into a new `GAME.DAT` for distribution or testing:

```bash
zig build repack -- --input ./extracted --output ./GAME.DAT
```

This builds a new `PRIV.TRE` archive from the directory tree and wraps it in a
valid ISO 9660 image. The resulting `GAME.DAT` can be used as a drop-in
replacement for the original.

**Modding workflow:**
```bash
# 1. Extract original assets
zig build extract -- --data-dir /path/to/original --output ./modded

# 2. Edit files in ./modded/ (replace sprites, tweak IFF data, etc.)

# 3. Repack into a new GAME.DAT
zig build repack -- --input ./modded --output ./GAME_MODDED.DAT
```

## 6. Run the Game

```bash
zig build run
```

The game loads configuration from `privateer.json`, with `PRIVATEER_DATA` env var
and CLI arguments as overrides. The options menu (in-game) modifies settings and
saves them back to `privateer.json`.
