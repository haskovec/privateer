//! Music format loaders for Wing Commander: Privateer.
//! Handles XMIDI (IFF-wrapped Extended MIDI), Standard MIDI, and raw ADL formats.
//!
//! File types:
//!   .ADL - AdLib music (IFF-wrapped XMIDI with OPL2 timbres)
//!   .GEN - General MIDI music (IFF-wrapped XMIDI with GM timbres)
//!   Both use the XMIDI structure: FORM:XDIR > INFO + CAT:XMID > FORM:XMID > TIMB + EVNT
//!
//! Standard MIDI files (MThd signature) are also supported for completeness.

const std = @import("std");
const iff = @import("iff.zig");

pub const MIN_FILE_SIZE: usize = 12;

pub const MusicError = error{
    /// Not a recognized music file format.
    InvalidFormat,
    /// No XMID sequences found in the IFF tree.
    NoSequences,
    /// An XMID sequence is missing its EVNT chunk.
    NoEventData,
    /// TIMB chunk data is malformed.
    InvalidTimbreData,
    OutOfMemory,
};

/// Detected music file format.
pub const MusicFormat = enum {
    /// IFF-wrapped Extended MIDI (FORM:XDIR or FORM:XMID).
    xmidi,
    /// Standard MIDI File (MThd header).
    midi,
    /// Raw binary (e.g. AdLib register data).
    raw,
};

/// Timbre (instrument) definition from a TIMB chunk.
pub const Timbre = struct {
    patch: u8,
    bank: u8,
};

/// A single XMIDI sequence extracted from a FORM:XMID container.
pub const Sequence = struct {
    /// Timbre definitions for this sequence (allocated; empty if no TIMB chunk).
    timbres: []const Timbre,
    /// Raw XMIDI event data from the EVNT chunk.
    /// This is a slice into the original data buffer passed to parse().
    event_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Sequence) void {
        if (self.timbres.len > 0) {
            self.allocator.free(self.timbres);
        }
    }
};

/// Parsed Standard MIDI header (MThd chunk).
pub const MidiHeader = struct {
    /// MIDI format: 0 = single track, 1 = multi-track synchronous, 2 = multi-track async.
    format: u16,
    /// Number of MTrk chunks.
    track_count: u16,
    /// Ticks per quarter note (or SMPTE if bit 15 set).
    ticks_per_qn: u16,
};

/// A parsed music file.
pub const MusicFile = struct {
    /// Detected format.
    format: MusicFormat,
    /// Number of sequences (XMIDI) or tracks (MIDI).
    sequence_count: u16,
    /// Parsed XMIDI sequences (only populated for xmidi format).
    sequences: []Sequence,
    /// Standard MIDI header (only populated for midi format).
    midi_header: ?MidiHeader,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MusicFile) void {
        for (self.sequences) |*seq| {
            seq.deinit();
        }
        self.allocator.free(self.sequences);
    }
};

// --- Format identification ---

/// Check if raw bytes look like an XMIDI file (IFF with XDIR or XMID form type).
pub fn isXmidi(data: []const u8) bool {
    if (data.len < 12) return false;
    if (!std.mem.eql(u8, data[0..4], "FORM") and !std.mem.eql(u8, data[0..4], "CAT ")) return false;
    const ft = data[8..12];
    return std.mem.eql(u8, ft, "XDIR") or std.mem.eql(u8, ft, "XMID");
}

/// Check if raw bytes look like a Standard MIDI file (MThd signature).
pub fn isMidi(data: []const u8) bool {
    if (data.len < 14) return false;
    return std.mem.eql(u8, data[0..4], "MThd");
}

// --- Parsing ---

/// Parse a music file. Tries XMIDI (IFF), then Standard MIDI, then raw.
/// The returned MusicFile references into the original `data` buffer, which
/// must remain valid for the lifetime of the MusicFile.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) MusicError!MusicFile {
    if (data.len < MIN_FILE_SIZE) return MusicError.InvalidFormat;

    if (isXmidi(data)) return parseXmidi(allocator, data);
    if (isMidi(data)) return parseMidi(allocator, data);

    // Raw format (ADL register data or unknown)
    return .{
        .format = .raw,
        .sequence_count = 1,
        .sequences = allocator.alloc(Sequence, 0) catch return MusicError.OutOfMemory,
        .midi_header = null,
        .allocator = allocator,
    };
}

/// Parse TIMB chunk data into an allocated Timbre slice.
fn parseTimbres(allocator: std.mem.Allocator, data: []const u8) MusicError![]Timbre {
    if (data.len < 2) return MusicError.InvalidTimbreData;
    const count = std.mem.readInt(u16, data[0..2], .little);
    if (data.len < 2 + @as(usize, count) * 2) return MusicError.InvalidTimbreData;

    const timbres = allocator.alloc(Timbre, count) catch return MusicError.OutOfMemory;
    for (0..count) |i| {
        timbres[i] = .{
            .patch = data[2 + i * 2],
            .bank = data[2 + i * 2 + 1],
        };
    }
    return timbres;
}

/// Extract a Sequence from a FORM:XMID chunk.
fn parseXmidForm(allocator: std.mem.Allocator, chunk: iff.Chunk) MusicError!Sequence {
    const evnt = chunk.findChild("EVNT".*) orelse return MusicError.NoEventData;

    var timbres: []const Timbre = &[_]Timbre{};
    if (chunk.findChild("TIMB".*)) |timb| {
        if (parseTimbres(allocator, timb.data)) |t| {
            timbres = t;
        } else |_| {}
    }

    return .{
        .timbres = timbres,
        .event_data = evnt.data,
        .allocator = allocator,
    };
}

/// Collect FORM:XMID sequences from a CAT:XMID container.
fn collectXmidSequences(allocator: std.mem.Allocator, cat_chunk: iff.Chunk, list: *std.ArrayListUnmanaged(Sequence)) MusicError!void {
    for (cat_chunk.children) |child| {
        if (!std.mem.eql(u8, &child.tag, "FORM")) continue;
        const ft = child.form_type orelse continue;
        if (!std.mem.eql(u8, &ft, "XMID")) continue;

        var seq = try parseXmidForm(allocator, child);
        errdefer seq.deinit();
        list.append(allocator, seq) catch return MusicError.OutOfMemory;
    }
}

/// Parse an IFF-wrapped XMIDI file.
/// Handles both nested (CAT:XMID inside FORM:XDIR) and sibling
/// (FORM:XDIR + CAT:XMID as top-level peers) layouts.
fn parseXmidi(allocator: std.mem.Allocator, data: []const u8) MusicError!MusicFile {
    var sequences_list: std.ArrayListUnmanaged(Sequence) = .empty;
    errdefer {
        for (sequences_list.items) |*s| {
            var seq = s.*;
            seq.deinit();
        }
        sequences_list.deinit(allocator);
    }

    // Parse all top-level IFF chunks (XMIDI files may have FORM:XDIR + CAT:XMID as siblings)
    var chunks: std.ArrayListUnmanaged(iff.Chunk) = .empty;
    defer {
        for (chunks.items) |*c| c.deinit();
        chunks.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset + iff.CHUNK_HEADER_SIZE <= data.len) {
        const result = iff.parseChunk(allocator, data, offset) catch break;
        chunks.append(allocator, result.chunk) catch return MusicError.OutOfMemory;
        offset = result.next_offset;
    }

    if (chunks.items.len == 0) return MusicError.InvalidFormat;

    var sequence_count: u16 = 0;

    for (chunks.items) |chunk| {
        const ft = chunk.form_type orelse continue;

        if (std.mem.eql(u8, &ft, "XDIR")) {
            // Read sequence count from INFO chunk
            if (chunk.findChild("INFO".*)) |info| {
                if (info.data.len >= 2) {
                    sequence_count = std.mem.readInt(u16, info.data[0..2], .little);
                }
            }
            // Check for nested CAT:XMID inside FORM:XDIR
            for (chunk.children) |child| {
                if (!std.mem.eql(u8, &child.tag, "CAT ")) continue;
                const cft = child.form_type orelse continue;
                if (!std.mem.eql(u8, &cft, "XMID")) continue;
                try collectXmidSequences(allocator, child, &sequences_list);
            }
        } else if (std.mem.eql(u8, &ft, "XMID")) {
            if (std.mem.eql(u8, &chunk.tag, "CAT ")) {
                // CAT:XMID at top level (sibling of FORM:XDIR)
                try collectXmidSequences(allocator, chunk, &sequences_list);
            } else {
                // Single FORM:XMID
                var seq = try parseXmidForm(allocator, chunk);
                errdefer seq.deinit();
                sequences_list.append(allocator, seq) catch return MusicError.OutOfMemory;
            }
        }
    }

    if (sequences_list.items.len == 0) return MusicError.NoSequences;
    if (sequence_count == 0) sequence_count = @intCast(sequences_list.items.len);

    return .{
        .format = .xmidi,
        .sequence_count = sequence_count,
        .sequences = sequences_list.toOwnedSlice(allocator) catch return MusicError.OutOfMemory,
        .midi_header = null,
        .allocator = allocator,
    };
}

/// Parse a Standard MIDI header.
fn parseMidiHeader(data: []const u8) ?MidiHeader {
    if (data.len < 14) return null;
    if (!std.mem.eql(u8, data[0..4], "MThd")) return null;
    const chunk_size = std.mem.readInt(u32, data[4..8], .big);
    if (chunk_size < 6) return null;

    return .{
        .format = std.mem.readInt(u16, data[8..10], .big),
        .track_count = std.mem.readInt(u16, data[10..12], .big),
        .ticks_per_qn = std.mem.readInt(u16, data[12..14], .big),
    };
}

/// Parse a Standard MIDI file.
fn parseMidi(allocator: std.mem.Allocator, data: []const u8) MusicError!MusicFile {
    const header = parseMidiHeader(data) orelse return MusicError.InvalidFormat;

    return .{
        .format = .midi,
        .sequence_count = header.track_count,
        .sequences = allocator.alloc(Sequence, 0) catch return MusicError.OutOfMemory,
        .midi_header = header,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("testing.zig");

test "parse XMIDI from fixture: single sequence with timbres" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_xmidi.bin");
    defer allocator.free(data);

    var music = try parse(allocator, data);
    defer music.deinit();

    try std.testing.expectEqual(MusicFormat.xmidi, music.format);
    try std.testing.expectEqual(@as(u16, 1), music.sequence_count);
    try std.testing.expectEqual(@as(usize, 1), music.sequences.len);

    // Verify timbres
    const seq = music.sequences[0];
    try std.testing.expectEqual(@as(usize, 2), seq.timbres.len);
    try std.testing.expectEqual(@as(u8, 0), seq.timbres[0].patch);
    try std.testing.expectEqual(@as(u8, 0), seq.timbres[0].bank);
    try std.testing.expectEqual(@as(u8, 10), seq.timbres[1].patch);
    try std.testing.expectEqual(@as(u8, 1), seq.timbres[1].bank);

    // Verify event data (end-of-track: FF 2F 00)
    try std.testing.expectEqual(@as(usize, 3), seq.event_data.len);
    try std.testing.expectEqual(@as(u8, 0xFF), seq.event_data[0]);
    try std.testing.expectEqual(@as(u8, 0x2F), seq.event_data[1]);
    try std.testing.expectEqual(@as(u8, 0x00), seq.event_data[2]);
}

test "parse XMIDI multi-sequence fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_xmidi_multi.bin");
    defer allocator.free(data);

    var music = try parse(allocator, data);
    defer music.deinit();

    try std.testing.expectEqual(MusicFormat.xmidi, music.format);
    try std.testing.expectEqual(@as(u16, 2), music.sequence_count);
    try std.testing.expectEqual(@as(usize, 2), music.sequences.len);

    // Sequence 0: 2 timbres, 3-byte EVNT
    try std.testing.expectEqual(@as(usize, 2), music.sequences[0].timbres.len);
    try std.testing.expectEqual(@as(usize, 3), music.sequences[0].event_data.len);

    // Sequence 1: 1 timbre (patch 5, bank 0), 7-byte EVNT
    try std.testing.expectEqual(@as(usize, 1), music.sequences[1].timbres.len);
    try std.testing.expectEqual(@as(u8, 5), music.sequences[1].timbres[0].patch);
    try std.testing.expectEqual(@as(u8, 0), music.sequences[1].timbres[0].bank);
    try std.testing.expectEqual(@as(usize, 7), music.sequences[1].event_data.len);
}

test "parse XMIDI without TIMB chunk" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_xmidi_no_timb.bin");
    defer allocator.free(data);

    var music = try parse(allocator, data);
    defer music.deinit();

    try std.testing.expectEqual(MusicFormat.xmidi, music.format);
    try std.testing.expectEqual(@as(usize, 1), music.sequences.len);
    try std.testing.expectEqual(@as(usize, 0), music.sequences[0].timbres.len);
    try std.testing.expectEqual(@as(usize, 3), music.sequences[0].event_data.len);
}

test "parse Standard MIDI from fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_midi.bin");
    defer allocator.free(data);

    var music = try parse(allocator, data);
    defer music.deinit();

    try std.testing.expectEqual(MusicFormat.midi, music.format);
    try std.testing.expectEqual(@as(u16, 1), music.sequence_count);
    try std.testing.expect(music.midi_header != null);

    const hdr = music.midi_header.?;
    try std.testing.expectEqual(@as(u16, 1), hdr.format);
    try std.testing.expectEqual(@as(u16, 1), hdr.track_count);
    try std.testing.expectEqual(@as(u16, 120), hdr.ticks_per_qn);
}

test "isXmidi identifies XMIDI files" {
    const allocator = std.testing.allocator;
    const xmidi_data = try testing_helpers.loadFixture(allocator, "test_xmidi.bin");
    defer allocator.free(xmidi_data);
    try std.testing.expect(isXmidi(xmidi_data));

    const midi_data = try testing_helpers.loadFixture(allocator, "test_midi.bin");
    defer allocator.free(midi_data);
    try std.testing.expect(!isXmidi(midi_data));

    // Too short
    try std.testing.expect(!isXmidi(&[_]u8{ 0, 0, 0, 0 }));
}

test "isMidi identifies Standard MIDI files" {
    const allocator = std.testing.allocator;
    const midi_data = try testing_helpers.loadFixture(allocator, "test_midi.bin");
    defer allocator.free(midi_data);
    try std.testing.expect(isMidi(midi_data));

    const xmidi_data = try testing_helpers.loadFixture(allocator, "test_xmidi.bin");
    defer allocator.free(xmidi_data);
    try std.testing.expect(!isMidi(xmidi_data));
}

test "parse rejects too-small data" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(MusicError.InvalidFormat, parse(allocator, &data));
}

test "parse falls back to raw format for unknown data" {
    const allocator = std.testing.allocator;
    // 16 bytes of non-IFF, non-MIDI data
    const data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F };

    var music = try parse(allocator, &data);
    defer music.deinit();

    try std.testing.expectEqual(MusicFormat.raw, music.format);
    try std.testing.expectEqual(@as(u16, 1), music.sequence_count);
    try std.testing.expectEqual(@as(usize, 0), music.sequences.len);
}

test "parseTimbres with valid data" {
    const allocator = std.testing.allocator;
    // 3 timbres: (0,0), (10,1), (127,5)
    const data = [_]u8{ 3, 0, 0, 0, 10, 1, 127, 5 }; // u16 LE count=3 + 3 pairs
    const timbres = try parseTimbres(allocator, &data);
    defer allocator.free(timbres);

    try std.testing.expectEqual(@as(usize, 3), timbres.len);
    try std.testing.expectEqual(@as(u8, 0), timbres[0].patch);
    try std.testing.expectEqual(@as(u8, 10), timbres[1].patch);
    try std.testing.expectEqual(@as(u8, 1), timbres[1].bank);
    try std.testing.expectEqual(@as(u8, 127), timbres[2].patch);
    try std.testing.expectEqual(@as(u8, 5), timbres[2].bank);
}

test "parseTimbres rejects truncated data" {
    const allocator = std.testing.allocator;
    // Count says 2 but only 1 pair of data
    const data = [_]u8{ 2, 0, 10, 1 };
    try std.testing.expectError(MusicError.InvalidTimbreData, parseTimbres(allocator, &data));

    // Too short for count field
    try std.testing.expectError(MusicError.InvalidTimbreData, parseTimbres(allocator, &[_]u8{0}));
}
