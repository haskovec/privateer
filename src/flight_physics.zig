//! Space flight physics for Wing Commander: Privateer.
//! Handles ship movement: thrust, rotation, velocity, speed capping,
//! and afterburner. Uses basic Newtonian physics with a speed limiter.

const std = @import("std");

/// 3D vector for positions and velocities.
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero = Vec3{ .x = 0, .y = 0, .z = 0 };

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len == 0) return zero;
        return v.scale(1.0 / len);
    }
};

/// Ship type with performance characteristics.
pub const ShipStats = struct {
    /// Maximum normal speed (units per second).
    max_speed: f32,
    /// Maximum speed with afterburner active (units per second).
    afterburner_speed: f32,
    /// Thrust acceleration (units per second squared).
    thrust: f32,
    /// Rotation rate (radians per second).
    rotation_rate: f32,
};

/// Predefined ship statistics matching the original game's four flyable ships.
pub const ship_stats = struct {
    pub const tarsus = ShipStats{
        .max_speed = 250.0,
        .afterburner_speed = 450.0,
        .thrust = 180.0,
        .rotation_rate = 1.8,
    };
    pub const galaxy = ShipStats{
        .max_speed = 200.0,
        .afterburner_speed = 400.0,
        .thrust = 140.0,
        .rotation_rate = 1.5,
    };
    pub const orion = ShipStats{
        .max_speed = 200.0,
        .afterburner_speed = 380.0,
        .thrust = 130.0,
        .rotation_rate = 1.4,
    };
    pub const centurion = ShipStats{
        .max_speed = 300.0,
        .afterburner_speed = 500.0,
        .thrust = 220.0,
        .rotation_rate = 2.0,
    };
};

/// Flight physics state for a single ship.
pub const FlightState = struct {
    /// Position in world space.
    position: Vec3,
    /// Velocity vector (units per second).
    velocity: Vec3,
    /// Yaw angle in radians (rotation around Y axis, 0 = +Z forward).
    yaw: f32,
    /// Pitch angle in radians (rotation around X axis, 0 = level).
    pitch: f32,
    /// Ship performance characteristics.
    stats: ShipStats,
    /// Whether the afterburner is currently active.
    afterburner_active: bool,
    /// Current throttle setting (0.0 to 1.0).
    throttle: f32,

    /// Create a new flight state at the origin with zero velocity.
    pub fn init(stats: ShipStats) FlightState {
        return .{
            .position = Vec3.zero,
            .velocity = Vec3.zero,
            .yaw = 0,
            .pitch = 0,
            .stats = stats,
            .afterburner_active = false,
            .throttle = 0,
        };
    }

    /// Compute the forward direction vector from current yaw and pitch.
    pub fn forward(self: *const FlightState) Vec3 {
        const cos_pitch = @cos(self.pitch);
        return .{
            .x = @sin(self.yaw) * cos_pitch,
            .y = @sin(self.pitch),
            .z = @cos(self.yaw) * cos_pitch,
        };
    }

    /// Get the current maximum speed (considering afterburner state).
    pub fn maxSpeed(self: *const FlightState) f32 {
        if (self.afterburner_active) return self.stats.afterburner_speed;
        return self.stats.max_speed;
    }

    /// Apply yaw rotation (positive = turn right).
    pub fn applyYaw(self: *FlightState, amount: f32, dt: f32) void {
        self.yaw += amount * self.stats.rotation_rate * dt;
    }

    /// Apply pitch rotation (positive = pitch up).
    pub fn applyPitch(self: *FlightState, amount: f32, dt: f32) void {
        self.pitch += amount * self.stats.rotation_rate * dt;
        // Clamp pitch to avoid gimbal lock
        const max_pitch = std.math.pi / 2.0 - 0.01;
        self.pitch = @min(@max(self.pitch, -max_pitch), max_pitch);
    }

    /// Update physics for one frame. Applies thrust based on throttle,
    /// caps speed, and integrates position.
    pub fn update(self: *FlightState, dt: f32) void {
        // Apply thrust in forward direction based on throttle
        if (self.throttle > 0) {
            const fwd = self.forward();
            const accel = fwd.scale(self.stats.thrust * self.throttle * dt);
            self.velocity = self.velocity.add(accel);
        }

        // Cap speed
        const current_max = self.maxSpeed();
        const spd = self.velocity.length();
        if (spd > current_max) {
            self.velocity = self.velocity.normalize().scale(current_max);
        }

        // Integrate position
        self.position = self.position.add(self.velocity.scale(dt));
    }

    /// Set throttle (clamped to 0.0 - 1.0).
    pub fn setThrottle(self: *FlightState, value: f32) void {
        self.throttle = @min(@max(value, 0.0), 1.0);
    }

    /// Get current speed (magnitude of velocity).
    pub fn speed(self: *const FlightState) f32 {
        return self.velocity.length();
    }
};

// --- Tests ---

const testing = std.testing;

// Vec3 basics

test "Vec3.zero is all zeros" {
    try testing.expectEqual(@as(f32, 0), Vec3.zero.x);
    try testing.expectEqual(@as(f32, 0), Vec3.zero.y);
    try testing.expectEqual(@as(f32, 0), Vec3.zero.z);
}

test "Vec3.add sums components" {
    const a = Vec3{ .x = 1, .y = 2, .z = 3 };
    const b = Vec3{ .x = 4, .y = 5, .z = 6 };
    const c = a.add(b);
    try testing.expectEqual(@as(f32, 5), c.x);
    try testing.expectEqual(@as(f32, 7), c.y);
    try testing.expectEqual(@as(f32, 9), c.z);
}

test "Vec3.scale multiplies all components" {
    const v = Vec3{ .x = 2, .y = 3, .z = 4 };
    const s = v.scale(2);
    try testing.expectEqual(@as(f32, 4), s.x);
    try testing.expectEqual(@as(f32, 6), s.y);
    try testing.expectEqual(@as(f32, 8), s.z);
}

test "Vec3.length computes magnitude" {
    const v = Vec3{ .x = 3, .y = 4, .z = 0 };
    try testing.expectApproxEqAbs(@as(f32, 5.0), v.length(), 0.001);
}

test "Vec3.normalize produces unit vector" {
    const v = Vec3{ .x = 3, .y = 0, .z = 4 };
    const n = v.normalize();
    try testing.expectApproxEqAbs(@as(f32, 1.0), n.length(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), n.z, 0.001);
}

test "Vec3.normalize zero vector returns zero" {
    const n = Vec3.zero.normalize();
    try testing.expectEqual(@as(f32, 0), n.x);
    try testing.expectEqual(@as(f32, 0), n.y);
    try testing.expectEqual(@as(f32, 0), n.z);
}

// FlightState initialization

test "init creates flight state at origin with zero velocity" {
    const fs = FlightState.init(ship_stats.tarsus);
    try testing.expectEqual(@as(f32, 0), fs.position.x);
    try testing.expectEqual(@as(f32, 0), fs.velocity.x);
    try testing.expectEqual(@as(f32, 0), fs.yaw);
    try testing.expectEqual(@as(f32, 0), fs.pitch);
    try testing.expectEqual(@as(f32, 0), fs.throttle);
    try testing.expect(!fs.afterburner_active);
}

// Forward direction

test "forward with zero angles points along +Z" {
    const fs = FlightState.init(ship_stats.tarsus);
    const fwd = fs.forward();
    try testing.expectApproxEqAbs(@as(f32, 0), fwd.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), fwd.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), fwd.z, 0.001);
}

test "forward with 90 degree yaw points along +X" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.yaw = std.math.pi / 2.0;
    const fwd = fs.forward();
    try testing.expectApproxEqAbs(@as(f32, 1.0), fwd.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), fwd.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), fwd.z, 0.01);
}

test "forward with positive pitch has positive Y component" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.pitch = std.math.pi / 4.0;
    const fwd = fs.forward();
    try testing.expect(fwd.y > 0);
}

// Thrust and velocity

test "applying thrust increases velocity in facing direction" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.setThrottle(1.0);
    fs.update(1.0);
    // Should have accelerated in +Z direction (default forward)
    try testing.expect(fs.velocity.z > 0);
    try testing.expectApproxEqAbs(ship_stats.tarsus.thrust, fs.velocity.z, 0.001);
}

test "zero throttle produces no acceleration" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.setThrottle(0.0);
    fs.update(1.0);
    try testing.expectEqual(@as(f32, 0), fs.speed());
}

test "thrust in yawed direction accelerates correctly" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.yaw = std.math.pi / 2.0; // facing +X
    fs.setThrottle(1.0);
    fs.update(1.0);
    try testing.expect(fs.velocity.x > 0);
    try testing.expectApproxEqAbs(@as(f32, 0), fs.velocity.z, 0.01);
}

// Speed capping

test "maximum speed is capped per ship type" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.setThrottle(1.0);
    // Apply many updates to exceed max speed
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        fs.update(0.1);
    }
    try testing.expect(fs.speed() <= ship_stats.tarsus.max_speed + 0.01);
}

test "different ship types have different max speeds" {
    var tarsus = FlightState.init(ship_stats.tarsus);
    var centurion = FlightState.init(ship_stats.centurion);
    tarsus.setThrottle(1.0);
    centurion.setThrottle(1.0);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        tarsus.update(0.1);
        centurion.update(0.1);
    }
    try testing.expect(centurion.speed() > tarsus.speed());
}

// Afterburner

test "afterburner temporarily increases max speed" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.setThrottle(1.0);
    fs.afterburner_active = true;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        fs.update(0.1);
    }
    // With afterburner, speed can exceed normal max
    try testing.expect(fs.speed() > ship_stats.tarsus.max_speed);
    try testing.expect(fs.speed() <= ship_stats.tarsus.afterburner_speed + 0.01);
}

test "disabling afterburner caps speed back to normal max" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.setThrottle(1.0);
    fs.afterburner_active = true;
    // Accelerate with afterburner
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        fs.update(0.1);
    }
    // Now disable afterburner and update
    fs.afterburner_active = false;
    fs.update(0.1);
    try testing.expect(fs.speed() <= ship_stats.tarsus.max_speed + 0.01);
}

// Rotation

test "applyYaw rotates heading" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.applyYaw(1.0, 1.0);
    try testing.expect(fs.yaw > 0);
    try testing.expectApproxEqAbs(ship_stats.tarsus.rotation_rate, fs.yaw, 0.001);
}

test "applyPitch rotates pitch" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.applyPitch(1.0, 1.0);
    try testing.expect(fs.pitch > 0);
}

test "pitch is clamped to prevent gimbal lock" {
    var fs = FlightState.init(ship_stats.tarsus);
    // Apply extreme pitch
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        fs.applyPitch(1.0, 0.1);
    }
    const max_pitch: f32 = std.math.pi / 2.0 - 0.01;
    try testing.expect(fs.pitch <= max_pitch + 0.001);
}

// Throttle

test "setThrottle clamps to 0-1 range" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.setThrottle(1.5);
    try testing.expectEqual(@as(f32, 1.0), fs.throttle);
    fs.setThrottle(-0.5);
    try testing.expectEqual(@as(f32, 0.0), fs.throttle);
}

// Position integration

test "position updates from velocity" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.velocity = .{ .x = 10, .y = 0, .z = 0 };
    fs.update(1.0);
    try testing.expectApproxEqAbs(@as(f32, 10.0), fs.position.x, 0.01);
}

test "position accumulates over multiple frames" {
    var fs = FlightState.init(ship_stats.tarsus);
    fs.velocity = .{ .x = 100, .y = 0, .z = 0 };
    fs.update(0.016); // ~60fps
    fs.update(0.016);
    try testing.expectApproxEqAbs(@as(f32, 3.2), fs.position.x, 0.01);
}

// Ship stats presets

test "all ship stat presets have valid values" {
    const all_stats = [_]ShipStats{
        ship_stats.tarsus,
        ship_stats.galaxy,
        ship_stats.orion,
        ship_stats.centurion,
    };
    for (all_stats) |s| {
        try testing.expect(s.max_speed > 0);
        try testing.expect(s.afterburner_speed > s.max_speed);
        try testing.expect(s.thrust > 0);
        try testing.expect(s.rotation_rate > 0);
    }
}
