//! Bar/fixer encounter system for Wing Commander: Privateer.
//!
//! Manages plot-driven NPC encounters at bars. Fixers are special NPCs
//! that appear at specific bases when plot conditions are met, advancing
//! the storyline through dialogue.
//!
//! The system works by examining the active plot mission's CAST and SCEN
//! data to determine which fixer should appear at which system:
//!   - CAST: names of NPCs involved in the mission
//!   - SCEN: scene objectives with system_id and participant indices
//!   - FLAG: boolean flags gating mission progression
//!
//! PlotState tracks the player's current position in the mission chain
//! (series 0-7, mission A-D within each series).

const std = @import("std");
const plot_missions = @import("../missions/plot_missions.zig");
const plot_series = @import("../missions/plot_series.zig");

/// Maximum number of plot flags tracked.
const MAX_FLAGS = 32;

/// Player index in the CAST array (always first entry).
const PLAYER_CAST_INDEX: u16 = 0;

/// Tracks the player's progress through the plot mission chain.
pub const PlotState = struct {
    /// Active series number (0-7, matching S0-S7 mission files).
    current_series: u8,
    /// Mission index within the series (0=A, 1=B, etc.).
    current_mission: u8,
    /// Boolean flag array for current mission state.
    flags: [MAX_FLAGS]u8,
    /// Number of active flags (from the current mission's FLAG chunk).
    flag_count: u8,
    /// True when all plot missions have been completed.
    completed: bool,

    /// Create a new PlotState at the beginning of the story (S0MA).
    pub fn init() PlotState {
        return .{
            .current_series = 0,
            .current_mission = 0,
            .flags = .{0} ** MAX_FLAGS,
            .flag_count = 0,
            .completed = false,
        };
    }

    /// Load flags from a mission's FLAG chunk data.
    pub fn setFlags(self: *PlotState, flags: []const u8) void {
        const count: u8 = @intCast(@min(flags.len, MAX_FLAGS));
        @memcpy(self.flags[0..count], flags[0..count]);
        // Zero remaining flags
        @memset(self.flags[count..], 0);
        self.flag_count = count;
    }

    /// Get a flag value by index. Returns false if out of range.
    pub fn getFlag(self: *const PlotState, index: u8) bool {
        if (index >= self.flag_count) return false;
        return self.flags[index] != 0;
    }

    /// Set a flag value by index. No-op if out of range.
    pub fn setFlag(self: *PlotState, index: u8, value: bool) void {
        if (index >= self.flag_count) return;
        self.flags[index] = if (value) 1 else 0;
    }

    /// Get the MissionId for the current plot position.
    /// Returns null if the plot is completed.
    pub fn currentMissionId(self: *const PlotState) ?plot_series.MissionId {
        if (self.completed) return null;
        return plot_series.MissionId{
            .series = self.current_series,
            .letter = self.current_mission,
        };
    }

    /// Advance to the next mission in the plot chain.
    /// Moves to the next mission letter within the series, or to the
    /// first mission of the next series if the current series is complete.
    /// Sets completed=true when all missions are finished.
    pub fn advanceToNextMission(self: *PlotState) void {
        if (self.completed) return;

        const expected = plot_series.expectedMissionCount(self.current_series);
        if (expected) |count| {
            if (self.current_mission + 1 < count) {
                // Next mission in same series
                self.current_mission += 1;
                self.resetFlags();
                return;
            }
        }

        // Advance to next series
        if (self.advanceToNextSeries()) {
            self.current_mission = 0;
            self.resetFlags();
        } else {
            self.completed = true;
        }
    }

    /// Find and advance to the next valid series after the current one.
    /// Returns true if a next series was found, false if all done.
    fn advanceToNextSeries(self: *PlotState) bool {
        var next = self.current_series + 1;
        while (next <= 9) : (next += 1) {
            if (plot_series.expectedMissionCount(next) != null) {
                self.current_series = next;
                return true;
            }
        }
        return false;
    }

    /// Reset all flags to zero (called on mission advance).
    fn resetFlags(self: *PlotState) void {
        @memset(&self.flags, 0);
        self.flag_count = 0;
    }
};

/// A fixer NPC encounter at a bar.
pub const FixerEncounter = struct {
    /// Fixer character name from the CAST chunk (null-padded to 8 bytes).
    fixer_name: [8]u8,
    /// System where the encounter takes place.
    system_id: u8,
    /// Index into the mission's CAST array.
    cast_index: u16,

    /// Get the fixer name as a trimmed string slice.
    pub fn name(self: *const FixerEncounter) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.fixer_name, 0) orelse 8;
        return self.fixer_name[0..end];
    }
};

/// Search a plot mission's scene objectives for a fixer encounter at the
/// given system. Returns the encounter info if a fixer should appear, or
/// null if no encounter is available at this system.
///
/// A fixer encounter is identified by:
///   - Scene type 1 (encounter/waypoint)
///   - A specific system_id (not 0xFF)
///   - At least one non-player participant in the CAST array
pub fn findFixerInMission(mission: *const plot_missions.PlotMission, current_system: u8) ?FixerEncounter {
    for (mission.objectives) |obj| {
        // Only encounter-type scenes at specific systems
        if (obj.scene_type != 1) continue;
        if (obj.system_id == 0xFF) continue;
        if (obj.system_id != current_system) continue;

        // Find first non-player participant
        for (obj.participants) |participant_idx| {
            if (participant_idx == PLAYER_CAST_INDEX) continue;

            // Look up the cast entry
            if (participant_idx < mission.cast.len) {
                return FixerEncounter{
                    .fixer_name = mission.cast[participant_idx].raw,
                    .system_id = obj.system_id,
                    .cast_index = participant_idx,
                };
            }
        }
    }
    return null;
}

/// Check if a fixer encounter is available given the current plot state,
/// mission data, and the player's current system.
/// Returns null if no fixer should appear (wrong system, plot completed,
/// or flags indicate the encounter is already done).
pub fn checkFixerAvailable(
    state: *const PlotState,
    mission: *const plot_missions.PlotMission,
    current_system: u8,
) ?FixerEncounter {
    if (state.completed) return null;

    // Check if any flag is set that would indicate encounter already happened.
    // In Privateer, flag[0] being set typically means the initial encounter
    // for this mission has already occurred.
    if (state.flag_count > 0 and state.getFlag(0)) return null;

    return findFixerInMission(mission, current_system);
}

// ── Tests ───────────────────────────────────────────────────────────

// -- PlotState tests --

test "PlotState.init starts at series 0, mission 0" {
    const state = PlotState.init();
    try std.testing.expectEqual(@as(u8, 0), state.current_series);
    try std.testing.expectEqual(@as(u8, 0), state.current_mission);
    try std.testing.expect(!state.completed);
}

test "PlotState.init has all flags zeroed" {
    const state = PlotState.init();
    try std.testing.expectEqual(@as(u8, 0), state.flag_count);
    for (state.flags) |f| {
        try std.testing.expectEqual(@as(u8, 0), f);
    }
}

test "PlotState.currentMissionId returns S0MA at start" {
    const state = PlotState.init();
    const id = state.currentMissionId().?;
    try std.testing.expectEqual(@as(u8, 0), id.series);
    try std.testing.expectEqual(@as(u8, 0), id.letter);
    try std.testing.expectEqualStrings("S0MA.IFF", &id.toFilename());
}

test "PlotState.setFlags loads flags from mission data" {
    var state = PlotState.init();
    state.setFlags(&.{ 0, 1, 0 });
    try std.testing.expectEqual(@as(u8, 3), state.flag_count);
    try std.testing.expect(!state.getFlag(0));
    try std.testing.expect(state.getFlag(1));
    try std.testing.expect(!state.getFlag(2));
}

test "PlotState.setFlag modifies a flag" {
    var state = PlotState.init();
    state.setFlags(&.{ 0, 0 });
    state.setFlag(0, true);
    try std.testing.expect(state.getFlag(0));
    try std.testing.expect(!state.getFlag(1));
}

test "PlotState.getFlag returns false for out of range" {
    const state = PlotState.init();
    try std.testing.expect(!state.getFlag(99));
}

test "PlotState.setFlag is no-op for out of range" {
    var state = PlotState.init();
    state.setFlags(&.{0});
    state.setFlag(99, true);
    // Should not crash or modify anything
    try std.testing.expect(!state.getFlag(99));
}

// -- Mission advancement tests --

test "advanceToNextMission moves from S0MA to S1MA" {
    var state = PlotState.init();
    // S0 has 1 mission, so advancing goes to S1
    state.advanceToNextMission();

    try std.testing.expectEqual(@as(u8, 1), state.current_series);
    try std.testing.expectEqual(@as(u8, 0), state.current_mission);
    try std.testing.expect(!state.completed);
}

test "advanceToNextMission moves within a series" {
    var state = PlotState.init();
    state.current_series = 1;
    state.current_mission = 0;
    state.advanceToNextMission();

    // S1 has 4 missions, so A -> B
    try std.testing.expectEqual(@as(u8, 1), state.current_series);
    try std.testing.expectEqual(@as(u8, 1), state.current_mission);
    try std.testing.expect(!state.completed);
}

test "advanceToNextMission moves from S1MD to S2MA" {
    var state = PlotState.init();
    state.current_series = 1;
    state.current_mission = 3; // D (last in S1)
    state.advanceToNextMission();

    try std.testing.expectEqual(@as(u8, 2), state.current_series);
    try std.testing.expectEqual(@as(u8, 0), state.current_mission);
}

test "advanceToNextMission skips series 6 (no missions)" {
    var state = PlotState.init();
    state.current_series = 5;
    state.current_mission = 3; // Last in S5
    state.advanceToNextMission();

    // S6 doesn't exist, should skip to S7
    try std.testing.expectEqual(@as(u8, 7), state.current_series);
    try std.testing.expectEqual(@as(u8, 0), state.current_mission);
}

test "advanceToNextMission sets completed after S7MB" {
    var state = PlotState.init();
    state.current_series = 7;
    state.current_mission = 1; // B (last in S7)
    state.advanceToNextMission();

    try std.testing.expect(state.completed);
}

test "advanceToNextMission is no-op when already completed" {
    var state = PlotState.init();
    state.completed = true;
    state.advanceToNextMission();
    try std.testing.expect(state.completed);
}

test "advanceToNextMission resets flags" {
    var state = PlotState.init();
    state.setFlags(&.{ 1, 1 });
    state.advanceToNextMission();
    try std.testing.expectEqual(@as(u8, 0), state.flag_count);
    try std.testing.expect(!state.getFlag(0));
}

test "currentMissionId returns null when completed" {
    var state = PlotState.init();
    state.completed = true;
    try std.testing.expect(state.currentMissionId() == null);
}

test "full plot progression through all series" {
    var state = PlotState.init();
    var mission_count: u16 = 0;

    while (!state.completed) {
        mission_count += 1;
        state.advanceToNextMission();
    }

    // Total: 1(S0) + 4(S1) + 4(S2) + 4(S3) + 4(S4) + 4(S5) + 2(S7) = 23
    // We advance 23 times (once from each mission, the last one sets completed)
    try std.testing.expectEqual(plot_series.TOTAL_EXPECTED_MISSIONS, mission_count);
}

// -- FixerEncounter tests --

test "FixerEncounter.name trims null padding" {
    const encounter = FixerEncounter{
        .fixer_name = "PIR_AA\x00\x00".*,
        .system_id = 0x29,
        .cast_index = 1,
    };
    try std.testing.expectEqualStrings("PIR_AA", encounter.name());
}

test "FixerEncounter.name handles full-length name" {
    const encounter = FixerEncounter{
        .fixer_name = "ABCDEFGH".*,
        .system_id = 0x10,
        .cast_index = 2,
    };
    try std.testing.expectEqualStrings("ABCDEFGH", encounter.name());
}

// -- findFixerInMission tests --

test "findFixerInMission returns fixer at matching system" {
    var participants = [_]u16{ 0, 1 };
    var objectives = [_]plot_missions.SceneObjective{
        .{
            .scene_type = 1,
            .nav_point = 0xFF,
            .system_id = 0xFF,
            .location_data = .{ 0xFF, 0xFF },
            .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
            .participants = &.{0},
            .allocator = std.testing.allocator,
        },
        .{
            .scene_type = 1,
            .nav_point = 0x00,
            .system_id = 0x29,
            .location_data = .{ 0x00, 0x00 },
            .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
            .participants = &participants,
            .allocator = std.testing.allocator,
        },
    };
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
        .{ .raw = "PIR_AA\x00\x00".* },
    };
    var flags = [_]u8{ 0, 0 };
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 15000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    const encounter = findFixerInMission(&mission, 0x29).?;
    try std.testing.expectEqualStrings("PIR_AA", encounter.name());
    try std.testing.expectEqual(@as(u8, 0x29), encounter.system_id);
    try std.testing.expectEqual(@as(u16, 1), encounter.cast_index);
}

test "findFixerInMission returns null at wrong system" {
    var participants = [_]u16{ 0, 1 };
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 1,
        .nav_point = 0x00,
        .system_id = 0x29,
        .location_data = .{ 0x00, 0x00 },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &participants,
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
        .{ .raw = "PIR_AA\x00\x00".* },
    };
    var flags = [_]u8{0};
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 15000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    // System 0x10 != 0x29
    try std.testing.expect(findFixerInMission(&mission, 0x10) == null);
}

test "findFixerInMission ignores scenes with system 0xFF" {
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 1,
        .nav_point = 0xFF,
        .system_id = 0xFF,
        .location_data = .{ 0xFF, 0xFF },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &.{0},
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
    };
    var flags = [_]u8{0};
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 5000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(findFixerInMission(&mission, 0xFF) == null);
}

test "findFixerInMission ignores scene type 0" {
    var participants = [_]u16{ 0, 1 };
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 0, // completion, not encounter
        .nav_point = 0x00,
        .system_id = 0x29,
        .location_data = .{ 0x00, 0x00 },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &participants,
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
        .{ .raw = "PIR_AA\x00\x00".* },
    };
    var flags = [_]u8{0};
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 15000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(findFixerInMission(&mission, 0x29) == null);
}

test "findFixerInMission skips player-only scenes" {
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 1,
        .nav_point = 0x00,
        .system_id = 0x29,
        .location_data = .{ 0x00, 0x00 },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &.{0}, // only player
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
    };
    var flags = [_]u8{0};
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 5000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(findFixerInMission(&mission, 0x29) == null);
}

// -- checkFixerAvailable tests --

test "checkFixerAvailable returns fixer when conditions met" {
    const state = PlotState.init();
    var participants = [_]u16{ 0, 1 };
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 1,
        .nav_point = 0x00,
        .system_id = 0x29,
        .location_data = .{ 0x00, 0x00 },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &participants,
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
        .{ .raw = "FIXER\x00\x00\x00".* },
    };
    var flags = [_]u8{ 0, 0 };
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 10000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    const encounter = checkFixerAvailable(&state, &mission, 0x29).?;
    try std.testing.expectEqualStrings("FIXER", encounter.name());
}

test "checkFixerAvailable returns null when plot completed" {
    var state = PlotState.init();
    state.completed = true;
    var participants = [_]u16{ 0, 1 };
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 1,
        .nav_point = 0x00,
        .system_id = 0x29,
        .location_data = .{ 0x00, 0x00 },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &participants,
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
        .{ .raw = "FIXER\x00\x00\x00".* },
    };
    var flags = [_]u8{0};
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 10000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(checkFixerAvailable(&state, &mission, 0x29) == null);
}

test "checkFixerAvailable returns null when flag 0 is set" {
    var state = PlotState.init();
    state.setFlags(&.{ 0, 0 });
    state.setFlag(0, true); // encounter already happened

    var participants = [_]u16{ 0, 1 };
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 1,
        .nav_point = 0x00,
        .system_id = 0x29,
        .location_data = .{ 0x00, 0x00 },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &participants,
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
        .{ .raw = "FIXER\x00\x00\x00".* },
    };
    var flags = [_]u8{0};
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 10000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(checkFixerAvailable(&state, &mission, 0x29) == null);
}

test "checkFixerAvailable returns null at wrong system" {
    const state = PlotState.init();
    var participants = [_]u16{ 0, 1 };
    var objectives = [_]plot_missions.SceneObjective{.{
        .scene_type = 1,
        .nav_point = 0x00,
        .system_id = 0x29,
        .location_data = .{ 0x00, 0x00 },
        .reserved = .{ 0xFF, 0xFF, 0xFF, 0xFF },
        .participants = &participants,
        .allocator = std.testing.allocator,
    }};
    var cast = [_]plot_missions.CastEntry{
        .{ .raw = "PLAYER\x00\x00".* },
        .{ .raw = "FIXER\x00\x00\x00".* },
    };
    var flags = [_]u8{0};
    const mission = plot_missions.PlotMission{
        .briefing = "Test",
        .reward = 10000,
        .cargo = null,
        .jump = null,
        .cast = &cast,
        .flags = &flags,
        .program = &.{ 0x47, 0x00 },
        .participants = &.{},
        .objectives = &objectives,
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(checkFixerAvailable(&state, &mission, 0x10) == null);
}
