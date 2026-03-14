//! Jump drive system for Wing Commander: Privateer.
//! Handles inter-system travel at jump points. The player must have a jump
//! drive installed and be at a jump point adjacent to the destination system.
//! Initiating a jump triggers a hyperspace animation sequence, after which
//! the player arrives in the connected system.

const std = @import("std");
const nav_graph = @import("../game/nav_graph.zig");
const NavGraph = nav_graph.NavGraph;
const flight_physics = @import("flight_physics.zig");
const FlightState = flight_physics.FlightState;
const Vec3 = flight_physics.Vec3;

/// Errors that prevent a jump from being initiated.
pub const JumpError = error{
    /// Ship does not have a jump drive installed.
    NoJumpDrive,
    /// Destination system is not adjacent (not reachable in one jump).
    NotAdjacent,
    /// Origin and destination are the same system.
    SameSystem,
    /// A jump is already in progress.
    JumpInProgress,
};

/// Jump drive operating state.
pub const State = enum {
    /// Jump drive is idle and ready for use.
    ready,
    /// Hyperspace jump is in progress (animation playing).
    jumping,
    /// Jump drive is on cooldown after completing a jump.
    cooldown,
};

/// Jump drive controller. Manages inter-system travel validation,
/// jump initiation, and completion.
pub const JumpDrive = struct {
    /// Current jump drive state.
    state: State,
    /// Whether the ship has a jump drive installed.
    installed: bool,
    /// The system the player is currently in.
    current_system: u8,
    /// The destination system for an in-progress jump (valid when state == .jumping).
    destination_system: u8,
    /// Cooldown timer in seconds (counts down to 0).
    cooldown_timer: f32,

    /// Cooldown duration after a jump completes (seconds).
    pub const cooldown_duration: f32 = 3.0;

    /// Create a jump drive for a ship in the given starting system.
    /// The `installed` parameter indicates whether the ship has a jump drive.
    pub fn init(starting_system: u8, installed: bool) JumpDrive {
        return .{
            .state = .ready,
            .installed = installed,
            .current_system = starting_system,
            .destination_system = 0,
            .cooldown_timer = 0,
        };
    }

    /// Attempt to initiate a jump to the destination system.
    /// Validates that:
    ///   - A jump drive is installed
    ///   - No jump is already in progress
    ///   - The destination differs from the current system
    ///   - The destination is adjacent (distance == 1) in the nav graph
    /// On success, sets state to `.jumping` and records the destination.
    pub fn initiate(self: *JumpDrive, destination: u8, graph: NavGraph) JumpError!void {
        if (!self.installed) return JumpError.NoJumpDrive;
        if (self.state == .jumping) return JumpError.JumpInProgress;
        if (destination == self.current_system) return JumpError.SameSystem;
        if (!graph.isAdjacent(self.current_system, destination)) return JumpError.NotAdjacent;

        self.destination_system = destination;
        self.state = .jumping;
    }

    /// Complete the current jump. Moves the player to the destination
    /// system and starts the cooldown timer. Returns the new system index.
    /// Must only be called when state is `.jumping`.
    pub fn complete(self: *JumpDrive) u8 {
        std.debug.assert(self.state == .jumping);
        self.current_system = self.destination_system;
        self.state = .cooldown;
        self.cooldown_timer = cooldown_duration;
        return self.current_system;
    }

    /// Update the jump drive each frame (handles cooldown timer).
    pub fn update(self: *JumpDrive, dt: f32) void {
        if (self.state == .cooldown) {
            self.cooldown_timer -= dt;
            if (self.cooldown_timer <= 0) {
                self.cooldown_timer = 0;
                self.state = .ready;
            }
        }
    }

    /// Whether the jump drive can currently initiate a jump.
    pub fn canJump(self: *const JumpDrive) bool {
        return self.installed and self.state == .ready;
    }
};

// --- Tests ---

const testing = std.testing;

// Helper: build a small 5-system nav graph for testing.
// Systems 0-4 in a chain: 0 <-> 1 <-> 2 <-> 3 <-> 4
fn makeTestGraph() !NavGraph {
    const allocator = testing.allocator;
    const testing_helpers = @import("../testing.zig");
    const data = try testing_helpers.loadFixture(allocator, "test_table.bin");
    defer allocator.free(data);
    return nav_graph.parseNavGraph(allocator, data);
}

// Initialization

test "init creates ready jump drive in starting system" {
    const jd = JumpDrive.init(0, true);
    try testing.expectEqual(State.ready, jd.state);
    try testing.expectEqual(@as(u8, 0), jd.current_system);
    try testing.expect(jd.installed);
    try testing.expect(jd.canJump());
}

test "init without jump drive installed" {
    const jd = JumpDrive.init(0, false);
    try testing.expect(!jd.installed);
    try testing.expect(!jd.canJump());
}

// Successful jump

test "jumping at a jump point transitions to connected system" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);

    // System 0 (Troy) is adjacent to system 1 (Palan)
    try jd.initiate(1, graph);
    try testing.expectEqual(State.jumping, jd.state);
    try testing.expectEqual(@as(u8, 1), jd.destination_system);

    // Complete the jump
    const new_system = jd.complete();
    try testing.expectEqual(@as(u8, 1), new_system);
    try testing.expectEqual(@as(u8, 1), jd.current_system);
    try testing.expectEqual(State.cooldown, jd.state);
}

test "can chain jumps along connected systems" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);

    // Jump 0 -> 1
    try jd.initiate(1, graph);
    _ = jd.complete();

    // Wait for cooldown
    jd.update(JumpDrive.cooldown_duration + 0.1);
    try testing.expectEqual(State.ready, jd.state);

    // Jump 1 -> 2
    try jd.initiate(2, graph);
    _ = jd.complete();
    try testing.expectEqual(@as(u8, 2), jd.current_system);
}

// Equipment requirement

test "jumping without a jump drive fails" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, false);
    try testing.expectError(JumpError.NoJumpDrive, jd.initiate(1, graph));
    // State should remain ready (no jump started)
    try testing.expectEqual(State.ready, jd.state);
    try testing.expectEqual(@as(u8, 0), jd.current_system);
}

// Non-adjacent destination

test "jumping to non-adjacent system fails" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);

    // System 0 -> System 2 is distance 2 (not adjacent)
    try testing.expectError(JumpError.NotAdjacent, jd.initiate(2, graph));
    try testing.expectEqual(State.ready, jd.state);
}

test "jumping to same system fails" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);
    try testing.expectError(JumpError.SameSystem, jd.initiate(0, graph));
}

// Jump in progress

test "cannot initiate jump while already jumping" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);
    try jd.initiate(1, graph);

    try testing.expectError(JumpError.JumpInProgress, jd.initiate(1, graph));
}

// Cooldown

test "jump drive enters cooldown after completing jump" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);
    try jd.initiate(1, graph);
    _ = jd.complete();

    try testing.expectEqual(State.cooldown, jd.state);
    try testing.expect(jd.cooldown_timer > 0);
    try testing.expect(!jd.canJump());
}

test "cooldown timer counts down to ready" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);
    try jd.initiate(1, graph);
    _ = jd.complete();

    // Partial cooldown
    jd.update(1.0);
    try testing.expectEqual(State.cooldown, jd.state);
    try testing.expectApproxEqAbs(JumpDrive.cooldown_duration - 1.0, jd.cooldown_timer, 0.001);

    // Complete cooldown
    jd.update(JumpDrive.cooldown_duration);
    try testing.expectEqual(State.ready, jd.state);
    try testing.expectEqual(@as(f32, 0), jd.cooldown_timer);
    try testing.expect(jd.canJump());
}

// canJump helper

test "canJump returns false during cooldown" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);
    try jd.initiate(1, graph);
    _ = jd.complete();

    try testing.expect(!jd.canJump());
}

test "canJump returns false when not installed" {
    const jd = JumpDrive.init(0, false);
    try testing.expect(!jd.canJump());
}

test "canJump returns true when ready and installed" {
    const jd = JumpDrive.init(0, true);
    try testing.expect(jd.canJump());
}

// Update with no cooldown is no-op

test "update is no-op when ready" {
    var jd = JumpDrive.init(0, true);
    jd.update(1.0);
    try testing.expectEqual(State.ready, jd.state);
}

test "update is no-op when jumping" {
    var graph = try makeTestGraph();
    defer graph.deinit();

    var jd = JumpDrive.init(0, true);
    try jd.initiate(1, graph);
    jd.update(1.0);
    try testing.expectEqual(State.jumping, jd.state);
}
