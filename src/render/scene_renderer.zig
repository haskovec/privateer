//! Scene renderer for Wing Commander: Privateer.
//! Renders landing screens by compositing RLE-encoded sprites from PAK resources
//! onto the framebuffer.
//!
//! PAK resource format for scene images:
//!   [0..4]:    Declared resource size (LE uint32)
//!   [4..N*4+4]: Offset table (LE uint32 entries) pointing to sprites
//!   [offsets..]: Sprite data at each offset (8-byte header + RLE pixel data)
//!
//! The first resource in a scene PAK is often a palette (772 bytes).
//! Subsequent resources contain one or more RLE-encoded sprites that cover
//! most of the 320x200 screen (typically 319x199).

const std = @import("std");
const framebuffer_mod = @import("framebuffer.zig");
const sprite_mod = @import("../formats/sprite.zig");
const pal = @import("../formats/pal.zig");

pub const Error = error{
    InvalidSize,
    InvalidFormat,
    IndexOutOfBounds,
    OffsetOutOfBounds,
    OutOfMemory,
};

/// A parsed scene pack resource from a PAK file.
/// Contains an offset table pointing to RLE-encoded sprites.
pub const ScenePack = struct {
    /// Raw resource data (not owned -- caller retains ownership).
    data: []const u8,
    /// Declared total size from the first 4 bytes.
    declared_size: u32,
    /// Offsets to sprite data within the resource.
    sprite_offsets: []u32,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScenePack) void {
        self.allocator.free(self.sprite_offsets);
    }

    /// Number of sprites in this scene pack.
    pub fn spriteCount(self: ScenePack) usize {
        return self.sprite_offsets.len;
    }

    /// Decode the sprite at the given index.
    pub fn decodeSprite(self: ScenePack, allocator: std.mem.Allocator, index: usize) !sprite_mod.Sprite {
        if (index >= self.sprite_offsets.len) return Error.IndexOutOfBounds;
        const offset: usize = self.sprite_offsets[index];
        if (offset + sprite_mod.HEADER_SIZE > self.data.len) return Error.OffsetOutOfBounds;
        return sprite_mod.decode(allocator, self.data[offset..]);
    }

    /// Read the sprite header at the given index without decoding pixel data.
    /// Useful for getting sprite bounds for click regions.
    pub fn getSpriteHeader(self: ScenePack, index: usize) !sprite_mod.SpriteHeader {
        if (index >= self.sprite_offsets.len) return Error.IndexOutOfBounds;
        const offset: usize = self.sprite_offsets[index];
        if (offset + sprite_mod.HEADER_SIZE > self.data.len) return Error.OffsetOutOfBounds;
        return sprite_mod.parseHeader(self.data[offset..]);
    }
};

/// Parse a PAK resource as a scene pack.
/// The resource should start with a 4-byte size, followed by an offset table.
pub fn parseScenePack(allocator: std.mem.Allocator, data: []const u8) Error!ScenePack {
    if (data.len < 8) return Error.InvalidSize;

    const declared_size = std.mem.readInt(u32, data[0..4], .little);
    const first_offset = std.mem.readInt(u32, data[4..8], .little);

    if (first_offset < 8 or first_offset > data.len) return Error.InvalidFormat;

    const num_offsets = (first_offset - 4) / 4;
    if (num_offsets == 0) return Error.InvalidFormat;

    const offsets = allocator.alloc(u32, num_offsets) catch return Error.OutOfMemory;
    errdefer allocator.free(offsets);

    for (0..num_offsets) |i| {
        const pos = 4 + i * 4;
        if (pos + 4 > data.len) {
            allocator.free(offsets);
            return Error.InvalidFormat;
        }
        offsets[i] = std.mem.readInt(u32, data[pos..][0..4], .little);
    }

    return .{
        .data = data,
        .declared_size = declared_size,
        .sprite_offsets = offsets,
        .allocator = allocator,
    };
}

/// A sprite positioned at a specific screen location.
pub const PositionedSprite = struct {
    sprite: sprite_mod.Sprite,
    x: i32,
    y: i32,
};

/// A renderable scene view combining a background sprite and overlay sprites.
pub const SceneView = struct {
    /// Background sprite covering most/all of the screen.
    background: ?sprite_mod.Sprite = null,
    /// Additional sprites to overlay on top.
    sprites: []const PositionedSprite = &.{},
};

/// Render a complete scene to the framebuffer.
/// Clears to black, then composites: background sprite at (0,0) -> overlay sprites.
pub fn renderScene(fb: *framebuffer_mod.Framebuffer, view: SceneView) void {
    fb.clear(0);
    if (view.background) |bg| {
        fb.blitSprite(bg, 0, 0);
    }
    for (view.sprites) |pos| {
        fb.blitSprite(pos.sprite, pos.x, pos.y);
    }
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parseScenePack parses single-sprite resource" {
    // Build a scene pack: [size:4][offset=8:4][sprite_header:8][rle_data...]
    // Minimal 2x2 sprite with even-key RLE
    var resource = [_]u8{
        // [0..4] declared size = 34
        0x22, 0x00, 0x00, 0x00,
        // [4..8] first offset = 8
        0x08, 0x00, 0x00, 0x00,
        // [8..16] sprite header: x2=1, x1=1, y1=1, y2=1 (2x2)
        0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00,
        // Row 0: even key=4 (2 pixels), x=0, y=0, colors=[5, 6]
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x06,
        // Row 1: even key=4 (2 pixels), x=0, y=1, colors=[7, 8]
        0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x07, 0x08,
        // Terminator
        0x00, 0x00,
    };

    const allocator = std.testing.allocator;
    var pack = try parseScenePack(allocator, &resource);
    defer pack.deinit();

    try std.testing.expectEqual(@as(usize, 1), pack.spriteCount());
    try std.testing.expectEqual(@as(u32, 34), pack.declared_size);
    try std.testing.expectEqual(@as(u32, 8), pack.sprite_offsets[0]);
}

test "parseScenePack parses multi-sprite resource" {
    // Two sprites with offsets at 12 and 12+26=38
    const sprite_data = [_]u8{
        // Sprite header: x2=1, x1=1, y1=1, y2=1 (2x2)
        0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00,
        // Row 0: even key=4, x=0, y=0, colors=[5, 6]
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x06,
        // Row 1: even key=4, x=0, y=1, colors=[7, 8]
        0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x07, 0x08,
        // Terminator
        0x00, 0x00,
    };

    // Resource: [size:4][offset0=12:4][offset1=38:4][sprite0:26][sprite1:26]
    const total_size = 4 + 4 + 4 + sprite_data.len + sprite_data.len;
    var resource: [total_size]u8 = undefined;
    // Size
    @memcpy(resource[0..4], &std.mem.toBytes(@as(u32, total_size)));
    // Offset 0 = 12 (after size + 2 offsets)
    @memcpy(resource[4..8], &std.mem.toBytes(@as(u32, 12)));
    // Offset 1 = 12 + sprite_data.len
    @memcpy(resource[8..12], &std.mem.toBytes(@as(u32, 12 + sprite_data.len)));
    // Sprite data
    @memcpy(resource[12 .. 12 + sprite_data.len], &sprite_data);
    @memcpy(resource[12 + sprite_data.len .. 12 + sprite_data.len * 2], &sprite_data);

    const allocator = std.testing.allocator;
    var pack = try parseScenePack(allocator, &resource);
    defer pack.deinit();

    try std.testing.expectEqual(@as(usize, 2), pack.spriteCount());
    try std.testing.expectEqual(@as(u32, 12), pack.sprite_offsets[0]);
    try std.testing.expectEqual(@as(u32, 12 + sprite_data.len), pack.sprite_offsets[1]);
}

test "ScenePack.decodeSprite decodes sprite at offset" {
    var resource = [_]u8{
        // [0..4] declared size
        0x22, 0x00, 0x00, 0x00,
        // [4..8] first offset = 8
        0x08, 0x00, 0x00, 0x00,
        // [8..16] sprite header: x2=1, x1=1, y1=1, y2=1 (2x2)
        0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00,
        // Row 0: even key=4 (2 pixels), x=0, y=0, colors=[5, 6]
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x06,
        // Row 1: even key=4 (2 pixels), x=0, y=1, colors=[7, 8]
        0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x07, 0x08,
        // Terminator
        0x00, 0x00,
    };

    const allocator = std.testing.allocator;
    var pack = try parseScenePack(allocator, &resource);
    defer pack.deinit();

    var spr = try pack.decodeSprite(allocator, 0);
    defer spr.deinit();

    try std.testing.expectEqual(@as(u16, 2), spr.width);
    try std.testing.expectEqual(@as(u16, 2), spr.height);
    // Row 0: [5, 6]
    try std.testing.expectEqual(@as(u8, 5), spr.pixels[0]);
    try std.testing.expectEqual(@as(u8, 6), spr.pixels[1]);
    // Row 1: [7, 8]
    try std.testing.expectEqual(@as(u8, 7), spr.pixels[2]);
    try std.testing.expectEqual(@as(u8, 8), spr.pixels[3]);
}

test "ScenePack.decodeSprite rejects out-of-bounds index" {
    var resource = [_]u8{
        0x22, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x06,
        0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x07, 0x08,
        0x00, 0x00,
    };

    const allocator = std.testing.allocator;
    var pack = try parseScenePack(allocator, &resource);
    defer pack.deinit();

    try std.testing.expectError(Error.IndexOutOfBounds, pack.decodeSprite(allocator, 1));
}

test "parseScenePack rejects too-small data" {
    var data = [_]u8{ 0x04, 0x00, 0x00, 0x00 };
    try std.testing.expectError(Error.InvalidSize, parseScenePack(std.testing.allocator, &data));
}

test "parseScenePack rejects invalid first offset" {
    // First offset points beyond data
    var data = [_]u8{
        0x08, 0x00, 0x00, 0x00,
        0xFF, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(Error.InvalidFormat, parseScenePack(std.testing.allocator, &data));
}

test "renderScene with background sprite produces non-black framebuffer" {
    var fb = framebuffer_mod.Framebuffer.create();

    // Create a 4x4 test sprite
    var pixels = [_]u8{
        10, 11, 12, 13,
        14, 15, 16, 17,
        18, 19, 20, 21,
        22, 23, 24, 25,
    };
    const spr = sprite_mod.Sprite{
        .header = .{ .x2 = 2, .x1 = 2, .y1 = 2, .y2 = 2 },
        .width = 4,
        .height = 4,
        .pixels = &pixels,
        .allocator = std.testing.allocator,
    };

    const view = SceneView{ .background = spr };
    renderScene(&fb, view);

    // Background sprite should appear at (0,0): top-left = (0-2, 0-2) = clipped
    // Visible portion: pixels from src(2,2) onwards
    // At (0,0): src pixel at (2,2) = 20
    try std.testing.expectEqual(@as(u8, 20), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 21), fb.getPixel(1, 0));
    try std.testing.expectEqual(@as(u8, 24), fb.getPixel(0, 1));
    try std.testing.expectEqual(@as(u8, 25), fb.getPixel(1, 1));
}

test "renderScene without background clears to black" {
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(42); // pre-fill

    const view = SceneView{};
    renderScene(&fb, view);

    for (fb.pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p);
    }
}

test "renderScene renders overlay sprites on top of background" {
    var fb = framebuffer_mod.Framebuffer.create();

    // Large background sprite (using x1=0 like real game data)
    var bg_pixels: [10 * 10]u8 = undefined;
    @memset(&bg_pixels, 30);
    const bg_spr = sprite_mod.Sprite{
        .header = .{ .x2 = 10, .x1 = 0, .y1 = 0, .y2 = 10 },
        .width = 10,
        .height = 10,
        .pixels = &bg_pixels,
        .allocator = std.testing.allocator,
    };

    // Small overlay sprite
    var overlay_pixels = [_]u8{ 0, 50, 50, 0 };
    const overlay_spr = sprite_mod.Sprite{
        .header = .{ .x2 = 1, .x1 = 1, .y1 = 1, .y2 = 1 },
        .width = 2,
        .height = 2,
        .pixels = &overlay_pixels,
        .allocator = std.testing.allocator,
    };

    const positioned = [_]PositionedSprite{
        .{ .sprite = overlay_spr, .x = 5, .y = 5 },
    };

    const view = SceneView{
        .background = bg_spr,
        .sprites = &positioned,
    };
    renderScene(&fb, view);

    // Background should be present
    try std.testing.expectEqual(@as(u8, 30), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 30), fb.getPixel(3, 3));
    // Overlay opaque pixels overwrite background
    try std.testing.expectEqual(@as(u8, 50), fb.getPixel(5, 4));
    try std.testing.expectEqual(@as(u8, 50), fb.getPixel(4, 5));
    // Overlay transparent pixels preserve background
    try std.testing.expectEqual(@as(u8, 30), fb.getPixel(4, 4));
    try std.testing.expectEqual(@as(u8, 30), fb.getPixel(5, 5));
}
