//! Cockpit renderer for Wing Commander: Privateer.
//! Loads cockpit IFF/PAK data for each ship type (Tarsus, Centurion, Galaxy)
//! and renders the cockpit frame as a sprite overlay during space flight.
//!
//! Cockpit IFF structure (FORM:COCK):
//!   FORM:FRNT - Front view: SHAP (RLE sprite) + TPLT (layout template)
//!   FORM:RITE - Right view: SHAP + TPLT
//!   FORM:BACK - Rear view: SHAP + TPLT
//!   FORM:LEFT - Left view: SHAP + TPLT
//!   (shared elements: FONT, CMFD, CHUD, DIAL, DAMG, CDMG follow)
//!
//! The SHAP chunks contain RLE-encoded sprites forming the cockpit frame.
//! Transparent pixels (index 0) define the viewport window into space.

const std = @import("std");
const iff = @import("../formats/iff.zig");
const sprite_mod = @import("../formats/sprite.zig");
const scene_renderer = @import("../render/scene_renderer.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");
const mfd_mod = @import("mfd.zig");

/// Ship types that have distinct cockpit designs.
pub const ShipType = enum {
    /// Tarsus (starter ship, "Clunker" cockpit)
    tarsus,
    /// Centurion (fighter cockpit)
    centurion,
    /// Galaxy (merchant cockpit)
    galaxy,
    /// Orion (tug cockpit)
    orion,

    /// Return the IFF filename for this ship's cockpit.
    pub fn iffFilename(self: ShipType) []const u8 {
        return switch (self) {
            .tarsus => "CLUNKCK.IFF",
            .centurion => "FIGHTCK.IFF",
            .galaxy => "MERCHCK.IFF",
            .orion => "TUGCK.IFF",
        };
    }

    /// Return the PAK filename for this ship's cockpit.
    pub fn pakFilename(self: ShipType) []const u8 {
        return switch (self) {
            .tarsus => "CLUNKCK.PAK",
            .centurion => "FIGHTCK.PAK",
            .galaxy => "MERCHCK.PAK",
            .orion => "TUGCK.PAK",
        };
    }
};

/// Viewing direction within the cockpit.
pub const ViewDirection = enum {
    front,
    right,
    back,
    left,

    /// IFF form type tag for this view.
    pub fn formType(self: ViewDirection) iff.Tag {
        return switch (self) {
            .front => "FRNT".*,
            .right => "RITE".*,
            .back => "BACK".*,
            .left => "LEFT".*,
        };
    }
};

pub const CockpitError = error{
    /// IFF root is not FORM:COCK.
    InvalidFormat,
    /// A required view form (FRNT/RITE/BACK/LEFT) is missing.
    MissingView,
    /// A view is missing its SHAP sprite data.
    MissingShape,
    /// Sprite decoding failed.
    SpriteDecodeFailed,
    OutOfMemory,
};

/// A single cockpit view (front, right, back, or left).
pub const CockpitView = struct {
    /// The cockpit frame sprite for this view. Transparent pixels (0) are
    /// the viewport window where space shows through.
    sprite: sprite_mod.Sprite,
    /// View direction.
    direction: ViewDirection,

    pub fn deinit(self: *CockpitView) void {
        self.sprite.deinit();
    }
};

/// Parsed cockpit data for a single ship type.
/// Contains up to 4 directional views and MFD display configuration.
pub const CockpitData = struct {
    views: [4]?CockpitView,
    /// Number of views successfully loaded.
    view_count: u8,
    /// MFD display areas, instrument dials, and HUD configuration.
    mfd: mfd_mod.MfdData,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *CockpitData) void {
        for (&self.views) |*v| {
            if (v.*) |*view| {
                view.deinit();
            }
        }
    }

    /// Get the view for a given direction, or null if not loaded.
    pub fn getView(self: *const CockpitData, direction: ViewDirection) ?*const CockpitView {
        for (&self.views) |*v| {
            if (v.*) |*view| {
                if (view.direction == direction) return view;
            }
        }
        return null;
    }

    /// Get the front view sprite (the primary cockpit frame).
    pub fn frontSprite(self: *const CockpitData) ?sprite_mod.Sprite {
        const view = self.getView(.front) orelse return null;
        return view.sprite;
    }
};

// findFormByType is now available as iff.Chunk.findForm

/// Parse a cockpit IFF file (FORM:COCK) and extract view sprites.
pub fn parseCockpitIff(allocator: std.mem.Allocator, data: []const u8) (CockpitError || iff.IffError)!CockpitData {
    var root = iff.parseFile(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => return CockpitError.OutOfMemory,
        else => return err,
    };
    defer root.deinit();

    // Verify root is FORM:COCK
    if (!std.mem.eql(u8, &root.tag, "FORM") or root.form_type == null or
        !std.mem.eql(u8, &root.form_type.?, "COCK"))
    {
        return CockpitError.InvalidFormat;
    }

    // Parse MFD data (CMFD, DIAL, CHUD) from the root chunk.
    const mfd_data = mfd_mod.parseMfdData(allocator, root) catch mfd_mod.MfdData{};

    var result = CockpitData{
        .views = .{ null, null, null, null },
        .view_count = 0,
        .mfd = mfd_data,
        .allocator = allocator,
    };
    errdefer result.deinit();

    // Extract each directional view.
    // Views are FORM containers with form_type FRNT/RITE/BACK/LEFT.
    const directions = [_]ViewDirection{ .front, .right, .back, .left };
    for (directions) |dir| {
        const view_type = dir.formType();
        // Search children for a FORM with matching form_type
        const view_form = root.findForm(view_type) orelse continue;
        // Find SHAP chunk within the view.
        // SHAP data uses the scene pack format: [size:4][offset_table][sprite_data].
        if (view_form.findChild("SHAP".*)) |shap_chunk| {
            // Parse SHAP as a scene pack containing one or more RLE sprites
            var pack = scene_renderer.parseScenePack(allocator, shap_chunk.data) catch {
                // Fallback: try decoding directly as a raw RLE sprite
                const spr = sprite_mod.decode(allocator, shap_chunk.data) catch {
                    return CockpitError.SpriteDecodeFailed;
                };
                result.views[result.view_count] = CockpitView{
                    .sprite = spr,
                    .direction = dir,
                };
                result.view_count += 1;
                continue;
            };
            defer pack.deinit();

            // Decode the first sprite from the scene pack (the cockpit frame)
            const spr = pack.decodeSprite(allocator, 0) catch {
                return CockpitError.SpriteDecodeFailed;
            };
            result.views[result.view_count] = CockpitView{
                .sprite = spr,
                .direction = dir,
            };
            result.view_count += 1;
        }
    }

    return result;
}

/// Render the cockpit frame overlay onto the framebuffer.
/// The cockpit sprite is blitted on top of whatever is already rendered
/// (space scene, ships, etc.). Transparent pixels (index 0) preserve
/// the underlying content, creating the viewport window.
pub fn renderCockpit(fb: *framebuffer_mod.Framebuffer, cockpit: *const CockpitData, direction: ViewDirection) void {
    const view = cockpit.getView(direction) orelse return;
    // Blit at (0, 0) - the cockpit frame covers the full 320x200 screen.
    // The sprite's center offsets handle positioning.
    fb.blitSprite(view.sprite, 0, 0);
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parseCockpitIff loads FORM:COCK with 4 views" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_cockpit.bin");
    defer allocator.free(data);

    var cockpit = try parseCockpitIff(allocator, data);
    defer cockpit.deinit();

    try std.testing.expectEqual(@as(u8, 4), cockpit.view_count);
}

test "parseCockpitIff extracts front view sprite" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_cockpit.bin");
    defer allocator.free(data);

    var cockpit = try parseCockpitIff(allocator, data);
    defer cockpit.deinit();

    const front = cockpit.getView(.front);
    try std.testing.expect(front != null);
    try std.testing.expectEqual(ViewDirection.front, front.?.direction);

    // Sprite should be 4x4
    try std.testing.expectEqual(@as(u16, 4), front.?.sprite.width);
    try std.testing.expectEqual(@as(u16, 4), front.?.sprite.height);
}

test "parseCockpitIff front sprite has correct pixels" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_cockpit.bin");
    defer allocator.free(data);

    var cockpit = try parseCockpitIff(allocator, data);
    defer cockpit.deinit();

    const front = cockpit.getView(.front).?;
    const pixels = front.sprite.pixels;

    // Row 0: all opaque (color 10)
    try std.testing.expectEqual(@as(u8, 10), pixels[0]);
    try std.testing.expectEqual(@as(u8, 10), pixels[1]);
    try std.testing.expectEqual(@as(u8, 10), pixels[2]);
    try std.testing.expectEqual(@as(u8, 10), pixels[3]);
    // Row 1: opaque, transparent, transparent, opaque
    try std.testing.expectEqual(@as(u8, 10), pixels[4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[5]);
    try std.testing.expectEqual(@as(u8, 0), pixels[6]);
    try std.testing.expectEqual(@as(u8, 10), pixels[7]);
    // Row 2: same pattern
    try std.testing.expectEqual(@as(u8, 10), pixels[8]);
    try std.testing.expectEqual(@as(u8, 0), pixels[9]);
    try std.testing.expectEqual(@as(u8, 0), pixels[10]);
    try std.testing.expectEqual(@as(u8, 10), pixels[11]);
    // Row 3: all opaque
    try std.testing.expectEqual(@as(u8, 10), pixels[12]);
    try std.testing.expectEqual(@as(u8, 10), pixels[15]);
}

test "parseCockpitIff extracts all 4 views with correct directions" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_cockpit.bin");
    defer allocator.free(data);

    var cockpit = try parseCockpitIff(allocator, data);
    defer cockpit.deinit();

    // All 4 directions should be present
    try std.testing.expect(cockpit.getView(.front) != null);
    try std.testing.expect(cockpit.getView(.right) != null);
    try std.testing.expect(cockpit.getView(.back) != null);
    try std.testing.expect(cockpit.getView(.left) != null);

    // Each view should have different sprite data (different colors)
    const front = cockpit.getView(.front).?.sprite.pixels;
    const right = cockpit.getView(.right).?.sprite.pixels;
    try std.testing.expectEqual(@as(u8, 10), front[0]); // front color
    try std.testing.expectEqual(@as(u8, 20), right[0]); // right color
}

test "frontSprite returns front view sprite" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_cockpit.bin");
    defer allocator.free(data);

    var cockpit = try parseCockpitIff(allocator, data);
    defer cockpit.deinit();

    const spr = cockpit.frontSprite();
    try std.testing.expect(spr != null);
    try std.testing.expectEqual(@as(u16, 4), spr.?.width);
    try std.testing.expectEqual(@as(u16, 4), spr.?.height);
}

test "parseCockpitIff rejects non-COCK IFF" {
    // Build a FORM:XXXX instead of FORM:COCK
    const data = [_]u8{
        'F', 'O', 'R', 'M', // tag
        0, 0, 0, 4, // size = 4
        'X', 'X', 'X', 'X', // form_type
    };
    try std.testing.expectError(CockpitError.InvalidFormat, parseCockpitIff(std.testing.allocator, &data));
}

test "ShipType.iffFilename returns correct names" {
    try std.testing.expectEqualStrings("CLUNKCK.IFF", ShipType.tarsus.iffFilename());
    try std.testing.expectEqualStrings("FIGHTCK.IFF", ShipType.centurion.iffFilename());
    try std.testing.expectEqualStrings("MERCHCK.IFF", ShipType.galaxy.iffFilename());
    try std.testing.expectEqualStrings("TUGCK.IFF", ShipType.orion.iffFilename());
}

test "ShipType.pakFilename returns correct names" {
    try std.testing.expectEqualStrings("CLUNKCK.PAK", ShipType.tarsus.pakFilename());
    try std.testing.expectEqualStrings("FIGHTCK.PAK", ShipType.centurion.pakFilename());
    try std.testing.expectEqualStrings("MERCHCK.PAK", ShipType.galaxy.pakFilename());
    try std.testing.expectEqualStrings("TUGCK.PAK", ShipType.orion.pakFilename());
}

test "renderCockpit overlays sprite on framebuffer" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_cockpit.bin");
    defer allocator.free(data);

    var cockpit = try parseCockpitIff(allocator, data);
    defer cockpit.deinit();

    var fb = framebuffer_mod.Framebuffer.create();
    // Fill with a "space" color
    fb.clear(42);

    // Render cockpit overlay
    renderCockpit(&fb, &cockpit, .front);

    // Cockpit frame pixels (color 10) should overwrite space
    // The sprite is 4x4 with center at (2,2), so top-left is at (-2,-2) = clipped
    // Only the bottom-right quadrant (2x2) is visible at screen positions (0,0)-(1,1)
    // Row 2 of sprite: [10, 0, 0, 10] -> visible part: pixels at x=2,3 y=2,3 relative to sprite
    // Actually with x1=2, y1=2 offset: top-left = (0-2, 0-2) = (-2,-2)
    // Visible pixels: sprite rows 2-3, cols 2-3
    // Row 2: [10, 0, 0, 10] -> cols 2,3 = [0, 10]
    // Row 3: [10, 10, 10, 10] -> cols 2,3 = [10, 10]
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(0, 0)); // transparent (0) preserves space
    try std.testing.expectEqual(@as(u8, 10), fb.getPixel(1, 0)); // cockpit frame
    try std.testing.expectEqual(@as(u8, 10), fb.getPixel(0, 1)); // cockpit frame
    try std.testing.expectEqual(@as(u8, 10), fb.getPixel(1, 1)); // cockpit frame
}

test "renderCockpit with missing direction is no-op" {
    // Create a COCK with only front view
    const allocator = std.testing.allocator;

    // Build minimal COCK IFF with only FRNT
    var sprite_data: [50]u8 = undefined;
    // Header: x2=1, x1=2, y1=2, y2=1 → width=2+1+1=4, height=2+1+1=4
    std.mem.writeInt(i16, sprite_data[0..2], 1, .little);
    std.mem.writeInt(i16, sprite_data[2..4], 2, .little);
    std.mem.writeInt(i16, sprite_data[4..6], 2, .little);
    std.mem.writeInt(i16, sprite_data[6..8], 1, .little);
    // Row 0: key=8, x=0, y=0, pixels=[1,1,1,1]
    std.mem.writeInt(u16, sprite_data[8..10], 8, .little);
    std.mem.writeInt(u16, sprite_data[10..12], 0, .little);
    std.mem.writeInt(u16, sprite_data[12..14], 0, .little);
    sprite_data[14] = 1;
    sprite_data[15] = 1;
    sprite_data[16] = 1;
    sprite_data[17] = 1;
    // Row 1: key=8, x=0, y=1
    std.mem.writeInt(u16, sprite_data[18..20], 8, .little);
    std.mem.writeInt(u16, sprite_data[20..22], 0, .little);
    std.mem.writeInt(u16, sprite_data[22..24], 1, .little);
    sprite_data[24] = 1;
    sprite_data[25] = 1;
    sprite_data[26] = 1;
    sprite_data[27] = 1;
    // Row 2: key=8, x=0, y=2
    std.mem.writeInt(u16, sprite_data[28..30], 8, .little);
    std.mem.writeInt(u16, sprite_data[30..32], 0, .little);
    std.mem.writeInt(u16, sprite_data[32..34], 2, .little);
    sprite_data[34] = 1;
    sprite_data[35] = 1;
    sprite_data[36] = 1;
    sprite_data[37] = 1;
    // Row 3: key=8, x=0, y=3
    std.mem.writeInt(u16, sprite_data[38..40], 8, .little);
    std.mem.writeInt(u16, sprite_data[40..42], 0, .little);
    std.mem.writeInt(u16, sprite_data[42..44], 3, .little);
    sprite_data[44] = 1;
    sprite_data[45] = 1;
    sprite_data[46] = 1;
    sprite_data[47] = 1;
    // Terminator
    std.mem.writeInt(u16, sprite_data[48..50], 0, .little);

    // Build IFF: FORM:COCK > FORM:FRNT > SHAP
    const shap_size: u32 = 50;
    const frnt_inner_size: u32 = 4 + 8 + shap_size; // "FRNT" + SHAP header + SHAP data
    const cock_inner_size: u32 = 4 + 8 + frnt_inner_size; // "COCK" + FORM header + FRNT

    var iff_data: [8 + cock_inner_size]u8 = undefined;
    var pos: usize = 0;
    // FORM:COCK header
    @memcpy(iff_data[pos..][0..4], "FORM");
    pos += 4;
    std.mem.writeInt(u32, iff_data[pos..][0..4], cock_inner_size, .big);
    pos += 4;
    @memcpy(iff_data[pos..][0..4], "COCK");
    pos += 4;
    // FORM:FRNT header
    @memcpy(iff_data[pos..][0..4], "FORM");
    pos += 4;
    std.mem.writeInt(u32, iff_data[pos..][0..4], 4 + 8 + shap_size, .big);
    pos += 4;
    @memcpy(iff_data[pos..][0..4], "FRNT");
    pos += 4;
    // SHAP chunk
    @memcpy(iff_data[pos..][0..4], "SHAP");
    pos += 4;
    std.mem.writeInt(u32, iff_data[pos..][0..4], shap_size, .big);
    pos += 4;
    @memcpy(iff_data[pos..][0..shap_size], sprite_data[0..shap_size]);

    var cockpit = try parseCockpitIff(allocator, &iff_data);
    defer cockpit.deinit();

    try std.testing.expectEqual(@as(u8, 1), cockpit.view_count);
    try std.testing.expect(cockpit.getView(.front) != null);
    try std.testing.expect(cockpit.getView(.right) == null);

    // Rendering a missing direction should be a no-op
    var fb = framebuffer_mod.Framebuffer.create();
    fb.clear(42);
    renderCockpit(&fb, &cockpit, .right);
    // All pixels should still be 42
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(0, 0));
    try std.testing.expectEqual(@as(u8, 42), fb.getPixel(160, 100));
}
