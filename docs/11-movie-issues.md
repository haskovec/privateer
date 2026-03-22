# Movie System Issues & Findings

Status: Work in progress. Movie playback disabled by default (use `--movie` flag).

## What Works

- **Planet scene renders correctly** — MID1A shows the planet and starfield background
- **Cockpit scenes render** — MID1B shows cockpit interior with instruments (3 ACTS frames)
- **Combat scenes render** — MID1D shows 9 frames of ships, explosions, asteroid fields
- **Scene transitions work** — Opaque backgrounds properly overwrite previous scene content
- **Music plays** — OPENING.GEN XMIDI decoded to PCM, plays throughout intro
- **Voice clips play** — Per-scene VOC file references load correct pirate/player clips
- **SFX plays** — SOUNDFX.PAK samples trigger during multi-ACTS combat scenes
- **Render-once optimization** — Each ACTS block renders once, not 60 times/sec
- **Font loading** — DEMOFONT.SHP loads with first_char=0 (glyph index = ASCII code)

## What Doesn't Work

### Text overlays not visible (CRITICAL)
The intro text ("2669, GEMINI SECTOR, TROY SYSTEM..." etc.) never appears on screen.

**What we know:**
- The renderTextSprite function executes (confirmed by debug prints)
- Font glyphs ARE loaded with valid dimensions (9x12 for uppercase, 8x12 for some)
- Glyph pixel data has non-zero values (62/108 for '2', first row: 0,0,155,155,155,155,155,0,0)
- The text string index formula works: `params[3] - font_fild.param3` correctly maps to MIDTEXT.PAK entries
- drawTextColored returns a valid width (37px for "TEST", 251px for full text)
- Framebuffer readback confirms pixels ARE written (getPixel returns 15 after setPixel)
- Color 255 (magenta) IS visible when drawn as a large solid rectangle

**What we DON'T know:**
- Why pixels written via drawTextColored or manual glyph iteration are invisible on screen,
  while pixels written via standalone setPixel loops in the same function are visible
- The type 0 overlay sprites seem to overwrite text drawn during the fallback loop. Moving
  text to after the loop didn't help. Re-rendering text every frame also didn't help.
- There may be a subtle issue with how the framebuffer is presented to SDL after text drawing,
  or with the palette conversion timing relative to text rendering

**Theories to investigate:**
1. The applyPalette conversion may run BEFORE text is drawn in the per-frame update cycle
2. The type 0 overlay sprites may re-render and overwrite text on subsequent frames
3. There may be a framebuffer double-buffering issue where text writes to a buffer that
   isn't the one being displayed
4. The font glyph pixel data may be corrupted or zeroed between the debug check and the
   actual blitGlyph call (pointer aliasing or stack corruption)

### Cockpit sprite details
- The shield display in the cockpit should change between ACTS blocks in MID1B, but this
  transition may not be visible to the user due to timing
- The character portrait video screen (mid1e scenes) has complex FILD structures that
  aren't fully decoded

### Animation keyframes not implemented
- SPRI type 4 (self-ref, 9 params) defines scrolling star field animations
- These are animation keyframes that need interpolation over time within a single ACTS block
- Currently skipped entirely (rendering them statically destroys the scene)
- In the original game, MID1A's single ACTS block animates over 7.3 seconds with scrolling
  stars and sequential text appearance

### Voice timing incomplete
- Each scene plays only the first VOC clip from its FILE slots
- Scenes with multiple VOC references (e.g., MID1C1 has 3 pirate clips) only play one
- The timing between voice clips and scene transitions needs work

## Key Technical Findings

### FILD param1 is NOT a resource index
`param1` is a type indicator: 2=background (opaque blit), 3=overlay (transparent blit).
The actual PAK sprite resource index is `param3 + 1` (offset to skip palette at resource 0).
This was the root cause of all scenes rendering the same starfield sprite.

### FILE slots are polymorphic
Detected by extension: `.PAK` → sprite container, `.SHP` → font, `.VOC` → voice clip,
no extension → skip. VOC slots specify per-scene voice clips embedded in each MOVI file's
FILE chunk.

### DEMOFONT.SHP uses first_char=0
Glyph indices map directly to ASCII codes (index 50='2', 65='A', 44=','). The main game
uses first_char=32 for the same font file, but the movie font reference uses first_char=0.

### Text string index formula
For SPRI type 12: `text_index = params[3] - font_fild.param3`. This indexes into MIDTEXT.PAK.
Verified: MID1A params[3]=31, font p3=31, gives index 0 = "2669, GEMINI SECTOR, TROY SYSTEM..."

### BFOR composition model
- `obj=9` renders the background FILD (flags = FILD object_id)
- `obj=14` renders overlay SPRIs (flags = SPRI object_id, params[0] = base SPRI)
- `obj=6` renders foreground SPRI
- `obj=42` LAYER entries are control/timing commands (not visual)
- LAYER entries with params like [0,25,319,152] define viewport clip regions

### Scene architecture
- MID1A (1 ACTS): Planet + text overlays, SPED=512 (~7.3s)
- MID1B (3 ACTS): Ship approach → cockpit interior (3 animation frames)
- MID1C1-C4 (EMPTY ACTS): Dialogue scenes — no sprites, just voice clips over persistent frame
- MID1D (9 ACTS): Combat sequence — ships, explosions (9 animation frames)
- MID1E1-E4 (1 ACTS): Post-combat dialogue with portraits + text
- MID1F (3 ACTS): Victory/finale sequence

### Opaque vs transparent blit
Background sprites (param1=2) must use opaque blit (blitSpriteOpaque) — palette index 0
is black, not transparent. Overlay sprites (param1=3) use transparent blit. Without this,
cockpit pixels bleed through combat backgrounds.

## Tools
- `tools/dump_movi.py` — Dumps complete MOVI scene graph data for all 12 intro files
- `tools/spri_verify.py` — Verifies SPRI record parsing across all MOVI files
- `tools/spri_deep.py` — Deep SPRI analysis with raw data dumps
