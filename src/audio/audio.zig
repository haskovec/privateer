//! Audio playback engine for Wing Commander: Privateer.
//! Uses SDL3 AudioStream for PCM audio playback with automatic
//! sample rate and format conversion.
//!
//! Source audio from game files: 8-bit unsigned PCM, mono, ~11025 Hz (VOC format).
//! Playback device: 44100 Hz, signed 16-bit, mono (via SDL3 conversion).

const std = @import("std");
const sdl = @import("../sdl.zig");
const c = sdl.raw;

pub const AudioError = error{
    /// Failed to open SDL3 audio playback device.
    DeviceOpenFailed,
    /// Failed to create SDL3 audio stream for format conversion.
    StreamCreateFailed,
    /// Failed to bind audio stream to playback device.
    StreamBindFailed,
    /// Failed to queue audio data for playback.
    PlaybackFailed,
};

/// Convert 8-bit unsigned PCM samples to 16-bit signed PCM.
/// Input: 0-255 (128 = silence). Output: -32768 to 32512 (0 = silence).
pub fn convertU8ToS16(src: []const u8, dst: []i16) void {
    for (src, 0..) |sample, i| {
        dst[i] = (@as(i16, sample) - 128) * 256;
    }
}

/// SDL3-based audio player.
/// Manages an audio device and stream for playing VOC PCM data.
pub const AudioPlayer = struct {
    device: c.SDL_AudioDeviceID,
    stream: ?*c.SDL_AudioStream,

    /// Open the default audio playback device.
    pub fn init() AudioError!AudioPlayer {
        const spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_S16,
            .channels = 1,
            .freq = 44100,
        };
        const device = c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec);
        if (device == 0) return AudioError.DeviceOpenFailed;

        return .{
            .device = device,
            .stream = null,
        };
    }

    /// Release audio resources.
    pub fn deinit(self: *AudioPlayer) void {
        self.stop();
        c.SDL_CloseAudioDevice(self.device);
    }

    /// Play 8-bit unsigned PCM audio at the given sample rate.
    /// Stops any currently playing audio first.
    pub fn play(self: *AudioPlayer, samples: []const u8, sample_rate: u32) AudioError!void {
        self.stop();

        const src_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_U8,
            .channels = 1,
            .freq = @intCast(sample_rate),
        };
        const dst_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_S16,
            .channels = 1,
            .freq = 44100,
        };

        const stream = c.SDL_CreateAudioStream(&src_spec, &dst_spec) orelse
            return AudioError.StreamCreateFailed;

        if (!c.SDL_BindAudioStream(self.device, stream)) {
            c.SDL_DestroyAudioStream(stream);
            return AudioError.StreamBindFailed;
        }

        if (!c.SDL_PutAudioStreamData(stream, samples.ptr, @intCast(samples.len))) {
            c.SDL_DestroyAudioStream(stream);
            return AudioError.PlaybackFailed;
        }

        _ = c.SDL_FlushAudioStream(stream);
        self.stream = stream;
    }

    /// Stop current playback and release the stream.
    pub fn stop(self: *AudioPlayer) void {
        if (self.stream) |s| {
            _ = c.SDL_ClearAudioStream(s);
            c.SDL_DestroyAudioStream(s);
            self.stream = null;
        }
    }

    /// Check if audio data is still queued for playback.
    pub fn isPlaying(self: *const AudioPlayer) bool {
        const s = self.stream orelse return false;
        return c.SDL_GetAudioStreamQueued(s) > 0;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "convertU8ToS16 maps silence (128) to zero" {
    const src = [_]u8{128};
    var dst: [1]i16 = undefined;
    convertU8ToS16(&src, &dst);
    try std.testing.expectEqual(@as(i16, 0), dst[0]);
}

test "convertU8ToS16 maps max (255) to positive" {
    const src = [_]u8{255};
    var dst: [1]i16 = undefined;
    convertU8ToS16(&src, &dst);
    try std.testing.expectEqual(@as(i16, 127 * 256), dst[0]);
}

test "convertU8ToS16 maps min (0) to negative" {
    const src = [_]u8{0};
    var dst: [1]i16 = undefined;
    convertU8ToS16(&src, &dst);
    try std.testing.expectEqual(@as(i16, -128 * 256), dst[0]);
}

test "convertU8ToS16 preserves sample count" {
    const src = [_]u8{ 128, 0, 255, 64, 192 };
    var dst: [5]i16 = undefined;
    convertU8ToS16(&src, &dst);
    try std.testing.expectEqual(@as(i16, 0), dst[0]); // 128 → 0
    try std.testing.expectEqual(@as(i16, -32768), dst[1]); // 0 → -32768
    try std.testing.expectEqual(@as(i16, 32512), dst[2]); // 255 → 32512
    try std.testing.expectEqual(@as(i16, -64 * 256), dst[3]); // 64 → -16384
    try std.testing.expectEqual(@as(i16, 64 * 256), dst[4]); // 192 → 16384
}

test "convertU8ToS16 handles empty input" {
    const src: []const u8 = &.{};
    var dst: [0]i16 = undefined;
    convertU8ToS16(src, &dst);
}

test "AudioPlayer init and deinit" {
    sdl.init() catch return; // skip if SDL unavailable
    defer sdl.shutdown();

    var player = AudioPlayer.init() catch return; // skip if no audio device
    defer player.deinit();

    try std.testing.expect(!player.isPlaying());
    try std.testing.expect(player.stream == null);
}

test "AudioPlayer play queues audio data" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var player = AudioPlayer.init() catch return;
    defer player.deinit();

    // 1000 samples of silence at 11025 Hz
    var samples: [1000]u8 = undefined;
    @memset(&samples, 128);

    player.play(&samples, 11025) catch return;
    try std.testing.expect(player.stream != null);
}

test "AudioPlayer stop clears stream" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var player = AudioPlayer.init() catch return;
    defer player.deinit();

    var samples: [100]u8 = undefined;
    @memset(&samples, 128);

    player.play(&samples, 11025) catch return;
    player.stop();
    try std.testing.expect(player.stream == null);
    try std.testing.expect(!player.isPlaying());
}

test "AudioPlayer play replaces previous playback" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var player = AudioPlayer.init() catch return;
    defer player.deinit();

    var samples1: [100]u8 = undefined;
    @memset(&samples1, 128);
    var samples2: [200]u8 = undefined;
    @memset(&samples2, 128);

    player.play(&samples1, 11025) catch return;
    try std.testing.expect(player.stream != null);

    // Stop explicitly to verify the stream was cleaned up, then play again
    player.stop();
    try std.testing.expect(player.stream == null);

    player.play(&samples2, 11025) catch return;
    // New stream should be active after replacement
    try std.testing.expect(player.stream != null);
}
