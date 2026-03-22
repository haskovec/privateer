//! Movie sprite renderer for Wing Commander: Privateer intro cinematic.
//!
//! Uses a scene-graph composition model driven by BFOR commands:
//!   1. FILD commands define background sprite objects (keyed by object_id)
//!   2. SPRI commands define sprite overlay objects (keyed by object_id)
//!   3. BFOR commands drive rendering order by referencing object_ids
//!
//! BFOR records with flags=0x7FFF are layer/clip commands that define
//! viewport regions (params[0..3] = x1, y1, x2, y2). Records with
//! flags != 0x7FFF reference a FILD/SPRI object_id for rendering.
//!
//! When no BFOR commands are present (some ACTS blocks), falls back to
//! direct FILD rendering for backward compatibility.
//!
//! Resource 0 of each MID*.PAK is a 772-byte palette.
//! Resources 1+ are ScenePack sprite containers.

const std = @import("std");
const movie_mod = @import("movie.zig");
const pak_mod = @import("../formats/pak.zig");
const pal_mod = @import("../formats/pal.zig");
const scene_renderer = @import("../render/scene_renderer.zig");
const sprite_mod = @import("../formats/sprite.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");
const text_mod = @import("../render/text.zig");

pub const MovieRendererError = error{
    /// A file reference index in a command is out of range.
    InvalidFileRef,
    /// The PAK resource for a sprite command could not be loaded.
    InvalidSpriteResource,
    /// The PAK file has no palette resource (resource 0).
    NoPalette,
    /// Failed to decode a sprite from PAK data.
    SpriteDecodeFailed,
    OutOfMemory,
};

/// A loaded PAK file with its parsed palette and sprite packs.
pub const LoadedPak = struct {
    pak: pak_mod.PakFile,
    palette: ?pal_mod.Palette,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LoadedPak) void {
        self.pak.deinit();
    }
};

/// A loaded file slot — either a PAK (sprite container) or a Font (SHP glyphs).
/// FILE chunk references can point to different file types; this union lets the
/// renderer handle them polymorphically.
pub const LoadedFile = union(enum) {
    pak: LoadedPak,
    font: text_mod.Font,

    pub fn deinit(self: *LoadedFile) void {
        switch (self.*) {
            .pak => |*p| p.deinit(),
            .font => |*f| f.deinit(),
        }
    }
};

/// Movie renderer that executes ACTS commands against a persistent framebuffer.
///
/// Uses a scene-graph composition model: FILD/SPRI commands define objects,
/// BFOR commands drive rendering order by referencing object_ids. When no
/// BFOR commands are present, falls back to direct FILD rendering.
///
/// The renderer maintains references to loaded PAK files (indexed by file_ref)
/// and composites sprites incrementally — each ACTS block adds to the existing
/// framebuffer content rather than clearing it. Use `clearScreen()` (triggered
/// by CLRC) to reset between scenes.
pub const MovieRenderer = struct {
    /// Loaded files indexed by file_ref from the MOVI script.
    /// Each slot is either a PAK (sprite container) or a Font (SHP glyphs).
    loaded_files: []?LoadedFile,
    /// The persistent framebuffer (delta compositing).
    fb: *framebuffer_mod.Framebuffer,
    /// Current palette (from the first loaded PAK with a palette).
    current_palette: ?pal_mod.Palette,
    /// FILE slot containing the text PAK (MIDTEXT.PAK), or null if not loaded.
    text_pak_slot: ?usize,
    allocator: std.mem.Allocator,

    /// Initialize a MovieRenderer for a MOVI script with the given number of
    /// file references. The caller provides a framebuffer that persists across
    /// frames for delta compositing.
    pub fn init(allocator: std.mem.Allocator, fb: *framebuffer_mod.Framebuffer, num_file_refs: usize) MovieRendererError!MovieRenderer {
        const files = allocator.alloc(?LoadedFile, num_file_refs) catch return MovieRendererError.OutOfMemory;
        @memset(files, null);
        return .{
            .loaded_files = files,
            .fb = fb,
            .current_palette = null,
            .text_pak_slot = null,
            .allocator = allocator,
        };
    }

    /// Release all loaded files and internal allocations.
    pub fn deinit(self: *MovieRenderer) void {
        for (self.loaded_files) |*slot| {
            if (slot.*) |*loaded| {
                loaded.deinit();
            }
        }
        self.allocator.free(self.loaded_files);
    }

    /// Load a PAK file for the given file reference index.
    /// Resource 0 is treated as a palette if it is exactly 772 bytes.
    pub fn loadPak(self: *MovieRenderer, file_ref: usize, pak_data: []const u8) MovieRendererError!void {
        if (file_ref >= self.loaded_files.len) return MovieRendererError.InvalidFileRef;

        var pak_file = pak_mod.parse(self.allocator, pak_data) catch return MovieRendererError.InvalidSpriteResource;
        errdefer pak_file.deinit();

        // Try to extract palette from resource 0
        var palette: ?pal_mod.Palette = null;
        if (pak_file.resourceCount() > 0) {
            if (pak_file.getResource(0)) |res0| {
                if (res0.len == pal_mod.PAL_FILE_SIZE) {
                    palette = pal_mod.parse(res0) catch null;
                }
            } else |_| {}
        }

        // Set as current palette if we found one and don't have one yet
        if (palette != null and self.current_palette == null) {
            self.current_palette = palette;
        }

        self.loaded_files[file_ref] = .{ .pak = .{
            .pak = pak_file,
            .palette = palette,
            .allocator = self.allocator,
        } };
    }

    /// Load a SHP font file for the given file reference index.
    /// Used for DEMOFONT.SHP and CONVFONT.SHP referenced by MOVI FILE chunks.
    pub fn loadFont(self: *MovieRenderer, file_ref: usize, shp_data: []const u8) MovieRendererError!void {
        if (file_ref >= self.loaded_files.len) return MovieRendererError.InvalidFileRef;

        // Movie fonts (DEMOFONT.SHP, CONVFONT.SHP) use first_char=0:
        // glyph indices map directly to ASCII codes (index 50='2', 65='A', etc.)
        var font = text_mod.Font.load(self.allocator, shp_data, 0) catch return MovieRendererError.InvalidSpriteResource;
        errdefer font.deinit();

        self.loaded_files[file_ref] = .{ .font = font };
    }

    /// Render text overlays for the current ACTS block.
    /// Called every frame (not just once) so text persists on screen.
    pub fn renderTextOverlays(self: *MovieRenderer, block: movie_mod.ActsBlock) void {
        for (block.sprite_commands) |spri| {
            if (spri.sprite_type == 12) {
                self.renderTextSprite(spri, block.field_commands);
            }
        }
    }

    /// Clear the framebuffer (triggered by CLRC command).
    pub fn clearScreen(self: *MovieRenderer) void {
        self.fb.clear(0);
    }

    /// Execute a single ACTS block using the scene-graph composition model.
    ///
    /// If BFOR commands are present: builds an object table from FILD+SPRI
    /// definitions, then processes BFOR records in order to composite the frame.
    /// BFOR records with flags=0x7FFF are layer/clip commands; others reference
    /// objects by their object_id (stored in the flags field).
    ///
    /// If no BFOR commands: falls back to direct FILD rendering (legacy mode
    /// for ACTS blocks that only contain definitions for later frames).
    pub fn executeActsBlock(self: *MovieRenderer, block: movie_mod.ActsBlock) MovieRendererError!void {
        if (block.composition_cmds.len > 0) {
            // BFOR-driven composition: build object table, then render via BFOR
            self.executeComposition(block) catch {};
        } else {
            // No BFOR: fall back to rendering FILD commands directly
            for (block.field_commands) |cmd| {
                self.renderFieldSprite(cmd.file_ref, cmd.param3 + 1, 0, 0, cmd.param1 == 2) catch {};
            }
        }
    }

    /// Build an object table from FILD+SPRI definitions and render via BFOR.
    /// After BFOR-referenced rendering, also render text overlays (type 12)
    /// that are not in the BFOR chain — text is additive and safe to overlay.
    /// Type 4/19/20 self-ref sprites are animation keyframes that require
    /// interpolation, so they are only rendered when directly referenced by BFOR.
    fn executeComposition(self: *MovieRenderer, block: movie_mod.ActsBlock) MovieRendererError!void {
        // Track which SPRI objects are rendered via BFOR (by index in sprite_commands)
        var rendered_via_bfor: [256]bool = [_]bool{false} ** 256;

        // Process BFOR commands in order
        for (block.composition_cmds) |bfor| {
            if (bfor.isLayerCommand()) {
                // Layer/clip command — currently a no-op (clip regions deferred)
                continue;
            }

            // flags field references an object_id from FILD or SPRI
            const ref_id = bfor.flags;

            // Look up in FILD table first
            if (findFild(block.field_commands, ref_id)) |fild| {
                self.renderFieldSprite(fild.file_ref, fild.param3 + 1, 0, 0, fild.param1 == 2) catch {};
                continue;
            }

            // Look up in SPRI table
            if (findSpriIndex(block.sprite_commands, ref_id)) |idx| {
                if (idx < 256) rendered_via_bfor[idx] = true;
                self.renderSpriteObject(block.sprite_commands[idx], block.field_commands) catch {};
                continue;
            }

            // Object not found — skip silently (may be audio/control object)
        }

        // Render unreferenced SPRI objects:
        // Type 0/1/3/11 positioned sprites with FILD reference
        for (block.sprite_commands, 0..) |spri, i| {
            if (i < 256 and rendered_via_bfor[i]) continue;
            switch (spri.sprite_type) {
                0, 1, 3, 11 => {
                    if (spri.ref != movie_mod.SpriteCommand.SELF_REF) {
                        self.renderSpriteObject(spri, block.field_commands) catch {};
                    }
                },
                else => {},
            }
        }

        // Render text overlays LAST
        for (block.sprite_commands) |spri| {
            if (spri.sprite_type == 12) {
                self.renderTextSprite(spri, block.field_commands);
            }
        }
    }

    /// Render a SPRI object. For types with a FILD reference, looks up the
    /// referenced FILD to get the PAK file/resource, then blits at the
    /// position specified by SPRI params.
    fn renderSpriteObject(self: *MovieRenderer, spri: movie_mod.SpriteCommand, fild_table: []const movie_mod.FieldCommand) MovieRendererError!void {
        switch (spri.sprite_type) {
            // Type 0, 1: simple positioned sprite — params[0]=x, params[1]=y
            0, 1 => {
                if (spri.ref != movie_mod.SpriteCommand.SELF_REF) {
                    // References a FILD object — get PAK file/resource from it
                    if (findFild(fild_table, spri.ref)) |fild| {
                        const x: i32 = @as(i32, @as(i16, @bitCast(spri.params[0])));
                        const y: i32 = @as(i32, @as(i16, @bitCast(spri.params[1])));
                        self.renderFieldSprite(fild.file_ref, fild.param3 + 1, x, y, false) catch {};
                    }
                }
            },

            // Type 3, 11: extended positioned sprite — treat like type 0/1
            3, 11 => {
                if (spri.ref != movie_mod.SpriteCommand.SELF_REF) {
                    if (findFild(fild_table, spri.ref)) |fild| {
                        const x: i32 = @as(i32, @as(i16, @bitCast(spri.params[0])));
                        const y: i32 = @as(i32, @as(i16, @bitCast(spri.params[1])));
                        self.renderFieldSprite(fild.file_ref, fild.param3 + 1, x, y, false) catch {};
                    }
                }
            },

            // Type 4, 19, 20: animated sprite sequence
            // Only render when directly referenced (non-self-ref has a FILD target).
            // Self-ref type 4 sprites are animation keyframes that need interpolation;
            // rendering them statically at the wrong position destroys the scene.
            4, 19, 20 => {
                if (spri.ref != movie_mod.SpriteCommand.SELF_REF) {
                    if (findFild(fild_table, spri.ref)) |fild| {
                        const x: i32 = @as(i32, @as(i16, @bitCast(spri.params[0])));
                        const y: i32 = if (spri.param_count >= 3) @as(i32, @as(i16, @bitCast(spri.params[2]))) else 0;
                        self.renderFieldSprite(fild.file_ref, fild.param3 + 1, x, y, false) catch {};
                    }
                }
            },

            // Type 12: text rendering — params[3]=text FILD ref, params[4]=font FILD ref, params[5]=color
            12 => {
                self.renderTextSprite(spri, fild_table);
            },

            // Type 18: extended animation — treat like type 4 (non-self-ref only)
            18 => {
                if (spri.ref != movie_mod.SpriteCommand.SELF_REF) {
                    if (findFild(fild_table, spri.ref)) |fild| {
                        const x: i32 = @as(i32, @as(i16, @bitCast(spri.params[0])));
                        const y: i32 = 0;
                        self.renderFieldSprite(fild.file_ref, fild.param3 + 1, x, y, false) catch {};
                    }
                }
            },

            else => {},
        }
    }

    /// Render a type 12 text sprite.
    ///
    /// Text string index is computed as: params[3] - font_fild.param3
    /// This indexes into MIDTEXT.PAK (the text PAK at text_pak_slot).
    /// The font is looked up via params[4] → FILD object_id → LoadedFile.font.
    fn renderTextSprite(self: *MovieRenderer, spri: movie_mod.SpriteCommand, fild_table: []const movie_mod.FieldCommand) void {
        if (spri.param_count < 6) return;

        const font_fild_id = spri.params[4];
        const color: u8 = @truncate(spri.params[5]);
        const y_param: i16 = @bitCast(spri.params[1]);

        // Look up font FILD → must point to a LoadedFile.font slot
        const font_fild = findFild(fild_table, font_fild_id) orelse return;
        if (font_fild.file_ref >= self.loaded_files.len) return;
        const font_file = self.loaded_files[font_fild.file_ref] orelse return;
        const font = switch (font_file) {
            .font => |*f| f,
            .pak => return,
        };

        // Compute text string index: params[3] - font_fild.param3
        const text_idx_raw = @as(i32, spri.params[3]) - @as(i32, font_fild.param3);
        if (text_idx_raw < 0) return;
        const text_idx: usize = @intCast(text_idx_raw);

        // Get text PAK (MIDTEXT.PAK)
        const pak_slot = self.text_pak_slot orelse return;
        if (pak_slot >= self.loaded_files.len) return;
        const text_file = self.loaded_files[pak_slot] orelse return;
        const text_pak = switch (text_file) {
            .pak => |p| p,
            .font => return,
        };

        // Extract text string from PAK resource at the computed index
        const resource = text_pak.pak.getResource(text_idx) catch return;
        var str_end: usize = resource.len;
        for (resource, 0..) |byte, i| {
            if (byte == 0) {
                str_end = i;
                break;
            }
        }
        if (str_end == 0) return;
        const text = resource[0..str_end];

        // Compute Y position — y_param is offset from bottom of screen
        const screen_height: u16 = 200;
        const render_y: u16 = if (y_param < 0)
            screen_height -| @as(u16, @intCast(-@as(i32, y_param)))
        else
            @min(@as(u16, @intCast(y_param)), 199);

        // Render text centered horizontally
        const text_width = font.measureText(text);
        const screen_width: u16 = 320;
        const x: u16 = if (text_width >= screen_width) 0 else (screen_width - text_width) / 2;
        _ = font.drawTextColored(self.fb, x, render_y, text, if (color == 0) null else color);
    }

    /// Render a sprite from a loaded PAK file at a given position.
    /// file_ref indexes into the loaded file table, resource_idx is the
    /// resource index within the PAK (ScenePack with RLE sprites).
    /// When opaque=true, all pixels are written (for backgrounds where
    /// index 0 means black, not transparent).
    fn renderFieldSprite(self: *MovieRenderer, file_ref: u16, resource_idx: u16, x: i32, y: i32, is_background: bool) MovieRendererError!void {
        if (file_ref >= self.loaded_files.len) return MovieRendererError.InvalidFileRef;
        const loaded_file = self.loaded_files[file_ref] orelse return MovieRendererError.InvalidFileRef;
        const loaded = switch (loaded_file) {
            .pak => |p| p,
            .font => return, // Fonts are not sprite PAKs — skip silently
        };

        var spr = self.decodeSpriteFromPak(loaded, resource_idx) catch return MovieRendererError.SpriteDecodeFailed;
        defer spr.deinit();

        if (is_background) {
            self.fb.blitSpriteOpaque(spr, x, y);
        } else {
            self.fb.blitSprite(spr, x, y);
        }
    }

    /// Find a FILD command by object_id in the field commands array.
    fn findFild(fild_table: []const movie_mod.FieldCommand, object_id: u16) ?movie_mod.FieldCommand {
        for (fild_table) |cmd| {
            if (cmd.object_id == object_id) return cmd;
        }
        return null;
    }

    /// Find a SPRI command by object_id in the sprite commands array.
    fn findSpri(spri_table: []const movie_mod.SpriteCommand, object_id: u16) ?movie_mod.SpriteCommand {
        for (spri_table) |cmd| {
            if (cmd.object_id == object_id) return cmd;
        }
        return null;
    }

    /// Find the index of a SPRI command by object_id.
    fn findSpriIndex(spri_table: []const movie_mod.SpriteCommand, object_id: u16) ?usize {
        for (spri_table, 0..) |cmd, i| {
            if (cmd.object_id == object_id) return i;
        }
        return null;
    }

    /// Decode a sprite from a loaded PAK file.
    /// The sprite_index maps to a PAK resource which is a ScenePack containing
    /// one or more RLE sprites. We decode the first sprite in the pack.
    fn decodeSpriteFromPak(self: *MovieRenderer, loaded: LoadedPak, sprite_index: u16) !sprite_mod.Sprite {
        const resource = loaded.pak.getResource(sprite_index) catch return MovieRendererError.InvalidSpriteResource;

        // Parse as a scene pack (offset table + RLE sprites)
        var pack = scene_renderer.parseScenePack(self.allocator, resource) catch return MovieRendererError.SpriteDecodeFailed;
        defer pack.deinit();

        if (pack.spriteCount() == 0) return MovieRendererError.SpriteDecodeFailed;

        return pack.decodeSprite(self.allocator, 0) catch return MovieRendererError.SpriteDecodeFailed;
    }

    /// Get the current palette (from the first loaded PAK with a palette).
    pub fn getPalette(self: *const MovieRenderer) ?pal_mod.Palette {
        return self.current_palette;
    }

    /// Execute an entire movie script: optionally clear screen, then process
    /// all ACTS blocks in sequence.
    pub fn executeScript(self: *MovieRenderer, script: movie_mod.MovieScript) MovieRendererError!void {
        if (script.clear_screen) {
            self.clearScreen();
        }
        for (script.acts_blocks) |block| {
            try self.executeActsBlock(block);
        }
    }
};

// --- Tests ---

const testing_helpers = @import("../testing.zig");

/// Build a minimal PAK file with a palette and one scene pack resource.
/// Returns a buffer containing a valid PAK structure.
fn makeTestMoviePak(allocator: std.mem.Allocator) ![]u8 {
    // Resource 0: 772-byte palette (4-byte header + 768 bytes RGB)
    var pal_data: [pal_mod.PAL_FILE_SIZE]u8 = undefined;
    @memset(&pal_data, 0);
    // Set color 5 = red (VGA6: 63, 0, 0)
    pal_data[4 + 5 * 3 + 0] = 63;
    pal_data[4 + 5 * 3 + 1] = 0;
    pal_data[4 + 5 * 3 + 2] = 0;

    // Resource 1: ScenePack with a single 2x2 sprite
    const sprite_resource = [_]u8{
        // [0..4] declared size
        0x22, 0x00, 0x00, 0x00,
        // [4..8] first offset = 8
        0x08, 0x00, 0x00, 0x00,
        // [8..16] sprite header: x2=1, x1=0, y1=0, y2=1 (2x2)
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
        // Row 0: even key=4 (2 pixels), x=0, y=0, colors=[5, 5]
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x05,
        // Row 1: even key=4 (2 pixels), x=0, y=1, colors=[5, 5]
        0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x05, 0x05,
        // Terminator
        0x00, 0x00,
    };

    // Build PAK: [file_size:4][offset0:4][offset1:4][terminator:4][palette:772][sprite_resource]
    const header_size: u32 = 4 + 4 + 4 + 4; // file_size + 2 entries + terminator
    const total_size: u32 = header_size + pal_mod.PAL_FILE_SIZE + sprite_resource.len;

    var buf = try allocator.alloc(u8, total_size);

    // File size
    std.mem.writeInt(u32, buf[0..4], total_size, .little);

    // Entry 0: palette at offset header_size, marker 0xE0
    const pal_offset: u32 = header_size;
    buf[4] = @intCast(pal_offset & 0xFF);
    buf[5] = @intCast((pal_offset >> 8) & 0xFF);
    buf[6] = @intCast((pal_offset >> 16) & 0xFF);
    buf[7] = 0xE0;

    // Entry 1: sprite at offset header_size + 772, marker 0xE0
    const spr_offset: u32 = header_size + pal_mod.PAL_FILE_SIZE;
    buf[8] = @intCast(spr_offset & 0xFF);
    buf[9] = @intCast((spr_offset >> 8) & 0xFF);
    buf[10] = @intCast((spr_offset >> 16) & 0xFF);
    buf[11] = 0xE0;

    // Terminator
    buf[12] = 0;
    buf[13] = 0;
    buf[14] = 0;
    buf[15] = 0;

    // Palette data
    @memcpy(buf[header_size .. header_size + pal_mod.PAL_FILE_SIZE], &pal_data);

    // Sprite resource data
    @memcpy(buf[spr_offset..total_size], &sprite_resource);

    return buf;
}

test "MovieRenderer.init creates renderer with correct number of slots" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 3);
    defer renderer.deinit();

    try std.testing.expectEqual(@as(usize, 3), renderer.loaded_files.len);
    try std.testing.expect(renderer.current_palette == null);
}

test "MovieRenderer.loadPak extracts palette from resource 0" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // Should have extracted the palette
    const palette = renderer.getPalette();
    try std.testing.expect(palette != null);

    // Color 5 should be red (VGA6 63 → 8-bit: (63<<2)|(63>>4) = 255)
    try std.testing.expectEqual(@as(u8, 255), palette.?.colors[5].r);
    try std.testing.expectEqual(@as(u8, 0), palette.?.colors[5].g);
    try std.testing.expectEqual(@as(u8, 0), palette.?.colors[5].b);
}

test "MovieRenderer.loadPak rejects invalid file_ref" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try std.testing.expectError(MovieRendererError.InvalidFileRef, renderer.loadPak(5, pak_data));
}

test "MovieRenderer.clearScreen resets framebuffer to black" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(42); // Pre-fill with non-black

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    renderer.clearScreen();

    // All pixels should be 0
    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
}

test "MovieRenderer BFOR-driven composition renders referenced FILD object" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // FILD object 23 loads sprite from PAK resource 1 (2x2 red sprite)
    const fild_cmds = [_]movie_mod.FieldCommand{
        .{ .object_id = 23, .file_ref = 0, .param1 = 1, .param2 = 0, .param3 = 0 },
    };
    // BFOR: layer command (0x7FFF), then render object 23
    const bfor_cmds = [_]movie_mod.BforRecord{
        .{ .object_id = 7, .flags = movie_mod.BforRecord.LAYER_FLAG, .params = [_]u16{0} ** 10 },
        .{ .object_id = 9, .flags = 23, .params = [_]u16{0} ** 10 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &fild_cmds,
        .sprite_commands = &.{},
        .composition_cmds = &bfor_cmds,
    });

    // BFOR record with flags=23 should render FILD object 23's sprite at origin
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(1, 0));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 1));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(1, 1));
}

test "MovieRenderer BFOR skips unreferenced FILD objects" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // FILD object 23 has sprite data, but BFOR only has a layer command (no object refs)
    const fild_cmds = [_]movie_mod.FieldCommand{
        .{ .object_id = 23, .file_ref = 0, .param1 = 1, .param2 = 0, .param3 = 0 },
    };
    const bfor_cmds = [_]movie_mod.BforRecord{
        .{ .object_id = 7, .flags = movie_mod.BforRecord.LAYER_FLAG, .params = [_]u16{0} ** 10 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &fild_cmds,
        .sprite_commands = &.{},
        .composition_cmds = &bfor_cmds,
    });

    // BFOR has no object references, so nothing should be rendered
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(0, 0));
}

test "MovieRenderer BFOR renders SPRI type 0 at position from FILD ref" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 2);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // FILD object 25 loads from PAK resource 1 (2x2 red sprite)
    const fild_cmds = [_]movie_mod.FieldCommand{
        .{ .object_id = 25, .file_ref = 0, .param1 = 1, .param2 = 0, .param3 = 0 },
    };
    // SPRI object 39 references FILD 25, type 0, positioned at (10, 20)
    const spri_cmds = [_]movie_mod.SpriteCommand{
        .{
            .object_id = 39,
            .ref = 25,
            .sprite_type = 0,
            .params = [_]u16{ 10, 20, 0, 0, 0, 0, 0, 0, 0 },
            .param_count = 3,
        },
    };
    // BFOR references SPRI object 39
    const bfor_cmds = [_]movie_mod.BforRecord{
        .{ .object_id = 11, .flags = 39, .params = [_]u16{0} ** 10 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &fild_cmds,
        .sprite_commands = &spri_cmds,
        .composition_cmds = &bfor_cmds,
    });

    // SPRI type 0 renders FILD 25's sprite at (10, 20)
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(10, 20));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(11, 20));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(10, 21));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(11, 21));
    // Origin should still be black (sprite is at 10,20 not 0,0)
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(0, 0));
}

test "MovieRenderer delta compositing preserves prior frame content" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // Frame 1: FILD renders 2x2 sprite at origin (no BFOR = direct FILD mode)
    const fild1 = [_]movie_mod.FieldCommand{
        .{ .object_id = 1, .file_ref = 0, .param1 = 1, .param2 = 0, .param3 = 0 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &fild1,
        .sprite_commands = &.{},
        .composition_cmds = &.{},
    });

    // Verify frame 1 rendered
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 0));

    // Frame 2: empty block should NOT erase frame 1 content
    try renderer.executeActsBlock(.{
        .field_commands = &.{},
        .sprite_commands = &.{},
        .composition_cmds = &.{},
    });

    // Prior frame content should be preserved (delta compositing)
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 0));
}

test "MovieRenderer CLRC clears between scenes" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    // Fill pixel manually to test CLRC
    fb.setPixel(10, 10, 5);
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(10, 10));

    // CLRC clears the framebuffer
    renderer.clearScreen();
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(10, 10));
}

test "MovieRenderer.executeScript processes clear_screen flag and ACTS blocks" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(42); // Pre-fill

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // Build a script with clear_screen=true and one ACTS block using BFOR
    const fild_cmds = [_]movie_mod.FieldCommand{
        .{ .object_id = 23, .file_ref = 0, .param1 = 1, .param2 = 0, .param3 = 0 },
    };
    const bfor_cmds = [_]movie_mod.BforRecord{
        .{ .object_id = 9, .flags = 23, .params = [_]u16{0} ** 10 },
    };
    const acts_blocks = [_]movie_mod.ActsBlock{
        .{
            .field_commands = &fild_cmds,
            .sprite_commands = &.{},
            .composition_cmds = &bfor_cmds,
        },
    };
    const script = movie_mod.MovieScript{
        .clear_screen = true,
        .frame_speed_ticks = 10,
        .file_references = &.{},
        .acts_blocks = &acts_blocks,
        .allocator = allocator,
    };

    try renderer.executeScript(script);

    // Pre-fill at (5,5) should be cleared (CLRC), sprite renders at (0,0)
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(5, 5)); // was 42, now cleared
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 0)); // sprite rendered via BFOR
}

test "MovieRenderer.executeActsBlock renders FILD command" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // FILD command: object_id=1, file_ref=0, param1=1 (sprite index), param2=0, param3=0
    const fild_cmds = [_]movie_mod.FieldCommand{
        .{ .object_id = 1, .file_ref = 0, .param1 = 1, .param2 = 0, .param3 = 0 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &fild_cmds,
        .sprite_commands = &.{},
        .composition_cmds = &.{},
    });

    // FILD blits at origin (0, 0) — sprite has 2x2 pixels
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(1, 0));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(0, 1));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(1, 1));
}
