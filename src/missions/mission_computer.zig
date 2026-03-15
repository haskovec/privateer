//! Mission computer UI system for Wing Commander: Privateer.
//!
//! The mission computer is accessed at bases to browse and accept
//! randomly generated missions. It generates a set of available missions
//! based on the current base type, and allows the player to accept them
//! (up to a maximum number of active missions).

const std = @import("std");
const missions = @import("missions.zig");

const Mission = missions.Mission;
const MissionTemplate = missions.MissionTemplate;
const MissionTemplateRegistry = missions.MissionTemplateRegistry;
const MissionType = missions.MissionType;

/// Maximum number of missions a player can have active simultaneously.
pub const MAX_ACTIVE_MISSIONS: usize = 4;
/// Number of missions displayed in the mission computer at a time.
pub const MISSIONS_PER_PAGE: usize = 3;

/// Errors from mission computer operations.
pub const MissionComputerError = error{
    /// Player already has the maximum number of active missions.
    TooManyActiveMissions,
    /// The selected mission index is out of range.
    InvalidMissionIndex,
    /// No missions are available at this base.
    NoMissionsAvailable,
    /// Out of memory.
    OutOfMemory,
};

/// Manages the mission computer state: available and active missions.
pub const MissionComputer = struct {
    /// Missions currently available at this base.
    available: []Mission,
    /// Missions the player has accepted and are in progress.
    active: [MAX_ACTIVE_MISSIONS]?Mission,
    /// Number of active missions.
    active_count: usize,
    /// Allocator for mission data.
    allocator: std.mem.Allocator,

    /// Create a new mission computer.
    pub fn init(allocator: std.mem.Allocator) MissionComputer {
        return .{
            .available = &.{},
            .active = .{null} ** MAX_ACTIVE_MISSIONS,
            .active_count = 0,
            .allocator = allocator,
        };
    }

    /// Free all missions and lists.
    pub fn deinit(self: *MissionComputer) void {
        self.clearAvailable();
        for (&self.active) |*slot| {
            if (slot.*) |*m| {
                m.deinit();
                slot.* = null;
            }
        }
        self.active_count = 0;
    }

    /// Free and clear available missions.
    fn clearAvailable(self: *MissionComputer) void {
        for (self.available) |*m| {
            m.deinit();
        }
        if (self.available.len > 0) {
            self.allocator.free(self.available);
        }
        self.available = &.{};
    }

    /// Generate available missions for the given base type.
    /// Clears any previously generated available missions.
    pub fn generateMissions(
        self: *MissionComputer,
        registry: *const MissionTemplateRegistry,
        base_type: u8,
        destination_system: u8,
        seed: u64,
    ) MissionComputerError!void {
        // Clear old available missions
        self.clearAvailable();

        // Get templates available at this base type
        const templates = registry.templatesForBase(self.allocator, base_type) catch
            return MissionComputerError.OutOfMemory;
        defer self.allocator.free(templates);

        if (templates.len == 0) return MissionComputerError.NoMissionsAvailable;

        // Allocate space for generated missions
        const generated = self.allocator.alloc(Mission, templates.len) catch
            return MissionComputerError.OutOfMemory;
        errdefer self.allocator.free(generated);

        // Generate a mission from each available template
        var count: usize = 0;
        errdefer {
            for (generated[0..count]) |*m| {
                m.deinit();
            }
        }

        for (templates, 0..) |template, i| {
            const mission_seed = seed +% @as(u64, @intCast(i)) *% 7919;
            generated[count] = missions.generateMission(
                self.allocator,
                template,
                destination_system,
                mission_seed,
            ) catch return MissionComputerError.OutOfMemory;
            count += 1;
        }

        self.available = generated;
    }

    /// Accept the mission at the given index in the available list.
    /// Moves it from available to active.
    pub fn acceptMission(self: *MissionComputer, index: usize) MissionComputerError!void {
        if (self.active_count >= MAX_ACTIVE_MISSIONS)
            return MissionComputerError.TooManyActiveMissions;
        if (index >= self.available.len)
            return MissionComputerError.InvalidMissionIndex;

        // Take the mission out of available
        var mission = self.available[index];
        mission.accepted = true;

        // Shift remaining available missions down
        const new_len = self.available.len - 1;
        if (new_len == 0) {
            self.allocator.free(self.available);
            self.available = &.{};
        } else {
            // Shift elements after index
            for (index..new_len) |j| {
                self.available[j] = self.available[j + 1];
            }
            // Resize (shrink) - if realloc fails, just keep the old (larger) slice
            if (self.allocator.realloc(self.available, new_len)) |new_slice| {
                self.available = new_slice;
            } else |_| {
                self.available = self.available[0..new_len];
            }
        }

        // Find empty active slot
        for (&self.active) |*slot| {
            if (slot.* == null) {
                slot.* = mission;
                self.active_count += 1;
                return;
            }
        }
        // Should not reach here since we checked active_count
        unreachable;
    }

    /// Get the number of available missions.
    pub fn availableCount(self: *const MissionComputer) usize {
        return self.available.len;
    }

    /// Get the number of active missions.
    pub fn activeCount(self: *const MissionComputer) usize {
        return self.active_count;
    }

    /// Get an available mission by index (for display).
    pub fn getAvailable(self: *const MissionComputer, index: usize) ?*const Mission {
        if (index >= self.available.len) return null;
        return &self.available[index];
    }

    /// Get an active mission by index (iterating over non-null slots).
    pub fn getActive(self: *const MissionComputer, index: usize) ?*const Mission {
        var count: usize = 0;
        for (&self.active) |*slot| {
            if (slot.*) |*m| {
                if (count == index) return m;
                count += 1;
            }
        }
        return null;
    }

    /// Complete an active mission by logical index and return the reward.
    pub fn completeMission(self: *MissionComputer, index: usize) MissionComputerError!i32 {
        var count: usize = 0;
        for (&self.active) |*slot| {
            if (slot.*) |*m| {
                if (count == index) {
                    const reward = m.reward;
                    m.deinit();
                    slot.* = null;
                    self.active_count -= 1;
                    return reward;
                }
                count += 1;
            }
        }
        return MissionComputerError.InvalidMissionIndex;
    }

    /// Abandon an active mission by logical index.
    pub fn abandonMission(self: *MissionComputer, index: usize) MissionComputerError!void {
        var count: usize = 0;
        for (&self.active) |*slot| {
            if (slot.*) |*m| {
                if (count == index) {
                    m.deinit();
                    slot.* = null;
                    self.active_count -= 1;
                    return;
                }
                count += 1;
            }
        }
        return MissionComputerError.InvalidMissionIndex;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

fn loadTestRegistry(allocator: std.mem.Allocator) !struct { registry: MissionTemplateRegistry, data: []const u8 } {
    const data = try testing_helpers.loadFixture(allocator, "test_mission_templates.bin");
    const registry = missions.parseTemplates(allocator, data) catch {
        allocator.free(data);
        return error.TestFixtureError;
    };
    return .{ .registry = registry, .data = data };
}

test "MissionComputer init creates empty state" {
    const allocator = std.testing.allocator;
    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try std.testing.expectEqual(@as(usize, 0), mc.availableCount());
    try std.testing.expectEqual(@as(usize, 0), mc.activeCount());
}

test "generateMissions populates available missions for agricultural base" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    // Agricultural base (type 1): patrol (0x3F), cargo (0x07), defend (0x23)
    try mc.generateMissions(&loaded.registry, 1, 5, 42);

    try std.testing.expectEqual(@as(usize, 3), mc.availableCount());

    // Verify mission types match the templates available at agricultural bases
    try std.testing.expectEqual(MissionType.patrol, mc.getAvailable(0).?.mission_type);
    try std.testing.expectEqual(MissionType.cargo, mc.getAvailable(1).?.mission_type);
    try std.testing.expectEqual(MissionType.defend, mc.getAvailable(2).?.mission_type);
}

test "generateMissions populates available missions for pirate base" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    // Pirate base (type 5): patrol (0x3F), bounty (0x30)
    try mc.generateMissions(&loaded.registry, 5, 10, 99);

    try std.testing.expectEqual(@as(usize, 2), mc.availableCount());
    try std.testing.expectEqual(MissionType.patrol, mc.getAvailable(0).?.mission_type);
    try std.testing.expectEqual(MissionType.bounty, mc.getAvailable(1).?.mission_type);
}

test "generateMissions sets destination system on all missions" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try mc.generateMissions(&loaded.registry, 1, 42, 0);

    for (0..mc.availableCount()) |i| {
        try std.testing.expectEqual(@as(u8, 42), mc.getAvailable(i).?.destination_system);
    }
}

test "generateMissions clears previous available missions" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    // Generate for agricultural (3 missions)
    try mc.generateMissions(&loaded.registry, 1, 5, 42);
    try std.testing.expectEqual(@as(usize, 3), mc.availableCount());

    // Generate for pirate (2 missions) - should replace previous
    try mc.generateMissions(&loaded.registry, 5, 10, 99);
    try std.testing.expectEqual(@as(usize, 2), mc.availableCount());
}

test "acceptMission moves mission from available to active" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try mc.generateMissions(&loaded.registry, 1, 5, 42);
    try std.testing.expectEqual(@as(usize, 3), mc.availableCount());
    try std.testing.expectEqual(@as(usize, 0), mc.activeCount());

    // Accept the first mission (patrol)
    try mc.acceptMission(0);

    try std.testing.expectEqual(@as(usize, 2), mc.availableCount());
    try std.testing.expectEqual(@as(usize, 1), mc.activeCount());

    // The accepted mission should be in active list
    const active = mc.getActive(0).?;
    try std.testing.expectEqual(MissionType.patrol, active.mission_type);
    try std.testing.expect(active.accepted);
}

test "acceptMission marks mission as accepted" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try mc.generateMissions(&loaded.registry, 1, 5, 42);

    // Before acceptance, mission is not accepted
    try std.testing.expect(!mc.getAvailable(0).?.accepted);

    try mc.acceptMission(0);

    // After acceptance, mission is accepted
    try std.testing.expect(mc.getActive(0).?.accepted);
}

test "acceptMission fails when at maximum active missions" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    // Fill up active missions by generating and accepting across multiple bases
    for (0..MAX_ACTIVE_MISSIONS) |i| {
        try mc.generateMissions(&loaded.registry, 1, 5, @intCast(i * 1000));
        try mc.acceptMission(0);
    }

    try std.testing.expectEqual(MAX_ACTIVE_MISSIONS, mc.activeCount());

    // Generate new missions
    try mc.generateMissions(&loaded.registry, 1, 5, 9999);

    // Trying to accept another should fail
    try std.testing.expectError(
        MissionComputerError.TooManyActiveMissions,
        mc.acceptMission(0),
    );
}

test "acceptMission fails with invalid index" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try mc.generateMissions(&loaded.registry, 1, 5, 42);

    try std.testing.expectError(
        MissionComputerError.InvalidMissionIndex,
        mc.acceptMission(10),
    );
}

test "accepting removes correct mission from available list" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    // Agricultural: patrol, cargo, defend
    try mc.generateMissions(&loaded.registry, 1, 5, 42);

    // Accept the middle one (cargo, index 1)
    try mc.acceptMission(1);

    // Available should now be: patrol, defend
    try std.testing.expectEqual(@as(usize, 2), mc.availableCount());
    try std.testing.expectEqual(MissionType.patrol, mc.getAvailable(0).?.mission_type);
    try std.testing.expectEqual(MissionType.defend, mc.getAvailable(1).?.mission_type);

    // Active should have cargo
    try std.testing.expectEqual(MissionType.cargo, mc.getActive(0).?.mission_type);
}

test "completeMission removes from active and returns reward" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try mc.generateMissions(&loaded.registry, 1, 5, 42);
    try mc.acceptMission(0);
    try std.testing.expectEqual(@as(usize, 1), mc.activeCount());

    const reward = try mc.completeMission(0);

    try std.testing.expectEqual(@as(usize, 0), mc.activeCount());
    try std.testing.expect(reward >= 5000); // Patrol min reward
    try std.testing.expect(reward <= 15000); // Patrol max reward
}

test "completeMission fails with invalid index" {
    const allocator = std.testing.allocator;

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try std.testing.expectError(
        MissionComputerError.InvalidMissionIndex,
        mc.completeMission(0),
    );
}

test "abandonMission removes from active list" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try mc.generateMissions(&loaded.registry, 1, 5, 42);
    try mc.acceptMission(0);
    try mc.acceptMission(0); // Accept next available (was index 1, now 0)
    try std.testing.expectEqual(@as(usize, 2), mc.activeCount());

    try mc.abandonMission(0);

    try std.testing.expectEqual(@as(usize, 1), mc.activeCount());
}

test "abandonMission fails with invalid index" {
    const allocator = std.testing.allocator;

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try std.testing.expectError(
        MissionComputerError.InvalidMissionIndex,
        mc.abandonMission(0),
    );
}

test "getAvailable returns null for out of range index" {
    const allocator = std.testing.allocator;

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try std.testing.expect(mc.getAvailable(0) == null);
}

test "getActive returns null for out of range index" {
    const allocator = std.testing.allocator;

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try std.testing.expect(mc.getActive(0) == null);
}

test "missions have valid rewards within template bounds" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    try mc.generateMissions(&loaded.registry, 1, 5, 42);

    // Patrol: min 5000, max 15000
    const patrol = mc.getAvailable(0).?;
    try std.testing.expect(patrol.reward >= 5000);
    try std.testing.expect(patrol.reward <= 15000);

    // Cargo: min 3000, max 10000
    const cargo = mc.getAvailable(1).?;
    try std.testing.expect(cargo.reward >= 3000);
    try std.testing.expect(cargo.reward <= 10000);

    // Defend: min 8000, max 20000
    const defend = mc.getAvailable(2).?;
    try std.testing.expect(defend.reward >= 8000);
    try std.testing.expect(defend.reward <= 20000);
}

test "accept multiple missions then complete one frees a slot" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer allocator.free(loaded.data);
    defer loaded.registry.deinit();

    var mc = MissionComputer.init(allocator);
    defer mc.deinit();

    // Fill all active slots
    for (0..MAX_ACTIVE_MISSIONS) |i| {
        try mc.generateMissions(&loaded.registry, 1, 5, @intCast(i * 1000));
        try mc.acceptMission(0);
    }
    try std.testing.expectEqual(MAX_ACTIVE_MISSIONS, mc.activeCount());

    // Complete one mission to free a slot
    _ = try mc.completeMission(0);
    try std.testing.expectEqual(MAX_ACTIVE_MISSIONS - 1, mc.activeCount());

    // Now we can accept another
    try mc.generateMissions(&loaded.registry, 1, 5, 9999);
    try mc.acceptMission(0);
    try std.testing.expectEqual(MAX_ACTIVE_MISSIONS, mc.activeCount());
}
