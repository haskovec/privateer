//! Opening sequence playlist parser for Wing Commander: Privateer.
//!
//! Parses GFMIDGAM.IFF (FORM:MIDG) to identify the intro sequence control
//! file, then parses the playlist PAK (OPENING.PAK) to extract the ordered
//! list of scene names (mid1a, mid1b, mid1c1, ...) that make up the opening
//! cinematic.
//!
//! Scene names map to FORM:MOVI IFF files in the TRE archive:
//!   "mid1a" → "MIDGAMES/MID1A.IFF"
//!
//! GFMIDGAM.IFF structure:
//!   FORM:MIDG
//!     TABL — entry count / mapping data
//!     FNAM — filename (one per midgame type, null-terminated)
//!
//! The opening sequence is at FNAM index 2 (type index for the intro movie).

const std = @import("std");
const iff = @import("../formats/iff.zig");
const pak = @import("../formats/pak.zig");

pub const OpeningError = error{
    /// Data is not a valid FORM:MIDG container.
    InvalidFormat,
    /// No scene names found in playlist data.
    NoScenes,
    /// No FNAM entries found in GFMIDGAM.IFF.
    NoFilenames,
    OutOfMemory,
};

/// Index of the opening sequence in the GFMIDGAM.IFF FNAM list.
pub const OPENING_TYPE_INDEX: usize = 2;

/// A parsed midgame table from GFMIDGAM.IFF (FORM:MIDG).
/// Maps type indices to control file names.
pub const MidgameTable = struct {
    /// Filenames indexed by type (e.g., index 2 = "OPENING.PAK").
    filenames: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MidgameTable) void {
        for (self.filenames) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.filenames);
    }

    /// Get the filename for a given type index.
    pub fn getFilename(self: MidgameTable, index: usize) ?[]const u8 {
        if (index >= self.filenames.len) return null;
        return self.filenames[index];
    }

    /// Get the opening sequence control filename (type index 2).
    pub fn getOpeningFilename(self: MidgameTable) ?[]const u8 {
        return self.getFilename(OPENING_TYPE_INDEX);
    }
};

/// Parse GFMIDGAM.IFF (FORM:MIDG) to extract midgame type-to-file mappings.
///
/// The actual file structure is:
///   FORM:MIDG
///     TABL chunk: N little-endian u32 offsets (N = TABL size / 4)
///     At each offset (relative to file start):
///       u32 LE: sub-block size (size of following FNAM IFF chunk)
///       FNAM IFF chunk: tag(4) + size(4 BE) + null-terminated filename
///
/// The IFF parser only sees TABL as a child because the entries after it
/// have a non-IFF 4-byte prefix before each FNAM chunk.
pub fn parseMidgameTable(allocator: std.mem.Allocator, data: []const u8) (OpeningError || iff.IffError)!MidgameTable {
    if (data.len < 12) return OpeningError.InvalidFormat;

    const result = iff.parseChunk(allocator, data, 0) catch |err| switch (err) {
        error.OutOfMemory => return OpeningError.OutOfMemory,
        else => return OpeningError.InvalidFormat,
    };
    var root = result.chunk;
    defer root.deinit();

    // Validate FORM:MIDG
    if (!std.mem.eql(u8, &root.tag, "FORM")) return OpeningError.InvalidFormat;
    const ft = root.form_type orelse return OpeningError.InvalidFormat;
    if (!std.mem.eql(u8, &ft, "MIDG")) return OpeningError.InvalidFormat;

    // Get TABL chunk (contains LE u32 offsets into the raw file)
    const tabl = root.findChild("TABL".*) orelse return OpeningError.InvalidFormat;
    if (tabl.data.len < 4 or tabl.data.len % 4 != 0) return OpeningError.InvalidFormat;

    const entry_count = tabl.data.len / 4;

    var filenames: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (filenames.items) |name| allocator.free(name);
        filenames.deinit(allocator);
    }

    for (0..entry_count) |i| {
        // Read LE u32 offset from TABL
        const offset = std.mem.readInt(u32, tabl.data[i * 4 ..][0..4], .little);

        // At the offset: 4-byte sub-block size prefix, then FNAM IFF chunk
        // FNAM chunk: tag(4) + size(4 BE) + string data
        const fnam_start = offset + 4; // skip sub-block size prefix
        if (fnam_start + 8 > data.len) continue;

        // Verify FNAM tag
        if (!std.mem.eql(u8, data[fnam_start..][0..4], "FNAM")) continue;

        const fnam_size = std.mem.readInt(u32, data[fnam_start + 4 ..][0..4], .big);
        const str_start = fnam_start + 8;
        if (str_start + fnam_size > data.len) continue;

        const name = extractNullTermString(data[str_start .. str_start + fnam_size]);
        filenames.append(allocator, allocator.dupe(u8, name) catch return OpeningError.OutOfMemory) catch return OpeningError.OutOfMemory;
    }

    if (filenames.items.len == 0) return OpeningError.NoFilenames;

    return .{
        .filenames = filenames.toOwnedSlice(allocator) catch return OpeningError.OutOfMemory,
        .allocator = allocator,
    };
}

/// An opening sequence playlist (parsed from OPENING.PAK or similar).
pub const OpeningSequence = struct {
    /// Ordered scene names (e.g., "mid1a", "mid1b", "mid1c1", ...).
    scene_names: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OpeningSequence) void {
        for (self.scene_names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.scene_names);
    }

    /// Number of scenes in the playlist.
    pub fn sceneCount(self: OpeningSequence) usize {
        return self.scene_names.len;
    }

    /// Get a scene name by index.
    pub fn getSceneName(self: OpeningSequence, index: usize) ?[]const u8 {
        if (index >= self.scene_names.len) return null;
        return self.scene_names[index];
    }

    /// Map a scene index to its TRE path (caller owns returned memory).
    pub fn getSceneTrePath(self: OpeningSequence, allocator: std.mem.Allocator, index: usize) !?[]u8 {
        const name = self.getSceneName(index) orelse return null;
        return try sceneNameToTrePath(allocator, name);
    }
};

/// Parse a playlist PAK file to extract an ordered list of scene names.
///
/// Tries the standard PAK parser first (OPENING.PAK may use offset tables
/// pointing to null-terminated string resources). Falls back to raw
/// string-list format (4-byte size header + concatenated null-terminated
/// strings) if the PAK parser fails.
pub fn parsePlaylist(allocator: std.mem.Allocator, data: []const u8) OpeningError!OpeningSequence {
    // Try standard PAK parser first
    if (pak.parse(allocator, data)) |pak_result| {
        var pak_file = pak_result;
        defer pak_file.deinit();
        return extractPakStrings(allocator, &pak_file);
    } else |_| {}

    // Fall back to raw string-list format
    return parseRawStringList(allocator, data);
}

/// Extract null-terminated strings from PAK resources.
fn extractPakStrings(allocator: std.mem.Allocator, pak_file: *pak.PakFile) OpeningError!OpeningSequence {
    const count = pak_file.resourceCount();
    if (count == 0) return OpeningError.NoScenes;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    for (0..count) |i| {
        const resource = pak_file.getResource(i) catch continue;
        const name = extractNullTermString(resource);
        if (name.len > 0) {
            names.append(allocator, allocator.dupe(u8, name) catch return OpeningError.OutOfMemory) catch return OpeningError.OutOfMemory;
        }
    }

    if (names.items.len == 0) return OpeningError.NoScenes;

    return .{
        .scene_names = names.toOwnedSlice(allocator) catch return OpeningError.OutOfMemory,
        .allocator = allocator,
    };
}

/// Parse raw string-list format: 4-byte LE size header + null-terminated strings.
fn parseRawStringList(allocator: std.mem.Allocator, data: []const u8) OpeningError!OpeningSequence {
    if (data.len < 5) return OpeningError.InvalidFormat;

    // Skip 4-byte size header
    const string_data = data[4..];

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var start: usize = 0;
    for (string_data, 0..) |byte, i| {
        if (byte == 0) {
            if (i > start) {
                names.append(allocator, allocator.dupe(u8, string_data[start..i]) catch return OpeningError.OutOfMemory) catch return OpeningError.OutOfMemory;
            }
            start = i + 1;
        }
    }

    if (names.items.len == 0) return OpeningError.NoScenes;

    return .{
        .scene_names = names.toOwnedSlice(allocator) catch return OpeningError.OutOfMemory,
        .allocator = allocator,
    };
}

/// Map a scene name to a TRE-compatible path.
/// e.g., "mid1a" → "MIDGAMES/MID1A.IFF"
pub fn sceneNameToTrePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const result = try std.fmt.allocPrint(allocator, "MIDGAMES/{s}.IFF", .{name});
    // Uppercase the entire path
    for (result) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }
    return result;
}

/// Detect the base name for variant grouping.
/// Strips a single trailing digit to find the group key.
/// e.g., "mid1c1" → "mid1c", "mid1a" → "mid1a".
fn variantBase(name: []const u8) []const u8 {
    if (name.len > 0 and std.ascii.isDigit(name[name.len - 1])) {
        // Only strip if the character before the digit is a letter,
        // to avoid stripping the '1' from "mid1" (which is part of the base name).
        if (name.len >= 2 and std.ascii.isAlphabetic(name[name.len - 2])) {
            return name[0 .. name.len - 1];
        }
    }
    return name;
}

/// Select one scene from each variant group, collapsing the playlist.
///
/// Variant groups are consecutive scenes sharing the same base name
/// (name minus trailing digit). e.g., mid1c1/mid1c2/mid1c3/mid1c4 → pick one.
/// Non-variant scenes pass through unchanged.
pub fn selectVariants(
    allocator: std.mem.Allocator,
    sequence: *const OpeningSequence,
    rand: std.Random,
) !OpeningSequence {
    var selected: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (selected.items) |name| allocator.free(name);
        selected.deinit(allocator);
    }

    var i: usize = 0;
    while (i < sequence.scene_names.len) {
        const base = variantBase(sequence.scene_names[i]);

        // Find extent of this variant group (consecutive scenes with same base)
        var group_end = i + 1;
        while (group_end < sequence.scene_names.len) {
            const next_base = variantBase(sequence.scene_names[group_end]);
            if (!std.mem.eql(u8, base, next_base)) break;
            group_end += 1;
        }

        const group_size = group_end - i;
        if (group_size == 1) {
            // Not a variant group — include as-is
            try selected.append(allocator, try allocator.dupe(u8, sequence.scene_names[i]));
        } else {
            // Pick one randomly from the group
            const pick = rand.uintLessThan(usize, group_size);
            try selected.append(allocator, try allocator.dupe(u8, sequence.scene_names[i + pick]));
        }

        i = group_end;
    }

    return .{
        .scene_names = try selected.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Extract a null-terminated string from raw bytes.
/// Returns the slice up to (but not including) the first null byte,
/// or the entire slice if no null byte is found.
fn extractNullTermString(data: []const u8) []const u8 {
    for (data, 0..) |byte, i| {
        if (byte == 0) return data[0..i];
    }
    return data;
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parsePlaylist extracts scene names from PAK fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_opening_pak.bin");
    defer allocator.free(data);

    var seq = try parsePlaylist(allocator, data);
    defer seq.deinit();

    try std.testing.expectEqual(@as(usize, 4), seq.sceneCount());
    try std.testing.expectEqualStrings("mid1a", seq.getSceneName(0).?);
    try std.testing.expectEqualStrings("mid1b", seq.getSceneName(1).?);
    try std.testing.expectEqualStrings("mid1c1", seq.getSceneName(2).?);
    try std.testing.expectEqualStrings("mid1d", seq.getSceneName(3).?);
}

test "parsePlaylist falls back to raw string-list format" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_opening_raw.bin");
    defer allocator.free(data);

    var seq = try parsePlaylist(allocator, data);
    defer seq.deinit();

    try std.testing.expectEqual(@as(usize, 4), seq.sceneCount());
    try std.testing.expectEqualStrings("mid1a", seq.getSceneName(0).?);
    try std.testing.expectEqualStrings("mid1b", seq.getSceneName(1).?);
    try std.testing.expectEqualStrings("mid1c1", seq.getSceneName(2).?);
    try std.testing.expectEqualStrings("mid1d", seq.getSceneName(3).?);
}

test "parsePlaylist rejects empty data" {
    const allocator = std.testing.allocator;
    const result = parsePlaylist(allocator, "");
    try std.testing.expectError(OpeningError.InvalidFormat, result);
}

test "parseMidgameTable extracts filenames from FORM:MIDG fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gfmidgam.bin");
    defer allocator.free(data);

    var table = try parseMidgameTable(allocator, data);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 3), table.filenames.len);
    try std.testing.expectEqualStrings("LANDINGS.IFF", table.getFilename(0).?);
    try std.testing.expectEqualStrings("TAKEOFFS.IFF", table.getFilename(1).?);
    try std.testing.expectEqualStrings("OPENING.PAK", table.getFilename(2).?);
}

test "parseMidgameTable getOpeningFilename returns OPENING.PAK" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gfmidgam.bin");
    defer allocator.free(data);

    var table = try parseMidgameTable(allocator, data);
    defer table.deinit();

    try std.testing.expectEqualStrings("OPENING.PAK", table.getOpeningFilename().?);
}

test "parseMidgameTable rejects non-MIDG data" {
    const allocator = std.testing.allocator;
    // Use MOVI fixture (wrong FORM type)
    const data = try testing_helpers.loadFixture(allocator, "test_movi.bin");
    defer allocator.free(data);

    const result = parseMidgameTable(allocator, data);
    try std.testing.expectError(OpeningError.InvalidFormat, result);
}

test "parseMidgameTable rejects too-short data" {
    const allocator = std.testing.allocator;
    const result = parseMidgameTable(allocator, "short");
    try std.testing.expectError(OpeningError.InvalidFormat, result);
}

test "sceneNameToTrePath maps scene name to TRE path" {
    const allocator = std.testing.allocator;

    const path1 = try sceneNameToTrePath(allocator, "mid1a");
    defer allocator.free(path1);
    try std.testing.expectEqualStrings("MIDGAMES/MID1A.IFF", path1);

    const path2 = try sceneNameToTrePath(allocator, "mid1c3");
    defer allocator.free(path2);
    try std.testing.expectEqualStrings("MIDGAMES/MID1C3.IFF", path2);

    const path3 = try sceneNameToTrePath(allocator, "mid1f");
    defer allocator.free(path3);
    try std.testing.expectEqualStrings("MIDGAMES/MID1F.IFF", path3);
}

test "OpeningSequence getSceneTrePath returns mapped path" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_opening_pak.bin");
    defer allocator.free(data);

    var seq = try parsePlaylist(allocator, data);
    defer seq.deinit();

    const path = (try seq.getSceneTrePath(allocator, 0)).?;
    defer allocator.free(path);
    try std.testing.expectEqualStrings("MIDGAMES/MID1A.IFF", path);
}

test "OpeningSequence getSceneName out-of-bounds returns null" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_opening_pak.bin");
    defer allocator.free(data);

    var seq = try parsePlaylist(allocator, data);
    defer seq.deinit();

    try std.testing.expect(seq.getSceneName(99) == null);
}

test "OpeningSequence getSceneTrePath out-of-bounds returns null" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_opening_pak.bin");
    defer allocator.free(data);

    var seq = try parsePlaylist(allocator, data);
    defer seq.deinit();

    const result = try seq.getSceneTrePath(allocator, 99);
    try std.testing.expect(result == null);
}

test "variantBase strips trailing digit" {
    try std.testing.expectEqualStrings("mid1c", variantBase("mid1c1"));
    try std.testing.expectEqualStrings("mid1c", variantBase("mid1c4"));
    try std.testing.expectEqualStrings("mid1a", variantBase("mid1a"));
    try std.testing.expectEqualStrings("mid1f", variantBase("mid1f"));
    try std.testing.expectEqualStrings("", variantBase(""));
}

test "selectVariants collapses variant groups" {
    const allocator = std.testing.allocator;

    // Build a sequence with variant groups: mid1c1-c4, mid1e1-e4
    const raw_names = [_][]const u8{
        "mid1a", "mid1b", "mid1c1", "mid1c2", "mid1c3", "mid1c4",
        "mid1d", "mid1e1", "mid1e2", "mid1e3", "mid1e4", "mid1f",
    };

    var owned_names = try allocator.alloc([]const u8, raw_names.len);
    for (raw_names, 0..) |name, i| {
        owned_names[i] = try allocator.dupe(u8, name);
    }

    var seq = OpeningSequence{
        .scene_names = owned_names,
        .allocator = allocator,
    };
    defer seq.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    var result = try selectVariants(allocator, &seq, prng.random());
    defer result.deinit();

    // Should have 6 scenes: a, b, one of c1-c4, d, one of e1-e4, f
    try std.testing.expectEqual(@as(usize, 6), result.sceneCount());
    try std.testing.expectEqualStrings("mid1a", result.getSceneName(0).?);
    try std.testing.expectEqualStrings("mid1b", result.getSceneName(1).?);
    // Scene 2 should be one of c1-c4
    const c_pick = result.getSceneName(2).?;
    try std.testing.expect(std.mem.startsWith(u8, c_pick, "mid1c"));
    try std.testing.expectEqualStrings("mid1d", result.getSceneName(3).?);
    // Scene 4 should be one of e1-e4
    const e_pick = result.getSceneName(4).?;
    try std.testing.expect(std.mem.startsWith(u8, e_pick, "mid1e"));
    try std.testing.expectEqualStrings("mid1f", result.getSceneName(5).?);
}

test "selectVariants with no variants returns same list" {
    const allocator = std.testing.allocator;
    const raw_names = [_][]const u8{ "mid1a", "mid1b", "mid1d" };

    var owned_names = try allocator.alloc([]const u8, raw_names.len);
    for (raw_names, 0..) |name, i| {
        owned_names[i] = try allocator.dupe(u8, name);
    }

    var seq = OpeningSequence{
        .scene_names = owned_names,
        .allocator = allocator,
    };
    defer seq.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    var result = try selectVariants(allocator, &seq, prng.random());
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.sceneCount());
    try std.testing.expectEqualStrings("mid1a", result.getSceneName(0).?);
    try std.testing.expectEqualStrings("mid1b", result.getSceneName(1).?);
    try std.testing.expectEqualStrings("mid1d", result.getSceneName(2).?);
}

test "selectVariants always picks one from each group" {
    const allocator = std.testing.allocator;

    // Run multiple times with different seeds to verify invariant
    for (0..20) |seed| {
        const raw_names = [_][]const u8{ "mid1c1", "mid1c2", "mid1c3", "mid1c4" };

        var owned_names = try allocator.alloc([]const u8, raw_names.len);
        for (raw_names, 0..) |name, i| {
            owned_names[i] = try allocator.dupe(u8, name);
        }

        var seq = OpeningSequence{
            .scene_names = owned_names,
            .allocator = allocator,
        };
        defer seq.deinit();

        var prng = std.Random.DefaultPrng.init(seed);
        var result = try selectVariants(allocator, &seq, prng.random());
        defer result.deinit();

        // Should always produce exactly one scene
        try std.testing.expectEqual(@as(usize, 1), result.sceneCount());
        // And it should be one of the variants
        try std.testing.expect(std.mem.startsWith(u8, result.getSceneName(0).?, "mid1c"));
    }
}

test "selectVariants with empty sequence returns empty" {
    const allocator = std.testing.allocator;

    const owned_names = try allocator.alloc([]const u8, 0);
    var seq = OpeningSequence{
        .scene_names = owned_names,
        .allocator = allocator,
    };
    defer seq.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    var result = try selectVariants(allocator, &seq, prng.random());
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.sceneCount());
}

test "MidgameTable getFilename out-of-bounds returns null" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gfmidgam.bin");
    defer allocator.free(data);

    var table = try parseMidgameTable(allocator, data);
    defer table.deinit();

    try std.testing.expect(table.getFilename(99) == null);
}
