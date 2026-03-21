//! Movie voice dialog playback for Wing Commander: Privateer intro cinematic.
//!
//! Loads speech VOC files from SPEECH/MID01/ in the TRE archive for the
//! intro movie pirate encounter scenes (mid1c*, mid1d, mid1e*).
//!
//! Voice clips:
//!   - PC_1MG1.VOC through PC_1MG8.VOC  (8 player character lines)
//!   - PIR1MG1.VOC through PIR1MG9.VOC  (9 pirate lines)
//!
//! Audio pipeline: TRE entry → VOC parse → 8-bit unsigned PCM (11025 Hz)
//!   → AudioPlayer.play() (layered over music via separate SDL3 AudioStream)

const std = @import("std");
const voc = @import("../formats/voc.zig");
const tre = @import("../formats/tre.zig");
const audio = @import("../audio/audio.zig");

/// Number of player character voice clips (PC_1MG1–PC_1MG8).
pub const PLAYER_CLIP_COUNT = 8;

/// Number of pirate voice clips (PIR1MG1–PIR1MG9).
pub const PIRATE_CLIP_COUNT = 9;

/// Total voice clips for the intro movie.
pub const TOTAL_CLIP_COUNT = PLAYER_CLIP_COUNT + PIRATE_CLIP_COUNT;

/// TRE filenames for player character voice lines.
pub const PLAYER_FILENAMES = [PLAYER_CLIP_COUNT][]const u8{
    "PC_1MG1.VOC", "PC_1MG2.VOC", "PC_1MG3.VOC", "PC_1MG4.VOC",
    "PC_1MG5.VOC", "PC_1MG6.VOC", "PC_1MG7.VOC", "PC_1MG8.VOC",
};

/// TRE filenames for pirate voice lines.
pub const PIRATE_FILENAMES = [PIRATE_CLIP_COUNT][]const u8{
    "PIR1MG1.VOC", "PIR1MG2.VOC", "PIR1MG3.VOC", "PIR1MG4.VOC",
    "PIR1MG5.VOC", "PIR1MG6.VOC", "PIR1MG7.VOC", "PIR1MG8.VOC",
    "PIR1MG9.VOC",
};

pub const MovieVoiceError = error{
    /// Voice file not found in TRE archive.
    VoiceFileNotFound,
    /// VOC data could not be parsed.
    InvalidVocData,
    OutOfMemory,
};

/// A loaded voice clip with PCM audio data ready for playback.
pub const VoiceClip = struct {
    /// PCM audio samples (8-bit unsigned, mono). Owned.
    samples: []const u8,
    /// Sample rate in Hz (typically 11025).
    sample_rate: u32,
    /// Duration in milliseconds.
    duration_ms: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VoiceClip) void {
        self.allocator.free(self.samples);
    }
};

/// Load a single voice clip from raw VOC file data.
/// Returns an owned VoiceClip the caller must deinit().
pub fn loadVoiceClip(allocator: std.mem.Allocator, file_data: []const u8) MovieVoiceError!VoiceClip {
    var voc_file = voc.parse(allocator, file_data) catch return MovieVoiceError.InvalidVocData;

    const samples = allocator.dupe(u8, voc_file.samples) catch {
        voc_file.deinit();
        return MovieVoiceError.OutOfMemory;
    };
    const sample_rate = voc_file.sample_rate;
    const duration_ms = voc_file.durationMs();
    voc_file.deinit();

    return VoiceClip{
        .samples = samples,
        .sample_rate = sample_rate,
        .duration_ms = duration_ms,
        .allocator = allocator,
    };
}

/// Load a voice clip by TRE filename lookup.
pub fn loadFromTreIndex(
    allocator: std.mem.Allocator,
    index: *const tre.TreIndex,
    tre_data: []const u8,
    filename: []const u8,
) MovieVoiceError!VoiceClip {
    const entry = index.findEntry(filename) orelse return MovieVoiceError.VoiceFileNotFound;
    const file_data = tre.extractFileData(tre_data, entry.offset, entry.size) catch
        return MovieVoiceError.VoiceFileNotFound;
    return loadVoiceClip(allocator, file_data);
}

/// Collection of all voice clips for the intro movie pirate encounter.
/// Supports graceful degradation: clips that fail to load are left null.
pub const MovieVoiceSet = struct {
    player_clips: [PLAYER_CLIP_COUNT]?VoiceClip,
    pirate_clips: [PIRATE_CLIP_COUNT]?VoiceClip,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MovieVoiceSet {
        return .{
            .player_clips = [_]?VoiceClip{null} ** PLAYER_CLIP_COUNT,
            .pirate_clips = [_]?VoiceClip{null} ** PIRATE_CLIP_COUNT,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MovieVoiceSet) void {
        for (&self.player_clips) |*slot| {
            if (slot.*) |*clip| clip.deinit();
            slot.* = null;
        }
        for (&self.pirate_clips) |*slot| {
            if (slot.*) |*clip| clip.deinit();
            slot.* = null;
        }
    }

    /// Load all voice clips from the TRE archive.
    /// Clips that fail to load are left as null (graceful degradation).
    pub fn loadFromTre(
        self: *MovieVoiceSet,
        index: *const tre.TreIndex,
        tre_data: []const u8,
    ) void {
        for (PLAYER_FILENAMES, 0..) |filename, i| {
            self.player_clips[i] = loadFromTreIndex(self.allocator, index, tre_data, filename) catch null;
        }
        for (PIRATE_FILENAMES, 0..) |filename, i| {
            self.pirate_clips[i] = loadFromTreIndex(self.allocator, index, tre_data, filename) catch null;
        }
    }

    /// Get a player character voice clip by index (0-based).
    pub fn getPlayerClip(self: *const MovieVoiceSet, index: usize) ?*const VoiceClip {
        if (index >= PLAYER_CLIP_COUNT) return null;
        return if (self.player_clips[index]) |*clip| clip else null;
    }

    /// Get a pirate voice clip by index (0-based).
    pub fn getPirateClip(self: *const MovieVoiceSet, index: usize) ?*const VoiceClip {
        if (index >= PIRATE_CLIP_COUNT) return null;
        return if (self.pirate_clips[index]) |*clip| clip else null;
    }

    /// Count of successfully loaded clips.
    pub fn loadedCount(self: *const MovieVoiceSet) usize {
        var count: usize = 0;
        for (self.player_clips) |clip| {
            if (clip != null) count += 1;
        }
        for (self.pirate_clips) |clip| {
            if (clip != null) count += 1;
        }
        return count;
    }

    /// Play a player voice clip on the given AudioPlayer.
    /// Returns clip duration in ms, or null if clip not loaded.
    pub fn playPlayerClip(
        self: *const MovieVoiceSet,
        index: usize,
        player: *audio.AudioPlayer,
    ) ?u64 {
        const clip = self.getPlayerClip(index) orelse return null;
        player.play(clip.samples, clip.sample_rate) catch return null;
        return clip.duration_ms;
    }

    /// Play a pirate voice clip on the given AudioPlayer.
    /// Returns clip duration in ms, or null if clip not loaded.
    pub fn playPirateClip(
        self: *const MovieVoiceSet,
        index: usize,
        player: *audio.AudioPlayer,
    ) ?u64 {
        const clip = self.getPirateClip(index) orelse return null;
        player.play(clip.samples, clip.sample_rate) catch return null;
        return clip.duration_ms;
    }
};

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "loadVoiceClip parses VOC fixture to valid PCM" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_voc.bin");
    defer allocator.free(data);

    var clip = try loadVoiceClip(allocator, data);
    defer clip.deinit();

    // VOC fixture has 16 samples of 8-bit PCM
    try std.testing.expectEqual(@as(usize, 16), clip.samples.len);
    try std.testing.expect(clip.sample_rate > 10000);
    try std.testing.expect(clip.sample_rate < 12000);
    try std.testing.expect(clip.duration_ms < 10);
}

test "loadVoiceClip rejects empty data" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(MovieVoiceError.InvalidVocData, loadVoiceClip(allocator, ""));
}

test "loadVoiceClip rejects non-VOC data" {
    const allocator = std.testing.allocator;
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ** 8;
    try std.testing.expectError(MovieVoiceError.InvalidVocData, loadVoiceClip(allocator, &garbage));
}

test "loadVoiceClip preserves sample values" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_voc.bin");
    defer allocator.free(data);

    var clip = try loadVoiceClip(allocator, data);
    defer clip.deinit();

    // First sample should be 128 (silence) per fixture
    try std.testing.expectEqual(@as(u8, 128), clip.samples[0]);
    // Last sample should be 96 per fixture
    try std.testing.expectEqual(@as(u8, 96), clip.samples[15]);
}

test "loadVoiceClip handles multi-block VOC" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_voc_multi.bin");
    defer allocator.free(data);

    var clip = try loadVoiceClip(allocator, data);
    defer clip.deinit();

    // Multi-block fixture: 8 + 8 = 16 samples
    try std.testing.expectEqual(@as(usize, 16), clip.samples.len);
}

test "MovieVoiceSet init has no loaded clips" {
    var set = MovieVoiceSet.init(std.testing.allocator);
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, 0), set.loadedCount());
    try std.testing.expect(set.getPlayerClip(0) == null);
    try std.testing.expect(set.getPirateClip(0) == null);
}

test "MovieVoiceSet getPlayerClip rejects out-of-range" {
    var set = MovieVoiceSet.init(std.testing.allocator);
    defer set.deinit();

    try std.testing.expect(set.getPlayerClip(PLAYER_CLIP_COUNT) == null);
    try std.testing.expect(set.getPlayerClip(99) == null);
}

test "MovieVoiceSet getPirateClip rejects out-of-range" {
    var set = MovieVoiceSet.init(std.testing.allocator);
    defer set.deinit();

    try std.testing.expect(set.getPirateClip(PIRATE_CLIP_COUNT) == null);
    try std.testing.expect(set.getPirateClip(99) == null);
}

test "filename constants have correct counts" {
    try std.testing.expectEqual(@as(usize, 8), PLAYER_FILENAMES.len);
    try std.testing.expectEqual(@as(usize, 9), PIRATE_FILENAMES.len);
}

test "filename constants have .VOC extension" {
    for (PLAYER_FILENAMES) |name| {
        try std.testing.expect(std.mem.endsWith(u8, name, ".VOC"));
    }
    for (PIRATE_FILENAMES) |name| {
        try std.testing.expect(std.mem.endsWith(u8, name, ".VOC"));
    }
}

test "player filenames follow PC_1MG pattern" {
    for (PLAYER_FILENAMES, 1..) |name, i| {
        // Expected: "PC_1MG1.VOC" through "PC_1MG8.VOC"
        var expected: [11]u8 = undefined;
        _ = std.fmt.bufPrint(&expected, "PC_1MG{d}.VOC", .{i}) catch unreachable;
        try std.testing.expectEqualStrings(&expected, name);
    }
}

test "pirate filenames follow PIR1MG pattern" {
    for (PIRATE_FILENAMES, 1..) |name, i| {
        // Expected: "PIR1MG1.VOC" through "PIR1MG9.VOC"
        var expected: [11]u8 = undefined;
        _ = std.fmt.bufPrint(&expected, "PIR1MG{d}.VOC", .{i}) catch unreachable;
        try std.testing.expectEqualStrings(&expected, name);
    }
}

test "TOTAL_CLIP_COUNT is sum of player and pirate" {
    try std.testing.expectEqual(PLAYER_CLIP_COUNT + PIRATE_CLIP_COUNT, TOTAL_CLIP_COUNT);
    try std.testing.expectEqual(@as(usize, 17), TOTAL_CLIP_COUNT);
}
