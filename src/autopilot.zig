//! Autopilot system for Wing Commander: Privateer.
//! Navigates the ship toward a selected nav point automatically.
//! Disengages when a hostile is detected nearby.

const std = @import("std");
const flight_physics = @import("flight_physics.zig");
const Vec3 = flight_physics.Vec3;
const FlightState = flight_physics.FlightState;
const ship_stats = flight_physics.ship_stats;

/// Autopilot operating state.
pub const State = enum {
    /// Autopilot is not active.
    inactive,
    /// Autopilot is actively steering toward target.
    engaged,
    /// Ship has arrived at the target nav point.
    arrived,
    /// Autopilot was interrupted by hostile detection.
    interrupted,
};

/// Default arrival distance threshold (units).
pub const default_arrival_radius: f32 = 50.0;

/// Wrap an angle to the range [-pi, pi].
fn normalizeAngle(angle: f32) f32 {
    const tau: f32 = 2.0 * std.math.pi;
    return angle - tau * @floor(angle / tau + 0.5);
}

/// Autopilot controller. Steers a ship toward a target position,
/// detects arrival, and disengages on hostile contact.
pub const Autopilot = struct {
    /// Current autopilot state.
    state: State,
    /// Target position to navigate toward.
    target: Vec3,
    /// Distance at which the ship is considered to have arrived.
    arrival_radius: f32,

    /// Create an inactive autopilot.
    pub fn init() Autopilot {
        return .{
            .state = .inactive,
            .target = Vec3.zero,
            .arrival_radius = default_arrival_radius,
        };
    }

    /// Engage autopilot toward the given target position.
    pub fn engage(self: *Autopilot, target: Vec3) void {
        self.target = target;
        self.state = .engaged;
    }

    /// Disengage autopilot (return to manual control).
    pub fn disengage(self: *Autopilot) void {
        self.state = .inactive;
    }

    /// Whether the autopilot is actively steering.
    pub fn isEngaged(self: *const Autopilot) bool {
        return self.state == .engaged;
    }

    /// Update autopilot for one frame. Steers the ship toward the target,
    /// checks for arrival, and interrupts on hostile detection.
    /// Returns the autopilot state after the update.
    pub fn update(self: *Autopilot, flight: *FlightState, dt: f32, hostile_detected: bool) State {
        if (self.state != .engaged) return self.state;

        // Hostile contact interrupts autopilot immediately
        if (hostile_detected) {
            self.state = .interrupted;
            flight.setThrottle(0);
            return self.state;
        }

        // Direction to target
        const delta = Vec3{
            .x = self.target.x - flight.position.x,
            .y = self.target.y - flight.position.y,
            .z = self.target.z - flight.position.z,
        };
        const dist = delta.length();

        // Arrival check
        if (dist <= self.arrival_radius) {
            self.state = .arrived;
            flight.setThrottle(0);
            return self.state;
        }

        // Desired heading toward target
        const desired_yaw = std.math.atan2(delta.x, delta.z);
        const horiz_dist = @sqrt(delta.x * delta.x + delta.z * delta.z);
        const desired_pitch = std.math.atan2(delta.y, horiz_dist);

        // Steering errors (wrapped to -pi..pi)
        const yaw_error = normalizeAngle(desired_yaw - flight.yaw);
        const pitch_error = desired_pitch - flight.pitch;

        // Proportional steering (gain=2 so half-radian error gives full input)
        const yaw_input = std.math.clamp(yaw_error * 2.0, @as(f32, -1.0), @as(f32, 1.0));
        const pitch_input = std.math.clamp(pitch_error * 2.0, @as(f32, -1.0), @as(f32, 1.0));

        flight.applyYaw(yaw_input, dt);
        flight.applyPitch(pitch_input, dt);

        // Full throttle while engaged
        flight.setThrottle(1.0);

        return self.state;
    }
};

// ---- Tests ----

const testing = std.testing;

// Initialization

test "init creates inactive autopilot" {
    const ap = Autopilot.init();
    try testing.expectEqual(State.inactive, ap.state);
    try testing.expect(!ap.isEngaged());
}

// Engage / disengage

test "engage sets target and activates autopilot" {
    var ap = Autopilot.init();
    const target = Vec3{ .x = 100, .y = 0, .z = 200 };
    ap.engage(target);
    try testing.expectEqual(State.engaged, ap.state);
    try testing.expect(ap.isEngaged());
    try testing.expectEqual(@as(f32, 100), ap.target.x);
    try testing.expectEqual(@as(f32, 200), ap.target.z);
}

test "disengage returns to inactive" {
    var ap = Autopilot.init();
    ap.engage(Vec3{ .x = 100, .y = 0, .z = 0 });
    ap.disengage();
    try testing.expectEqual(State.inactive, ap.state);
    try testing.expect(!ap.isEngaged());
}

// Steering toward target

test "autopilot moves ship toward target nav point" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    // Target is ahead along +Z axis
    const target = Vec3{ .x = 0, .y = 0, .z = 1000 };
    ap.engage(target);

    // Run several frames
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        _ = ap.update(&flight, 0.016, false);
        flight.update(0.016);
    }

    // Ship should have moved toward the target (+Z direction)
    try testing.expect(flight.position.z > 0);
    try testing.expect(flight.speed() > 0);
    try testing.expectEqual(State.engaged, ap.state);
}

test "autopilot steers yaw toward target to the right" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    // Target is to the right (+X)
    ap.engage(Vec3{ .x = 1000, .y = 0, .z = 0 });

    _ = ap.update(&flight, 0.1, false);

    // Yaw should have increased (turning right toward +X)
    try testing.expect(flight.yaw > 0);
}

test "autopilot steers yaw toward target to the left" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    // Target is to the left (-X)
    ap.engage(Vec3{ .x = -1000, .y = 0, .z = 0 });

    _ = ap.update(&flight, 0.1, false);

    // Yaw should have decreased (turning left toward -X)
    try testing.expect(flight.yaw < 0);
}

test "autopilot steers pitch toward target above" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    // Target is above (+Y) and ahead (+Z)
    ap.engage(Vec3{ .x = 0, .y = 1000, .z = 1000 });

    _ = ap.update(&flight, 0.1, false);

    // Pitch should have increased (nose up toward +Y)
    try testing.expect(flight.pitch > 0);
}

test "autopilot sets throttle to maximum" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);
    flight.setThrottle(0);

    ap.engage(Vec3{ .x = 0, .y = 0, .z = 1000 });
    _ = ap.update(&flight, 0.016, false);

    try testing.expectEqual(@as(f32, 1.0), flight.throttle);
}

// Arrival detection

test "autopilot detects arrival at target" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    // Place ship very close to target (within arrival radius)
    flight.position = .{ .x = 0, .y = 0, .z = 990 };
    ap.engage(Vec3{ .x = 0, .y = 0, .z = 1000 });

    const state = ap.update(&flight, 0.016, false);

    try testing.expectEqual(State.arrived, state);
    try testing.expect(!ap.isEngaged());
    // Throttle should be zero on arrival
    try testing.expectEqual(@as(f32, 0), flight.throttle);
}

test "autopilot arrives after flying to target" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);
    ap.arrival_radius = 50.0;

    // Target is 500 units ahead
    ap.engage(Vec3{ .x = 0, .y = 0, .z = 500 });

    // Run until arrival or timeout
    var frames: u32 = 0;
    while (frames < 6000) : (frames += 1) {
        const state = ap.update(&flight, 0.016, false);
        flight.update(0.016);
        if (state == .arrived) break;
    }

    try testing.expectEqual(State.arrived, ap.state);
    // Ship should be near the target
    const dist_to_target = (Vec3{
        .x = ap.target.x - flight.position.x,
        .y = ap.target.y - flight.position.y,
        .z = ap.target.z - flight.position.z,
    }).length();
    try testing.expect(dist_to_target <= ap.arrival_radius);
}

// Hostile detection

test "autopilot disengages when enemy detected" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    ap.engage(Vec3{ .x = 0, .y = 0, .z = 1000 });

    // First frame: no hostile, autopilot stays engaged
    var state = ap.update(&flight, 0.016, false);
    try testing.expectEqual(State.engaged, state);

    // Second frame: hostile detected, autopilot interrupts
    state = ap.update(&flight, 0.016, true);
    try testing.expectEqual(State.interrupted, state);
    try testing.expect(!ap.isEngaged());
    // Throttle should be zero on interruption
    try testing.expectEqual(@as(f32, 0), flight.throttle);
}

test "autopilot can re-engage after interruption" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    ap.engage(Vec3{ .x = 0, .y = 0, .z = 1000 });

    // Interrupt by hostile
    _ = ap.update(&flight, 0.016, true);
    try testing.expectEqual(State.interrupted, ap.state);

    // Re-engage
    ap.engage(Vec3{ .x = 0, .y = 0, .z = 1000 });
    try testing.expectEqual(State.engaged, ap.state);
    try testing.expect(ap.isEngaged());
}

test "autopilot can re-engage after arrival" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    // Already at target
    ap.engage(Vec3{ .x = 0, .y = 0, .z = 10 });
    _ = ap.update(&flight, 0.016, false);
    try testing.expectEqual(State.arrived, ap.state);

    // Re-engage to new target
    ap.engage(Vec3{ .x = 500, .y = 0, .z = 0 });
    try testing.expectEqual(State.engaged, ap.state);
}

// No-op when inactive

test "update is no-op when inactive" {
    var ap = Autopilot.init();
    var flight = FlightState.init(ship_stats.tarsus);

    const state = ap.update(&flight, 0.016, false);

    try testing.expectEqual(State.inactive, state);
    try testing.expectEqual(@as(f32, 0), flight.throttle);
    try testing.expectEqual(@as(f32, 0), flight.yaw);
}

// Angle normalization

test "normalizeAngle wraps large positive angles" {
    const result = normalizeAngle(3.0 * std.math.pi);
    try testing.expectApproxEqAbs(std.math.pi, @abs(result), 0.001);
}

test "normalizeAngle wraps large negative angles" {
    const result = normalizeAngle(-3.0 * std.math.pi);
    try testing.expectApproxEqAbs(std.math.pi, @abs(result), 0.001);
}

test "normalizeAngle preserves small angles" {
    try testing.expectApproxEqAbs(@as(f32, 0.5), normalizeAngle(0.5), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), normalizeAngle(-0.5), 0.001);
}
