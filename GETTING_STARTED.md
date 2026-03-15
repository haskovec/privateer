# Getting Started

A quick guide to installing, configuring, and playing the Privateer engine -- a
modern reimplementation of Wing Commander: Privateer (1993).

## What You Need

1. **Zig 0.15.2** or later -- https://ziglang.org/download/
2. **Original game files** -- a legal copy of Wing Commander: Privateer containing
   `GAME.DAT` (the ISO 9660 image with `PRIV.TRE` inside). Common sources include
   the GOG or EA release.
3. **A gamepad is optional** for space flight (Xbox, PlayStation, or any
   SDL3-compatible controller). Keyboard flight controls are fully supported
   and both input methods work simultaneously.

## Quick Start

```bash
# 1. Clone the repository
git clone <repo-url> privateer
cd privateer

# 2. Copy and edit the config file
cp privateer.json.example privateer.json
# Edit privateer.json and set "data_dir" to the folder containing GAME.DAT

# 3. Build and run
zig build run
```

That's it. The game reads `privateer.json` on startup and loads all assets from
your original game data.

### Minimal Configuration

The only required setting is `data_dir`. Create a `privateer.json` with:

```json
{
  "data_dir": "/path/to/directory/containing/GAME.DAT"
}
```

Or set the environment variable instead:

```bash
export PRIVATEER_DATA="/path/to/directory/containing/GAME.DAT"
```

See [SETUP.md](SETUP.md) for the full configuration reference (graphics, audio,
input options).

## Controls

### General

| Key / Input       | Action              |
|-------------------|---------------------|
| Alt + Enter       | Toggle fullscreen   |
| Mouse click       | Interact with menus, landing screens, conversations |

### Gamepad -- Space Flight

A gamepad (Xbox, PlayStation, or compatible) is the primary input method for
space flight.

| Input             | Action              |
|-------------------|---------------------|
| Left Stick X      | Yaw (turn left/right) |
| Left Stick Y      | Pitch (nose up/down)  |
| Right Trigger     | Throttle (0% to 100%) |
| Left Shoulder (LB)  | Afterburner (hold)  |
| Right Shoulder (RB) | Fire guns (hold)    |
| A / Cross         | Fire missile        |
| Y / Triangle      | Cycle target        |
| X / Square        | Toggle autopilot    |
| B / Circle        | Toggle nav map      |

The gamepad is auto-detected on connection and supports hot-plug. Deadzone
defaults to 15% and can be adjusted in `privateer.json`:

```json
{
  "input": {
    "joystick_deadzone": 0.15
  }
}
```

### Keyboard -- Space Flight

Keyboard flight controls match the original DOS game. Both keyboard and gamepad
can be used simultaneously — the engine merges inputs automatically.

| Key               | Action              |
|-------------------|---------------------|
| Arrow Left/Right  | Yaw (turn left/right) |
| Arrow Up/Down     | Pitch (nose up/down)  |
| + / =             | Increase throttle (held) |
| -                 | Decrease throttle (held) |
| Tab               | Afterburner (hold)  |
| Space / Enter     | Fire guns (hold)    |
| F                 | Fire missile        |
| T                 | Cycle target        |
| A                 | Autopilot           |
| N                 | Nav map             |

Note: Alt + Enter is reserved for fullscreen toggle and will not fire guns.

## Graphics Options

The engine renders at the original 320x200 resolution internally, then upscales
for display. You can tweak this in `privateer.json`:

```json
{
  "graphics": {
    "scale_factor": 4,
    "fullscreen": false,
    "viewport_mode": "fit_4_3"
  }
}
```

| Option          | Values                | Default    |
|-----------------|-----------------------|------------|
| `scale_factor`  | 2, 3, or 4           | 4 (1280x800) |
| `fullscreen`    | true / false          | false      |
| `viewport_mode` | `"fit_4_3"` or `"fill"` | `"fit_4_3"` |

These can also be changed from the in-game Options menu.

## Audio Options

```json
{
  "audio": {
    "sfx_volume": 1.0,
    "music_volume": 0.7
  }
}
```

Volume values range from 0.0 (muted) to 1.0 (full). Adjustable in the
in-game Options menu.

## Modding

The engine supports loading modded assets from a `mods/` directory. Files placed
there override the corresponding files from the TRE archive. In dev mode, asset
changes are hot-reloaded automatically.

For the full modding workflow (extract, edit, repack), see [SETUP.md](SETUP.md).

## Troubleshooting

**"No game data found"** -- Make sure `data_dir` in `privateer.json` points to
the directory that directly contains `GAME.DAT`, not to `GAME.DAT` itself.

**No gamepad detected** -- Plug in a controller before or after launching. The
engine auto-detects via SDL3. Most Xbox and PlayStation controllers work
out of the box.

**Black screen on launch** -- Verify your `GAME.DAT` is a valid Privateer ISO
image containing `PRIV.TRE`. Some repackaged versions may have a different
structure.

## Building From Source

```bash
zig build            # Build game + tools
zig build test       # Run unit tests (no game data needed)
zig build run        # Build and run
```

For macOS .app bundles:

```bash
./macos/bundle.sh              # Native architecture
./macos/bundle.sh --universal  # Universal (Intel + Apple Silicon)
```

For more detail on building, testing, asset tools, and the project architecture,
see the [README](README.md) and [SETUP.md](SETUP.md).
