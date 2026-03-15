//! Faction reputation system for Wing Commander: Privateer.
//!
//! Parses ATTITUDE.IFF (FORM:ATTD) which defines initial faction dispositions,
//! the kill reputation matrix, and the hostility threshold.
//!
//! Structure:
//!   FORM:ATTD
//!     DISP (N*2 bytes: initial disposition per faction, i16 LE each)
//!     KMAT (N*N bytes: kill matrix, i8 values, row=killed faction, col=affected faction)
//!     THRS (2 bytes: hostility threshold, i16 LE)

const std = @import("std");
const iff = @import("../formats/iff.zig");

/// Maximum number of factions supported.
pub const MAX_FACTIONS = 8;

/// Faction identifiers matching SpawnFaction ordering.
pub const Faction = enum(u8) {
    confed = 0,
    militia = 1,
    merchant = 2,
    pirate = 3,
    kilrathi = 4,
    retro = 5,
};

pub const FACTION_COUNT = 6;

/// Faction attitude data loaded from ATTITUDE.IFF.
pub const AttitudeData = struct {
    /// Number of factions in the data.
    faction_count: u8,
    /// Initial disposition toward each faction.
    initial_dispositions: [MAX_FACTIONS]i16,
    /// Kill reputation matrix: kill_matrix[killed][affected] = rep change.
    kill_matrix: [MAX_FACTIONS][MAX_FACTIONS]i8,
    /// Below this threshold, a faction becomes hostile to the player.
    hostility_threshold: i16,
};

pub const ParseError = error{
    InvalidFormat,
    MissingData,
};

fn readI16LE(data: []const u8) i16 {
    return @bitCast(std.mem.readInt(u16, data[0..2], .little));
}

/// Parse ATTITUDE.IFF (FORM:ATTD) into AttitudeData.
pub fn parseAttitude(allocator: std.mem.Allocator, data: []const u8) ParseError!AttitudeData {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "ATTD")) return ParseError.InvalidFormat;

    var result = AttitudeData{
        .faction_count = 0,
        .initial_dispositions = [_]i16{0} ** MAX_FACTIONS,
        .kill_matrix = [_][MAX_FACTIONS]i8{[_]i8{0} ** MAX_FACTIONS} ** MAX_FACTIONS,
        .hostility_threshold = -30,
    };

    // Parse DISP (initial dispositions)
    if (root.findChild("DISP".*)) |disp| {
        const count: u8 = @intCast(@min(disp.data.len / 2, MAX_FACTIONS));
        result.faction_count = count;
        for (0..count) |i| {
            const offset = i * 2;
            result.initial_dispositions[i] = readI16LE(disp.data[offset .. offset + 2]);
        }
    } else return ParseError.MissingData;

    // Parse KMAT (kill matrix: faction_count x faction_count, i8 each)
    if (root.findChild("KMAT".*)) |kmat| {
        const n = result.faction_count;
        if (kmat.data.len >= @as(usize, n) * @as(usize, n)) {
            for (0..n) |row| {
                for (0..n) |col| {
                    result.kill_matrix[row][col] = @bitCast(kmat.data[row * n + col]);
                }
            }
        }
    }

    // Parse THRS (hostility threshold)
    if (root.findChild("THRS".*)) |thrs| {
        if (thrs.data.len >= 2) {
            result.hostility_threshold = readI16LE(thrs.data[0..2]);
        }
    }

    return result;
}

// ── Player Reputation Tracker ───────────────────────────────────────

/// Tracks the player's reputation with each faction.
pub const PlayerReputation = struct {
    /// Current standing with each faction.
    standings: [MAX_FACTIONS]i16,
    /// Attitude data (kill matrix, thresholds).
    attitude: AttitudeData,

    /// Initialize with default dispositions from attitude data.
    pub fn init(attitude: AttitudeData) PlayerReputation {
        return .{
            .standings = attitude.initial_dispositions,
            .attitude = attitude,
        };
    }

    /// Get the player's current standing with a faction.
    pub fn getStanding(self: *const PlayerReputation, faction: Faction) i16 {
        return self.standings[@intFromEnum(faction)];
    }

    /// Check if a faction is hostile to the player (below threshold).
    pub fn isHostile(self: *const PlayerReputation, faction: Faction) bool {
        return self.standings[@intFromEnum(faction)] < self.attitude.hostility_threshold;
    }

    /// Apply reputation changes from killing a member of the given faction.
    pub fn applyKill(self: *PlayerReputation, killed_faction: Faction) void {
        const killed_idx = @intFromEnum(killed_faction);
        const n = self.attitude.faction_count;
        for (0..n) |i| {
            const delta: i16 = self.attitude.kill_matrix[killed_idx][i];
            self.standings[i] = std.math.clamp(
                self.standings[i] + delta,
                -100,
                100,
            );
        }
    }

    /// Directly modify standing with a faction (e.g., from mission rewards).
    pub fn modifyStanding(self: *PlayerReputation, faction: Faction, delta: i16) void {
        const idx = @intFromEnum(faction);
        self.standings[idx] = std.math.clamp(
            self.standings[idx] + delta,
            -100,
            100,
        );
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

fn loadTestAttitude(allocator: std.mem.Allocator) !struct { attitude: AttitudeData, data: []const u8 } {
    const data = try testing_helpers.loadFixture(allocator, "test_attitude.bin");
    const attitude = parseAttitude(allocator, data) catch {
        allocator.free(data);
        return error.TestFixtureError;
    };
    return .{ .attitude = attitude, .data = data };
}

test "parseAttitude loads 6 factions" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    try std.testing.expectEqual(@as(u8, 6), loaded.attitude.faction_count);
}

test "parseAttitude initial dispositions correct" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    try std.testing.expectEqual(@as(i16, 25), loaded.attitude.initial_dispositions[0]); // Confed
    try std.testing.expectEqual(@as(i16, 25), loaded.attitude.initial_dispositions[1]); // Militia
    try std.testing.expectEqual(@as(i16, 0), loaded.attitude.initial_dispositions[2]); // Merchants
    try std.testing.expectEqual(@as(i16, -50), loaded.attitude.initial_dispositions[3]); // Pirates
    try std.testing.expectEqual(@as(i16, -75), loaded.attitude.initial_dispositions[4]); // Kilrathi
    try std.testing.expectEqual(@as(i16, -50), loaded.attitude.initial_dispositions[5]); // Retro
}

test "parseAttitude hostility threshold" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    try std.testing.expectEqual(@as(i16, -30), loaded.attitude.hostility_threshold);
}

test "parseAttitude kill matrix for killing pirate" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    // Kill pirate (index 3): Confed+5, Militia+3, Merchant+2, Pirate-10
    const pirate_row = loaded.attitude.kill_matrix[3];
    try std.testing.expectEqual(@as(i8, 5), pirate_row[0]); // Confed
    try std.testing.expectEqual(@as(i8, 3), pirate_row[1]); // Militia
    try std.testing.expectEqual(@as(i8, 2), pirate_row[2]); // Merchants
    try std.testing.expectEqual(@as(i8, -10), pirate_row[3]); // Pirates
}

test "killing pirate improves Confed reputation" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    var rep = PlayerReputation.init(loaded.attitude);
    const initial_confed = rep.getStanding(.confed);

    rep.applyKill(.pirate);

    try std.testing.expect(rep.getStanding(.confed) > initial_confed);
    try std.testing.expectEqual(initial_confed + 5, rep.getStanding(.confed));
}

test "killing pirate worsens Pirate reputation" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    var rep = PlayerReputation.init(loaded.attitude);
    const initial_pirate = rep.getStanding(.pirate);

    rep.applyKill(.pirate);

    try std.testing.expect(rep.getStanding(.pirate) < initial_pirate);
    try std.testing.expectEqual(initial_pirate - 10, rep.getStanding(.pirate));
}

test "low reputation makes faction hostile" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    var rep = PlayerReputation.init(loaded.attitude);

    // Pirates start at -50 which is below threshold -30, so hostile
    try std.testing.expect(rep.isHostile(.pirate));
    // Kilrathi start at -75, also hostile
    try std.testing.expect(rep.isHostile(.kilrathi));
    // Confed starts at +25, not hostile
    try std.testing.expect(!rep.isHostile(.confed));
    // Merchants start at 0, not hostile
    try std.testing.expect(!rep.isHostile(.merchant));
}

test "reputation can cross hostility threshold" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    var rep = PlayerReputation.init(loaded.attitude);

    // Confed starts at 25, not hostile
    try std.testing.expect(!rep.isHostile(.confed));

    // Kill enough Confed ships to cross the threshold
    // Kill Confed: Confed rep -10 each time
    // Need to go from 25 to below -30: need at least 6 kills (25 - 60 = -35)
    rep.applyKill(.confed);
    rep.applyKill(.confed);
    rep.applyKill(.confed);
    rep.applyKill(.confed);
    rep.applyKill(.confed);
    try std.testing.expect(!rep.isHostile(.confed)); // 25 - 50 = -25, not yet
    rep.applyKill(.confed);
    try std.testing.expect(rep.isHostile(.confed)); // 25 - 60 = -35, hostile!
}

test "reputation is clamped to -100..100" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    var rep = PlayerReputation.init(loaded.attitude);

    // Boost Confed a lot
    rep.modifyStanding(.confed, 200);
    try std.testing.expectEqual(@as(i16, 100), rep.getStanding(.confed));

    // Tank Confed a lot
    rep.modifyStanding(.confed, -300);
    try std.testing.expectEqual(@as(i16, -100), rep.getStanding(.confed));
}

test "modifyStanding applies direct rep changes" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestAttitude(allocator);
    defer allocator.free(loaded.data);

    var rep = PlayerReputation.init(loaded.attitude);
    try std.testing.expectEqual(@as(i16, 0), rep.getStanding(.merchant));

    rep.modifyStanding(.merchant, 15);
    try std.testing.expectEqual(@as(i16, 15), rep.getStanding(.merchant));

    rep.modifyStanding(.merchant, -20);
    try std.testing.expectEqual(@as(i16, -5), rep.getStanding(.merchant));
}

test "parseAttitude rejects non-ATTD form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseAttitude(allocator, data));
}
