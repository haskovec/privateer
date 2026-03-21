//! Movie sprite renderer for Wing Commander: Privateer intro cinematic.
//!
//! Executes FORM:MOVI ACTS commands frame-by-frame, rendering sprites from
//! PAK resources onto a persistent 320x200 framebuffer. Supports delta/
//! incremental compositing (each frame updates, not full redraws) and CLRC
//! clearing between scenes.
//!
//! Data flow for a SPRI command:
//!   1. Look up file_references[file_ref] → normalized TRE path
//!   2. PAK resource at sprite_index → ScenePack → RLE sprite
//!   3. Blit sprite to framebuffer at (x, y)
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

/// Movie renderer that executes ACTS commands against a persistent framebuffer.
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

    /// Execute a single ACTS block, rendering all its commands to the framebuffer.
    /// Commands are applied incrementally on top of existing framebuffer content.
    pub fn executeActsBlock(self: *MovieRenderer, block: movie_mod.ActsBlock) MovieRendererError!void {
        // Process FILD commands (background/field sprites)
        for (block.field_commands) |cmd| {
            try self.renderFieldCommand(cmd);
        }
        // Process SPRI commands (positioned sprites)
        for (block.sprite_commands) |cmd| {
            try self.renderSpriteCommand(cmd);
        }
    }

    /// Render a FILD command: load sprite from PAK and blit at (x, y).
    fn renderFieldCommand(self: *MovieRenderer, cmd: movie_mod.FieldCommand) MovieRendererError!void {
        if (cmd.file_ref >= self.loaded_paks.len) return MovieRendererError.InvalidFileRef;
        const loaded = self.loaded_paks[cmd.file_ref] orelse return MovieRendererError.InvalidFileRef;

        var spr = self.decodeSpriteFromPak(loaded, cmd.sprite_index) catch return MovieRendererError.SpriteDecodeFailed;
        defer spr.deinit();

        self.fb.blitSprite(spr, @as(i32, cmd.x), @as(i32, cmd.y));
    }

    /// Render a SPRI command: load sprite from PAK and blit at signed (x, y).
    fn renderSpriteCommand(self: *MovieRenderer, cmd: movie_mod.SpriteCommand) MovieRendererError!void {
        if (cmd.file_ref >= self.loaded_paks.len) return MovieRendererError.InvalidFileRef;
        const loaded = self.loaded_paks[cmd.file_ref] orelse return MovieRendererError.InvalidFileRef;

        var spr = self.decodeSpriteFromPak(loaded, cmd.sprite_index) catch return MovieRendererError.SpriteDecodeFailed;
        defer spr.deinit();

        self.fb.blitSprite(spr, @as(i32, cmd.x), @as(i32, cmd.y));
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

test "MovieRenderer.executeActsBlock renders SPRI command to framebuffer" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // Create an ACTS block with a SPRI command pointing to resource 1 at (10, 10)
    const sprite_cmds = [_]movie_mod.SpriteCommand{
        .{
            .file_ref = 0,
            .sprite_index = 1, // Resource 1 = our 2x2 sprite
            .x = 10,
            .y = 10,
            .flags = 0,
        },
    };
    const block = movie_mod.ActsBlock{
        .field_commands = &.{},
        .sprite_commands = &sprite_cmds,
        .layer_orders = &.{},
    };

    try renderer.executeActsBlock(block);

    // The 2x2 sprite with color 5 should appear near (10, 10)
    // Sprite has x1=0, x2=1, y1=0, y2=1 → width=2, height=2
    // blitSprite at center (10, 10): top-left = (10-0, 10-0) = (10, 10)
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(11, 10));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(10, 11));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(11, 11));

    // Pixels outside the sprite should still be black
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(9, 9));
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(12, 12));
}

test "MovieRenderer delta compositing preserves prior frame content" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // Frame 1: sprite at (10, 10)
    const cmds1 = [_]movie_mod.SpriteCommand{
        .{ .file_ref = 0, .sprite_index = 1, .x = 10, .y = 10, .flags = 0 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &.{},
        .sprite_commands = &cmds1,
        .layer_orders = &.{},
    });

    // Frame 2: sprite at (20, 20) — should NOT erase the one at (10, 10)
    const cmds2 = [_]movie_mod.SpriteCommand{
        .{ .file_ref = 0, .sprite_index = 1, .x = 20, .y = 20, .flags = 0 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &.{},
        .sprite_commands = &cmds2,
        .layer_orders = &.{},
    });

    // Both sprites should be visible (delta compositing)
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(10, 10));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(20, 20));
}

test "MovieRenderer CLRC clears between scenes" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // Render a sprite
    const cmds = [_]movie_mod.SpriteCommand{
        .{ .file_ref = 0, .sprite_index = 1, .x = 10, .y = 10, .flags = 0 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &.{},
        .sprite_commands = &cmds,
        .layer_orders = &.{},
    });
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

    // Build a script with clear_screen=true and one ACTS block
    const sprite_cmds = [_]movie_mod.SpriteCommand{
        .{ .file_ref = 0, .sprite_index = 1, .x = 50, .y = 50, .flags = 0 },
    };
    const acts_blocks = [_]movie_mod.ActsBlock{
        .{
            .field_commands = &.{},
            .sprite_commands = &sprite_cmds,
            .layer_orders = &.{},
        },
    };
    // We construct a MovieScript-like structure for executeScript
    const script = movie_mod.MovieScript{
        .clear_screen = true,
        .frame_speed_ticks = 10,
        .file_references = &.{},
        .acts_blocks = &acts_blocks,
        .allocator = allocator,
    };

    try renderer.executeScript(script);

    // Pre-fill should be cleared (CLRC), then sprite drawn
    try std.testing.expectEqual(@as(u8, 0), fb.getPixel(0, 0)); // was 42, now cleared
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(50, 50)); // sprite drawn
}

test "MovieRenderer.executeActsBlock renders FILD command" {
    const allocator = std.testing.allocator;
    var fb = framebuffer_mod.Framebuffer.create();

    var renderer = try MovieRenderer.init(allocator, &fb, 1);
    defer renderer.deinit();

    const pak_data = try makeTestMoviePak(allocator);
    defer allocator.free(pak_data);

    try renderer.loadPak(0, pak_data);

    // FILD command: file_ref=0, sprite_index=1, x=30, y=40
    const fild_cmds = [_]movie_mod.FieldCommand{
        .{ .file_ref = 0, .sprite_index = 1, .x = 30, .y = 40, .flags = 0 },
    };
    try renderer.executeActsBlock(.{
        .field_commands = &fild_cmds,
        .sprite_commands = &.{},
        .layer_orders = &.{},
    });

    // Sprite should appear at (30, 40)
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(30, 40));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(31, 40));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(30, 41));
    try std.testing.expectEqual(@as(u8, 5), fb.getPixel(31, 41));
}
