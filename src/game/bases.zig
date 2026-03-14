//! Base data loader for Wing Commander: Privateer.
//! Parses BASES.IFF (FORM:BASE) which defines all bases in the Gemini Sector.
//!
//! Structure (from real game data analysis):
//!   FORM:BASE
//!     DATA (N bytes: counts per base type)
//!     INFO (per base: index(u8), type(u8), name(null-terminated))

const std = @import("std");
const iff = @import("../formats/iff.zig");

/// A base in the Gemini Sector.
pub const Base = struct {
    /// Base index (matches indices stored in StarSystem.base_indices).
    index: u8,
    /// Base type ID (0-6, determines available facilities).
    base_type: u8,
    /// Base name (owned).
    name: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Base) void {
        self.allocator.free(self.name);
    }
};

/// All bases loaded from BASES.IFF.
pub const BaseRegistry = struct {
    /// All bases, ordered by their index within the file.
    bases: []Base,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *BaseRegistry) void {
        for (self.bases) |*b| {
            var base = b.*;
            base.deinit();
        }
        self.allocator.free(self.bases);
    }

    /// Find a base by its index. Returns null if not found.
    pub fn findByIndex(self: BaseRegistry, index: u8) ?*const Base {
        for (self.bases) |*b| {
            if (b.index == index) return b;
        }
        return null;
    }

    /// Find a base by name (case-insensitive). Returns null if not found.
    pub fn findByName(self: BaseRegistry, name: []const u8) ?*const Base {
        for (self.bases) |*b| {
            if (std.ascii.eqlIgnoreCase(b.name, name)) return b;
        }
        return null;
    }
};

pub const BaseError = error{
    InvalidFormat,
    MissingInfo,
    OutOfMemory,
};

/// Parse a BASES.IFF file (FORM:BASE) into a BaseRegistry.
pub fn parseBases(allocator: std.mem.Allocator, data: []const u8) BaseError!BaseRegistry {
    var root = iff.parseFile(allocator, data) catch return BaseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return BaseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "BASE")) return BaseError.InvalidFormat;

    // Count INFO chunks (skip the DATA chunk)
    var info_count: usize = 0;
    for (root.children) |child| {
        if (!child.isContainer() and std.mem.eql(u8, &child.tag, "INFO")) {
            info_count += 1;
        }
    }

    const bases = allocator.alloc(Base, info_count) catch return BaseError.OutOfMemory;
    errdefer allocator.free(bases);

    var idx: usize = 0;
    errdefer {
        for (bases[0..idx]) |*b| {
            var base = b.*;
            base.deinit();
        }
    }

    for (root.children) |child| {
        if (!child.isContainer() and std.mem.eql(u8, &child.tag, "INFO")) {
            // Minimum: index(1) + type(1) = 2 bytes
            if (child.data.len < 2) return BaseError.MissingInfo;

            const base_index = child.data[0];
            const base_type = child.data[1];

            // Name starts at byte 2, null-terminated
            const name_data = child.data[2..];
            const name_len = std.mem.indexOfScalar(u8, name_data, 0) orelse name_data.len;
            const name = allocator.dupe(u8, name_data[0..name_len]) catch return BaseError.OutOfMemory;

            bases[idx] = Base{
                .index = base_index,
                .base_type = base_type,
                .name = name,
                .allocator = allocator,
            };
            idx += 1;
        }
    }

    return BaseRegistry{
        .bases = bases,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parseBases loads test fixture with 4 bases" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_bases.bin");
    defer allocator.free(data);

    var registry = try parseBases(allocator, data);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 4), registry.bases.len);
}

test "parseBases base 0 has correct properties" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_bases.bin");
    defer allocator.free(data);

    var registry = try parseBases(allocator, data);
    defer registry.deinit();

    const base0 = registry.bases[0];
    try std.testing.expectEqual(@as(u8, 0), base0.index);
    try std.testing.expectEqual(@as(u8, 3), base0.base_type);
    try std.testing.expectEqualStrings("Achilles", base0.name);
}

test "parseBases base 3 is Perry Naval Base" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_bases.bin");
    defer allocator.free(data);

    var registry = try parseBases(allocator, data);
    defer registry.deinit();

    const base3 = registry.bases[3];
    try std.testing.expectEqual(@as(u8, 3), base3.index);
    try std.testing.expectEqual(@as(u8, 6), base3.base_type);
    try std.testing.expectEqualStrings("Perry Naval Base", base3.name);
}

test "BaseRegistry.findByIndex finds existing base" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_bases.bin");
    defer allocator.free(data);

    var registry = try parseBases(allocator, data);
    defer registry.deinit();

    const base = registry.findByIndex(2);
    try std.testing.expect(base != null);
    try std.testing.expectEqualStrings("Oxford", base.?.name);
    try std.testing.expectEqual(@as(u8, 6), base.?.base_type);
}

test "BaseRegistry.findByIndex returns null for missing index" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_bases.bin");
    defer allocator.free(data);

    var registry = try parseBases(allocator, data);
    defer registry.deinit();

    try std.testing.expect(registry.findByIndex(99) == null);
}

test "BaseRegistry.findByName finds base case-insensitively" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_bases.bin");
    defer allocator.free(data);

    var registry = try parseBases(allocator, data);
    defer registry.deinit();

    const base = registry.findByName("helen");
    try std.testing.expect(base != null);
    try std.testing.expectEqual(@as(u8, 1), base.?.index);
    try std.testing.expectEqual(@as(u8, 4), base.?.base_type);

    try std.testing.expect(registry.findByName("Nonexistent") == null);
}

test "parseBases rejects non-BASE form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(BaseError.InvalidFormat, parseBases(allocator, data));
}
