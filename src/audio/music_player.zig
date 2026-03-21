//! Music playback system for Wing Commander: Privateer.
//!
//! Provides XMIDI event decoding, PCM audio synthesis from MIDI events,
//! looping music playback via SDL3 AudioStream, and a state machine that
//! selects the appropriate music track based on game state.
//!
//! Music tracks from the original game:
//!   BASETUNE - Landing base theme
//!   COMBAT   - Combat encounter music
//!   CREDITS  - Credits sequence
//!   OPENING  - Title screen / opening
//!   VICTORY  - Mission success fanfare
//!
//! Architecture:
//!   GameState → MusicStateMachine → MusicState → MusicPlayer (SDL3 AudioStream)
//!                                       ↓
//!   XMIDI EVNT data → decodeXmidiEvents → renderEventsToPcm → PCM buffer

const std = @import("std");
const sdl = @import("../sdl.zig");
const c = sdl.raw;
const game_state = @import("../game/game_state.zig");

// ── Music State ─────────────────────────────────────────────────────

/// Music context determining which track should play.
pub const MusicState = enum {
    /// No music (silence).
    none,
    /// Title/opening screen (OPENING track).
    opening,
    /// Landed at a base (BASETUNE track).
    base,
    /// In combat with hostiles (COMBAT track).
    combat,
    /// Mission victory (VICTORY track).
    victory,
    /// End credits (CREDITS track).
    credits,
};

/// Map a game state to the appropriate music state.
/// Returns null when the music should not change (e.g., during conversations
/// or animations, the current track keeps playing).
pub fn musicForGameState(state: game_state.State) ?MusicState {
    return switch (state) {
        .intro_movie => null,
        .title => .opening,
        .loading => null,
        .space_flight => .none,
        .landed => .base,
        .conversation => null,
        .combat => .combat,
        .dead => .none,
        .animation => null,
        .options => null,
    };
}

// ── XMIDI Event Decoder ─────────────────────────────────────────────

/// Decoded MIDI event types.
pub const EventType = enum {
    note_on,
    note_off,
    program_change,
    control_change,
    end_of_track,
};

/// A decoded MIDI event with absolute timing.
pub const MidiEvent = struct {
    /// Absolute tick position in the sequence.
    tick: u32,
    /// Event type.
    event_type: EventType,
    /// MIDI channel (0-15).
    channel: u4,
    /// First data byte (note number / program / controller).
    data1: u8,
    /// Second data byte (velocity / value).
    data2: u8,
    /// Note duration in ticks (XMIDI note-on extension; 0 for other events).
    duration: u32,
};

pub const DecodeError = error{
    UnexpectedEnd,
    InvalidEvent,
    OutOfMemory,
};

/// Read a MIDI variable-length quantity from the data stream.
fn readVlq(data: []const u8, pos: *usize) DecodeError!u32 {
    var value: u32 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        value = (value << 7) | @as(u32, b & 0x7F);
        if (b & 0x80 == 0) return value;
    }
    return DecodeError.UnexpectedEnd;
}

/// Decode raw XMIDI EVNT data into a sorted list of timed MIDI events.
/// The caller owns the returned slice and must free it with `allocator`.
pub fn decodeXmidiEvents(allocator: std.mem.Allocator, evnt_data: []const u8) DecodeError![]MidiEvent {
    var events: std.ArrayListUnmanaged(MidiEvent) = .empty;
    errdefer events.deinit(allocator);

    var pos: usize = 0;
    var tick: u32 = 0;

    while (pos < evnt_data.len) {
        // Accumulate delay bytes (0x00-0x7F between events)
        while (pos < evnt_data.len and evnt_data[pos] < 0x80) {
            tick += evnt_data[pos];
            pos += 1;
        }
        if (pos >= evnt_data.len) break;

        const status = evnt_data[pos];
        pos += 1;
        const channel: u4 = @intCast(status & 0x0F);
        const msg_type = status & 0xF0;

        switch (msg_type) {
            0x90 => {
                // Note On with XMIDI duration extension
                if (pos + 2 > evnt_data.len) return DecodeError.UnexpectedEnd;
                const note = evnt_data[pos];
                const velocity = evnt_data[pos + 1];
                pos += 2;
                const dur = try readVlq(evnt_data, &pos);

                if (velocity > 0) {
                    events.append(allocator, .{
                        .tick = tick,
                        .event_type = .note_on,
                        .channel = channel,
                        .data1 = note,
                        .data2 = velocity,
                        .duration = dur,
                    }) catch return DecodeError.OutOfMemory;
                    // Generate implied note-off at end of duration
                    events.append(allocator, .{
                        .tick = tick + dur,
                        .event_type = .note_off,
                        .channel = channel,
                        .data1 = note,
                        .data2 = 0,
                        .duration = 0,
                    }) catch return DecodeError.OutOfMemory;
                }
            },
            0x80 => {
                // Explicit Note Off (2 data bytes)
                if (pos + 2 > evnt_data.len) return DecodeError.UnexpectedEnd;
                events.append(allocator, .{
                    .tick = tick,
                    .event_type = .note_off,
                    .channel = channel,
                    .data1 = evnt_data[pos],
                    .data2 = evnt_data[pos + 1],
                    .duration = 0,
                }) catch return DecodeError.OutOfMemory;
                pos += 2;
            },
            0xC0 => {
                // Program Change (1 data byte)
                if (pos >= evnt_data.len) return DecodeError.UnexpectedEnd;
                events.append(allocator, .{
                    .tick = tick,
                    .event_type = .program_change,
                    .channel = channel,
                    .data1 = evnt_data[pos],
                    .data2 = 0,
                    .duration = 0,
                }) catch return DecodeError.OutOfMemory;
                pos += 1;
            },
            0xB0 => {
                // Control Change (2 data bytes)
                if (pos + 2 > evnt_data.len) return DecodeError.UnexpectedEnd;
                events.append(allocator, .{
                    .tick = tick,
                    .event_type = .control_change,
                    .channel = channel,
                    .data1 = evnt_data[pos],
                    .data2 = evnt_data[pos + 1],
                    .duration = 0,
                }) catch return DecodeError.OutOfMemory;
                pos += 2;
            },
            0xA0, 0xE0 => {
                // Polyphonic aftertouch / Pitch bend (2 data bytes) - skip
                if (pos + 2 > evnt_data.len) return DecodeError.UnexpectedEnd;
                pos += 2;
            },
            0xD0 => {
                // Channel pressure (1 data byte) - skip
                if (pos >= evnt_data.len) return DecodeError.UnexpectedEnd;
                pos += 1;
            },
            0xF0 => {
                if (status == 0xFF) {
                    // Meta event
                    if (pos >= evnt_data.len) return DecodeError.UnexpectedEnd;
                    const meta_type = evnt_data[pos];
                    pos += 1;
                    const length = try readVlq(evnt_data, &pos);

                    if (meta_type == 0x2F) {
                        events.append(allocator, .{
                            .tick = tick,
                            .event_type = .end_of_track,
                            .channel = 0,
                            .data1 = 0,
                            .data2 = 0,
                            .duration = 0,
                        }) catch return DecodeError.OutOfMemory;
                        break;
                    }
                    // Skip other meta events
                    if (pos + length > evnt_data.len) return DecodeError.UnexpectedEnd;
                    pos += @intCast(length);
                } else if (status == 0xF0 or status == 0xF7) {
                    // SysEx - read length and skip
                    const length = try readVlq(evnt_data, &pos);
                    if (pos + length > evnt_data.len) return DecodeError.UnexpectedEnd;
                    pos += @intCast(length);
                } else {
                    return DecodeError.InvalidEvent;
                }
            },
            else => return DecodeError.InvalidEvent,
        }
    }

    // Sort events by tick for correct temporal processing
    const items = events.items;
    std.sort.pdq(MidiEvent, items, {}, lessThanByTick);

    return events.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
}

fn lessThanByTick(_: void, a: MidiEvent, b: MidiEvent) bool {
    if (a.tick != b.tick) return a.tick < b.tick;
    // note_off before note_on at same tick (clean release before re-trigger)
    const a_pri: u8 = if (a.event_type == .note_off) 0 else if (a.event_type == .end_of_track) 2 else 1;
    const b_pri: u8 = if (b.event_type == .note_off) 0 else if (b.event_type == .end_of_track) 2 else 1;
    return a_pri < b_pri;
}

// ── PCM Synthesis ───────────────────────────────────────────────────

/// XMIDI timing: 120 ticks per quarter note, 120 BPM default.
pub const XMIDI_PPQN: u32 = 120;
const DEFAULT_TEMPO_US: u32 = 500_000;

/// Number of PCM samples per XMIDI tick at the given sample rate.
pub fn samplesPerTick(sample_rate: u32) f64 {
    const us_per_tick: f64 = @as(f64, @floatFromInt(DEFAULT_TEMPO_US)) / @as(f64, @floatFromInt(XMIDI_PPQN));
    return @as(f64, @floatFromInt(sample_rate)) * us_per_tick / 1_000_000.0;
}

/// Convert a MIDI note number to frequency in Hz.
/// A4 (note 69) = 440 Hz.
pub fn noteToFreq(note: u8) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(note)) - 69.0) / 12.0);
}

const ActiveNote = struct {
    channel: u4,
    note: u8,
    velocity: u8,
    frequency: f32,
    phase: f32,
    end_tick: u32,
    active: bool,
};

const MAX_ACTIVE_NOTES = 32;

/// Render decoded MIDI events to PCM audio (8-bit unsigned mono).
/// Returns an owned slice the caller must free.
pub fn renderEventsToPcm(
    allocator: std.mem.Allocator,
    events: []const MidiEvent,
    sample_rate: u32,
) ![]u8 {
    if (events.len == 0) return try allocator.alloc(u8, 0);

    // Find the last tick considering note durations
    var max_tick: u32 = 0;
    for (events) |evt| {
        const end = if (evt.event_type == .note_on) evt.tick + evt.duration else evt.tick;
        if (end > max_tick) max_tick = end;
    }
    // Add a small tail
    max_tick += XMIDI_PPQN / 4;

    const spt = samplesPerTick(sample_rate);
    const total_samples: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(max_tick)) * spt));
    if (total_samples == 0) return try allocator.alloc(u8, 0);

    const pcm = try allocator.alloc(u8, total_samples);
    @memset(pcm, 128); // silence

    var notes: [MAX_ACTIVE_NOTES]ActiveNote = undefined;
    for (&notes) |*n| n.active = false;

    var event_idx: usize = 0;
    const rate_f: f32 = @floatFromInt(sample_rate);

    for (0..total_samples) |sample_i| {
        const current_tick: u32 = @intFromFloat(@as(f64, @floatFromInt(sample_i)) / spt);

        // Process events at or before this sample's tick
        while (event_idx < events.len and events[event_idx].tick <= current_tick) {
            const evt = events[event_idx];
            switch (evt.event_type) {
                .note_on => {
                    for (&notes) |*n| {
                        if (!n.active) {
                            n.* = .{
                                .channel = evt.channel,
                                .note = evt.data1,
                                .velocity = evt.data2,
                                .frequency = noteToFreq(evt.data1),
                                .phase = 0,
                                .end_tick = evt.tick + evt.duration,
                                .active = true,
                            };
                            break;
                        }
                    }
                },
                .note_off => {
                    for (&notes) |*n| {
                        if (n.active and n.channel == evt.channel and n.note == evt.data1) {
                            n.active = false;
                            break;
                        }
                    }
                },
                .end_of_track, .program_change, .control_change => {},
            }
            event_idx += 1;
        }

        // Deactivate notes past their end tick
        for (&notes) |*n| {
            if (n.active and n.end_tick <= current_tick) n.active = false;
        }

        // Mix active notes (sine wave synthesis)
        var mix: f32 = 0;
        var active_count: u32 = 0;
        for (&notes) |*n| {
            if (n.active) {
                const value = @sin(n.phase * 2.0 * std.math.pi);
                const vel_scale: f32 = @as(f32, @floatFromInt(n.velocity)) / 127.0;
                mix += value * vel_scale * 0.3;
                n.phase += n.frequency / rate_f;
                if (n.phase >= 1.0) n.phase -= 1.0;
                active_count += 1;
            }
        }

        if (active_count > 0) {
            const limited = std.math.clamp(mix, -1.0, 1.0);
            pcm[sample_i] = @intFromFloat(@round(limited * 127.0 + 128.0));
        }
    }

    return pcm;
}

// ── Music Player ────────────────────────────────────────────────────

/// Looping music player using SDL3 AudioStream.
pub const MusicPlayer = struct {
    device: c.SDL_AudioDeviceID,
    stream: ?*c.SDL_AudioStream,
    pcm_data: ?[]const u8,
    loop_enabled: bool,
    current_state: MusicState,
    volume: f32,
    allocator: std.mem.Allocator,

    pub const SAMPLE_RATE: u32 = 22050;
    const REFILL_THRESHOLD: usize = SAMPLE_RATE; // ~1 second of audio

    pub fn init(allocator: std.mem.Allocator) !MusicPlayer {
        const spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_U8,
            .channels = 1,
            .freq = @intCast(SAMPLE_RATE),
        };
        const device = c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec);
        if (device == 0) return error.DeviceOpenFailed;

        return .{
            .device = device,
            .stream = null,
            .pcm_data = null,
            .loop_enabled = true,
            .current_state = .none,
            .volume = 0.7,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MusicPlayer) void {
        self.stop();
        c.SDL_CloseAudioDevice(self.device);
    }

    /// Start playing a PCM buffer. Takes ownership of the data.
    pub fn playPcm(self: *MusicPlayer, pcm: []const u8, state: MusicState) void {
        self.stop();

        const src_spec = c.SDL_AudioSpec{ .format = c.SDL_AUDIO_U8, .channels = 1, .freq = @intCast(SAMPLE_RATE) };
        const stream = c.SDL_CreateAudioStream(&src_spec, &src_spec) orelse return;

        if (!c.SDL_BindAudioStream(self.device, stream)) {
            c.SDL_DestroyAudioStream(stream);
            return;
        }

        if (pcm.len > 0) {
            _ = c.SDL_PutAudioStreamData(stream, pcm.ptr, @intCast(pcm.len));
            _ = c.SDL_FlushAudioStream(stream);
        }

        self.stream = stream;
        self.pcm_data = pcm;
        self.current_state = state;
    }

    /// Stop playback and free PCM data.
    pub fn stop(self: *MusicPlayer) void {
        if (self.stream) |s| {
            _ = c.SDL_ClearAudioStream(s);
            c.SDL_DestroyAudioStream(s);
            self.stream = null;
        }
        if (self.pcm_data) |data| {
            self.allocator.free(data);
            self.pcm_data = null;
        }
        self.current_state = .none;
    }

    /// Call each frame to handle looping.
    pub fn update(self: *MusicPlayer) void {
        if (!self.loop_enabled) return;
        const s = self.stream orelse return;
        const data = self.pcm_data orelse return;
        if (data.len == 0) return;

        const queued: usize = @intCast(c.SDL_GetAudioStreamQueued(s));
        if (queued < REFILL_THRESHOLD) {
            _ = c.SDL_PutAudioStreamData(s, data.ptr, @intCast(data.len));
            _ = c.SDL_FlushAudioStream(s);
        }
    }

    /// Check if music is currently playing.
    pub fn isPlaying(self: *const MusicPlayer) bool {
        const s = self.stream orelse return false;
        return c.SDL_GetAudioStreamQueued(s) > 0;
    }
};

// ── Music State Machine ─────────────────────────────────────────────

/// Manages music transitions based on game state changes.
pub const MusicStateMachine = struct {
    current: MusicState,
    previous_game_state: ?game_state.State,

    pub fn init() MusicStateMachine {
        return .{
            .current = .none,
            .previous_game_state = null,
        };
    }

    /// Process a game state change and return the new music state
    /// if music should change, or null if no change is needed.
    pub fn processStateChange(self: *MusicStateMachine, new_state: game_state.State) ?MusicState {
        defer self.previous_game_state = new_state;

        const target = musicForGameState(new_state) orelse return null;
        if (target == self.current) return null;

        self.current = target;
        return target;
    }

    /// Force a music state (e.g., for victory fanfare).
    pub fn force(self: *MusicStateMachine, state: MusicState) void {
        self.current = state;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "musicForGameState maps title to opening" {
    try std.testing.expectEqual(MusicState.opening, musicForGameState(.title).?);
}

test "musicForGameState maps landed to base" {
    try std.testing.expectEqual(MusicState.base, musicForGameState(.landed).?);
}

test "musicForGameState maps combat to combat" {
    try std.testing.expectEqual(MusicState.combat, musicForGameState(.combat).?);
}

test "musicForGameState maps space_flight to none" {
    try std.testing.expectEqual(MusicState.none, musicForGameState(.space_flight).?);
}

test "musicForGameState maps dead to none" {
    try std.testing.expectEqual(MusicState.none, musicForGameState(.dead).?);
}

test "musicForGameState returns null for conversation (no change)" {
    try std.testing.expect(musicForGameState(.conversation) == null);
}

test "musicForGameState returns null for animation (no change)" {
    try std.testing.expect(musicForGameState(.animation) == null);
}

test "musicForGameState returns null for loading (no change)" {
    try std.testing.expect(musicForGameState(.loading) == null);
}

// XMIDI decoder tests

test "decode end-of-track only" {
    const allocator = std.testing.allocator;
    const evnt = [_]u8{ 0xFF, 0x2F, 0x00 };
    const events = try decodeXmidiEvents(allocator, &evnt);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(EventType.end_of_track, events[0].event_type);
    try std.testing.expectEqual(@as(u32, 0), events[0].tick);
}

test "decode note-on with duration" {
    const allocator = std.testing.allocator;
    // Note On: ch 0, note 48, vel 80, dur 24; End of track
    const evnt = [_]u8{ 0x90, 48, 80, 24, 0xFF, 0x2F, 0x00 };
    const events = try decodeXmidiEvents(allocator, &evnt);
    defer allocator.free(events);

    // Expect: note_on, note_off (implied), end_of_track (sorted by tick)
    try std.testing.expectEqual(@as(usize, 3), events.len);

    // tick 0: end_of_track and note_on (end_of_track sorted after note_on? Let me check)
    // Actually with sorting: tick 0 events = note_on (pri 1), end_of_track (pri 2)
    // tick 24: note_off (pri 0)
    // Sorted: note_on(0), end_of_track(0), note_off(24)
    // Wait, note_off at tick 24 has pri 0, but it's at a later tick. Let me re-check.
    // Sort is by tick first, then priority. So:
    // tick 0: note_on, end_of_track (note_on pri=1, end_of_track pri=2)
    // tick 24: note_off (pri=0)
    // Result: [note_on@0, end_of_track@0, note_off@24]
    try std.testing.expectEqual(EventType.note_on, events[0].event_type);
    try std.testing.expectEqual(@as(u32, 0), events[0].tick);
    try std.testing.expectEqual(@as(u8, 48), events[0].data1);
    try std.testing.expectEqual(@as(u8, 80), events[0].data2);
    try std.testing.expectEqual(@as(u32, 24), events[0].duration);

    try std.testing.expectEqual(EventType.end_of_track, events[1].event_type);
    try std.testing.expectEqual(@as(u32, 0), events[1].tick);

    try std.testing.expectEqual(EventType.note_off, events[2].event_type);
    try std.testing.expectEqual(@as(u32, 24), events[2].tick);
    try std.testing.expectEqual(@as(u8, 48), events[2].data1);
}

test "decode with delay between notes" {
    const allocator = std.testing.allocator;
    const evnt = [_]u8{
        0x90, 60, 100, 24, // Note On C4, vel 100, dur 24 at tick 0
        24, // Delay 24 ticks
        0x90, 64, 80,  24, // Note On E4, vel 80, dur 24 at tick 24
        0xFF, 0x2F, 0x00, // End of track at tick 24
    };
    const events = try decodeXmidiEvents(allocator, &evnt);
    defer allocator.free(events);

    // Expected sorted events:
    // tick 0: note_on(60)
    // tick 24: note_off(60), note_on(64), end_of_track
    // tick 48: note_off(64)
    try std.testing.expectEqual(@as(usize, 5), events.len);

    try std.testing.expectEqual(EventType.note_on, events[0].event_type);
    try std.testing.expectEqual(@as(u32, 0), events[0].tick);
    try std.testing.expectEqual(@as(u8, 60), events[0].data1);

    // tick 24: note_off(60) first (pri 0), then note_on(64) (pri 1), then end_of_track (pri 2)
    try std.testing.expectEqual(EventType.note_off, events[1].event_type);
    try std.testing.expectEqual(@as(u32, 24), events[1].tick);
    try std.testing.expectEqual(@as(u8, 60), events[1].data1);

    try std.testing.expectEqual(EventType.note_on, events[2].event_type);
    try std.testing.expectEqual(@as(u32, 24), events[2].tick);
    try std.testing.expectEqual(@as(u8, 64), events[2].data1);

    try std.testing.expectEqual(EventType.end_of_track, events[3].event_type);
    try std.testing.expectEqual(@as(u32, 24), events[3].tick);

    try std.testing.expectEqual(EventType.note_off, events[4].event_type);
    try std.testing.expectEqual(@as(u32, 48), events[4].tick);
    try std.testing.expectEqual(@as(u8, 64), events[4].data1);
}

test "decode with program change" {
    const allocator = std.testing.allocator;
    const evnt = [_]u8{
        0xC0, 10, // Program Change ch 0, program 10
        0x90, 60, 100, 48, // Note On C4
        0xFF, 0x2F, 0x00,
    };
    const events = try decodeXmidiEvents(allocator, &evnt);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 4), events.len);
    try std.testing.expectEqual(EventType.program_change, events[0].event_type);
    try std.testing.expectEqual(@as(u8, 10), events[0].data1);
}

test "decode with control change" {
    const allocator = std.testing.allocator;
    const evnt = [_]u8{
        0xB0, 7, 100, // Control Change ch 0, controller 7 (volume), value 100
        0xFF, 0x2F, 0x00,
    };
    const events = try decodeXmidiEvents(allocator, &evnt);
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(EventType.control_change, events[0].event_type);
    try std.testing.expectEqual(@as(u8, 7), events[0].data1);
    try std.testing.expectEqual(@as(u8, 100), events[0].data2);
}

test "decode rejects truncated note-on" {
    const allocator = std.testing.allocator;
    const evnt = [_]u8{ 0x90, 60 }; // Missing velocity and duration
    try std.testing.expectError(DecodeError.UnexpectedEnd, decodeXmidiEvents(allocator, &evnt));
}

test "decode empty data produces empty events" {
    const allocator = std.testing.allocator;
    const events = try decodeXmidiEvents(allocator, &[_]u8{});
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "readVlq single byte" {
    var pos: usize = 0;
    const data = [_]u8{0x18};
    const val = try readVlq(&data, &pos);
    try std.testing.expectEqual(@as(u32, 24), val);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readVlq multi byte" {
    var pos: usize = 0;
    // 0x81 0x00 = 128
    const data = [_]u8{ 0x81, 0x00 };
    const val = try readVlq(&data, &pos);
    try std.testing.expectEqual(@as(u32, 128), val);
    try std.testing.expectEqual(@as(usize, 2), pos);
}

test "readVlq three bytes" {
    var pos: usize = 0;
    // 0x82 0x80 0x00 = (2 << 14) | (0 << 7) | 0 = 32768
    const data = [_]u8{ 0x82, 0x80, 0x00 };
    const val = try readVlq(&data, &pos);
    try std.testing.expectEqual(@as(u32, 32768), val);
}

// PCM synthesis tests

test "noteToFreq returns 440 for A4" {
    const freq = noteToFreq(69);
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), freq, 0.01);
}

test "noteToFreq returns 261.63 for middle C" {
    const freq = noteToFreq(60);
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), freq, 0.1);
}

test "noteToFreq octave doubles frequency" {
    const c4 = noteToFreq(60);
    const c5 = noteToFreq(72);
    try std.testing.expectApproxEqAbs(c4 * 2.0, c5, 0.1);
}

test "samplesPerTick at 22050 Hz" {
    const spt = samplesPerTick(22050);
    // 500000 / 120 = 4166.67 us per tick
    // 22050 * 4166.67 / 1000000 = 91.875
    try std.testing.expectApproxEqAbs(@as(f64, 91.875), spt, 0.01);
}

test "renderEventsToPcm empty events" {
    const allocator = std.testing.allocator;
    const pcm = try renderEventsToPcm(allocator, &[_]MidiEvent{}, 22050);
    defer allocator.free(pcm);
    try std.testing.expectEqual(@as(usize, 0), pcm.len);
}

test "renderEventsToPcm produces audio from note" {
    const allocator = std.testing.allocator;
    const events = [_]MidiEvent{
        .{ .tick = 0, .event_type = .note_on, .channel = 0, .data1 = 60, .data2 = 100, .duration = 120 },
        .{ .tick = 120, .event_type = .note_off, .channel = 0, .data1 = 60, .data2 = 0, .duration = 0 },
        .{ .tick = 120, .event_type = .end_of_track, .channel = 0, .data1 = 0, .data2 = 0, .duration = 0 },
    };
    const pcm = try renderEventsToPcm(allocator, &events, 22050);
    defer allocator.free(pcm);

    // Should produce non-empty audio
    try std.testing.expect(pcm.len > 0);

    // Should contain non-silence values
    var has_non_silence = false;
    for (pcm) |sample| {
        if (sample != 128) {
            has_non_silence = true;
            break;
        }
    }
    try std.testing.expect(has_non_silence);
}

test "renderEventsToPcm note produces expected duration" {
    const allocator = std.testing.allocator;
    // One quarter note (120 ticks) + tail (30 ticks) = 150 ticks
    const events = [_]MidiEvent{
        .{ .tick = 0, .event_type = .note_on, .channel = 0, .data1 = 69, .data2 = 100, .duration = 120 },
        .{ .tick = 120, .event_type = .note_off, .channel = 0, .data1 = 69, .data2 = 0, .duration = 0 },
    };
    const pcm = try renderEventsToPcm(allocator, &events, 22050);
    defer allocator.free(pcm);

    // 150 ticks * 91.875 samples/tick ≈ 13781 samples
    const expected: usize = @intFromFloat(@ceil(150.0 * samplesPerTick(22050)));
    try std.testing.expectEqual(expected, pcm.len);
}

test "renderEventsToPcm end-of-track only is silence" {
    const allocator = std.testing.allocator;
    const events = [_]MidiEvent{
        .{ .tick = 0, .event_type = .end_of_track, .channel = 0, .data1 = 0, .data2 = 0, .duration = 0 },
    };
    const pcm = try renderEventsToPcm(allocator, &events, 22050);
    defer allocator.free(pcm);

    // All samples should be silence (128)
    for (pcm) |sample| {
        try std.testing.expectEqual(@as(u8, 128), sample);
    }
}

// MusicStateMachine tests

test "MusicStateMachine init starts with none" {
    const sm = MusicStateMachine.init();
    try std.testing.expectEqual(MusicState.none, sm.current);
    try std.testing.expect(sm.previous_game_state == null);
}

test "MusicStateMachine base music plays when landed" {
    var sm = MusicStateMachine.init();
    const result = sm.processStateChange(.landed);
    try std.testing.expectEqual(MusicState.base, result.?);
    try std.testing.expectEqual(MusicState.base, sm.current);
}

test "MusicStateMachine combat music triggers on combat" {
    var sm = MusicStateMachine.init();
    _ = sm.processStateChange(.landed);
    const result = sm.processStateChange(.combat);
    try std.testing.expectEqual(MusicState.combat, result.?);
    try std.testing.expectEqual(MusicState.combat, sm.current);
}

test "MusicStateMachine opening music on title" {
    var sm = MusicStateMachine.init();
    const result = sm.processStateChange(.title);
    try std.testing.expectEqual(MusicState.opening, result.?);
}

test "MusicStateMachine returns null for conversation (no music change)" {
    var sm = MusicStateMachine.init();
    _ = sm.processStateChange(.landed);
    const result = sm.processStateChange(.conversation);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(MusicState.base, sm.current); // Still base music
}

test "MusicStateMachine returns null for animation (no music change)" {
    var sm = MusicStateMachine.init();
    _ = sm.processStateChange(.landed);
    const result = sm.processStateChange(.animation);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(MusicState.base, sm.current);
}

test "MusicStateMachine returns null when state unchanged" {
    var sm = MusicStateMachine.init();
    _ = sm.processStateChange(.landed);
    const result = sm.processStateChange(.landed);
    try std.testing.expect(result == null); // Already playing base
}

test "MusicStateMachine force overrides current state" {
    var sm = MusicStateMachine.init();
    _ = sm.processStateChange(.landed);
    sm.force(.victory);
    try std.testing.expectEqual(MusicState.victory, sm.current);
}

test "MusicStateMachine full gameplay cycle" {
    var sm = MusicStateMachine.init();

    // Title screen
    try std.testing.expectEqual(MusicState.opening, sm.processStateChange(.title).?);

    // Loading → no change
    try std.testing.expect(sm.processStateChange(.loading) == null);

    // Land at base
    try std.testing.expectEqual(MusicState.base, sm.processStateChange(.landed).?);

    // Enter conversation → no change
    try std.testing.expect(sm.processStateChange(.conversation) == null);
    try std.testing.expectEqual(MusicState.base, sm.current);

    // Back to landed → no change (still base)
    try std.testing.expect(sm.processStateChange(.landed) == null);

    // Launch → animation → no change
    try std.testing.expect(sm.processStateChange(.animation) == null);

    // Space flight → silence
    try std.testing.expectEqual(MusicState.none, sm.processStateChange(.space_flight).?);

    // Combat → combat music
    try std.testing.expectEqual(MusicState.combat, sm.processStateChange(.combat).?);

    // Back to flight → silence
    try std.testing.expectEqual(MusicState.none, sm.processStateChange(.space_flight).?);

    // Dead → already none, no change
    try std.testing.expect(sm.processStateChange(.dead) == null);

    // Back to title
    try std.testing.expectEqual(MusicState.opening, sm.processStateChange(.title).?);
}

// MusicPlayer tests (require SDL)

test "MusicPlayer init and deinit" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var player = MusicPlayer.init(std.testing.allocator) catch return;
    defer player.deinit();

    try std.testing.expectEqual(MusicState.none, player.current_state);
    try std.testing.expect(!player.isPlaying());
    try std.testing.expect(player.stream == null);
    try std.testing.expect(player.pcm_data == null);
}

test "MusicPlayer playPcm sets state and stream" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var player = MusicPlayer.init(std.testing.allocator) catch return;
    defer player.deinit();

    const pcm = try std.testing.allocator.alloc(u8, 1000);
    @memset(pcm, 128);

    player.playPcm(pcm, .base);
    try std.testing.expectEqual(MusicState.base, player.current_state);
    try std.testing.expect(player.stream != null);
    try std.testing.expect(player.pcm_data != null);
}

test "MusicPlayer stop clears everything" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var player = MusicPlayer.init(std.testing.allocator) catch return;
    defer player.deinit();

    const pcm = try std.testing.allocator.alloc(u8, 1000);
    @memset(pcm, 128);

    player.playPcm(pcm, .combat);
    player.stop();

    try std.testing.expectEqual(MusicState.none, player.current_state);
    try std.testing.expect(player.stream == null);
    try std.testing.expect(player.pcm_data == null);
}

test "MusicPlayer playPcm replaces previous" {
    sdl.init() catch return;
    defer sdl.shutdown();

    var player = MusicPlayer.init(std.testing.allocator) catch return;
    defer player.deinit();

    const pcm1 = try std.testing.allocator.alloc(u8, 500);
    @memset(pcm1, 128);
    player.playPcm(pcm1, .base);

    try std.testing.expect(player.stream != null);
    try std.testing.expectEqual(MusicState.base, player.current_state);

    const pcm2 = try std.testing.allocator.alloc(u8, 800);
    @memset(pcm2, 128);
    player.playPcm(pcm2, .combat);

    // Stream should still be active after replacement, state should update
    try std.testing.expect(player.stream != null);
    try std.testing.expectEqual(MusicState.combat, player.current_state);
}
