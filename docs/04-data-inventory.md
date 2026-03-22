# Game Data Inventory

## Summary Statistics

| Metric | Value |
|--------|-------|
| Total files in PRIV.TRE | 832 |
| Total data size | 89,399,420 bytes (85.3 MB) |
| Directories | 14 |
| File formats | 14 unique extensions |

## Size by Format

| Extension | Files | Total Size | % of Total |
|-----------|-------|------------|------------|
| .VPK | 193 | 48.6 MB | 57.0% |
| .PAK | 32 | 23.2 MB | 27.2% |
| .VPF | 59 | 7.7 MB | 9.0% |
| .IFF | 305 | 4.5 MB | 5.3% |
| .VOC | 17 | 0.4 MB | 0.5% |
| .GEN | 5 | 0.3 MB | 0.3% |
| .ADL | 5 | 0.2 MB | 0.2% |
| .SHP | 11 | 0.2 MB | 0.2% |
| .PFC | 193 | 0.2 MB | 0.2% |
| .MT | 1 | 0.04 MB | <0.1% |
| .DRV | 4 | 0.03 MB | <0.1% |
| .DAT | 2 | 0.01 MB | <0.1% |
| .AD | 1 | 0.004 MB | <0.1% |
| .PAL | 4 | 0.003 MB | <0.1% |

**Note:** Voice/audio data (VPK + VPF + VOC) accounts for ~66% of total game data.

## Directory Breakdown

### DATA/AIDS/ (61 IFF files) - AI Decision System
AI behavior definition files for different factions and encounter types.

| File Pattern | Count | Description |
|-------------|-------|-------------|
| ATTITUDE.IFF | 1 | Global attitude/disposition matrix |
| BASE_*.IFF | 10 | Base-specific AI (AGR, DER, MIN, NC, ND, OX, PER, PIR, PLE, REF) |
| BOU_*.IFF | 6 | Bounty hunter AI variants |
| COM_*.IFF | 3 | Confed AI variants |
| CON_*.IFF | 3 | Confed encounter AI |
| KIL_*.IFF | 5 | Kilrathi AI variants |
| MER_*.IFF | 4 | Mercenary AI variants |
| MIL_*.IFF | 4 | Militia AI variants |
| PIR_*.IFF | 7 | Pirate AI variants |
| RET_*.IFF | 4 | Retro AI variants |
| Named NPCs | 5 | CONFED1, FORGE, GARVICK, KROIZ, MIGGS |
| MANEUVER.IFF | 1 | Flight maneuver definitions |
| MFDFACES.IFF | 1 | MFD face display data |
| PLOTUTIL.IFF | 1 | Plot utility data |

### DATA/APPEARNC/ (95 files) - Ship/Object Appearance
Visual appearance data for all ships and space objects.

**IFF Files (73):**
| File | Description |
|------|-------------|
| Ship types | BRDSWORD, CENTTYPE, DEMNTYPE, DRALTYPE, GALAXTYP, GLADIUS, GOTHRI, etc. |
| Player ships | CENTURION as CENTTYPE, TARSUS as TARSTYPE, etc. |
| Objects | ASTROID1, ASTROID2, BIGEXPL, BODYPRT1, BODYPRT2, CAPGOOD, etc. |
| Bases | AGRIC, MINING, PIRATE, PLEASURE, REFINERY, and unique bases |
| Effects | CLNKDETH, SMLEXPL, DRONTYPE, etc. |
| Misc | GALAXY (star map), NAVMAP, UNIVERSE |

**PAK Files (1):** STARS.PAK (star field)

**SHP Files (5):** Various sprite sheets

### DATA/COCKPITS/ (12 files) - Cockpit Displays
| File | Description |
|------|-------------|
| CLUNKCK.IFF/.PAK | Tarsus cockpit |
| FIGHTCK.IFF/.PAK | Centurion/fighter cockpit |
| MERCHCK.IFF/.PAK | Galaxy/merchant cockpit |
| COCKMISC.IFF | Shared cockpit elements |
| ITTS.IFF | Targeting reticle |
| PLAQUES.IFF | Ship name plaques |
| SOFTWARE.IFF | Software upgrade displays |
| WEAPONS.IFF | Weapon status display |

### DATA/CONV/ (464 files) - Conversations
The largest directory by file count. Contains conversation data in triplets:
- `*.IFF` - Conversation script/structure
- `*.VPK` or `*.VPF` - Compressed voice audio
- `*.PFC` - Variable name mappings

| Pattern | Description |
|---------|-------------|
| AGRIRUMR/AGRRUM* | Agricultural base rumors |
| GENRUM* | General rumors |
| MIGRUMR/MIGRUM* | Mining base rumors |
| PIRBAR* | Pirate bar conversations |
| PLSRUMR/PLSRUM* | Pleasure base conversations |
| REFRUMR/REFRUM* | Refinery rumors |
| Plot conversations | Series-specific (S0-S9+ storyline) |
| BZZOFPLT/BZZOF* | "Buzz off" rejection dialogues |

### DATA/FONTS/ (6 SHP files) - Game Fonts
| File | Description |
|------|-------------|
| CONVFONT.SHP | Conversation text font |
| DEMOFONT.SHP | Demo/title screen font |
| MSSGFONT.SHP | In-flight message font |
| OPTFONT.SHP | Options menu font |
| PCFONT.SHP | General PC font |
| PRIVFNT.SHP | Privateer-specific font |

### DATA/MIDGAMES/ (37 files) - Cutscenes/Transitions
Landing/takeoff animations and mid-game cinematics.

| File | Description |
|------|-------------|
| CUBICLE.IFF/.PAK | Quine 4000 computer terminal (IFF=MOVI script, PAK=device sprites + 320x200 backgrounds, palette=OPTPALS 28) |
| DEATHAPR.IFF | Death approach sequence |
| GFMIDGAM.IFF | Game flow midgame data |
| JUMP.IFF/.PAK | Jump sequence animation |
| LANDINGS.IFF/.PAK | Landing sequence |
| LTOBASES.PAK | Landing to bases transitions |
| MID*.PAK | Various midgame scene packs |

### DATA/MISSIONS/ (27 IFF files) - Mission Definitions
| File | Description |
|------|-------------|
| BFILMNGR.IFF | Mission file manager |
| PLOTMSNS.IFF | Plot mission master list (24 entries) |
| S0MA.IFF | Series 0 Mission A |
| S1MA-S1MD.IFF | Series 1 Missions A-D |
| S2MA-S2MD.IFF | Series 2 Missions A-D |
| S3MA-S3MD.IFF | Series 3 Missions A-D |
| S4MA-S4MD.IFF | Series 4 Missions A-D |
| S5MA-S5MD.IFF | Series 5 Missions A-D |
| S7MA-S7MB.IFF | Series 7 Missions A-B (finale) |
| SKELETON.IFF | Mission template/skeleton |

### DATA/MOUSE/ (1 SHP file)
- `PNT.SHP` - Mouse cursor sprites

### DATA/OPTIONS/ (39 files) - Game Configuration & Economy
| File | Description |
|------|-------------|
| APPRCOCK.IFF | Approach cockpit data |
| COMMSTUF.IFF | Commodity stuff |
| COMMTXT.IFF | Commodity text descriptions |
| COMODTYP.IFF | Commodity type definitions and pricing |
| COMPTEXT.IFF | Computer text |
| CU.IFF/.PAK | Character/upgrade data |
| EYES.IFF | Eye customization |
| FACES.IFF | Face customization |
| FILES.IFF | Master file reference index |
| GAMEFLOW.IFF | Game flow state machine |
| GAMELINK.IFF | Game link data |
| JOYCALIB.IFF/.PAL | Joystick calibration |
| LANDFEE.IFF | Landing fee data |
| LIMITS.IFF | Game limits/constraints |
| OPTPALS2.IFF | Option palette set 2 |
| OPTSHPS2.IFF | Option shapes set 2 |
| PLAYTYPE.IFF | Player type definition |
| PLAYSCOR.IFF | Play score tracking |
| PREFBUTT.IFF | Preference buttons |
| SHIPSTUF.IFF | Ship equipment data |
| SOFTTXT.IFF | Software text |
| SOFTWARE.IFF | Software upgrade definitions |

### DATA/PALETTE/ (3 PAL files) - Color Palettes
| File | Description |
|------|-------------|
| PCMAIN.PAL | Main game palette (256 colors) |
| PREFMAIN.PAL | Preferences menu palette |
| SPACE.PAL | Space flight palette |

### DATA/SECTORS/ (5 files) - Universe Structure
| File | Description |
|------|-------------|
| BASES.IFF | Base definitions and properties |
| QUADRANT.IFF | Quadrant layout (4 quadrants, systems within) |
| SECTORS.IFF | Sector definitions |
| TABLE.DAT | Navigation/connectivity lookup table |
| TEAMS.IFF | Faction/team definitions |

### DATA/SOUND/ (18 files) - Audio
| Type | Files | Description |
|------|-------|-------------|
| .ADL | 5 | AdLib music (BASETUNE, COMBAT, CREDITS, OPENING, VICTORY) |
| .GEN | 5 | General MIDI music (same tracks) |
| .DRV | 4 | Sound drivers (ADLIB, PAS, ROLAND, SB) |
| .DAT | 2 | Sound lookup tables (COMBAT, TABLE) |
| .AD | 1 | AdLib data |
| .MT | 1 | MT-32 data |

### DATA/SPEECH/ (17 VOC files) - Speech Audio
Uncompressed Creative Voice files for cutscene speech.
- `PC_1MG*.VOC` (8 files) - Player character midgame speech
- `PIR1MG*.VOC` (5 files) - Pirate midgame speech
- Additional speech clips

### DATA/TYPES/ (46 IFF files) - Game Object Type Definitions
Defines properties for every object type in the game.

| File | Description |
|------|-------------|
| Ship types | BRODTYPE, CENTTYPE, DEMNTYPE, DRALTYPE, GALXTYPE, GLADTYPE, GOTHTYPE, TARSTYPE, etc. |
| Weapon types | BEAMTYPE, TORPTYPE, WEAPONS |
| Object types | ASTRTYPE, BASETYPE, CDBRTYPE, CPODTYPE, DRONTYPE, EXPLTYPE, TRSHTYPE |
| Cargo | CARGO |
| TARGTYPE | Targeting type |
| TCHNTYPE | Technology type |

---

## ISO Contents (GAME.DAT)

Beyond PRIV.TRE, the ISO 9660 image contains:

| File | Size | Description |
|------|------|-------------|
| LICENSE.1 | 1,152 bytes | License file |
| LICENSE.ALL | 8,239 bytes | Full license text |
| PRIV.TRE | 89,486,108 bytes | Main game data archive |
| PSFONTS.CAT | 671,740 bytes | PostScript font catalog |
| PSFONTS.INF | 416 bytes | PostScript font info |
| X.LBM | 52,176 bytes | LBM image (IFF ILBM format) |
