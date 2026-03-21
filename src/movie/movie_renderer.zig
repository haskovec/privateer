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

/// An object in the scene graph — either a FILD (background sprite) or
/// a SPRI (sprite overlay), keyed by object_id.
const ObjectEntry = union(enum) {
    fild: movie_mod.FieldCommand,
    spri: movie_mod.SpriteCommand,
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
    /// Loaded PAK files indexed by file_ref from the MOVI script.
    loaded_paks: []?LoadedPak,
    /// The persistent framebuffer (delta compositing).
    fb: *framebuffer_mod.Framebuffer,
    /// Current palette (from the first loaded PAK with a palette).
    current_palette: ?pal_mod.Palette,
    allocator: std.mem.Allocator,

    /// Initialize a MovieRenderer for a MOVI script with the given number of
    /// file references. The caller provides a framebuffer that persists across
    /// frames for delta compositing.
    pub fn init(allocator: std.mem.Allocator, fb: *framebuffer_mod.Framebuffer, num_file_refs: usize) MovieRendererError!MovieRenderer {
        const paks = allocator.alloc(?LoadedPak, num_file_refs) catch return MovieRendererError.OutOfMemory;
        @memset(paks, null);
        return .{
            .loaded_paks = paks,
            .fb = fb,
            .current_palette = null,
            .allocator = allocator,
        };
    }

    /// Release all loaded PAK files and internal allocations.
    pub fn deinit(self: *MovieRenderer) void {
        for (self.loaded_paks) |*slot| {
            if (slot.*) |*loaded| {
                loaded.deinit();
            }
        }
        self.allocator.free(self.loaded_paks);
    }

    /// Load a PAK file for the given file reference index.
    /// Resource 0 is treated as a palette if it is exactly 772 bytes.
    pub fn loadPak(self: *MovieRenderer, file_ref: usize, pak_data: []const u8) MovieRendererError!void {
        if (file_ref >= self.loaded_paks.len) return MovieRendererError.InvalidFileRef;

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

        self.loaded_paks[file_ref] = .{
            .pak = pak_file,
            .palette = palette,
            .allocator = self.allocator,
        };
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
            try self.executeComposition(block);
        } else {
            // No BFOR: fall back to rendering FILD commands directly
            for (block.field_commands) |cmd| {
                self.renderFieldSprite(cmd.file_ref, cmd.param1, 0, 0) catch {};
            }
        }
    }

    /// Build an object table from FILD+SPRI definitions and render via BFOR.
    fn executeComposition(self: *MovieRenderer, block: movie_mod.ActsBlock) MovieRendererError!void {
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
                self.renderFieldSprite(fild.file_ref, fild.param1, 0, 0) catch {};
                continue;
            }

            // Look up in SPRI table
            if (findSpri(block.sprite_commands, ref_id)) |spri| {
                self.renderSpriteObject(spri, block.field_commands) catch {};
                continue;
            }

            // Object not found — skip silently (may be audio/control object)
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
                        self.renderFieldSprite(fild.file_ref, fild.param1, x, y) catch {};
                    }
                }
            },
            // Types 3, 4, 11, 12, 18, 19, 20: complex animation/text — deferred
            else => {},
        }
    }

    /// Render a sprite from a loaded PAK file at a given position.
    /// file_ref indexes into the loaded PAK table, resource_idx is the
    /// resource index within the PAK (ScenePack with RLE sprites).
    fn renderFieldSprite(self: *MovieRenderer, file_ref: u16, resource_idx: u16, x: i32, y: i32) MovieRendererError!void {
        if (file_ref >= self.loaded_paks.len) return MovieRendererError.InvalidFileRef;
        const loaded = self.loaded_paks[file_ref] orelse return MovieRendererError.InvalidFileRef;

        var spr = self.decodeSpriteFromPak(loaded, resource_idx) catch return MovieRendererError.SpriteDecodeFailed;
        defer spr.deinit();

        self.fb.blitSprite(spr, x, y);
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

    try std.testing.expectEqual(@as(usize, 3), renderer.loaded_paks.len);
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
