# Existing Community Work & Tools

## Open-Source Reimplementations

### Privateer Gemini Gold (via Vega Strike Engine)
- **Status:** Released (v1.03)
- **Technology:** C++, OpenGL, Python scripting
- **Approach:** Faithful gameplay recreation using the Vega Strike engine
- **Assets:** Recreated (not original) - new 3D models, textures, audio
- **Source:** https://github.com/DMJC/Privateer_Gold
- **Engine:** https://github.com/vegastrike/Vega-Strike-Engine-Source
- **Relevance:** Proves the game design works in a modern engine. However, it does
  not read original game data files. The Vega Strike engine itself (GPL3) provides
  a full space sim framework with BSP models, collision detection, dynamic lighting.

### Confederation Project
- **Status:** Work in progress
- **Technology:** C++, AngelScript
- **Approach:** Custom cross-platform engine that reads **original data files directly**
- **Key component:** `libOriginData` library for parsing WC data formats
- **Targets:** WC1/WC2 first, Privateer planned
- **Relevance:** Most directly relevant to our goal. Their libOriginData library
  demonstrates reading TRE, IFF, PAK, and sprite formats from the original game.

### Privateer: Wing Commander Universe (PWCU)
- **Status:** Active
- **Technology:** Vega Strike engine
- **Approach:** Extended mod adding WCU content beyond original Privateer
- **Source:** https://github.com/pwcu

## Modding Tools

### wctools (C++)
- **Purpose:** TRE extraction, PAK unpacking
- **Source:** https://github.com/DMJC/wctools
- **Tools:** `wctre` (TRE extractor), `unpak` (PAK unpacker)
- **Relevance:** Working code for reading the TRE and PAK formats

### Originator
- **Purpose:** Integrated data viewer/exporter for WC game assets
- **Status:** Released (v0.3.07c)
- **Relevance:** Can view and export sprites, palettes, and other assets

### WC Toolbox
- **Purpose:** Pack/unpack PAK, palette, shape, IFF files
- **Relevance:** Reference implementation for multiple format parsers

### wcmodtoolsources (Python/C/VB.NET)
- **Source:** https://github.com/delMar43/wcmodtoolsources
- **Purpose:** Legacy modding tools for WC1/WC2 formats
- **Relevance:** Some format overlap with Privateer

### HCl's Wing Commander Editing Site
- **URL:** https://hcl.solsector.net/
- **Author:** Mario "HCl" Brito (primary WC reverse engineer)
- **Resources:** Format documentation, P2 IFF extractor, Huffman decompressor,
  image readers, comprehensive technical articles
- **Relevance:** The most authoritative source of WC format documentation

### Privateer Save Editor (Python)
- **Source:** https://github.com/MestreLion/privateer
- **Purpose:** Read/modify Privateer saved games
- **Relevance:** Documents the save game format

## Key Community Resources

### Wing Commander CIC (Combat Information Center)
- **URL:** https://www.wcnews.com/
- **WCPedia:** https://www.wcnews.com/wcpedia/
- **Chat Zone:** Active forums with modding threads
- **Relevance:** Central hub for WC modding community knowledge

### Key Technical Documents
1. **wc1g.txt** by Fabien Sanglard - Comprehensive reverse engineering notes for
   WC1/Strike Commander formats (significant overlap with Privateer)
2. **Privateer File Formats** (WCPedia) - Community-documented file format specs
3. **HCl Information Page** - Detailed sprite/RLE compression documentation

## What We Can Leverage

1. **TRE Parser:** wctools provides working C++ code for TRE extraction
2. **IFF Parser:** Multiple implementations exist (Confederation's libOriginData,
   HCl's tools, wcmodtoolsources)
3. **RLE Decoder:** Documented algorithm with working C code from HCl and wc1g.txt
4. **PAK Unpacker:** wctools unpak utility
5. **VOC Player:** Standard format supported by most audio libraries
6. **MIDI Player:** XMIDI is well-documented; can convert to standard MIDI
7. **Game Logic:** Gemini Gold demonstrates the complete game loop in modern code
