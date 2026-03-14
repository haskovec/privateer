//! Universe data loader for Wing Commander: Privateer.
//! Parses QUADRANT.IFF (FORM:UNIV) which defines the Gemini Sector layout:
//! 4 quadrants, each containing star systems with coordinates, names,
//! and optional base references.
//!
//! Structure (from real game data analysis):
//!   FORM:UNIV
//!     INFO (1 byte: number of quadrants)
//!     FORM:QUAD (per quadrant)
//!       INFO (4+ bytes: x(i16 LE), y(i16 LE), name(null-terminated))
//!       FORM:SYST (per star system)
//!         INFO (5+ bytes: index(u8), x(i16 LE), y(i16 LE), name(null-terminated))
//!         [BASE] (optional: list of base indices, one byte each)

const std = @import("std");
const iff = @import("iff.zig");

/// A star system within a quadrant.
pub const StarSystem = struct {
    /// Global system index (0-68 in the original game).
    index: u8,
    /// X coordinate on the nav map (signed, LE in data).
    x: i16,
    /// Y coordinate on the nav map (signed, LE in data).
    y: i16,
    /// System name (owned, null-terminated in original data).
    name: []const u8,
    /// Base indices referencing BASES.IFF entries (empty if no bases).
    base_indices: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *StarSystem) void {
        self.allocator.free(self.name);
        self.allocator.free(self.base_indices);
    }

    /// Returns true if this system has at least one base.
    pub fn hasBase(self: StarSystem) bool {
        return self.base_indices.len > 0;
    }
};

/// A quadrant of the Gemini Sector.
pub const Quadrant = struct {
    /// X coordinate of quadrant origin (signed, LE in data).
    x: i16,
    /// Y coordinate of quadrant origin (signed, LE in data).
    y: i16,
    /// Quadrant name (owned).
    name: []const u8,
    /// Star systems in this quadrant.
    systems: []StarSystem,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Quadrant) void {
        for (self.systems) |*sys| {
            var s = sys.*;
            s.deinit();
        }
        self.allocator.free(self.systems);
        self.allocator.free(self.name);
    }
};

/// The complete Gemini Sector universe.
pub const Universe = struct {
    /// Number of quadrants (from INFO chunk).
    quadrant_count: u8,
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

    /// Count total systems that have at least one base.
    pub fn totalBases(self: Universe) usize {
        var count: usize = 0;
        for (self.quadrants) |q| {
            for (q.systems) |sys| {
                if (sys.hasBase()) count += 1;
            }
        }
        return count;
    }

    /// Find a system by coordinates. Returns null if not found.
    pub fn findSystemByCoords(self: Universe, x: i16, y: i16) ?*const StarSystem {
        for (self.quadrants) |q| {
            for (q.systems) |*sys| {
                if (sys.x == x and sys.y == y) return sys;
            }
        }
        return null;
    }

    /// Find a system by its global index. Returns null if not found.
    pub fn findSystemByIndex(self: Universe, index: u8) ?*const StarSystem {
        for (self.quadrants) |q| {
            for (q.systems) |*sys| {
                if (sys.index == index) return sys;
            }
        }
        return null;
    }

    /// Find a system by name (case-insensitive). Returns null if not found.
    pub fn findSystemByName(self: Universe, name: []const u8) ?*const StarSystem {
        for (self.quadrants) |q| {
            for (q.systems) |*sys| {
                if (std.ascii.eqlIgnoreCase(sys.name, name)) return sys;
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

/// Read a little-endian i16 from a byte slice.
fn readI16LE(data: []const u8) i16 {
    return @bitCast(std.mem.readInt(u16, data[0..2], .little));
}

/// Parse a FORM:SYST chunk into a StarSystem.
fn parseSystem(allocator: std.mem.Allocator, chunk: iff.Chunk) UniverseError!StarSystem {
    if (!chunk.isContainer()) return UniverseError.InvalidFormat;
    if (!std.mem.eql(u8, &chunk.form_type.?, "SYST")) return UniverseError.InvalidFormat;

    const info_chunk = chunk.findChild("INFO".*) orelse return UniverseError.MissingInfo;
    // Minimum: index(1) + x(2) + y(2) = 5 bytes
    if (info_chunk.data.len < 5) return UniverseError.MissingInfo;

    const index = info_chunk.data[0];
    const x = readI16LE(info_chunk.data[1..3]);
    const y = readI16LE(info_chunk.data[3..5]);

    // Name starts at byte 5, null-terminated
    const name_data = info_chunk.data[5..];
    const name_len = std.mem.indexOfScalar(u8, name_data, 0) orelse name_data.len;
    const name = allocator.dupe(u8, name_data[0..name_len]) catch return UniverseError.OutOfMemory;
    errdefer allocator.free(name);

    // BASE chunk: list of base indices (one byte each)
    const base_chunk = chunk.findChild("BASE".*);
    const base_indices = if (base_chunk) |b|
        (allocator.dupe(u8, b.data) catch return UniverseError.OutOfMemory)
    else
        (allocator.alloc(u8, 0) catch return UniverseError.OutOfMemory);

    return StarSystem{
        .index = index,
        .x = x,
        .y = y,
        .name = name,
        .base_indices = base_indices,
        .allocator = allocator,
    };
}

/// Parse a FORM:QUAD chunk into a Quadrant.
fn parseQuadrant(allocator: std.mem.Allocator, chunk: iff.Chunk) UniverseError!Quadrant {
    if (!chunk.isContainer()) return UniverseError.InvalidFormat;
    if (!std.mem.eql(u8, &chunk.form_type.?, "QUAD")) return UniverseError.InvalidFormat;

    const info_chunk = chunk.findChild("INFO".*) orelse return UniverseError.MissingInfo;
    // Minimum: x(2) + y(2) = 4 bytes
    if (info_chunk.data.len < 4) return UniverseError.MissingInfo;

    const x = readI16LE(info_chunk.data[0..2]);
    const y = readI16LE(info_chunk.data[2..4]);

    // Name starts at byte 4, null-terminated
    const name_data = info_chunk.data[4..];
    const name_len = std.mem.indexOfScalar(u8, name_data, 0) orelse name_data.len;
    const name = allocator.dupe(u8, name_data[0..name_len]) catch return UniverseError.OutOfMemory;
    errdefer allocator.free(name);

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
    errdefer {
        for (systems[0..idx]) |*s| {
            var sys = s.*;
            sys.deinit();
        }
    }
    for (chunk.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SYST")) {
            systems[idx] = try parseSystem(allocator, child);
            idx += 1;
        }
    }

    return Quadrant{
        .x = x,
        .y = y,
        .name = name,
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
        .quadrant_count = info_chunk.data[0],
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
    try std.testing.expectEqual(@as(u8, 0x02), universe.quadrant_count);
}

test "parseUniverse quadrant 0 has correct name and coords" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const q0 = universe.quadrants[0];
    try std.testing.expectEqualStrings("Alpha", q0.name);
    try std.testing.expectEqual(@as(i16, -50), q0.x);
    try std.testing.expectEqual(@as(i16, 50), q0.y);
    try std.testing.expectEqual(@as(usize, 3), q0.systems.len);
}

test "parseUniverse quadrant 0 system 0 has correct properties" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys0 = universe.quadrants[0].systems[0];
    try std.testing.expectEqual(@as(u8, 0), sys0.index);
    try std.testing.expectEqual(@as(i16, -30), sys0.x);
    try std.testing.expectEqual(@as(i16, 40), sys0.y);
    try std.testing.expectEqualStrings("Troy", sys0.name);
    try std.testing.expectEqual(@as(usize, 2), sys0.base_indices.len);
    try std.testing.expectEqual(@as(u8, 0), sys0.base_indices[0]);
    try std.testing.expectEqual(@as(u8, 1), sys0.base_indices[1]);
}

test "parseUniverse system without base has empty base_indices" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys1 = universe.quadrants[0].systems[1];
    try std.testing.expectEqual(@as(u8, 1), sys1.index);
    try std.testing.expectEqual(@as(i16, -60), sys1.x);
    try std.testing.expectEqual(@as(i16, 20), sys1.y);
    try std.testing.expectEqualStrings("Palan", sys1.name);
    try std.testing.expectEqual(@as(usize, 0), sys1.base_indices.len);
    try std.testing.expect(!sys1.hasBase());
}

test "parseUniverse quadrant 1 has correct name and systems" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const q1 = universe.quadrants[1];
    try std.testing.expectEqualStrings("Beta", q1.name);
    try std.testing.expectEqual(@as(i16, 50), q1.x);
    try std.testing.expectEqual(@as(i16, -50), q1.y);
    try std.testing.expectEqual(@as(usize, 2), q1.systems.len);

    const sys0 = q1.systems[0];
    try std.testing.expectEqual(@as(u8, 3), sys0.index);
    try std.testing.expectEqualStrings("Perry", sys0.name);
    try std.testing.expectEqual(@as(usize, 1), sys0.base_indices.len);

    const sys1 = q1.systems[1];
    try std.testing.expectEqual(@as(u8, 4), sys1.index);
    try std.testing.expectEqualStrings("Junction", sys1.name);
    try std.testing.expect(!sys1.hasBase());
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

    // Troy (2 bases), Oxford (1 base), Perry (1 base) = 3 systems with bases
    try std.testing.expectEqual(@as(usize, 3), universe.totalBases());
}

test "Universe.findSystemByCoords finds existing system" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys = universe.findSystemByCoords(-40, 70);
    try std.testing.expect(sys != null);
    try std.testing.expectEqualStrings("Oxford", sys.?.name);
    try std.testing.expectEqual(@as(usize, 1), sys.?.base_indices.len);
}

test "Universe.findSystemByCoords returns null for missing coords" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    try std.testing.expect(universe.findSystemByCoords(999, 999) == null);
}

test "Universe.findSystemByIndex finds system" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys = universe.findSystemByIndex(2);
    try std.testing.expect(sys != null);
    try std.testing.expectEqualStrings("Oxford", sys.?.name);

    try std.testing.expect(universe.findSystemByIndex(99) == null);
}

test "Universe.findSystemByName finds system case-insensitively" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_quadrant.bin");
    defer allocator.free(data);

    var universe = try parseUniverse(allocator, data);
    defer universe.deinit();

    const sys = universe.findSystemByName("troy");
    try std.testing.expect(sys != null);
    try std.testing.expectEqual(@as(u8, 0), sys.?.index);
    try std.testing.expectEqual(@as(i16, -30), sys.?.x);
    try std.testing.expectEqual(@as(i16, 40), sys.?.y);

    try std.testing.expect(universe.findSystemByName("Nonexistent") == null);
}

test "parseUniverse rejects non-UNIV form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(UniverseError.InvalidFormat, parseUniverse(allocator, data));
}

test "parseUniverse rejects truncated data" {
    try std.testing.expectError(UniverseError.InvalidFormat, parseUniverse(std.testing.allocator, "FORM"));
}
