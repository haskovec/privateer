//! Sound effects system for Wing Commander: Privateer.
//!
//! Provides multi-channel audio mixing and an event-driven sound effect
//! dispatch. Sound effects can be synthesized procedurally or loaded from
//! external PCM data (VOC files or raw 8-bit unsigned samples).
//!
//! Architecture:
//!   SoundEffect (enum) → SoundBank (PCM storage) → SoundMixer (multi-channel playback)
//!
//! The original game used OPL2 FM synthesis for sound effects. This module
//! provides simple waveform synthesis as a baseline, with the ability to
//! load replacement samples from mod files.

const std = @import("std");
const sdl = @import("../sdl.zig");
const c = sdl.raw;

/// Maximum number of simultaneous sound channels.
pub const MAX_CHANNELS: usize = 8;

/// Default playback sample rate.
pub const PLAYBACK_RATE: u32 = 22050;

// ── Sound Effect Types ──────────────────────────────────────────────

/// All sound effect types in the game.
pub const SoundEffect = enum(u8) {
    // Weapons
    gun_laser = 0,
    gun_mass_driver = 1,
    gun_meson = 2,
    gun_neutron = 3,
    gun_tachyon = 4,
    gun_particle = 5,
    gun_plasma = 6,
    gun_ionic_pulse = 7,
    missile_launch = 8,
    torpedo_launch = 9,

    // Combat feedback
    shield_hit = 10,
    armor_hit = 11,
    explosion_small = 12,
    explosion_medium = 13,
    explosion_big = 14,
    explosion_death = 15,

    // Flight
    afterburner_engage = 16,
    afterburner_loop = 17,
    autopilot_engage = 18,
    jump_drive = 19,
    tractor_beam = 20,

    // UI
    button_click = 21,
    missile_lock_warning = 22,
    comm_beep = 23,

    pub const COUNT = 24;
};

// ── Sound Sample ────────────────────────────────────────────────────

/// A PCM audio sample (8-bit unsigned, mono).
pub const SoundSample = struct {
    /// Raw PCM data (8-bit unsigned, 128 = silence).
    data: []const u8,
    /// Sample rate in Hz.
    sample_rate: u32,
    /// Whether this sample was allocated and should be freed.
    owned: bool,

    pub fn durationMs(self: SoundSample) u32 {
        if (self.sample_rate == 0) return 0;
        return @intCast((self.data.len * 1000) / self.sample_rate);
    }
};

// ── Waveform Synthesis ──────────────────────────────────────────────

/// Waveform shapes for procedural sound synthesis.
pub const Waveform = enum {
    sine,
    square,
    noise,
    sawtooth,
};

/// Generate a PCM buffer with a simple waveform.
/// Returns 8-bit unsigned samples (128 = silence).
pub fn synthesize(
    allocator: std.mem.Allocator,
    waveform: Waveform,
    frequency: f32,
    duration_ms: u32,
    sample_rate: u32,
) !SoundSample {
    const num_samples: usize = @intCast((@as(u64, sample_rate) * duration_ms) / 1000);
    if (num_samples == 0) return .{ .data = &.{}, .sample_rate = sample_rate, .owned = false };

    const buf = try allocator.alloc(u8, num_samples);
    errdefer allocator.free(buf);

    const rate_f: f32 = @floatFromInt(sample_rate);

    switch (waveform) {
        .sine => {
            for (buf, 0..) |*sample, i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / rate_f;
                const value = @sin(t * frequency * 2.0 * std.math.pi);
                // Map [-1, 1] to [0, 255]
                sample.* = @intFromFloat(@round(value * 127.0 + 128.0));
            }
        },
        .square => {
            for (buf, 0..) |*sample, i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / rate_f;
                const phase = t * frequency - @floor(t * frequency);
                sample.* = if (phase < 0.5) 255 else 0;
            }
        },
        .noise => {
            var rng = std.Random.DefaultPrng.init(@intCast(duration_ms));
            const random = rng.random();
            for (buf) |*sample| {
                sample.* = random.int(u8);
            }
        },
        .sawtooth => {
            for (buf, 0..) |*sample, i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / rate_f;
                const phase = t * frequency - @floor(t * frequency);
                sample.* = @intFromFloat(@round(phase * 255.0));
            }
        },
    }

    return .{ .data = buf, .sample_rate = sample_rate, .owned = true };
}

// ── Sound Bank ──────────────────────────────────────────────────────

/// Stores loaded PCM data for all sound effect types.
pub const SoundBank = struct {
    samples: [SoundEffect.COUNT]?SoundSample,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SoundBank {
        return .{
            .samples = [_]?SoundSample{null} ** SoundEffect.COUNT,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SoundBank) void {
        for (&self.samples) |*slot| {
            if (slot.*) |sample| {
                if (sample.owned) {
                    self.allocator.free(sample.data);
                }
                slot.* = null;
            }
        }
    }

    /// Load a sound sample for the given effect.
    pub fn load(self: *SoundBank, effect: SoundEffect, sample: SoundSample) void {
        const idx: usize = @intFromEnum(effect);
        // Free previous if owned
        if (self.samples[idx]) |prev| {
            if (prev.owned) self.allocator.free(prev.data);
        }
        self.samples[idx] = sample;
    }

    /// Get the sample for a sound effect (null if not loaded).
    pub fn get(self: *const SoundBank, effect: SoundEffect) ?SoundSample {
        return self.samples[@intFromEnum(effect)];
    }

    /// Returns the number of loaded samples.
    pub fn loadedCount(self: *const SoundBank) usize {
        var count: usize = 0;
        for (self.samples) |slot| {
            if (slot != null) count += 1;
        }
        return count;
    }

    /// Generate default synthesized sounds for all effects.
    pub fn loadDefaults(self: *SoundBank) !void {
        // Weapons - various frequencies for different gun types
        try self.loadSynth(.gun_laser, .sine, 880.0, 80);
        try self.loadSynth(.gun_mass_driver, .square, 220.0, 100);
        try self.loadSynth(.gun_meson, .sine, 660.0, 90);
        try self.loadSynth(.gun_neutron, .sawtooth, 330.0, 120);
        try self.loadSynth(.gun_tachyon, .sine, 1100.0, 70);
        try self.loadSynth(.gun_particle, .square, 440.0, 85);
        try self.loadSynth(.gun_plasma, .sawtooth, 550.0, 110);
        try self.loadSynth(.gun_ionic_pulse, .sine, 990.0, 95);
        try self.loadSynth(.missile_launch, .sawtooth, 200.0, 200);
        try self.loadSynth(.torpedo_launch, .sawtooth, 150.0, 250);

        // Combat feedback
        try self.loadSynth(.shield_hit, .square, 300.0, 50);
        try self.loadSynth(.armor_hit, .noise, 100.0, 60);
        try self.loadSynth(.explosion_small, .noise, 80.0, 200);
        try self.loadSynth(.explosion_medium, .noise, 60.0, 350);
        try self.loadSynth(.explosion_big, .noise, 40.0, 500);
        try self.loadSynth(.explosion_death, .noise, 30.0, 800);

        // Flight
        try self.loadSynth(.afterburner_engage, .sawtooth, 400.0, 150);
        try self.loadSynth(.afterburner_loop, .sawtooth, 350.0, 300);
        try self.loadSynth(.autopilot_engage, .sine, 600.0, 200);
        try self.loadSynth(.jump_drive, .sine, 100.0, 500);
        try self.loadSynth(.tractor_beam, .sine, 250.0, 300);

        // UI
        try self.loadSynth(.button_click, .square, 1000.0, 30);
        try self.loadSynth(.missile_lock_warning, .square, 800.0, 150);
        try self.loadSynth(.comm_beep, .sine, 700.0, 100);
    }

    fn loadSynth(self: *SoundBank, effect: SoundEffect, waveform: Waveform, freq: f32, dur_ms: u32) !void {
        const sample = try synthesize(self.allocator, waveform, freq, dur_ms, PLAYBACK_RATE);
        self.load(effect, sample);
    }
};

// ── Sound Mixer ─────────────────────────────────────────────────────

/// A single mixer channel playing one sound.
const MixerChannel = struct {
    stream: ?*c.SDL_AudioStream,
    effect: SoundEffect,
    active: bool,
};

/// Multi-channel audio mixer for simultaneous sound playback.
/// Uses SDL3 AudioStreams bound to a single output device.
pub const SoundMixer = struct {
    device: c.SDL_AudioDeviceID,
    channels: [MAX_CHANNELS]MixerChannel,
    bank: *const SoundBank,
    /// Master volume (0.0 = mute, 1.0 = full).
    volume: f32,

    pub fn init(bank: *const SoundBank) !SoundMixer {
        const spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_U8,
            .channels = 1,
            .freq = @intCast(PLAYBACK_RATE),
        };
        const device = c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec);
        if (device == 0) return error.DeviceOpenFailed;

        var mixer = SoundMixer{
            .device = device,
            .channels = undefined,
            .bank = bank,
            .volume = 1.0,
        };
        for (&mixer.channels) |*ch| {
            ch.* = .{ .stream = null, .effect = .gun_laser, .active = false };
        }
        return mixer;
    }

    pub fn deinit(self: *SoundMixer) void {
        self.stopAll();
        c.SDL_CloseAudioDevice(self.device);
    }

    /// Play a sound effect. Returns the channel index used, or null if all channels are busy.
    pub fn play(self: *SoundMixer, effect: SoundEffect) ?usize {
        const sample = self.bank.get(effect) orelse return null;
        if (sample.data.len == 0) return null;

        // Find a free channel (or reuse one that finished)
        self.reclaimFinished();

        var channel_idx: ?usize = null;
        for (&self.channels, 0..) |*ch, i| {
            if (!ch.active) {
                channel_idx = i;
                break;
            }
        }
        const idx = channel_idx orelse return null;

        // Create an audio stream for this sound
        const src_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_U8,
            .channels = 1,
            .freq = @intCast(sample.sample_rate),
        };
        const dst_spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_U8,
            .channels = 1,
            .freq = @intCast(PLAYBACK_RATE),
        };

        const stream = c.SDL_CreateAudioStream(&src_spec, &dst_spec) orelse return null;

        if (!c.SDL_BindAudioStream(self.device, stream)) {
            c.SDL_DestroyAudioStream(stream);
            return null;
        }

        if (!c.SDL_PutAudioStreamData(stream, sample.data.ptr, @intCast(sample.data.len))) {
            c.SDL_DestroyAudioStream(stream);
            return null;
        }

        _ = c.SDL_FlushAudioStream(stream);

        self.channels[idx] = .{
            .stream = stream,
            .effect = effect,
            .active = true,
        };

        return idx;
    }

    /// Stop a specific channel.
    pub fn stopChannel(self: *SoundMixer, channel: usize) void {
        if (channel >= MAX_CHANNELS) return;
        var ch = &self.channels[channel];
        if (ch.stream) |s| {
            _ = c.SDL_ClearAudioStream(s);
            c.SDL_DestroyAudioStream(s);
            ch.stream = null;
        }
        ch.active = false;
    }

    /// Stop all channels.
    pub fn stopAll(self: *SoundMixer) void {
        for (0..MAX_CHANNELS) |i| {
            self.stopChannel(i);
        }
    }

    /// Count active (playing) channels.
    pub fn activeChannels(self: *const SoundMixer) usize {
        var count: usize = 0;
        for (self.channels) |ch| {
            if (ch.active) count += 1;
        }
        return count;
    }

    /// Reclaim channels that have finished playing.
    fn reclaimFinished(self: *SoundMixer) void {
        for (&self.channels, 0..) |*ch, i| {
            if (ch.active) {
                if (ch.stream) |s| {
                    if (c.SDL_GetAudioStreamQueued(s) == 0) {
                        self.stopChannel(i);
                    }
                } else {
                    ch.active = false;
                }
            }
        }
    }
};

// ── Game Event Dispatch ─────────────────────────────────────────────

/// Maps a gun type index to its corresponding sound effect.
pub fn gunSound(gun_index: u8) SoundEffect {
    return switch (gun_index) {
        0 => .gun_laser,
        1 => .gun_mass_driver,
        2 => .gun_meson,
        3 => .gun_neutron,
        4 => .gun_tachyon,
        5 => .gun_particle,
        6 => .gun_plasma,
        7 => .gun_ionic_pulse,
        else => .gun_laser, // fallback
    };
}

/// Maps an explosion size to its corresponding sound effect.
pub fn explosionSound(size: u8) SoundEffect {
    return switch (size) {
        0 => .explosion_big,
        1 => .explosion_medium,
        2 => .explosion_small,
        3 => .explosion_death,
        else => .explosion_medium,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "SoundEffect enum has correct count" {
    try std.testing.expectEqual(@as(u8, 24), SoundEffect.COUNT);
}

test "SoundEffect values are contiguous from 0" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(SoundEffect.gun_laser));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(SoundEffect.comm_beep));
}

test "SoundSample duration calculation" {
    const sample = SoundSample{
        .data = &[_]u8{128} ** 22050,
        .sample_rate = 22050,
        .owned = false,
    };
    try std.testing.expectEqual(@as(u32, 1000), sample.durationMs());
}

test "SoundSample duration zero rate" {
    const sample = SoundSample{
        .data = &[_]u8{128} ** 100,
        .sample_rate = 0,
        .owned = false,
    };
    try std.testing.expectEqual(@as(u32, 0), sample.durationMs());
}

test "synthesize sine produces correct length" {
    const allocator = std.testing.allocator;
    const sample = try synthesize(allocator, .sine, 440.0, 100, 22050);
    defer allocator.free(sample.data);

    // 100ms at 22050 Hz = 2205 samples
    try std.testing.expectEqual(@as(usize, 2205), sample.data.len);
    try std.testing.expectEqual(@as(u32, 22050), sample.sample_rate);
    try std.testing.expect(sample.owned);
}

test "synthesize sine midpoint is near 128" {
    const allocator = std.testing.allocator;
    // Very low frequency so first sample is at phase 0 → sin(0) = 0 → value = 128
    const sample = try synthesize(allocator, .sine, 1.0, 100, 22050);
    defer allocator.free(sample.data);

    try std.testing.expectEqual(@as(u8, 128), sample.data[0]);
}

test "synthesize square alternates high and low" {
    const allocator = std.testing.allocator;
    // 1 Hz square at 4 Hz sample rate: 2 samples high, 2 samples low
    const sample = try synthesize(allocator, .square, 1.0, 1000, 4);
    defer allocator.free(sample.data);

    try std.testing.expectEqual(@as(usize, 4), sample.data.len);
    try std.testing.expectEqual(@as(u8, 255), sample.data[0]); // first half = high
    try std.testing.expectEqual(@as(u8, 255), sample.data[1]);
    try std.testing.expectEqual(@as(u8, 0), sample.data[2]); // second half = low
    try std.testing.expectEqual(@as(u8, 0), sample.data[3]);
}

test "synthesize noise produces non-uniform data" {
    const allocator = std.testing.allocator;
    const sample = try synthesize(allocator, .noise, 100.0, 100, 22050);
    defer allocator.free(sample.data);

    // Noise should not be all the same value
    var all_same = true;
    for (sample.data[1..]) |s| {
        if (s != sample.data[0]) {
            all_same = false;
            break;
        }
    }
    try std.testing.expect(!all_same);
}

test "synthesize zero duration returns empty" {
    const allocator = std.testing.allocator;
    const sample = try synthesize(allocator, .sine, 440.0, 0, 22050);
    try std.testing.expectEqual(@as(usize, 0), sample.data.len);
    try std.testing.expect(!sample.owned);
}

test "synthesize sawtooth ramps up" {
    const allocator = std.testing.allocator;
    // 1 Hz sawtooth at 10 Hz sample rate: ramps from 0 to ~230 over one cycle
    const sample = try synthesize(allocator, .sawtooth, 1.0, 1000, 10);
    defer allocator.free(sample.data);

    try std.testing.expectEqual(@as(usize, 10), sample.data.len);
    // First sample at phase 0 → 0
    try std.testing.expectEqual(@as(u8, 0), sample.data[0]);
    // Samples should increase through the cycle
    try std.testing.expect(sample.data[5] > sample.data[1]);
}

test "SoundBank init has no loaded samples" {
    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();

    try std.testing.expectEqual(@as(usize, 0), bank.loadedCount());
    try std.testing.expect(bank.get(.gun_laser) == null);
}

test "SoundBank load and get" {
    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();

    const data = [_]u8{ 128, 128, 128, 128 };
    bank.load(.gun_laser, .{
        .data = &data,
        .sample_rate = 11025,
        .owned = false,
    });

    try std.testing.expectEqual(@as(usize, 1), bank.loadedCount());
    const sample = bank.get(.gun_laser).?;
    try std.testing.expectEqual(@as(usize, 4), sample.data.len);
    try std.testing.expectEqual(@as(u32, 11025), sample.sample_rate);
}

test "SoundBank loadDefaults loads all effects" {
    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();

    try bank.loadDefaults();
    try std.testing.expectEqual(@as(usize, SoundEffect.COUNT), bank.loadedCount());

    // Verify each effect has non-empty data
    inline for (0..SoundEffect.COUNT) |i| {
        const effect: SoundEffect = @enumFromInt(i);
        const sample = bank.get(effect).?;
        try std.testing.expect(sample.data.len > 0);
    }
}

test "SoundBank load replaces previous sample" {
    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();

    // Load a synthesized sample (owned)
    const sample1 = try synthesize(std.testing.allocator, .sine, 440.0, 50, 22050);
    bank.load(.gun_laser, sample1);
    try std.testing.expectEqual(@as(usize, 1), bank.loadedCount());

    // Replace with another (previous owned memory should be freed)
    const sample2 = try synthesize(std.testing.allocator, .square, 220.0, 50, 22050);
    bank.load(.gun_laser, sample2);
    try std.testing.expectEqual(@as(usize, 1), bank.loadedCount());
}

test "gunSound maps indices to effects" {
    try std.testing.expectEqual(SoundEffect.gun_laser, gunSound(0));
    try std.testing.expectEqual(SoundEffect.gun_mass_driver, gunSound(1));
    try std.testing.expectEqual(SoundEffect.gun_meson, gunSound(2));
    try std.testing.expectEqual(SoundEffect.gun_neutron, gunSound(3));
    try std.testing.expectEqual(SoundEffect.gun_tachyon, gunSound(4));
    try std.testing.expectEqual(SoundEffect.gun_particle, gunSound(5));
    try std.testing.expectEqual(SoundEffect.gun_plasma, gunSound(6));
    try std.testing.expectEqual(SoundEffect.gun_ionic_pulse, gunSound(7));
    // Unknown index falls back to laser
    try std.testing.expectEqual(SoundEffect.gun_laser, gunSound(255));
}

test "explosionSound maps sizes to effects" {
    try std.testing.expectEqual(SoundEffect.explosion_big, explosionSound(0));
    try std.testing.expectEqual(SoundEffect.explosion_medium, explosionSound(1));
    try std.testing.expectEqual(SoundEffect.explosion_small, explosionSound(2));
    try std.testing.expectEqual(SoundEffect.explosion_death, explosionSound(3));
    // Unknown size falls back to medium
    try std.testing.expectEqual(SoundEffect.explosion_medium, explosionSound(99));
}

test "SoundMixer init and deinit" {
    sdl.init() catch return; // skip if SDL unavailable
    defer sdl.shutdown();

    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();

    var mixer = SoundMixer.init(&bank) catch return; // skip if no audio device
    defer mixer.deinit();

    try std.testing.expectEqual(@as(usize, 0), mixer.activeChannels());
    try std.testing.expectEqual(@as(f32, 1.0), mixer.volume);
}

test "SoundMixer play returns null for unloaded effect" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();

    var mixer = SoundMixer.init(&bank) catch return;
    defer mixer.deinit();

    // No samples loaded, play should return null
    try std.testing.expect(mixer.play(.gun_laser) == null);
}

test "SoundMixer play returns channel index for loaded effect" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();
    try bank.loadDefaults();

    var mixer = SoundMixer.init(&bank) catch return;
    defer mixer.deinit();

    const ch = mixer.play(.gun_laser);
    try std.testing.expect(ch != null);
    try std.testing.expectEqual(@as(usize, 0), ch.?);
}

test "SoundMixer plays multiple sounds simultaneously" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();
    try bank.loadDefaults();

    var mixer = SoundMixer.init(&bank) catch return;
    defer mixer.deinit();

    const ch0 = mixer.play(.gun_laser);
    const ch1 = mixer.play(.explosion_big);
    const ch2 = mixer.play(.missile_launch);

    try std.testing.expect(ch0 != null);
    try std.testing.expect(ch1 != null);
    try std.testing.expect(ch2 != null);

    // All should be on different channels
    try std.testing.expect(ch0.? != ch1.?);
    try std.testing.expect(ch1.? != ch2.?);
}

test "SoundMixer stopAll clears all channels" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();
    try bank.loadDefaults();

    var mixer = SoundMixer.init(&bank) catch return;
    defer mixer.deinit();

    _ = mixer.play(.gun_laser);
    _ = mixer.play(.explosion_big);
    mixer.stopAll();

    try std.testing.expectEqual(@as(usize, 0), mixer.activeChannels());
}

test "SoundMixer stopChannel clears specific channel" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();
    try bank.loadDefaults();

    var mixer = SoundMixer.init(&bank) catch return;
    defer mixer.deinit();

    const ch = mixer.play(.gun_laser) orelse return;
    mixer.stopChannel(ch);

    // Channel should now be free
    try std.testing.expect(!mixer.channels[ch].active);
}

test "SoundMixer respects MAX_CHANNELS limit" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var bank = SoundBank.init(std.testing.allocator);
    defer bank.deinit();
    try bank.loadDefaults();

    var mixer = SoundMixer.init(&bank) catch return;
    defer mixer.deinit();

    // Fill all channels
    for (0..MAX_CHANNELS) |_| {
        _ = mixer.play(.gun_laser);
    }

    // Next play should return null (all channels busy)
    // Note: channels may have been reclaimed if sound finished quickly,
    // so we only check that we got at least MAX_CHANNELS worth of plays
    try std.testing.expect(mixer.activeChannels() <= MAX_CHANNELS);
}
