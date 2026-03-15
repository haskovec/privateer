//! Conversation audio manager for Wing Commander: Privateer.
//! Bridges VPK/VPF voice packs to the conversation UI, providing
//! voice clip playback synchronized with dialogue lines.
//!
//! Each conversation PFC script has a corresponding VPK voice pack file
//! where entry N contains the voice audio for dialogue line N.
//! Audio pipeline: VPK entry → LZW decompress → VOC parse → PCM samples → AudioPlayer.

const std = @import("std");
const vpk = @import("../formats/vpk.zig");
const voc = @import("../formats/voc.zig");
const audio = @import("../audio/audio.zig");

pub const ConvAudioError = error{
    /// VPK entry index exceeds available entries.
    EntryOutOfRange,
    /// Decompressed VPK entry is not valid VOC audio.
    InvalidVocData,
    /// No audio player available for playback.
    NoAudioPlayer,
    OutOfMemory,
};

/// A decompressed voice clip ready for playback.
pub const VoiceClip = struct {
    /// PCM audio samples (8-bit unsigned, mono).
    samples: []const u8,
    /// Sample rate in Hz (typically ~11025).
    sample_rate: u32,
    /// Duration in milliseconds.
    duration_ms: u64,
    /// Backing VOC data (owned).
    voc_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VoiceClip) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.voc_data);
    }
};

/// Manages voice pack audio for a conversation.
/// Loads a VPK file and decompresses voice clips on demand.
pub const ConversationVoice = struct {
    /// Parsed VPK file (references external data, not owned).
    vpk_file: vpk.VpkFile,
    /// Audio player for playback (optional, null for data-only mode).
    player: ?*audio.AudioPlayer,
    allocator: std.mem.Allocator,

    /// Create a ConversationVoice from parsed VPK data.
    /// The player is optional -- if null, clips can be decompressed but not played.
    pub fn init(
        allocator: std.mem.Allocator,
        vpk_file: vpk.VpkFile,
        player: ?*audio.AudioPlayer,
    ) ConversationVoice {
        return .{
            .vpk_file = vpk_file,
            .player = player,
            .allocator = allocator,
        };
    }

    /// Number of voice clips available (should match dialogue line count).
    pub fn clipCount(self: *const ConversationVoice) usize {
        return self.vpk_file.entryCount();
    }

    /// Decompress and parse voice clip for the given dialogue line index.
    /// Caller must call deinit() on the returned VoiceClip.
    pub fn getClip(self: *const ConversationVoice, line_index: usize) (ConvAudioError || vpk.VpkError)!VoiceClip {
        if (line_index >= self.vpk_file.entryCount()) return ConvAudioError.EntryOutOfRange;

        // Decompress VPK entry to raw VOC data
        const voc_data = try self.vpk_file.decompressEntry(self.allocator, line_index);
        errdefer self.allocator.free(voc_data);

        // Parse VOC to extract PCM samples
        var voc_file = voc.parse(self.allocator, voc_data) catch return ConvAudioError.InvalidVocData;

        const samples = voc_file.samples;
        const sample_rate = voc_file.sample_rate;
        const duration_ms = voc_file.durationMs();

        // Transfer ownership: we keep samples and voc_data, clear voc_file's ownership
        // Since VocFile owns samples, we need to prevent double-free.
        // We'll take ownership by duplicating then freeing the VocFile.
        const owned_samples = self.allocator.dupe(u8, samples) catch {
            voc_file.deinit();
            return ConvAudioError.OutOfMemory;
        };
        voc_file.deinit();

        return VoiceClip{
            .samples = owned_samples,
            .sample_rate = sample_rate,
            .duration_ms = duration_ms,
            .voc_data = voc_data,
            .allocator = self.allocator,
        };
    }

    /// Play the voice clip for the given dialogue line.
    /// Returns the clip duration in milliseconds, or error if playback fails.
    pub fn playLine(self: *ConversationVoice, line_index: usize) (ConvAudioError || vpk.VpkError || audio.AudioError)!u64 {
        const player = self.player orelse return ConvAudioError.NoAudioPlayer;

        var clip = try self.getClip(line_index);
        defer clip.deinit();

        try player.play(clip.samples, clip.sample_rate);
        return clip.duration_ms;
    }

    /// Stop any currently playing voice audio.
    pub fn stopPlayback(self: *ConversationVoice) void {
        if (self.player) |player| {
            player.stop();
        }
    }

    /// Check if voice audio is currently playing.
    pub fn isPlaying(self: *const ConversationVoice) bool {
        const player = self.player orelse return false;
        return player.isPlaying();
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

test "ConversationVoice.clipCount matches VPK entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    const cv = ConversationVoice.init(allocator, vpk_file, null);
    try std.testing.expectEqual(@as(usize, 2), cv.clipCount());
}

test "ConversationVoice.getClip decompresses to valid audio" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    const cv = ConversationVoice.init(allocator, vpk_file, null);

    var clip = try cv.getClip(0);
    defer clip.deinit();

    // Should have valid PCM data
    try std.testing.expect(clip.samples.len > 0);
    try std.testing.expect(clip.sample_rate >= 10000);
    try std.testing.expect(clip.sample_rate <= 12000);
}

test "ConversationVoice.getClip returns correct sample data" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    const cv = ConversationVoice.init(allocator, vpk_file, null);

    var clip = try cv.getClip(0);
    defer clip.deinit();

    // First sample should be 128 (silence) per the VPK test fixture
    try std.testing.expectEqual(@as(u8, 128), clip.samples[0]);
    try std.testing.expectEqual(@as(usize, 8), clip.samples.len);
}

test "ConversationVoice.getClip works for all entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    const cv = ConversationVoice.init(allocator, vpk_file, null);

    for (0..cv.clipCount()) |i| {
        var clip = try cv.getClip(i);
        defer clip.deinit();

        try std.testing.expect(clip.samples.len > 0);
        try std.testing.expect(clip.sample_rate > 0);
        try std.testing.expect(clip.duration_ms >= 0);
    }
}

test "ConversationVoice.getClip rejects out-of-range index" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    const cv = ConversationVoice.init(allocator, vpk_file, null);

    try std.testing.expectError(ConvAudioError.EntryOutOfRange, cv.getClip(99));
}

test "ConversationVoice.playLine fails without player" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    var cv = ConversationVoice.init(allocator, vpk_file, null);

    try std.testing.expectError(ConvAudioError.NoAudioPlayer, cv.playLine(0));
}

test "ConversationVoice.isPlaying returns false without player" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    const cv = ConversationVoice.init(allocator, vpk_file, null);

    try std.testing.expect(!cv.isPlaying());
}

test "ConversationVoice.stopPlayback is safe without player" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    var cv = ConversationVoice.init(allocator, vpk_file, null);
    cv.stopPlayback(); // should not crash
}

test "VoiceClip duration is calculated from samples and rate" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk_file = try vpk.parse(allocator, data);
    defer vpk_file.deinit();

    const cv = ConversationVoice.init(allocator, vpk_file, null);

    var clip = try cv.getClip(0);
    defer clip.deinit();

    // 8 samples at ~11111 Hz ≈ <1ms
    try std.testing.expect(clip.duration_ms < 10);
}
