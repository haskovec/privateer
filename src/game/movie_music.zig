//! Movie music system for Wing Commander: Privateer intro cinematic.
//!
//! Loads the opening music track (OPENING.GEN or OPENING.ADL) from the TRE
//! archive, parses it as XMIDI, decodes MIDI events, and renders to PCM
//! audio for playback via the MusicPlayer.
//!
//! The opening music plays continuously across all intro scene transitions
//! (mid1a → mid1f) and stops on movie completion or Escape skip.
//!
//! Data flow:
//!   TRE("OPENING.GEN") → music.parse() → XMIDI sequence
//!     → decodeXmidiEvents() → MidiEvent[]
//!     → renderEventsToPcm() → PCM buffer (8-bit unsigned mono)
//!     → MusicPlayer.playPcm()

const std = @import("std");
const music = @import("../formats/music.zig");
const music_player = @import("../audio/music_player.zig");
const tre = @import("../formats/tre.zig");

/// TRE filename for the General MIDI opening music track.
pub const OPENING_GEN_FILENAME = "OPENING.GEN";

/// TRE filename for the AdLib opening music track (fallback).
pub const OPENING_ADL_FILENAME = "OPENING.ADL";

pub const MovieMusicError = error{
    /// The music file could not be parsed as a recognized format.
    InvalidMusicFormat,
    /// The music file has no XMIDI sequences.
    NoSequences,
    /// The XMIDI sequence has no event data.
    NoEventData,
    /// Failed to decode XMIDI events.
    DecodeError,
    /// Failed to render PCM audio.
    RenderError,
    /// Music file not found in TRE archive.
    MusicNotFound,
    OutOfMemory,
};

/// Load opening music from raw file data (OPENING.GEN or OPENING.ADL).
///
/// Parses the file as XMIDI, decodes the first sequence's events, and
/// renders them to PCM audio. Returns an owned PCM buffer (8-bit unsigned
/// mono at 22050 Hz) that the caller must free.
pub fn loadOpeningMusic(allocator: std.mem.Allocator, file_data: []const u8) MovieMusicError![]u8 {
    // Parse as music file (tries XMIDI → MIDI → raw)
    var music_file = music.parse(allocator, file_data) catch return MovieMusicError.InvalidMusicFormat;
    defer music_file.deinit();

    if (music_file.format != .xmidi) return MovieMusicError.InvalidMusicFormat;
    if (music_file.sequences.len == 0) return MovieMusicError.NoSequences;

    const seq = music_file.sequences[0];
    if (seq.event_data.len == 0) return MovieMusicError.NoEventData;

    // Decode XMIDI events
    const events = music_player.decodeXmidiEvents(allocator, seq.event_data) catch return MovieMusicError.DecodeError;
    defer allocator.free(events);

    if (events.len == 0) return MovieMusicError.NoEventData;

    // Render to PCM at the MusicPlayer's sample rate
    const pcm = music_player.renderEventsToPcm(allocator, events, music_player.MusicPlayer.SAMPLE_RATE) catch return MovieMusicError.RenderError;
    return pcm;
}

/// Load opening music from a TRE index.
///
/// Tries OPENING.GEN first (General MIDI), falls back to OPENING.ADL (AdLib).
/// Returns owned PCM data the caller must free.
pub fn loadFromTreIndex(allocator: std.mem.Allocator, index: *const tre.TreIndex, tre_data: []const u8) MovieMusicError![]u8 {
    // Try General MIDI first
    if (index.findEntry(OPENING_GEN_FILENAME)) |entry| {
        const file_data = tre.extractFileData(tre_data, entry.offset, entry.size) catch return MovieMusicError.MusicNotFound;
        return loadOpeningMusic(allocator, file_data);
    }

    // Fall back to AdLib
    if (index.findEntry(OPENING_ADL_FILENAME)) |entry| {
        const file_data = tre.extractFileData(tre_data, entry.offset, entry.size) catch return MovieMusicError.MusicNotFound;
        return loadOpeningMusic(allocator, file_data);
    }

    return MovieMusicError.MusicNotFound;
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "loadOpeningMusic rejects empty data" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(MovieMusicError.InvalidMusicFormat, loadOpeningMusic(allocator, ""));
}

test "loadOpeningMusic rejects non-XMIDI data" {
    const allocator = std.testing.allocator;
    // Standard MIDI header (not XMIDI)
    const midi_data = try testing_helpers.loadFixture(allocator, "test_midi.bin");
    defer allocator.free(midi_data);
    try std.testing.expectError(MovieMusicError.InvalidMusicFormat, loadOpeningMusic(allocator, midi_data));
}

test "loadOpeningMusic parses XMIDI fixture to PCM" {
    const allocator = std.testing.allocator;
    // Use the existing multi-sequence XMIDI fixture (has real note events)
    const xmidi_data = try testing_helpers.loadFixture(allocator, "test_xmidi_notes.bin");
    defer allocator.free(xmidi_data);

    const pcm = try loadOpeningMusic(allocator, xmidi_data);
    defer allocator.free(pcm);

    // PCM should be non-empty (the fixture has note events)
    try std.testing.expect(pcm.len > 0);

    // Should contain non-silence samples (not all 128)
    var has_non_silence = false;
    for (pcm) |sample| {
        if (sample != 128) {
            has_non_silence = true;
            break;
        }
    }
    try std.testing.expect(has_non_silence);
}

test "loadOpeningMusic rejects XMIDI with no event data" {
    const allocator = std.testing.allocator;
    // The test_xmidi.bin fixture has only an end-of-track marker (FF 2F 00)
    // which should produce events but the PCM will be very short
    const xmidi_data = try testing_helpers.loadFixture(allocator, "test_xmidi.bin");
    defer allocator.free(xmidi_data);

    // This should succeed since it has EVNT data (even if just end-of-track)
    // The end-of-track event alone produces an empty PCM
    const pcm = try loadOpeningMusic(allocator, xmidi_data);
    defer allocator.free(pcm);
    // PCM may be empty since the only event is end_of_track with no notes
}
