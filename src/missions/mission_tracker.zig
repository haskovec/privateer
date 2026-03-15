//! Mission tracking and completion system for Wing Commander: Privateer.
//!
//! Tracks mission objectives in real-time during gameplay and determines
//! when missions are completed or failed. Each mission type has specific
//! objectives and failure conditions:
//!
//!   - Patrol: Visit all designated nav points in the destination system
//!   - Cargo: Deliver cargo to the destination base (fail if cargo destroyed)
//!   - Bounty: Kill the specific bounty target
//!   - Attack: Kill the required number of enemy targets
//!   - Defend: Keep the defended target alive through the engagement
//!   - Scout: Visit the destination system and return

const std = @import("std");
const missions = @import("missions.zig");

const MissionType = missions.MissionType;
const Mission = missions.Mission;

/// Maximum number of nav points a patrol mission can require.
pub const MAX_NAV_POINTS: usize = 8;

/// Status of a tracked mission.
pub const MissionStatus = enum {
    /// Mission is in progress.
    active,
    /// All objectives completed successfully.
    completed,
    /// Mission has failed (cargo destroyed, target lost, etc.).
    failed,
};

/// Objective-specific tracking data, varies by mission type.
pub const ObjectiveState = union(enum) {
    /// Patrol: track which nav points have been visited.
    patrol: PatrolState,
    /// Cargo: track whether cargo is still intact.
    cargo: CargoState,
    /// Bounty: track whether the bounty target has been killed.
    bounty: BountyState,
    /// Attack: track kill count against required kills.
    attack: AttackState,
    /// Defend: track whether the defended target is still alive.
    defend: DefendState,
    /// Scout: track whether the destination system has been visited.
    scout: ScoutState,
};

/// Patrol objective: visit all nav points.
pub const PatrolState = struct {
    /// Which nav points must be visited (by nav point index).
    required_nav_points: [MAX_NAV_POINTS]u8,
    /// Number of required nav points.
    required_count: u8,
    /// Whether each required nav point has been visited.
    visited: [MAX_NAV_POINTS]bool,
};

/// Cargo delivery objective: deliver cargo to destination.
pub const CargoState = struct {
    /// Whether the cargo is still in the player's hold.
    cargo_intact: bool,
};

/// Bounty hunt objective: kill a specific target.
pub const BountyState = struct {
    /// Unique ID of the bounty target NPC.
    target_id: u16,
    /// Whether the target has been killed.
    target_killed: bool,
};

/// Attack objective: kill N enemies of a faction.
pub const AttackState = struct {
    /// Number of kills required.
    required_kills: u8,
    /// Current kill count.
    current_kills: u8,
};

/// Defend objective: keep a target alive.
pub const DefendState = struct {
    /// Unique ID of the target to defend.
    target_id: u16,
    /// Whether the defended target is still alive.
    target_alive: bool,
};

/// Scout objective: visit a system.
pub const ScoutState = struct {
    /// Target system index to scout.
    target_system: u8,
    /// Whether the system has been visited.
    system_visited: bool,
};

/// A tracked mission with objective state.
pub const TrackedMission = struct {
    /// The underlying mission data.
    mission: *Mission,
    /// Current status.
    status: MissionStatus,
    /// Objective tracking state.
    objective: ObjectiveState,

    /// Check if all objectives are complete (status should be .completed).
    pub fn isComplete(self: *const TrackedMission) bool {
        return self.status == .completed;
    }

    /// Check if the mission has failed.
    pub fn isFailed(self: *const TrackedMission) bool {
        return self.status == .failed;
    }
};

/// Maximum number of simultaneously tracked missions.
pub const MAX_TRACKED: usize = 4;

/// Mission tracker: manages objective state for all active missions.
pub const MissionTracker = struct {
    /// Tracked missions (sparse array, null = empty slot).
    tracked: [MAX_TRACKED]?TrackedMission,
    /// Number of active tracked missions.
    count: usize,

    /// Create an empty mission tracker.
    pub fn init() MissionTracker {
        return .{
            .tracked = .{null} ** MAX_TRACKED,
            .count = 0,
        };
    }

    /// Start tracking a mission with the given objective.
    /// Returns the slot index, or error if tracker is full.
    pub fn track(self: *MissionTracker, mission: *Mission, objective: ObjectiveState) error{TrackerFull}!usize {
        for (&self.tracked, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = TrackedMission{
                    .mission = mission,
                    .status = .active,
                    .objective = objective,
                };
                self.count += 1;
                return i;
            }
        }
        return error.TrackerFull;
    }

    /// Stop tracking a mission at the given slot index.
    pub fn untrack(self: *MissionTracker, index: usize) error{InvalidIndex}!void {
        if (index >= MAX_TRACKED or self.tracked[index] == null) {
            return error.InvalidIndex;
        }
        self.tracked[index] = null;
        self.count -= 1;
    }

    /// Get a tracked mission by slot index.
    pub fn get(self: *const MissionTracker, index: usize) ?*const TrackedMission {
        if (index >= MAX_TRACKED) return null;
        if (self.tracked[index]) |*tm| {
            return tm;
        }
        return null;
    }

    /// Get a mutable tracked mission by slot index.
    pub fn getMut(self: *MissionTracker, index: usize) ?*TrackedMission {
        if (index >= MAX_TRACKED) return null;
        if (self.tracked[index] != null) {
            return &(self.tracked[index].?);
        }
        return null;
    }

    /// Report that the player arrived at a nav point.
    /// Updates all active patrol missions that require this nav point.
    pub fn reportNavPointVisited(self: *MissionTracker, system_index: u8, nav_point: u8) void {
        for (&self.tracked) |*slot| {
            if (slot.*) |*tm| {
                if (tm.status != .active) continue;
                if (tm.mission.destination_system != system_index) continue;
                if (tm.objective != .patrol) continue;

                var state = &tm.objective.patrol;
                for (0..state.required_count) |i| {
                    if (state.required_nav_points[i] == nav_point) {
                        state.visited[i] = true;
                        break;
                    }
                }

                // Check if all nav points visited
                if (allNavPointsVisited(state)) {
                    tm.status = .completed;
                    tm.mission.completed = true;
                }
            }
        }
    }

    /// Report that a target NPC was killed.
    /// Updates bounty missions targeting this NPC and attack mission kill counts.
    pub fn reportTargetKilled(self: *MissionTracker, target_id: u16) void {
        for (&self.tracked) |*slot| {
            if (slot.*) |*tm| {
                if (tm.status != .active) continue;

                switch (tm.objective) {
                    .bounty => |*state| {
                        if (state.target_id == target_id) {
                            state.target_killed = true;
                            tm.status = .completed;
                            tm.mission.completed = true;
                        }
                    },
                    .attack => |*state| {
                        state.current_kills += 1;
                        if (state.current_kills >= state.required_kills) {
                            tm.status = .completed;
                            tm.mission.completed = true;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Report that the player's mission cargo was destroyed.
    /// Fails all active cargo delivery missions.
    pub fn reportCargoDestroyed(self: *MissionTracker) void {
        for (&self.tracked) |*slot| {
            if (slot.*) |*tm| {
                if (tm.status != .active) continue;
                if (tm.objective != .cargo) continue;

                tm.objective.cargo.cargo_intact = false;
                tm.status = .failed;
            }
        }
    }

    /// Report that a defended target was destroyed.
    /// Fails defend missions targeting this NPC.
    pub fn reportDefendTargetDestroyed(self: *MissionTracker, target_id: u16) void {
        for (&self.tracked) |*slot| {
            if (slot.*) |*tm| {
                if (tm.status != .active) continue;
                if (tm.objective != .defend) continue;

                if (tm.objective.defend.target_id == target_id) {
                    tm.objective.defend.target_alive = false;
                    tm.status = .failed;
                }
            }
        }
    }

    /// Report that the player has entered a system.
    /// Updates scout missions targeting this system.
    pub fn reportSystemVisited(self: *MissionTracker, system_index: u8) void {
        for (&self.tracked) |*slot| {
            if (slot.*) |*tm| {
                if (tm.status != .active) continue;
                if (tm.objective != .scout) continue;

                if (tm.objective.scout.target_system == system_index) {
                    tm.objective.scout.system_visited = true;
                    tm.status = .completed;
                    tm.mission.completed = true;
                }
            }
        }
    }

    /// Report that the player landed at a base in a system.
    /// Completes cargo delivery missions with matching destination.
    pub fn reportLandedAtBase(self: *MissionTracker, system_index: u8) void {
        for (&self.tracked) |*slot| {
            if (slot.*) |*tm| {
                if (tm.status != .active) continue;
                if (tm.objective != .cargo) continue;
                if (tm.mission.destination_system != system_index) continue;

                if (tm.objective.cargo.cargo_intact) {
                    tm.status = .completed;
                    tm.mission.completed = true;
                }
            }
        }
    }

    /// Report that all enemies in a defend engagement are cleared.
    /// Completes active defend missions where the target survived.
    pub fn reportDefendEngagementCleared(self: *MissionTracker, target_id: u16) void {
        for (&self.tracked) |*slot| {
            if (slot.*) |*tm| {
                if (tm.status != .active) continue;
                if (tm.objective != .defend) continue;

                if (tm.objective.defend.target_id == target_id and
                    tm.objective.defend.target_alive)
                {
                    tm.status = .completed;
                    tm.mission.completed = true;
                }
            }
        }
    }

    /// Count how many tracked missions have a given status.
    pub fn countByStatus(self: *const MissionTracker, status: MissionStatus) usize {
        var n: usize = 0;
        for (self.tracked) |slot| {
            if (slot) |tm| {
                if (tm.status == status) n += 1;
            }
        }
        return n;
    }
};

/// Helper: check if all required nav points in a patrol state have been visited.
fn allNavPointsVisited(state: *const PatrolState) bool {
    for (0..state.required_count) |i| {
        if (!state.visited[i]) return false;
    }
    return true;
}

/// Create a patrol objective for a mission.
pub fn makePatrolObjective(nav_points: []const u8) ObjectiveState {
    var state = PatrolState{
        .required_nav_points = .{0} ** MAX_NAV_POINTS,
        .required_count = @intCast(@min(nav_points.len, MAX_NAV_POINTS)),
        .visited = .{false} ** MAX_NAV_POINTS,
    };
    for (0..state.required_count) |i| {
        state.required_nav_points[i] = nav_points[i];
    }
    return .{ .patrol = state };
}

/// Create a cargo delivery objective.
pub fn makeCargoObjective() ObjectiveState {
    return .{ .cargo = CargoState{ .cargo_intact = true } };
}

/// Create a bounty hunt objective.
pub fn makeBountyObjective(target_id: u16) ObjectiveState {
    return .{ .bounty = BountyState{ .target_id = target_id, .target_killed = false } };
}

/// Create an attack objective.
pub fn makeAttackObjective(required_kills: u8) ObjectiveState {
    return .{ .attack = AttackState{ .required_kills = required_kills, .current_kills = 0 } };
}

/// Create a defend objective.
pub fn makeDefendObjective(target_id: u16) ObjectiveState {
    return .{ .defend = DefendState{ .target_id = target_id, .target_alive = true } };
}

/// Create a scout objective.
pub fn makeScoutObjective(target_system: u8) ObjectiveState {
    return .{ .scout = ScoutState{ .target_system = target_system, .system_visited = false } };
}

// ── Tests ───────────────────────────────────────────────────────────

test "MissionTracker init creates empty tracker" {
    const tracker = MissionTracker.init();
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
    for (tracker.tracked) |slot| {
        try std.testing.expect(slot == null);
    }
}

test "track adds a mission to the tracker" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.patrol, 5);

    const idx = try tracker.track(&mission, makePatrolObjective(&.{ 1, 2, 3 }));

    try std.testing.expectEqual(@as(usize, 1), tracker.count);
    const tm = tracker.get(idx).?;
    try std.testing.expectEqual(MissionStatus.active, tm.status);
    try std.testing.expect(!tm.isComplete());
    try std.testing.expect(!tm.isFailed());
}

test "track fails when tracker is full" {
    var tracker = MissionTracker.init();
    var m1 = makeDummyMission(.patrol, 1);
    var m2 = makeDummyMission(.cargo, 2);
    var m3 = makeDummyMission(.bounty, 3);
    var m4 = makeDummyMission(.attack, 4);
    var m5 = makeDummyMission(.scout, 5);

    _ = try tracker.track(&m1, makePatrolObjective(&.{1}));
    _ = try tracker.track(&m2, makeCargoObjective());
    _ = try tracker.track(&m3, makeBountyObjective(100));
    _ = try tracker.track(&m4, makeAttackObjective(3));

    try std.testing.expectError(error.TrackerFull, tracker.track(&m5, makeScoutObjective(10)));
}

test "untrack removes a mission from the tracker" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.patrol, 5);

    const idx = try tracker.track(&mission, makePatrolObjective(&.{1}));
    try std.testing.expectEqual(@as(usize, 1), tracker.count);

    try tracker.untrack(idx);
    try std.testing.expectEqual(@as(usize, 0), tracker.count);
    try std.testing.expect(tracker.get(idx) == null);
}

test "untrack fails with invalid index" {
    var tracker = MissionTracker.init();
    try std.testing.expectError(error.InvalidIndex, tracker.untrack(0));
    try std.testing.expectError(error.InvalidIndex, tracker.untrack(99));
}

test "patrol mission completes when all nav points visited" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.patrol, 5);
    const idx = try tracker.track(&mission, makePatrolObjective(&.{ 1, 2, 3 }));

    // Visit nav points one by one in the correct system
    tracker.reportNavPointVisited(5, 1);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);

    tracker.reportNavPointVisited(5, 2);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);

    tracker.reportNavPointVisited(5, 3);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
    try std.testing.expect(mission.completed);
}

test "patrol mission ignores nav points from wrong system" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.patrol, 5);
    const idx = try tracker.track(&mission, makePatrolObjective(&.{ 1, 2 }));

    // Visit nav points in wrong system
    tracker.reportNavPointVisited(10, 1);
    tracker.reportNavPointVisited(10, 2);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);
}

test "patrol mission ignores irrelevant nav points" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.patrol, 5);
    const idx = try tracker.track(&mission, makePatrolObjective(&.{ 1, 3 }));

    // Visit nav point 2 (not required)
    tracker.reportNavPointVisited(5, 2);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);

    // Visit required points
    tracker.reportNavPointVisited(5, 1);
    tracker.reportNavPointVisited(5, 3);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
}

test "cargo mission completes on landing at destination" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.cargo, 8);
    const idx = try tracker.track(&mission, makeCargoObjective());

    // Land at wrong system - no completion
    tracker.reportLandedAtBase(5);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);

    // Land at destination system
    tracker.reportLandedAtBase(8);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
    try std.testing.expect(mission.completed);
}

test "cargo mission fails when cargo destroyed" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.cargo, 8);
    const idx = try tracker.track(&mission, makeCargoObjective());

    tracker.reportCargoDestroyed();
    try std.testing.expectEqual(MissionStatus.failed, tracker.get(idx).?.status);
    try std.testing.expect(!tracker.get(idx).?.objective.cargo.cargo_intact);
}

test "cargo mission does not complete at destination after cargo destroyed" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.cargo, 8);
    const idx = try tracker.track(&mission, makeCargoObjective());

    tracker.reportCargoDestroyed();
    try std.testing.expectEqual(MissionStatus.failed, tracker.get(idx).?.status);

    // Landing at destination after failure should not complete
    tracker.reportLandedAtBase(8);
    try std.testing.expectEqual(MissionStatus.failed, tracker.get(idx).?.status);
}

test "bounty mission completes when target killed" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.bounty, 5);
    const idx = try tracker.track(&mission, makeBountyObjective(42));

    // Kill wrong target
    tracker.reportTargetKilled(99);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);

    // Kill correct target
    tracker.reportTargetKilled(42);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
    try std.testing.expect(mission.completed);
}

test "attack mission completes after required kills" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.attack, 5);
    const idx = try tracker.track(&mission, makeAttackObjective(3));

    tracker.reportTargetKilled(1);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);
    try std.testing.expectEqual(@as(u8, 1), tracker.get(idx).?.objective.attack.current_kills);

    tracker.reportTargetKilled(2);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);

    tracker.reportTargetKilled(3);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
    try std.testing.expect(mission.completed);
}

test "defend mission fails when target destroyed" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.defend, 5);
    const idx = try tracker.track(&mission, makeDefendObjective(77));

    tracker.reportDefendTargetDestroyed(77);
    try std.testing.expectEqual(MissionStatus.failed, tracker.get(idx).?.status);
    try std.testing.expect(!tracker.get(idx).?.objective.defend.target_alive);
}

test "defend mission ignores destruction of other targets" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.defend, 5);
    const idx = try tracker.track(&mission, makeDefendObjective(77));

    tracker.reportDefendTargetDestroyed(99);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);
}

test "defend mission completes when engagement cleared" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.defend, 5);
    const idx = try tracker.track(&mission, makeDefendObjective(77));

    tracker.reportDefendEngagementCleared(77);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
    try std.testing.expect(mission.completed);
}

test "defend mission does not complete if target already dead" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.defend, 5);
    const idx = try tracker.track(&mission, makeDefendObjective(77));

    // Target dies first
    tracker.reportDefendTargetDestroyed(77);
    try std.testing.expectEqual(MissionStatus.failed, tracker.get(idx).?.status);

    // Engagement cleared after target death - should stay failed
    tracker.reportDefendEngagementCleared(77);
    try std.testing.expectEqual(MissionStatus.failed, tracker.get(idx).?.status);
}

test "scout mission completes when system visited" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.scout, 5);
    const idx = try tracker.track(&mission, makeScoutObjective(12));

    // Visit wrong system
    tracker.reportSystemVisited(5);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(idx).?.status);

    // Visit correct system
    tracker.reportSystemVisited(12);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
    try std.testing.expect(mission.completed);
}

test "countByStatus counts correctly" {
    var tracker = MissionTracker.init();
    var m1 = makeDummyMission(.patrol, 5);
    var m2 = makeDummyMission(.cargo, 8);
    var m3 = makeDummyMission(.bounty, 3);

    _ = try tracker.track(&m1, makePatrolObjective(&.{1}));
    _ = try tracker.track(&m2, makeCargoObjective());
    _ = try tracker.track(&m3, makeBountyObjective(42));

    try std.testing.expectEqual(@as(usize, 3), tracker.countByStatus(.active));
    try std.testing.expectEqual(@as(usize, 0), tracker.countByStatus(.completed));
    try std.testing.expectEqual(@as(usize, 0), tracker.countByStatus(.failed));

    // Complete one, fail another
    tracker.reportNavPointVisited(5, 1);
    tracker.reportCargoDestroyed();

    try std.testing.expectEqual(@as(usize, 1), tracker.countByStatus(.active));
    try std.testing.expectEqual(@as(usize, 1), tracker.countByStatus(.completed));
    try std.testing.expectEqual(@as(usize, 1), tracker.countByStatus(.failed));
}

test "multiple missions tracked simultaneously" {
    var tracker = MissionTracker.init();
    var patrol = makeDummyMission(.patrol, 5);
    var cargo = makeDummyMission(.cargo, 8);

    const p_idx = try tracker.track(&patrol, makePatrolObjective(&.{ 1, 2 }));
    const c_idx = try tracker.track(&cargo, makeCargoObjective());

    // Complete patrol
    tracker.reportNavPointVisited(5, 1);
    tracker.reportNavPointVisited(5, 2);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(p_idx).?.status);
    try std.testing.expectEqual(MissionStatus.active, tracker.get(c_idx).?.status);

    // Complete cargo
    tracker.reportLandedAtBase(8);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(c_idx).?.status);
}

test "completed mission does not respond to further events" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.patrol, 5);
    const idx = try tracker.track(&mission, makePatrolObjective(&.{1}));

    // Complete the mission
    tracker.reportNavPointVisited(5, 1);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);

    // Further events should not change status
    tracker.reportCargoDestroyed();
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
}

test "getMut allows modifying tracked mission" {
    var tracker = MissionTracker.init();
    var mission = makeDummyMission(.attack, 5);
    const idx = try tracker.track(&mission, makeAttackObjective(2));

    const tm = tracker.getMut(idx).?;
    try std.testing.expectEqual(MissionStatus.active, tm.status);

    // Modify via mutable reference
    tracker.reportTargetKilled(1);
    tracker.reportTargetKilled(2);
    try std.testing.expectEqual(MissionStatus.completed, tracker.get(idx).?.status);
}

test "getMut returns null for empty slot" {
    var tracker = MissionTracker.init();
    try std.testing.expect(tracker.getMut(0) == null);
}

test "get returns null for out of range index" {
    const tracker = MissionTracker.init();
    try std.testing.expect(tracker.get(99) == null);
}

// ── Test Helpers ────────────────────────────────────────────────────

/// Create a minimal dummy mission for testing (no allocation needed).
/// Uses a static buffer for briefing text.
fn makeDummyMission(mission_type: MissionType, destination: u8) Mission {
    return Mission{
        .mission_type = mission_type,
        .difficulty = 1,
        .briefing = &.{},
        .reward = 10000,
        .destination_system = destination,
        .accepted = true,
        .completed = false,
        .allocator = std.testing.allocator,
    };
}
