# Wing Commander: Privateer - Game Overview

## Background

Wing Commander: Privateer was developed by Origin Systems and released in 1993 for
MS-DOS. It runs on the **Origin FX** raster-based engine (the last game to use this
engine before Origin transitioned to the polygon-based RealSpace engine for WC3).

The EA re-release (which we are analyzing) wraps the original DOS game in DOSBox 0.74
for modern Windows compatibility. The game runs at **320x200 VGA, 256 colors (Mode 13h)**.

## Game Structure

Privateer is an open-world ("sandbox") space combat and trading game set in the
**Gemini Sector** of the Wing Commander universe.

### World Layout
- **4 quadrants** making up the Gemini Sector
- **~69 star systems**, each containing nav points
- Nav points include: bases, jump points, nav buoys, asteroids
- Star systems are connected by jump points forming a navigable graph

### Base Types (9 total)
| Type | Examples | Facilities |
|------|----------|------------|
| Agricultural | Troy, Palan | Commodity exchange, ship dealer, bar |
| Mining | Rygannon, Pentonville | Commodity exchange, ship dealer, bar |
| Pleasure | Jolson, Oakham | Commodity exchange, ship dealer, bar |
| Pirate | Tingerhoff, Blockade Point | Limited trade, unique missions |
| Refinery | Refinery bases | Commodity exchange |
| New Constantinople | Unique | Full facilities, plot-critical |
| New Detroit | Unique | Full facilities, plot-critical |
| Oxford | Unique | University, plot-critical |
| Perry Naval Base | Unique | Military base, plot-critical |

### Base Rooms (landing screens)
When landed at a base, the player navigates static first-person room screens:
- **Mission Computer** - Accept freelance missions
- **Commodity Exchange** - Buy/sell trade goods
- **Ship Dealer** - Buy ships, upgrade equipment
- **Bar** - Meet NPCs, hear rumors, find fixers (plot missions)
- **Hangar** - Launch from base

### Flyable Ships (4 player ships)
| Ship | Class | Role |
|------|-------|------|
| Tarsus | Scout | Starting ship, cheapest |
| Orion | Heavy Fighter | Balanced combat/cargo |
| Galaxy | Freighter | Maximum cargo capacity |
| Centurion | Heavy Fighter | Best combat ship |

### NPC Factions
- **Confed** (Confederation military)
- **Militia** (Local defense)
- **Merchants** (Traders)
- **Pirates** (Hostile)
- **Kilrathi** (Alien enemies)
- **Retro** (Anti-technology terrorists)
- **Bounty Hunters**
- **Mercenaries**

### Economy
- Multiple commodity types tradeable between bases
- Prices vary by base type with modifiers
- Formula: `SELL_PRICE = (BASE_COST - MODIFIER) + 1`
- Modifier of -1 means commodity unavailable at that base
- Credits are the in-game currency

### Combat
- Real-time space combat with joystick/keyboard controls
- Weapons: guns (energy-based), missiles, torpedoes
- Ship systems: shields, armor, afterburner, tractor beam, ECM, jump drive
- MFD (Multi-Function Displays) on cockpit for targeting, radar, damage, etc.

### Story
- Plot missions acquired from "fixers" in bars at specific locations
- Multiple story arcs (series S0-S9+)
- Righteous Fire expansion adds additional plot content

## EA Release Structure

The EA distribution wraps the original game:
```
wingco~1/
  DATA/
    DOSBox/          - DOSBox 0.74 emulator + DRM wrapper
    GAME.DAT         - ISO 9660 CD image (90 MB) containing PRIV.TRE
    PRIV.EXE         - DOS loader (memory manager, launches PRCD.EXE)
    PRCD.EXE         - Main game executable (938 KB, Borland C++ 1991)
    PRIV.CFG         - Config file (points to D:priv.tre on virtual CD)
    SOUND.CFG        - Sound card configuration
    INSTALL.EXE      - Original DOS installer
    JEMM.OVL         - EMS memory manager overlay
    JOYA.DAT         - Joystick calibration
    TABTNE.VDA       - Unknown data file
    TABTXE.NDA       - Unknown data file
  manual.pdf         - Original game manual
  reference_guide.pdf - Quick reference card
  Support/           - EA support files
  __Installer/       - EA installer files
```

### Boot Sequence
1. DOSBox starts with `dosbox.conf` configuration
2. Mounts `C:` as the DATA parent directory
3. Mounts `GAME.DAT` as `D:` (ISO image)
4. Runs `priv.exe` which:
   - Sets up JEMM EMS/XMS memory management
   - Loads and launches `prcd.exe` (the actual game)
5. `prcd.exe` reads `priv.cfg` for data paths
6. Game data loaded from `D:\PRIV.TRE` (the ISO-mounted archive)
