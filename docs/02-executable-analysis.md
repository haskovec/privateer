# Executable Analysis

## PRIV.EXE - Memory Manager / Loader (8,325 bytes)

PRIV.EXE is **not** the game itself. It is Origin Systems' custom DOS memory manager
and loader program. Its responsibilities:

### Functions
1. **CPU Detection** - Requires 80386 or better
2. **Memory Management** - Sets up EMS (Expanded Memory) via JEMM overlay
3. **XMS/EMS Configuration** - Requires sufficient XMS and EMS memory
4. **Protected Mode** - Switches CPU to protected mode via VCPI
5. **Game Launch** - Loads and executes `PRCD.EXE`

### Key Strings Found
```
ORIGIN EMS Driver(tm) (Blue productions, 1992.) version 4.31
Usage: PRIV [switches]
  -f : move the page frame from E000h to D000h
  -o[filename] : specify the full path name of the overlay file
  -e : eat DOS and EMS memory down to absolute min (512K DOS, 1.2 MEG EMS)
  -l { 1 | 2 | 3 } : change the load address slightly
```

### Memory Requirements
- Minimum: 512K DOS memory + 1.2 MB EMS
- FILES=25 in CONFIG.SYS required

---

## PRCD.EXE - Main Game Executable (937,760 bytes)

This is the actual Wing Commander: Privateer game binary.

### Compiler
- **Borland C++ 1991** (confirmed by embedded copyright string)
- Uses Borland's overlay system for memory management
- 16-bit DOS protected mode executable

### Source File References (extracted from debug strings)
The executable contains references to original C++ source files:
| Source File | Purpose |
|-------------|---------|
| `CCINE.CPP` | Cinematic/cutscene engine |
| `CCHNKPAR.CPP` | IFF chunk parser |
| `CEXECUTE.CPP` | Script execution engine |
| `CSHOT.CPP` | Shot/projectile handling |
| `CSHPLIST.CPP` | Shape list management |
| `CSSHAPE.CPP` | Scaled shape rendering |
| `CMOVIE.CPP` | Movie/animation playback |
| `CACT.CPP` | Actor/entity system |
| `CSCENE.CPP` | Scene management |
| `CDIGITAL.CPP` | Digital audio (VOC playback) |
| `MUSIC.CPP` | Music playback (XMIDI) |
| `MUSIC-I.CPP` | Music implementation |
| `SAMPLE.CPP` | Sound sample management |
| `SOUNDF-I.CPP` | Sound effects implementation |

### Game Systems Identified

#### IFF Chunk Parser
The game reads IFF files using 4-character chunk tags. Over 100 unique chunk types
were identified being pushed onto the stack for parsing:

**Ship Systems:** SHIP, REAL, FITE, ENER, SHLD, DAMG, WEAP, GUNS, LNCH, MISL,
TRRT, REPR, COOL, SHBO, SPEE, THRU, ECMS, MOBI, AFTB, NAVQ, JDRV, CRGO, COMM

**World/Navigation:** UNIV, QUAD, SYST, BASE, SCTR, GLXY, JUMP, OJMP, STRS, DUST,
SUNS, JMPT, NMAP, GRID, NAVI

**Combat:** BEAM, PROJ, LINR, MSSL, EXPL, ASTR, CDBR, TDBR, ANSC, TRGT, HAZE

**Appearance/Rendering:** APPR, SHAP, BMAP, BM3D, PALT, FORE, BACK, SCEN, TABL,
SPRT, LOOK, EXTR, FACE, HEAD, EYES, MOTH, UNIF, HAND, HAIR

**Conversations/Story:** CONV, SCRP, CAST, FLAG, PROG, PART, PLAY, LOAD, SEND,
RECV, XCHS, FRMN, TEAM, RUMR, PLOT, MSSN, MISS

**Economy/Trade:** CRGI, CRGO, COMD, COST, AVAL, XCHG, PRIC, CARG

**UI/Cockpit:** COCK, OFFS, TPLT, ITTS, CMFD, CHUD, DIAL, FONT, RADR, PLAQ

**Music/Sound:** XDIR, XMID, TIMB, TUNE, EFCT

**Camera:** CAMR, CKPT, CHAS, AUTO, DETH, JUMP

#### Memory Management
Custom memory manager with three pools:
- **Near Memory** (conventional DOS memory)
- **Far Memory** (extended memory)
- **EMS Memory** (expanded memory)

#### File I/O System
Custom file access with pack file support:
```
NumPacks=%ld, CurPack=%ld
CurPackOffset=%ld, CurPakLen=%ld
```
Supports reading from TRE archives and individual files.

#### Sound System
- **XMIDI** music format (Extended MIDI) for music playback
- **Timbre caching** for XMIDI instrument loading
- **VOC playback** for digital speech/effects
- Sound drivers: AdLib, Roland (MT-32), Sound Blaster, Pro Audio Spectrum (PAS)
- Music files: ADL (AdLib), GEN (General MIDI)

#### Input System
- Keyboard with scan code mapping
- Joystick with polling interrupt
- Mouse support
- Stack-based interrupt handlers for each device

### Key Game Strings
```
"Type PRIV to run Privateer, or RF to run Righteous Fire."
"Thanks for playing %s."
"Load an old Privateer ship?"
"Privateer CD not found."
"BAD MISSION TYPE"
"Game Paused"
"No information available."
"No missions."
"Missile Camera On/Off"
"CREDITS : "
"DAMAGE REPORT"
"Tractor Beam"
"No Missiles"
"No Torpedoes"
"Never mind"
"NO TARGET"
"Jump to %s"
"System : %s"
"%s Quadrant"
```

### Rendering Pipeline
The game uses a sprite-based "2.5D" rendering system:
- Ships rendered as pre-rotated sprites at 62 viewing angles
- 12 rotations around Y-axis x ~5 around X-axis
- Symmetry lookup tables reduce to ~37 unique sprites per ship
- Real-time distance-based scaling of sprites
- RLE (Run-Length Encoding) compression for sprite data
- Cockpit overlay rendered as static frame around viewport
