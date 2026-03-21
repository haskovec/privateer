//! Movie sound effects system for Wing Commander: Privateer intro cinematic.
//!
//! Loads sound effects from SOUNDFX.PAK (nested PAK containing VOC files)
//! and provides event-to-sound mapping from COMBAT.DAT for playback during
//! intro movie flight scenes (mid1b, mid1c*, mid1e*).
//!
//! Data architecture:
//!   SOUNDFX.PAK: outer PAK wrapping an inner PAK with 43 VOC sound clips
//!   COMBAT.DAT:  PAK-wrapped mapping table — byte groups separated by 0xFF
//!                map event categories to SOUNDFX.PAK resource indices
//!
//! Audio pipeline: SOUNDFX.PAK → nested PAK parse → VOC decode → 8-bit PCM
//!   → SoundMixer.play() (layered over music/voice via separate SDL3 channels)

const std = @import("std");
const pak_mod = @import("../formats/pak.zig");
const voc_mod = @import("../formats/voc.zig");
const sound_effects = @import("../audio/sound_effects.zig");

/// Maximum number of sound effect resources we expect in SOUNDFX.PAK.
pub const MAX_SFX_RESOURCES = 64;

/// Maximum number of event groups in COMBAT.DAT.
pub const MAX_EVENT_GROUPS = 32;

/// Maximum entries per event group.
pub const MAX_GROUP_ENTRIES = 64;

pub const MovieSfxError = error{
    /// SOUNDFX.PAK outer PAK has no resources.
    EmptyOuterPak,
    /// The inner PAK (resource 0 of outer) could not be parsed.
    InvalidInnerPak,
    /// COMBAT.DAT has no data resource.
    EmptyMappingFile,
    /// A VOC resource could not be decoded.
    InvalidVocData,
    OutOfMemory,
};

/// A single sound effect sample decoded from a VOC resource.
pub const SfxSample = struct {
    /// PCM audio data (8-bit unsigned, mono). Owned.
    samples: []const u8,
    /// Sample rate in Hz (typically 11025).
    sample_rate: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SfxSample) void {
        self.allocator.free(self.samples);
    }

    pub fn durationMs(self: SfxSample) u32 {
        if (self.sample_rate == 0) return 0;
        return @intCast((self.samples.len * 1000) / self.sample_rate);
    }
};

/// Bank of sound effect samples loaded from SOUNDFX.PAK.
///
/// SOUNDFX.PAK is a nested PAK: the outer PAK contains one resource which
/// is itself a PAK file holding 43 VOC sound clips. Each VOC is decoded
/// to 8-bit unsigned PCM for playback via SoundMixer.
pub const SfxBank = struct {
    samples: []?SfxSample,
    count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SfxBank {
        return .{
            .samples = &.{},
            .count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SfxBank) void {
        for (self.samples) |*slot| {
            if (slot.*) |*sample| sample.deinit();
            slot.* = null;
        }
        if (self.samples.len > 0) self.allocator.free(self.samples);
    }

    /// Load sound effects from SOUNDFX.PAK data (the complete file).
    /// Handles the nested PAK structure: outer → inner → VOC resources.
    pub fn loadFromPak(self: *SfxBank, data: []const u8) MovieSfxError!void {
        // Parse outer PAK
        var outer_pak = pak_mod.parse(self.allocator, data) catch return MovieSfxError.EmptyOuterPak;
        defer outer_pak.deinit();

        if (outer_pak.resourceCount() == 0) return MovieSfxError.EmptyOuterPak;

        // Resource 0 of outer PAK is the inner PAK
        const inner_data = outer_pak.getResource(0) catch return MovieSfxError.EmptyOuterPak;

        // Parse inner PAK
        var inner_pak = pak_mod.parse(self.allocator, inner_data) catch return MovieSfxError.InvalidInnerPak;
        defer inner_pak.deinit();

        const resource_count = inner_pak.resourceCount();
        if (resource_count == 0) return MovieSfxError.InvalidInnerPak;

        // Allocate sample slots
        const slots = self.allocator.alloc(?SfxSample, resource_count) catch return MovieSfxError.OutOfMemory;
        @memset(slots, null);

        // Decode each VOC resource
        var loaded: usize = 0;
        for (0..resource_count) |i| {
            const voc_data = inner_pak.getResource(i) catch continue;
            slots[i] = decodeVocToSample(self.allocator, voc_data) catch null;
            if (slots[i] != null) loaded += 1;
        }

        self.samples = slots;
        self.count = loaded;
    }

    /// Get a sound sample by index (null if not loaded or out of range).
    pub fn getSample(self: *const SfxBank, index: usize) ?*const SfxSample {
        if (index >= self.samples.len) return null;
        return if (self.samples[index]) |*s| s else null;
    }

    /// Number of successfully loaded samples.
    pub fn loadedCount(self: *const SfxBank) usize {
        return self.count;
    }

    /// Total number of resource slots (loaded + failed).
    pub fn totalSlots(self: *const SfxBank) usize {
        return self.samples.len;
    }

    /// Convert a loaded SfxSample to a SoundSample for use with SoundBank.
    pub fn toSoundSample(sample: *const SfxSample) sound_effects.SoundSample {
        return .{
            .data = sample.samples,
            .sample_rate = sample.sample_rate,
            .owned = false, // SfxBank owns the data
        };
    }
};

/// Decode a VOC file's raw bytes into a SfxSample with owned PCM data.
fn decodeVocToSample(allocator: std.mem.Allocator, voc_data: []const u8) MovieSfxError!SfxSample {
    var voc_file = voc_mod.parse(allocator, voc_data) catch return MovieSfxError.InvalidVocData;

    const samples = allocator.dupe(u8, voc_file.samples) catch {
        voc_file.deinit();
        return MovieSfxError.OutOfMemory;
    };
    const sample_rate = voc_file.sample_rate;
    voc_file.deinit();

    return SfxSample{
        .samples = samples,
        .sample_rate = sample_rate,
        .allocator = allocator,
    };
}

// ── COMBAT.DAT Event Mapping ────────────────────────────────────────

/// An event group: a category of combat events mapped to SFX indices.
pub const EventGroup = struct {
    /// SFX indices for this event category.
    indices: []const u8,
};

/// Combat event-to-SFX mapping parsed from COMBAT.DAT.
///
/// COMBAT.DAT is a PAK-wrapped data file. The data portion contains
/// byte groups separated by 0xFF markers. Each group maps a category
/// of combat events (weapons, impacts, explosions, etc.) to indices
/// into SOUNDFX.PAK.
pub const CombatSfxMap = struct {
    groups: []EventGroup,
    /// Raw data backing the group slices.
    raw_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CombatSfxMap {
        return .{
            .groups = &.{},
            .raw_data = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CombatSfxMap) void {
        if (self.groups.len > 0) self.allocator.free(self.groups);
        if (self.raw_data.len > 0) self.allocator.free(self.raw_data);
    }

    /// Load event mapping from COMBAT.DAT file data.
    /// Handles the PAK wrapper and parses the byte-group mapping.
    pub fn loadFromData(self: *CombatSfxMap, data: []const u8) MovieSfxError!void {
        // Parse as PAK to extract the data resource
        var combat_pak = pak_mod.parse(self.allocator, data) catch return MovieSfxError.EmptyMappingFile;
        defer combat_pak.deinit();

        if (combat_pak.resourceCount() == 0) return MovieSfxError.EmptyMappingFile;

        const mapping_data = combat_pak.getResource(0) catch return MovieSfxError.EmptyMappingFile;

        // Copy the data (PAK doesn't own it, but we need it to outlive the PAK)
        const owned_data = self.allocator.dupe(u8, mapping_data) catch return MovieSfxError.OutOfMemory;
        errdefer self.allocator.free(owned_data);

        // Parse groups separated by 0xFF
        const groups = parseGroups(self.allocator, owned_data) catch return MovieSfxError.OutOfMemory;

        self.raw_data = owned_data;
        self.groups = groups;
    }

    /// Number of event groups parsed.
    pub fn groupCount(self: *const CombatSfxMap) usize {
        return self.groups.len;
    }

    /// Get the SFX indices for an event group.
    pub fn getGroup(self: *const CombatSfxMap, group_index: usize) ?[]const u8 {
        if (group_index >= self.groups.len) return null;
        return self.groups[group_index].indices;
    }

    /// Look up a specific SFX index by group and entry within group.
    pub fn getSfxIndex(self: *const CombatSfxMap, group_index: usize, entry_index: usize) ?u8 {
        const group = self.getGroup(group_index) orelse return null;
        if (entry_index >= group.len) return null;
        return group[entry_index];
    }
};

/// Parse byte data into groups separated by 0xFF markers.
fn parseGroups(allocator: std.mem.Allocator, data: []const u8) ![]EventGroup {
    // First pass: count groups
    var group_count: usize = 0;
    var in_group = false;
    for (data) |b| {
        if (b == 0xFF) {
            if (in_group) {
                group_count += 1;
                in_group = false;
            }
        } else {
            in_group = true;
        }
    }
    if (in_group) group_count += 1; // trailing group without final 0xFF

    if (group_count == 0) return allocator.alloc(EventGroup, 0);

    // Second pass: collect groups
    const groups = try allocator.alloc(EventGroup, group_count);
    var gi: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == 0xFF) {
            if (i > start) {
                groups[gi] = .{ .indices = data[start..i] };
                gi += 1;
            }
            start = i + 1;
        }
    }
    // Trailing group
    if (start < data.len) {
        groups[gi] = .{ .indices = data[start..] };
        gi += 1;
    }

    // Trim if we over-allocated (shouldn't happen, but be safe)
    if (gi < group_count) {
        return allocator.realloc(groups, gi);
    }
    return groups;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

test "SfxBank.init has no samples" {
    var bank = SfxBank.init(std.testing.allocator);
    defer bank.deinit();

    try std.testing.expectEqual(@as(usize, 0), bank.loadedCount());
    try std.testing.expectEqual(@as(usize, 0), bank.totalSlots());
    try std.testing.expect(bank.getSample(0) == null);
}

test "SfxBank.loadFromPak parses nested PAK with VOC resources" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_soundfx.bin");
    defer allocator.free(data);

    var bank = SfxBank.init(allocator);
    defer bank.deinit();

    try bank.loadFromPak(data);

    // Fixture has 3 VOC resources
    try std.testing.expectEqual(@as(usize, 3), bank.totalSlots());
    try std.testing.expectEqual(@as(usize, 3), bank.loadedCount());
}

test "SfxBank samples have valid PCM data and sample rate" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_soundfx.bin");
    defer allocator.free(data);

    var bank = SfxBank.init(allocator);
    defer bank.deinit();

    try bank.loadFromPak(data);

    // Sample 0: 8 PCM samples at ~11025 Hz
    const s0 = bank.getSample(0).?;
    try std.testing.expectEqual(@as(usize, 8), s0.samples.len);
    try std.testing.expect(s0.sample_rate >= 10000);
    try std.testing.expect(s0.sample_rate <= 12000);
    try std.testing.expectEqual(@as(u8, 128), s0.samples[0]); // first sample

    // Sample 1: 8 PCM samples
    const s1 = bank.getSample(1).?;
    try std.testing.expectEqual(@as(usize, 8), s1.samples.len);

    // Sample 2: 4 PCM samples
    const s2 = bank.getSample(2).?;
    try std.testing.expectEqual(@as(usize, 4), s2.samples.len);
}

test "SfxBank.getSample returns null for out-of-range index" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_soundfx.bin");
    defer allocator.free(data);

    var bank = SfxBank.init(allocator);
    defer bank.deinit();

    try bank.loadFromPak(data);

    try std.testing.expect(bank.getSample(3) == null);
    try std.testing.expect(bank.getSample(99) == null);
}

test "SfxBank.loadFromPak rejects empty data" {
    const allocator = std.testing.allocator;
    const too_small = [_]u8{0} ** 4;
    var bank = SfxBank.init(allocator);
    defer bank.deinit();

    try std.testing.expectError(MovieSfxError.EmptyOuterPak, bank.loadFromPak(&too_small));
}

test "SfxSample.durationMs calculates correctly" {
    const sample = SfxSample{
        .samples = &[_]u8{128} ** 11025,
        .sample_rate = 11025,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(u32, 1000), sample.durationMs());
}

test "SfxBank.toSoundSample converts for SoundBank compatibility" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_soundfx.bin");
    defer allocator.free(data);

    var bank = SfxBank.init(allocator);
    defer bank.deinit();

    try bank.loadFromPak(data);

    const sfx = bank.getSample(0).?;
    const ss = SfxBank.toSoundSample(sfx);

    try std.testing.expectEqual(sfx.samples.len, ss.data.len);
    try std.testing.expectEqual(sfx.sample_rate, ss.sample_rate);
    try std.testing.expect(!ss.owned); // SfxBank owns the data
}

test "CombatSfxMap.init has no groups" {
    var map = CombatSfxMap.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 0), map.groupCount());
    try std.testing.expect(map.getGroup(0) == null);
}

test "CombatSfxMap.loadFromData parses event groups" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_combat_dat.bin");
    defer allocator.free(data);

    var map = CombatSfxMap.init(allocator);
    defer map.deinit();

    try map.loadFromData(data);

    // Fixture has 3 groups: [0,1,2], [1,2], [0,2]
    try std.testing.expectEqual(@as(usize, 3), map.groupCount());
}

test "CombatSfxMap groups contain correct SFX indices" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_combat_dat.bin");
    defer allocator.free(data);

    var map = CombatSfxMap.init(allocator);
    defer map.deinit();

    try map.loadFromData(data);

    // Group 0: weapons → [0, 1, 2]
    const g0 = map.getGroup(0).?;
    try std.testing.expectEqual(@as(usize, 3), g0.len);
    try std.testing.expectEqual(@as(u8, 0), g0[0]);
    try std.testing.expectEqual(@as(u8, 1), g0[1]);
    try std.testing.expectEqual(@as(u8, 2), g0[2]);

    // Group 1: impacts → [1, 2]
    const g1 = map.getGroup(1).?;
    try std.testing.expectEqual(@as(usize, 2), g1.len);
    try std.testing.expectEqual(@as(u8, 1), g1[0]);
    try std.testing.expectEqual(@as(u8, 2), g1[1]);

    // Group 2: explosions → [0, 2]
    const g2 = map.getGroup(2).?;
    try std.testing.expectEqual(@as(usize, 2), g2.len);
    try std.testing.expectEqual(@as(u8, 0), g2[0]);
    try std.testing.expectEqual(@as(u8, 2), g2[1]);
}

test "CombatSfxMap.getSfxIndex looks up by group and entry" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_combat_dat.bin");
    defer allocator.free(data);

    var map = CombatSfxMap.init(allocator);
    defer map.deinit();

    try map.loadFromData(data);

    try std.testing.expectEqual(@as(u8, 0), map.getSfxIndex(0, 0).?);
    try std.testing.expectEqual(@as(u8, 2), map.getSfxIndex(0, 2).?);
    try std.testing.expectEqual(@as(u8, 1), map.getSfxIndex(1, 0).?);
    try std.testing.expectEqual(@as(u8, 2), map.getSfxIndex(2, 1).?);
}

test "CombatSfxMap.getSfxIndex returns null for invalid indices" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_combat_dat.bin");
    defer allocator.free(data);

    var map = CombatSfxMap.init(allocator);
    defer map.deinit();

    try map.loadFromData(data);

    try std.testing.expect(map.getSfxIndex(99, 0) == null); // bad group
    try std.testing.expect(map.getSfxIndex(0, 99) == null); // bad entry
}

test "CombatSfxMap.loadFromData rejects empty data" {
    const allocator = std.testing.allocator;
    const too_small = [_]u8{0} ** 4;
    var map = CombatSfxMap.init(allocator);
    defer map.deinit();

    try std.testing.expectError(MovieSfxError.EmptyMappingFile, map.loadFromData(&too_small));
}

test "parseGroups handles empty data" {
    const allocator = std.testing.allocator;
    const groups = try parseGroups(allocator, &.{});
    defer allocator.free(groups);
    try std.testing.expectEqual(@as(usize, 0), groups.len);
}

test "parseGroups handles single group without trailing FF" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 5, 10, 15 };
    const groups = try parseGroups(allocator, &data);
    defer allocator.free(groups);

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 3), groups[0].indices.len);
}

test "parseGroups skips consecutive FF markers" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 1, 2, 0xFF, 0xFF, 0xFF, 3, 4, 0xFF };
    const groups = try parseGroups(allocator, &data);
    defer allocator.free(groups);

    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].indices.len);
    try std.testing.expectEqual(@as(usize, 2), groups[1].indices.len);
}
