//! Midgame animation sequence player for Wing Commander: Privateer.
//! Loads MIDGAMES/ PAK files and plays them as frame-by-frame animations
//! for landing approach, launch, jump, and death sequences.
//!
//! MIDGAMES PAK files typically contain:
//!   Resource 0: palette data (772 bytes: 4-byte header + 768 RGB)
//!   Resources 1..N: scene pack frames (RLE-encoded sprites)
//!
//! The sequence player detects the palette resource, skips it when counting
//! frames, and provides it separately for rendering. Frame timing and
//! completion tracking manage the animation playback.

const std = @import("std");
const pak_mod = @import("pak.zig");
const pal_mod = @import("pal.zig");
const scene_renderer = @import("scene_renderer.zig");
const sprite_mod = @import("sprite.zig");

/// Default frame duration in milliseconds (~10 fps, matching original game).
pub const DEFAULT_FRAME_DURATION_MS: u32 = 100;

/// Types of midgame animation sequences.
pub const SequenceType = enum {
    /// Landing approach at a base.
    landing,
    /// Launching/taking off from a base.
    launch,
    /// Jump drive hyperspace sequence.
    jump,
    /// Player death/destruction sequence.
    death,
};

pub const SequenceError = error{
    /// PAK file has no animation frames.
    NoFrames,
    /// Failed to parse PAK data.
    InvalidPak,
    OutOfMemory,
};

/// An animation sequence loaded from a MIDGAMES PAK file.
/// Detects palette resources and treats remaining resources as animation frames.
pub const MidgameSequence = struct {
    /// Parsed PAK file containing frame resources.
    pak: pak_mod.PakFile,
    /// Index of the first animation frame resource in the PAK.
    /// If resource 0 is a palette, this is 1; otherwise 0.
    first_frame: usize,
    /// Total number of animation frames (excludes palette resource).
    frame_count: usize,
    /// Current frame index (0-based, relative to first_frame).
    current_frame: usize,
    /// Milliseconds per frame.
    frame_duration_ms: u32,
    /// Milliseconds elapsed on current frame.
    elapsed_ms: u32,
    /// Whether the sequence has played through all frames.
    complete: bool,
    /// Whether a palette was found as resource 0.
    has_palette: bool,

    /// Load a midgame animation sequence from raw PAK file data.
    pub fn init(allocator: std.mem.Allocator, pak_data: []const u8) SequenceError!MidgameSequence {
        return initWithDuration(allocator, pak_data, DEFAULT_FRAME_DURATION_MS);
    }

    /// Load a midgame animation sequence with a custom frame duration.
    pub fn initWithDuration(allocator: std.mem.Allocator, pak_data: []const u8, frame_duration_ms: u32) SequenceError!MidgameSequence {
        const pak = pak_mod.parse(allocator, pak_data) catch return SequenceError.InvalidPak;
        const total = pak.resourceCount();
        if (total == 0) {
            var p = pak;
            p.deinit();
            return SequenceError.NoFrames;
        }

        // Detect palette as resource 0 (exactly 772 bytes = PAL_FILE_SIZE)
        const res0 = pak.getResource(0) catch {
            var p = pak;
            p.deinit();
            return SequenceError.InvalidPak;
        };
        const has_pal = res0.len == pal_mod.PAL_FILE_SIZE;
        const first: usize = if (has_pal) 1 else 0;
        const count = total - first;

        if (count == 0) {
            var p = pak;
            p.deinit();
            return SequenceError.NoFrames;
        }

        return .{
            .pak = pak,
            .first_frame = first,
            .frame_count = count,
            .current_frame = 0,
            .frame_duration_ms = frame_duration_ms,
            .elapsed_ms = 0,
            .complete = false,
            .has_palette = has_pal,
        };
    }

    /// Release resources.
    pub fn deinit(self: *MidgameSequence) void {
        self.pak.deinit();
    }

    /// Advance the animation by the given number of milliseconds.
    /// Automatically advances to the next frame when enough time has elapsed.
    /// Sets complete=true when the last frame's duration has elapsed.
    pub fn advance(self: *MidgameSequence, delta_ms: u32) void {
        if (self.complete) return;

        self.elapsed_ms += delta_ms;
        while (self.elapsed_ms >= self.frame_duration_ms) {
            self.elapsed_ms -= self.frame_duration_ms;
            if (self.current_frame + 1 < self.frame_count) {
                self.current_frame += 1;
            } else {
                self.complete = true;
                return;
            }
        }
    }

    /// Get the current frame index (0-based, relative to animation frames).
    pub fn currentFrameIndex(self: MidgameSequence) usize {
        return self.current_frame;
    }

    /// Get the raw resource data for the current animation frame.
    pub fn getFrameData(self: MidgameSequence) ![]const u8 {
        const resource_idx = self.first_frame + self.current_frame;
        return self.pak.getResource(resource_idx) catch return SequenceError.InvalidPak;
    }

    /// Get the raw palette data (if present).
    /// Returns null if the PAK file has no palette resource.
    pub fn getPaletteData(self: MidgameSequence) !?[]const u8 {
        if (!self.has_palette) return null;
        return self.pak.getResource(0) catch return SequenceError.InvalidPak;
    }

    /// Decode the current frame as a scene pack and extract the first sprite.
    pub fn decodeCurrentFrame(self: MidgameSequence, allocator: std.mem.Allocator) !sprite_mod.Sprite {
        const data = try self.getFrameData();
        var pack = scene_renderer.parseScenePack(allocator, data) catch return SequenceError.InvalidPak;
        defer pack.deinit();
        return pack.decodeSprite(allocator, 0) catch return SequenceError.InvalidPak;
    }

    /// Check whether the animation has completed (all frames played).
    pub fn isComplete(self: MidgameSequence) bool {
        return self.complete;
    }

    /// Reset the sequence to the first frame for replay.
    pub fn reset(self: *MidgameSequence) void {
        self.current_frame = 0;
        self.elapsed_ms = 0;
        self.complete = false;
    }
};

// --- Tests ---

const testing_helpers = @import("testing.zig");

test "MidgameSequence loads from PAK fixture with correct frame count" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.init(allocator, data);
    defer seq.deinit();

    // test_midgame.bin has 3 resources, none are palettes
    try std.testing.expectEqual(@as(usize, 3), seq.frame_count);
    try std.testing.expectEqual(@as(usize, 0), seq.currentFrameIndex());
    try std.testing.expect(!seq.isComplete());
    try std.testing.expect(!seq.has_palette);
}

test "MidgameSequence starts at frame 0" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.init(allocator, data);
    defer seq.deinit();

    try std.testing.expectEqual(@as(usize, 0), seq.currentFrameIndex());
}

test "MidgameSequence advance moves to next frame after duration" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.initWithDuration(allocator, data, 100);
    defer seq.deinit();

    // Advance 50ms - still on frame 0
    seq.advance(50);
    try std.testing.expectEqual(@as(usize, 0), seq.currentFrameIndex());

    // Advance another 50ms - should move to frame 1
    seq.advance(50);
    try std.testing.expectEqual(@as(usize, 1), seq.currentFrameIndex());
}

test "MidgameSequence advance handles large delta spanning multiple frames" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.initWithDuration(allocator, data, 100);
    defer seq.deinit();

    // Advance 250ms - should be on frame 2 (2 full frames + 50ms into frame 2)
    seq.advance(250);
    try std.testing.expectEqual(@as(usize, 2), seq.currentFrameIndex());
    try std.testing.expect(!seq.isComplete());
}

test "MidgameSequence completes after last frame duration" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.initWithDuration(allocator, data, 100);
    defer seq.deinit();

    // 3 frames at 100ms each = 300ms to complete
    seq.advance(300);
    try std.testing.expect(seq.isComplete());
    try std.testing.expectEqual(@as(usize, 2), seq.currentFrameIndex());
}

test "MidgameSequence advance does nothing after completion" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.initWithDuration(allocator, data, 100);
    defer seq.deinit();

    seq.advance(500); // well past completion
    try std.testing.expect(seq.isComplete());
    try std.testing.expectEqual(@as(usize, 2), seq.currentFrameIndex());

    // Further advances do nothing
    seq.advance(100);
    try std.testing.expect(seq.isComplete());
    try std.testing.expectEqual(@as(usize, 2), seq.currentFrameIndex());
}

test "MidgameSequence reset returns to frame 0" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.initWithDuration(allocator, data, 100);
    defer seq.deinit();

    seq.advance(300); // complete
    try std.testing.expect(seq.isComplete());

    seq.reset();
    try std.testing.expectEqual(@as(usize, 0), seq.currentFrameIndex());
    try std.testing.expect(!seq.isComplete());
}

test "MidgameSequence getFrameData returns correct resource data" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.init(allocator, data);
    defer seq.deinit();

    // Frame 0 data should be non-empty
    const frame0 = try seq.getFrameData();
    try std.testing.expect(frame0.len > 0);

    // Advance to frame 1
    seq.advance(DEFAULT_FRAME_DURATION_MS);
    const frame1 = try seq.getFrameData();
    try std.testing.expect(frame1.len > 0);

    // Frames should be different data
    try std.testing.expect(!std.mem.eql(u8, frame0, frame1));
}

test "MidgameSequence decodeCurrentFrame produces valid sprite" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.init(allocator, data);
    defer seq.deinit();

    // Frame 0: 2x2 sprite with pixels [10, 11, 12, 13]
    var spr0 = try seq.decodeCurrentFrame(allocator);
    defer spr0.deinit();
    try std.testing.expectEqual(@as(u16, 2), spr0.width);
    try std.testing.expectEqual(@as(u16, 2), spr0.height);
    try std.testing.expectEqual(@as(u8, 10), spr0.pixels[0]);
    try std.testing.expectEqual(@as(u8, 11), spr0.pixels[1]);
    try std.testing.expectEqual(@as(u8, 12), spr0.pixels[2]);
    try std.testing.expectEqual(@as(u8, 13), spr0.pixels[3]);

    // Advance to frame 1: pixels [20, 21, 22, 23]
    seq.advance(DEFAULT_FRAME_DURATION_MS);
    var spr1 = try seq.decodeCurrentFrame(allocator);
    defer spr1.deinit();
    try std.testing.expectEqual(@as(u8, 20), spr1.pixels[0]);
    try std.testing.expectEqual(@as(u8, 21), spr1.pixels[1]);

    // Advance to frame 2: pixels [30, 31, 32, 33]
    seq.advance(DEFAULT_FRAME_DURATION_MS);
    var spr2 = try seq.decodeCurrentFrame(allocator);
    defer spr2.deinit();
    try std.testing.expectEqual(@as(u8, 30), spr2.pixels[0]);
    try std.testing.expectEqual(@as(u8, 33), spr2.pixels[3]);
}

test "MidgameSequence custom frame duration works" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.initWithDuration(allocator, data, 200);
    defer seq.deinit();

    try std.testing.expectEqual(@as(u32, 200), seq.frame_duration_ms);

    // At 200ms/frame, 150ms should still be on frame 0
    seq.advance(150);
    try std.testing.expectEqual(@as(usize, 0), seq.currentFrameIndex());

    // At 200ms total, should advance to frame 1
    seq.advance(50);
    try std.testing.expectEqual(@as(usize, 1), seq.currentFrameIndex());
}

test "MidgameSequence init rejects empty PAK data" {
    const allocator = std.testing.allocator;
    const data = [_]u8{0} ** 4; // too small for valid PAK
    try std.testing.expectError(SequenceError.InvalidPak, MidgameSequence.init(allocator, &data));
}

test "MidgameSequence default frame duration is 100ms" {
    try std.testing.expectEqual(@as(u32, 100), DEFAULT_FRAME_DURATION_MS);
}

test "MidgameSequence getPaletteData returns null when no palette" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midgame.bin");
    defer allocator.free(data);

    var seq = try MidgameSequence.init(allocator, data);
    defer seq.deinit();

    const pal_data = try seq.getPaletteData();
    try std.testing.expect(pal_data == null);
}
