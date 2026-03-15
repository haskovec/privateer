//! Plot mission series catalog and validation for Wing Commander: Privateer.
//!
//! Groups the 24 plot missions by series (S0-S9), validates mission data
//! consistency, and provides utilities for verifying the complete mission chain.
//!
//! Series layout (verified against real PRIV.TRE data):
//!   S0: 1 mission (A)          - Introduction
//!   S1: 4 missions (A-D)       - Story arc 1
//!   S2: 4 missions (A-D)       - Story arc 2
//!   S3: 4 missions (A-D)       - Story arc 3
//!   S4: 4 missions (A-D)       - Story arc 4
//!   S5: 4 missions (A-D)       - Story arc 5
//!   S7: 2 missions (A-B)       - Story arc 7 (finale)

const std = @import("std");
const plot_missions = @import("plot_missions.zig");

/// Identifies a specific plot mission by series number and mission letter.
pub const MissionId = struct {
    /// Series number (0-9).
    series: u8,
    /// Mission letter index (0 = 'A', 1 = 'B', etc.).
    letter: u8,

    /// Parse a mission ID from a filename like "S1MA.IFF" or "s2mb.iff".
    /// Returns null for filenames that don't match the pattern.
    pub fn fromFilename(name: []const u8) ?MissionId {
        if (name.len < 8) return null;
        if (std.ascii.toUpper(name[0]) != 'S') return null;

        const series_char = name[1];
        if (series_char < '0' or series_char > '9') return null;

        if (std.ascii.toUpper(name[2]) != 'M') return null;

        const letter_char = std.ascii.toUpper(name[3]);
        if (letter_char < 'A' or letter_char > 'Z') return null;

        if (!std.ascii.eqlIgnoreCase(name[4..8], ".IFF")) return null;

        return MissionId{
            .series = series_char - '0',
            .letter = letter_char - 'A',
        };
    }

    /// Format as a standard filename (e.g., "S1MA.IFF").
    pub fn toFilename(self: MissionId) [8]u8 {
        return .{
            'S',
            '0' + self.series,
            'M',
            'A' + self.letter,
            '.',
            'I',
            'F',
            'F',
        };
    }
};

/// Expected number of missions per series.
pub const SeriesInfo = struct {
    series: u8,
    expected_count: u8,
};

/// Known plot mission series and their expected mission counts.
/// Verified against actual PRIV.TRE mission file inventory.
pub const SERIES = [_]SeriesInfo{
    .{ .series = 0, .expected_count = 1 },
    .{ .series = 1, .expected_count = 4 },
    .{ .series = 2, .expected_count = 4 },
    .{ .series = 3, .expected_count = 4 },
    .{ .series = 4, .expected_count = 4 },
    .{ .series = 5, .expected_count = 4 },
    .{ .series = 7, .expected_count = 2 },
};

/// Total number of expected plot mission files across all series.
pub const TOTAL_EXPECTED_MISSIONS: u16 = blk: {
    var total: u16 = 0;
    for (SERIES) |s| {
        total += s.expected_count;
    }
    break :blk total;
};

/// Number of known series.
pub const SERIES_COUNT = SERIES.len;

/// Validation error types for mission data.
pub const ValidationError = enum {
    empty_briefing,
    empty_program,
    no_cast_members,
    no_objectives,
    program_odd_length,
};

/// Result of validating a plot mission.
pub const ValidationResult = struct {
    errors: [MAX_ERRORS]?ValidationError = .{null} ** MAX_ERRORS,
    error_count: usize = 0,

    const MAX_ERRORS = 16;

    pub fn isValid(self: *const ValidationResult) bool {
        return self.error_count == 0;
    }

    pub fn hasError(self: *const ValidationResult, err: ValidationError) bool {
        for (self.errors[0..self.error_count]) |e| {
            if (e == err) return true;
        }
        return false;
    }

    fn addError(self: *ValidationResult, err: ValidationError) void {
        if (self.error_count < MAX_ERRORS) {
            self.errors[self.error_count] = err;
            self.error_count += 1;
        }
    }
};

/// Validate a parsed plot mission for structural consistency.
pub fn validateMission(mission: *const plot_missions.PlotMission) ValidationResult {
    var result = ValidationResult{};

    if (mission.briefing.len == 0) {
        result.addError(.empty_briefing);
    }
    if (mission.program.len == 0) {
        result.addError(.empty_program);
    }
    if (mission.program.len % 2 != 0) {
        result.addError(.program_odd_length);
    }
    if (mission.cast.len == 0) {
        result.addError(.no_cast_members);
    }
    if (mission.objectives.len == 0) {
        result.addError(.no_objectives);
    }

    return result;
}

/// Look up the expected mission count for a series number.
/// Returns null if the series is not a known plot series.
pub fn expectedMissionCount(series: u8) ?u8 {
    for (SERIES) |s| {
        if (s.series == series) return s.expected_count;
    }
    return null;
}

/// Count missions per series from an array of MissionIds.
/// Returns an array indexed by series number (0-9) with counts.
pub fn countBySeries(ids: []const MissionId) [10]u8 {
    var counts = [_]u8{0} ** 10;
    for (ids) |id| {
        if (id.series < 10) {
            counts[id.series] += 1;
        }
    }
    return counts;
}

// ── Tests ───────────────────────────────────────────────────────────

test "MissionId.fromFilename parses S0MA.IFF" {
    const id = MissionId.fromFilename("S0MA.IFF").?;
    try std.testing.expectEqual(@as(u8, 0), id.series);
    try std.testing.expectEqual(@as(u8, 0), id.letter);
}

test "MissionId.fromFilename parses S1MD.IFF" {
    const id = MissionId.fromFilename("S1MD.IFF").?;
    try std.testing.expectEqual(@as(u8, 1), id.series);
    try std.testing.expectEqual(@as(u8, 3), id.letter);
}

test "MissionId.fromFilename parses lowercase s2mb.iff" {
    const id = MissionId.fromFilename("s2mb.iff").?;
    try std.testing.expectEqual(@as(u8, 2), id.series);
    try std.testing.expectEqual(@as(u8, 1), id.letter);
}

test "MissionId.fromFilename parses S9MA.IFF" {
    const id = MissionId.fromFilename("S9MA.IFF").?;
    try std.testing.expectEqual(@as(u8, 9), id.series);
    try std.testing.expectEqual(@as(u8, 0), id.letter);
}

test "MissionId.fromFilename returns null for non-mission files" {
    try std.testing.expect(MissionId.fromFilename("SKELETON.IFF") == null);
    try std.testing.expect(MissionId.fromFilename("PLOTMSNS.IFF") == null);
    try std.testing.expect(MissionId.fromFilename("BFILMNGR.IFF") == null);
    try std.testing.expect(MissionId.fromFilename("foo.txt") == null);
    try std.testing.expect(MissionId.fromFilename("S0MA") == null); // too short, no .IFF
}

test "MissionId.toFilename produces correct filename" {
    const id = MissionId{ .series = 1, .letter = 2 };
    try std.testing.expectEqualStrings("S1MC.IFF", &id.toFilename());
}

test "MissionId roundtrip: fromFilename -> toFilename" {
    const original = "S3MB.IFF";
    const id = MissionId.fromFilename(original).?;
    try std.testing.expectEqualStrings(original, &id.toFilename());
}

test "TOTAL_EXPECTED_MISSIONS equals 23" {
    try std.testing.expectEqual(@as(u16, 23), TOTAL_EXPECTED_MISSIONS);
}

test "SERIES_COUNT equals 7" {
    try std.testing.expectEqual(@as(usize, 7), SERIES_COUNT);
}

test "expectedMissionCount returns correct values" {
    try std.testing.expectEqual(@as(?u8, 1), expectedMissionCount(0));
    try std.testing.expectEqual(@as(?u8, 4), expectedMissionCount(1));
    try std.testing.expectEqual(@as(?u8, 4), expectedMissionCount(2));
    try std.testing.expectEqual(@as(?u8, 4), expectedMissionCount(3));
    try std.testing.expectEqual(@as(?u8, 4), expectedMissionCount(4));
    try std.testing.expectEqual(@as(?u8, 4), expectedMissionCount(5));
    try std.testing.expectEqual(@as(?u8, null), expectedMissionCount(6));
    try std.testing.expectEqual(@as(?u8, 2), expectedMissionCount(7));
    try std.testing.expectEqual(@as(?u8, null), expectedMissionCount(8));
    try std.testing.expectEqual(@as(?u8, null), expectedMissionCount(9));
}

test "countBySeries counts correctly" {
    const ids = [_]MissionId{
        .{ .series = 1, .letter = 0 },
        .{ .series = 1, .letter = 1 },
        .{ .series = 2, .letter = 0 },
        .{ .series = 9, .letter = 0 },
    };
    const counts = countBySeries(&ids);
    try std.testing.expectEqual(@as(u8, 0), counts[0]);
    try std.testing.expectEqual(@as(u8, 2), counts[1]);
    try std.testing.expectEqual(@as(u8, 1), counts[2]);
    try std.testing.expectEqual(@as(u8, 1), counts[9]);
}

/// Build a test PlotMission with overridable fields.
const TestMissionOpts = struct {
    briefing: []const u8 = "Test mission",
    program: []const u8 = &.{ 0x47, 0x00 },
    cast: ?[]plot_missions.CastEntry = null,
    objectives: ?[]plot_missions.SceneObjective = null,
};

fn makeTestMission(opts: TestMissionOpts) struct {
    flags: [1]u8,
    default_cast: [1]plot_missions.CastEntry,
    default_obj: [1]plot_missions.SceneObjective,

    pub fn get(self: *@This(), options: TestMissionOpts) plot_missions.PlotMission {
        return plot_missions.PlotMission{
            .briefing = options.briefing,
            .reward = 1000,
            .cargo = null,
            .jump = null,
            .cast = options.cast orelse &self.default_cast,
            .flags = &self.flags,
            .program = options.program,
            .participants = &.{},
            .objectives = options.objectives orelse &self.default_obj,
            .allocator = std.testing.allocator,
        };
    }
} {
    _ = opts;
    return .{
        .flags = .{0},
        .default_cast = .{.{ .raw = "PLAYER\x00\x00".* }},
        .default_obj = .{.{
            .scene_type = 1,
            .nav_point = 0xFF,
            .system_id = 0xFF,
            .location_data = .{ 0xFF, 0xFF },
            .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
            .participants = &.{},
            .allocator = std.testing.allocator,
        }},
    };
}

test "validateMission returns valid for well-formed mission" {
    var ctx = makeTestMission(.{});
    const mission = ctx.get(.{});
    const result = validateMission(&mission);
    try std.testing.expect(result.isValid());
}

test "validateMission detects empty briefing" {
    var ctx = makeTestMission(.{});
    const mission = ctx.get(.{ .briefing = "" });
    const result = validateMission(&mission);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.hasError(.empty_briefing));
}

test "validateMission detects empty program" {
    var ctx = makeTestMission(.{});
    const mission = ctx.get(.{ .program = &.{} });
    const result = validateMission(&mission);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.hasError(.empty_program));
}

test "validateMission detects odd-length program" {
    var ctx = makeTestMission(.{});
    const mission = ctx.get(.{ .program = &.{ 0x47, 0x00, 0x01 } });
    const result = validateMission(&mission);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.hasError(.program_odd_length));
}

test "validateMission detects no cast members" {
    var ctx = makeTestMission(.{});
    var empty_cast = [_]plot_missions.CastEntry{};
    const mission = ctx.get(.{ .cast = &empty_cast });
    const result = validateMission(&mission);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.hasError(.no_cast_members));
}

test "validateMission detects no objectives" {
    var ctx = makeTestMission(.{});
    var empty_objectives = [_]plot_missions.SceneObjective{};
    const mission = ctx.get(.{ .objectives = &empty_objectives });
    const result = validateMission(&mission);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.hasError(.no_objectives));
}

test "validateMission detects multiple errors" {
    var ctx = makeTestMission(.{});
    var empty_cast = [_]plot_missions.CastEntry{};
    var empty_objectives = [_]plot_missions.SceneObjective{};
    const mission = ctx.get(.{
        .briefing = "",
        .program = &.{},
        .cast = &empty_cast,
        .objectives = &empty_objectives,
    });
    const result = validateMission(&mission);
    try std.testing.expect(!result.isValid());
    try std.testing.expectEqual(@as(usize, 4), result.error_count);
    try std.testing.expect(result.hasError(.empty_briefing));
    try std.testing.expect(result.hasError(.empty_program));
    try std.testing.expect(result.hasError(.no_cast_members));
    try std.testing.expect(result.hasError(.no_objectives));
}
