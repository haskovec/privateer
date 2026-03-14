# Game Systems Architecture

## Overview

Based on reverse engineering of PRCD.EXE and analysis of the IFF data structures,
the following game systems have been identified. This document describes what each
system does and how it's represented in the data files.

---

## 1. Universe / Navigation System

### Data Files
- `SECTORS/QUADRANT.IFF` - FORM:UNIV containing nested FORM:QUAD > FORM:SYST
- `SECTORS/SECTORS.IFF` - Individual sector definitions
- `SECTORS/BASES.IFF` - Base definitions within sectors
- `SECTORS/TEAMS.IFF` - Faction control of sectors
- `SECTORS/TABLE.DAT` - Connectivity/navigation lookup table

### Structure
```
UNIV (Universe)
  +-- INFO (universe properties: number of quadrants)
  +-- QUAD (Quadrant 1)
  |     +-- INFO (quadrant properties: number of systems)
  |     +-- SYST (Star System)
  |     |     +-- INFO (system properties: coordinates, faction, hazard level)
  |     |     +-- BASE (base present at this system - optional)
  |     +-- SYST ...
  +-- QUAD (Quadrant 2) ...
  +-- QUAD (Quadrant 3) ...
  +-- QUAD (Quadrant 4) ...
```

### Nav Map System
- NMAP form with GRID, BTTN, QUAD, NAVI, NEXT, WNDW, MAIN, VARS, COLR, OBJE chunks
- Implements the in-cockpit navigation map display
- Jump points stored with JUMP/OJMP chunks for inter-system travel

---

## 2. Ship System

### Data Files
- `TYPES/*.IFF` - Ship type definitions (stats, hardpoints)
- `APPEARNC/*.IFF` - Ship visual appearance (sprites)
- `OPTIONS/SHIPSTUF.IFF` - Available ship equipment
- `OPTIONS/FILES.IFF` - Master file reference linking ships to their data

### Ship Definition Structure (TYPES/)
```
FORM:REAL (Ship reality/physics)
  +-- TABL (lookup tables)
  +-- SKEL (wireframe/skeleton data)
  +-- WEAP (weapon hardpoints)
  +-- GUNS (gun mount positions)
  +-- LNCH (launcher mount positions)
  +-- POSG (position data)
```

### Ship Properties (from IFF chunks)
| Chunk | Description |
|-------|-------------|
| INFO | Base ship info (name, class, dimensions) |
| SPED | Maximum speed |
| THRU | Thrust/acceleration |
| COOL | Cooling rate |
| SHBO | Shield bonus |
| REPR | Repair rate |
| ENER | Energy system (generation, capacity) |
| SHLD | Shield system (front/back/left/right) |
| DAMG | Damage model |
| MOBI | Mobility stats |
| AFTB | Afterburner data |
| ECMS | ECM (Electronic Counter-Measures) |
| NAVQ | Navigation computer quality |
| TRRT | Turret positions |
| JDRV | Jump drive |
| CRGO | Cargo capacity |
| COMM | Communications system |

### Ship Appearance Structure (APPEARNC/)
```
FORM:APPR (Appearance)
  +-- INFO (appearance metadata)
  +-- SHAP (sprite data - multiple viewing angles)
  +-- BMAP (bitmap data)
  +-- BM3D (3D bitmap/model reference)
```

### Sprite Orientation System
- 62 total viewing angles per ship
- 12 rotations around Y-axis (30-degree increments)
- ~5 rotations around X-axis
- Symmetry tables reduce unique sprites to ~37 per ship
- Each sprite is RLE-compressed

---

## 3. Combat System

### Weapons
**Data:** `TYPES/WEAPONS.IFF`, `TYPES/BEAMTYPE.IFF`, `TYPES/TORPTYPE.IFF`

Structure:
```
FORM:WEAP
  +-- FORM:LNCH (Launcher weapons)
  |     +-- UNIT (weapon unit definition x N)
  +-- FORM:MISL (Missile weapons)
        +-- UNIT (missile type definition x N)
```

**Weapon types identified from code:**
- Guns (energy weapons) - beam-based projectiles
- Heat-Seeking Missiles (MSSL type)
- Dumb-Fire Missiles (MSSL type)
- Friend-or-Foe Missiles
- Torpedoes (TORP type)
- Tractor Beam

### Damage Model
| Chunk | Description |
|-------|-------------|
| DAMG | Damage application/resistance values |
| ARMR | Armor values (per facing) |
| SHLD | Shield values (per facing) |
| FITE | Combat behavior/tactics |
| TRGT | Targeting data |
| EXPL | Explosion on destruction |

### Explosions & Debris
- `EXPLTYPE.IFF` - Explosion type definitions (BIGEXPL, MEDEXPL, SMLEXPL, DETHEXPL)
- `TRSHTYPE.IFF` - Debris/trash definitions
- `BODYPRT1/2.IFF` - Body part debris (grim but accurate)
- `CDBRTYPE.IFF` - Combat debris
- `TDBR` - Targeted debris

---

## 4. AI System

### Data Files
- `AIDS/*.IFF` - AI decision files (61 files)
- `AIDS/ATTITUDE.IFF` - Master attitude/disposition matrix
- `AIDS/MANEUVER.IFF` - Flight maneuver library

### Attitude Matrix (FORM:ATTD)
```
AROW (Attitude Row) - 9 bytes each, multiple rows
  Defines how faction X feels about faction Y
DISP (Disposition) - Starting dispositions
FLNG (Feeling) - Emotional state modifiers
THRD (Threat) - Threat assessment values
CNST (Constants) - AI behavior constants
```

### AI Behavior Patterns
- Per-faction: Kilrathi, Pirates, Retro, Confed, Militia, Merchants, Bounty Hunters
- Per-action: Attack(AA), Defend(DF/DA), Scout(SA/SF), Approach(AP)
- Combat AI uses MNVR (maneuver) chunks for flight patterns
- CNST (constants) define aggression, flee threshold, etc.

---

## 5. Economy / Trading System

### Data Files
- `OPTIONS/COMODTYP.IFF` - Commodity type definitions with base prices
- `OPTIONS/LANDFEE.IFF` - Landing fee data per base type
- `OPTIONS/LIMITS.IFF` - Trading limits and constraints
- `OPTIONS/SHIPSTUF.IFF` - Ship equipment for purchase

### Commerce Structure (from IFF chunks)
| Chunk | Description |
|-------|-------------|
| COMD | Commodity definition |
| COST | Base cost values |
| AVAL | Availability at each base type |
| XCHG | Exchange rate modifiers |
| PRIC | Price data |
| CARG | Cargo type |
| SELL | Sell price modifiers |

### Price Formula
```
SELL_PRICE = (BASE_COST - LOCATION_MODIFIER) + 1
```
Where LOCATION_MODIFIER = -1 means unavailable at that base type.

### Ship Purchase System
- Ships: Tarsus, Orion, Galaxy, Centurion
- Equipment upgrades: guns, missiles, shields, armor, afterburner, etc.
- Software upgrades: jump drive, repair droid, etc.
- Referenced via FORM:SHIP chunks with OPTS, TUGS, FIGH, MRCH, CLNK sub-forms

---

## 6. Mission System

### Data Files
- `MISSIONS/PLOTMSNS.IFF` - Master plot mission list
- `MISSIONS/S*M*.IFF` - Individual mission scripts (27 files)
- `MISSIONS/SKELETON.IFF` - Random mission template
- `MISSIONS/BFILMNGR.IFF` - Mission file manager

### Mission Structure
```
FORM:MSSN (Mission)
  +-- SCRP (Script program)
  +-- CAST (Characters involved)
  +-- FLAG (Mission state flags)
  +-- PROG (Program/logic)
  +-- PART (Participants/NPCs)
  +-- PLAY (Player objectives)
  +-- LOAD (Assets to load)
  +-- CARG (Cargo requirements)
  +-- TEXT (Briefing text)
  +-- PAYS (Payment/reward)
```

### Mission Types (from code strings)
- Patrol (PTRL)
- Scout (SCOU)
- Defend (DFND)
- Attack (ATAK)
- Bounty (BNTY)
- Cargo/Smuggling (SMGL)
- Spy (SPY)
- Sabotage (SABO)

### Random Mission Generation
- Uses `OPTIONS/RNDM*.IFF` files for templates
- FORM:RNDM and FORM:RNDF for random mission/fixer generation
- Parameterized by current sector, faction standings, player progress

---

## 7. Conversation System

### Data Files
- `CONV/*.IFF` - Conversation scripts (68 IFF files)
- `CONV/*.VPK` - Voice audio (LZW compressed VOC)
- `CONV/*.VPF` - Voice audio (alternate format)
- `CONV/*.PFC` - Variable name mappings
- `OPTIONS/COMMTXT.IFF` - Communication text
- `OPTIONS/COMMSTUF.IFF` - Communication assets
- `OPTIONS/COMPTEXT.IFF` - Computer text

### Conversation Structure
```
FORM:CONV (Conversation)
  +-- FORM:RECV (Receive - NPC speech)
  |     +-- INFO, LABL, CORD, etc.
  +-- FORM:SEND (Send - Player choices)
  |     +-- INFO, LABL, CORD, etc.
  +-- FORM:COMM (Communication link)
  +-- FORM:FRND/NEUT/HOST/CMBT (Context: friendly/neutral/hostile/combat)
  +-- FORM:PLOT (Plot-related dialogue)
  +-- FORM:RUMR (Rumors)
```

### Communication Types
| Context | Description |
|---------|-------------|
| COMP | Computer/automated messages |
| MERC | Mercenary guild |
| MRCH | Merchant guild |
| OPEN | Opening hail |
| JOIN | Join formation |
| WELC | Welcome |
| UNAV | Unavailable |
| SCAN | Cargo scan |
| NROM | Normal greeting |
| PTRL | Patrol check |
| SCOU | Scout report |
| DFND | Defense alert |
| ATAK | Attack callout |
| BOUN | Bounty claim |
| ACPT | Accept mission |
| CMIS | Complete mission |

---

## 8. Rendering System

### Cockpit
- `COCKPITS/*.IFF/.PAK` - Three cockpit types (Tarsus, Fighter, Merchant)
- COCK chunk with OFFS (offsets), TPLT (template), SHAP (overlay shape)
- MFD displays: CMFD, CHUD, DIAL, FONT chunks
- HUD elements: targeting reticle (ITTS), radar, damage display

### Scene Rendering
```
FORM:SCEN (Scene)
  +-- TABL (lookup/index table)
  +-- BACK (background image)
  +-- PALT (palette data)
  +-- FORE (foreground overlay)
  +-- SHAP (shape data)
  +-- INFO (scene metadata)
  +-- CLCK (clickable regions)
  +-- LABL (labels)
  +-- SEQU (animation sequence)
  +-- RECT (rectangular regions)
  +-- REGN (interaction regions)
  +-- SPRT (sprite positions)
```

### Space Rendering Pipeline
1. Clear to space background
2. Render star field (STRS, DUST chunks)
3. Render suns (SUNS chunk)
4. Render distant objects (planets, bases) as scaled sprites
5. Render ships/projectiles as oriented, scaled sprites
6. Render explosions/effects
7. Overlay cockpit frame
8. Render MFD displays
9. Render HUD elements (targeting, messages)

---

## 9. Save Game System

### Data
- `OPTIONS/PLAYSCOR.IFF` - Save game scoring/state
- `initcfg.pak` - Initial configuration

### Save State (FORM:GAME)
```
FORM:GAME
  +-- DATA (raw game state)
  +-- PLAY (player data)
  +-- KILL (kill statistics)
  +-- SCOR (score tracking)
```

### Player State (FORM:PLAY)
Tracks: current ship, location, credits, cargo, equipment, faction standings,
mission progress, story flags.

---

## 10. Sound / Music System

### Music
- XMIDI format (Extended MIDI) - used for in-game music
- XDIR/XMID/TIMB chunks in IFF files
- 5 music tracks: Base tune, Combat, Credits, Opening, Victory
- Dual format: ADL (AdLib FM) + GEN (General MIDI) for hardware compatibility

### Sound Effects
- `soundfx.pak` - Sound effects pack
- `speech.pak` - In-flight speech pack
- EFCT chunks reference sound effect indices
- TUNE chunks reference music tracks
- VOC format for digital audio playback

### Sound Drivers
- AdLib (OPL2/3 FM synthesis)
- Sound Blaster (PCM + OPL)
- Roland MT-32/LAPC-1 (MIDI)
- Pro Audio Spectrum (PAS)
