//! Navigation graph for Wing Commander: Privateer.
//! Parses TABLE.DAT which contains a system-to-system distance matrix.
//!
//! TABLE.DAT format: N*N byte matrix where entry[i*N+j] is the jump
//! distance from system i to system j.
//!   0    = same system (self)
//!   1-10 = number of jumps required
//!   0xFF = unreachable

const std = @import("std");

/// A navigation graph representing jump connectivity between star systems.
pub const NavGraph = struct {
    /// Number of systems (matrix dimension).
    system_count: u16,
    /// Raw distance matrix (system_count * system_count bytes).
    /// Access: distances[from * system_count + to]
    distances: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *NavGraph) void {
        self.allocator.free(self.distances);
    }

    /// Get the jump distance between two systems.
    /// Returns null if either index is out of range or the systems are unreachable.
    pub fn getDistance(self: NavGraph, from: u8, to: u8) ?u8 {
        if (from >= self.system_count or to >= self.system_count) return null;
        const dist = self.distances[@as(usize, from) * self.system_count + @as(usize, to)];
        if (dist == 0xFF) return null;
        return dist;
    }

    /// Returns true if two systems are directly connected (distance == 1).
    pub fn isAdjacent(self: NavGraph, a: u8, b: u8) bool {
        const dist = self.getDistance(a, b) orelse return false;
        return dist == 1;
    }

    /// Get all systems directly adjacent to the given system (distance == 1).
    /// Caller owns the returned slice.
    pub fn getAdjacentSystems(self: NavGraph, system: u8, allocator: std.mem.Allocator) ![]u8 {
        if (system >= self.system_count) return allocator.alloc(u8, 0);

        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(allocator);

        const row_start = @as(usize, system) * self.system_count;
        for (0..self.system_count) |i| {
            if (self.distances[row_start + i] == 1) {
                try list.append(allocator, @intCast(i));
            }
        }

        return list.toOwnedSlice(allocator);
    }
};

pub const NavGraphError = error{
    InvalidSize,
    OutOfMemory,
};

/// Parse a TABLE.DAT file into a NavGraph.
/// The data must be exactly N*N bytes for some integer N.
pub fn parseNavGraph(allocator: std.mem.Allocator, data: []const u8) NavGraphError!NavGraph {
    if (data.len == 0) return NavGraphError.InvalidSize;

    // Find N where N*N == data.len
    const n = std.math.sqrt(data.len);
    if (n * n != data.len) return NavGraphError.InvalidSize;

    const distances = allocator.dupe(u8, data) catch return NavGraphError.OutOfMemory;

    return NavGraph{
        .system_count = @intCast(n),
        .distances = distances,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("testing.zig");

test "parseNavGraph loads 5x5 test fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);

    var graph = try parseNavGraph(allocator, data);
    defer graph.deinit();

    try std.testing.expectEqual(@as(u16, 5), graph.system_count);
}

test "NavGraph self-distance is zero" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);

    var graph = try parseNavGraph(allocator, data);
    defer graph.deinit();

    try std.testing.expectEqual(@as(u8, 0), graph.getDistance(0, 0).?);
    try std.testing.expectEqual(@as(u8, 0), graph.getDistance(4, 4).?);
}

test "NavGraph adjacent systems have distance 1" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);

    var graph = try parseNavGraph(allocator, data);
    defer graph.deinit();

    // Troy(0) <-> Palan(1): distance 1
    try std.testing.expectEqual(@as(u8, 1), graph.getDistance(0, 1).?);
    try std.testing.expectEqual(@as(u8, 1), graph.getDistance(1, 0).?);
    try std.testing.expect(graph.isAdjacent(0, 1));

    // Palan(1) <-> Oxford(2): distance 1
    try std.testing.expect(graph.isAdjacent(1, 2));

    // Oxford(2) <-> Perry(3): distance 1
    try std.testing.expect(graph.isAdjacent(2, 3));

    // Perry(3) <-> Junction(4): distance 1
    try std.testing.expect(graph.isAdjacent(3, 4));
}

test "NavGraph non-adjacent systems have distance > 1" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);

    var graph = try parseNavGraph(allocator, data);
    defer graph.deinit();

    // Troy(0) -> Oxford(2): 2 jumps
    try std.testing.expectEqual(@as(u8, 2), graph.getDistance(0, 2).?);
    try std.testing.expect(!graph.isAdjacent(0, 2));

    // Troy(0) -> Perry(3): 3 jumps
    try std.testing.expectEqual(@as(u8, 3), graph.getDistance(0, 3).?);

    // Troy(0) -> Junction(4): 4 jumps
    try std.testing.expectEqual(@as(u8, 4), graph.getDistance(0, 4).?);
}

test "NavGraph.getAdjacentSystems returns correct neighbors" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);

    var graph = try parseNavGraph(allocator, data);
    defer graph.deinit();

    // Troy(0) is adjacent to Palan(1) only
    const troy_adj = try graph.getAdjacentSystems(0, allocator);
    defer allocator.free(troy_adj);
    try std.testing.expectEqual(@as(usize, 1), troy_adj.len);
    try std.testing.expectEqual(@as(u8, 1), troy_adj[0]);

    // Oxford(2) is adjacent to Palan(1) and Perry(3)
    const oxford_adj = try graph.getAdjacentSystems(2, allocator);
    defer allocator.free(oxford_adj);
    try std.testing.expectEqual(@as(usize, 2), oxford_adj.len);
    try std.testing.expectEqual(@as(u8, 1), oxford_adj[0]);
    try std.testing.expectEqual(@as(u8, 3), oxford_adj[1]);
}

test "NavGraph out-of-range returns null" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);

    var graph = try parseNavGraph(allocator, data);
    defer graph.deinit();

    try std.testing.expect(graph.getDistance(99, 0) == null);
    try std.testing.expect(graph.getDistance(0, 99) == null);
}

test "parseNavGraph rejects non-square data" {
    const allocator = std.testing.allocator;
    const bad_data = [_]u8{ 0, 0, 0, 0, 0, 0 }; // 6 bytes, not a perfect square
    try std.testing.expectError(NavGraphError.InvalidSize, parseNavGraph(allocator, &bad_data));
}

test "parseNavGraph rejects empty data" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(NavGraphError.InvalidSize, parseNavGraph(allocator, &[_]u8{}));
}
