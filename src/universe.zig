//! Universe data loader for Wing Commander: Privateer.
//! Parses QUADRANT.IFF (FORM:UNIV) which defines the Gemini Sector layout:
//! 4 quadrants, each containing star systems with coordinates, faction control,
//! hazard levels, and optional bases.
//!
//! Structure:
//!   FORM:UNIV
//!     INFO (1 byte: number of quadrants)
//!     FORM:QUAD (per quadrant)
//!       INFO (1 byte: quadrant metadata)
//!       FORM:SYST (per star system)
//!         INFO (4 bytes: x, y, faction, hazard)
//!         [BASE] (optional: 1 byte base type)

const std = @import("std");
const iff = @import("iff.zig");

/// A star system within a quadrant.
pub const StarSystem = struct {
    /// X coordinate on the nav map.
    x: u8,
    /// Y coordinate on the nav map.
    y: u8,
    /// Faction ID controlling this system.
    faction: u8,
    /// Hazard level (encounter difficulty).
    hazard: u8,
    /// Base type if a base is present (null if no base).
    base_type: ?u8,
};

/// A quadrant of the Gemini Sector.
pub const Quadrant = struct {
    /// Quadrant metadata byte from INFO chunk.
    info: u8,
    /// Star systems in this quadrant.
    systems: []StarSystem,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Quadrant) void {
        self.allocator.free(self.systems);
    }
};

/// The complete Gemini Sector universe.
pub const Universe = struct {
    /// Universe metadata byte from INFO chunk (number of quadrants).
    info: u8,
    /// All quadrants in the universe.
    quadrants: []Quadrant,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Universe) void {
        for (self.quadrants) |*q| {
            var quad = q.*;
            quad.deinit();
        }
        self.allocator.free(self.quadrants);
    }

    /// Count total star systems across all quadrants.
    pub fn totalSystems(self: Universe) usize {
        var count: usize = 0;
        for (self.quadrants) |q| {
            count += q.systems.len;
        }
        return count;
    }

    /// Count total bases across all quadrants.
    pub fn totalBases(self: Universe) usize {
        var count: usize = 0;
        for (self.quadrants) |q| {
            for (q.systems) |sys| {
                if (sys.base_type != null) count += 1;
            }
        }
        return count;
    }

    /// Find a system by coordinates. Returns null if not found.
    pub fn findSystemByCoords(self: Universe, x: u8, y: u8) ?*const StarSystem {
        for (self.quadrants) |q| {
            for (q.systems) |*sys| {
                if (sys.x == x and sys.y == y) return sys;
            }
        }
        return null;
    }
};

pub const UniverseError = error{
    InvalidFormat,
    MissingInfo,
    OutOfMemory,
};

/// Parse a FORM:SYST chunk into a StarSystem.
fn parseSystem(chunk: iff.Chunk) UniverseError!StarSystem {
    if (!chunk.isContainer()) return UniverseError.InvalidFormat;
    if (!std.mem.eql(u8, &chunk.form_type.?, "SYST")) return UniverseError.InvalidFormat;

    const info_chunk = chunk.findChild("INFO".*) orelse return UniverseError.MissingInfo;
    if (info_chunk.data.len < 4) return UniverseError.MissingInfo;

    const base_chunk = chunk.findChild("BASE".*);

    return StarSystem{
        .x = info_chunk.data[0],
        .y = info_chunk.data[1],
        .faction = info_chunk.data[2],
        .hazard = info_chunk.data[3],
        .base_type = if (base_chunk) |b| (if (b.data.len > 0) b.data[0] else null) else null,
    };
}

/// Parse a FORM:QUAD chunk into a Quadrant.
fn parseQuadrant(allocator: std.mem.Allocator, chunk: iff.Chunk) UniverseError!Quadrant {
    if (!chunk.isContainer()) return UniverseError.InvalidFormat;
    if (!std.mem.eql(u8, &chunk.form_type.?, "QUAD")) return UniverseError.InvalidFormat;

    const info_chunk = chunk.findChild("INFO".*) orelse return UniverseError.MissingInfo;
    if (info_chunk.data.len < 1) return UniverseError.MissingInfo;

    // Count FORM:SYST children
    var syst_count: usize = 0;
    for (chunk.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SYST")) {
            syst_count += 1;
        }
    }

    const systems = allocator.alloc(StarSystem, syst_count) catch return UniverseError.OutOfMemory;
    errdefer allocator.free(systems);

    var idx: usize = 0;
    for (chunk.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SYST")) {
            systems[idx] = try parseSystem(child);
            idx += 1;
        }
    }

    return Quadrant{
        .info = info_chunk.data[0],
        .systems = systems,
        .allocator = allocator,
    };
}

/// Parse a QUADRANT.IFF file (FORM:UNIV) into a Universe structure.
/// The input data should be the raw IFF file bytes.
pub fn parseUniverse(allocator: std.mem.Allocator, data: []const u8) UniverseError!Universe {
    var root = iff.parseFile(allocator, data) catch return UniverseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return UniverseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "UNIV")) return UniverseError.InvalidFormat;

    const info_chunk = root.findChild("INFO".*) orelse return UniverseError.MissingInfo;
    if (info_chunk.data.len < 1) return UniverseError.MissingInfo;

    // Count FORM:QUAD children
    var quad_count: usize = 0;
    for (root.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "QUAD")) {
            quad_count += 1;
        }
    }

    const quadrants = allocator.alloc(Quadrant, quad_count) catch return UniverseError.OutOfMemory;
    errdefer allocator.free(quadrants);

    var idx: usize = 0;
    errdefer {
        for (quadrants[0..idx]) |*q| {
            var quad = q.*;
            quad.deinit();
        }
    }
    for (root.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "QUAD")) {
            quadrants[idx] = try parseQuadrant(allocator, child);
            idx += 1;
        }
    }

    return Universe{
        .info = info_chunk.data[0],
        .quadrants = quadrants,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("testing.zig");

test "parseUniverse loads test fixture with 2 quadrants" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    try std.testing.expectEqual(@as(usize, 2), universe.quadrants.len);
    try std.testing.expectEqual(@as(u8, 0x02), universe.info);
}

test "parseUniverse quadrant 0 has 3 systems" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const q0 = universe.quadrants[0];
    try std.testing.expectEqual(@as(usize, 3), q0.systems.len);
}

test "parseUniverse quadrant 0 system 0 has correct properties" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys0 = universe.quadrants[0].systems[0];
    try std.testing.expectEqual(@as(u8, 10), sys0.x);
    try std.testing.expectEqual(@as(u8, 20), sys0.y);
    try std.testing.expectEqual(@as(u8, 1), sys0.faction);
    try std.testing.expectEqual(@as(u8, 2), sys0.hazard);
    try std.testing.expectEqual(@as(u8, 3), sys0.base_type.?);
}

test "parseUniverse system without base has null base_type" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys1 = universe.quadrants[0].systems[1];
    try std.testing.expectEqual(@as(u8, 30), sys1.x);
    try std.testing.expectEqual(@as(u8, 40), sys1.y);
    try std.testing.expectEqual(@as(u8, 2), sys1.faction);
    try std.testing.expectEqual(@as(u8, 1), sys1.hazard);
    try std.testing.expect(sys1.base_type == null);
}

test "parseUniverse quadrant 1 has 2 systems" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const q1 = universe.quadrants[1];
    try std.testing.expectEqual(@as(usize, 2), q1.systems.len);

    // System 0: coords (70, 80), faction 3, hazard 1, no base
    const sys0 = q1.systems[0];
    try std.testing.expectEqual(@as(u8, 70), sys0.x);
    try std.testing.expectEqual(@as(u8, 80), sys0.y);
    try std.testing.expectEqual(@as(u8, 3), sys0.faction);
    try std.testing.expect(sys0.base_type == null);

    // System 1: coords (90, 100), faction 2, hazard 2, base type 2
    const sys1 = q1.systems[1];
    try std.testing.expectEqual(@as(u8, 90), sys1.x);
    try std.testing.expectEqual(@as(u8, 100), sys1.y);
    try std.testing.expectEqual(@as(u8, 2), sys1.base_type.?);
}

test "Universe.totalSystems counts all systems" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    try std.testing.expectEqual(@as(usize, 5), universe.totalSystems());
}

test "Universe.totalBases counts systems with bases" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    try std.testing.expectEqual(@as(usize, 3), universe.totalBases());
}

test "Universe.findSystemByCoords finds existing system" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys = universe.findSystemByCoords(50, 60);
    try std.testing.expect(sys != null);
    try std.testing.expectEqual(@as(u8, 1), sys.?.faction);
    try std.testing.expectEqual(@as(u8, 1), sys.?.base_type.?);
}

test "Universe.findSystemByCoords returns null for missing coords" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    try std.testing.expect(universe.findSystemByCoords(255, 255) == null);
}

test "parseUniverse rejects non-UNIV form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(UniverseError.InvalidFormat, parseUniverse(allocator, data));
}

test "parseUniverse rejects truncated data" {
    try std.testing.expectError(UniverseError.InvalidFormat, parseUniverse(std.testing.allocator, "FORM"));
}
