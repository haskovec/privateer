//! Targeting system for Wing Commander: Privateer.
//!
//! Manages target selection (nearest hostile, cycle through targets) and
//! computes the ITTS (In-flight Targeting and Tracking System) lead indicator
//! for moving targets. The ITTS shows where to aim so that projectiles
//! will intercept the target given its current velocity.
//!
//! In the original game, pressing 'T' cycles through hostile targets and
//! the ITTS reticle appears ahead of moving targets on the HUD.

const std = @import("std");
const flight_physics = @import("../flight/flight_physics.zig");
const radar_mod = @import("radar.zig");

const Vec3 = flight_physics.Vec3;
pub const Faction = radar_mod.Faction;

/// A targetable entity in space.
pub const Target = struct {
    /// World-space position.
    position: Vec3,
    /// World-space velocity.
    velocity: Vec3,
    /// Faction affiliation.
    faction: Faction,
};

/// Result of an ITTS lead indicator calculation.
pub const IttsResult = struct {
    /// The predicted intercept point in world space.
    lead_point: Vec3,
    /// Time to intercept in seconds.
    time: f32,
    /// Whether a valid intercept solution exists.
    valid: bool,
};

/// Targeting system state.
pub const TargetingSystem = struct {
    /// Index of the currently selected target, or null if none.
    current_target: ?usize = null,

    /// Select the nearest hostile target to the player.
    /// Returns the index of the selected target, or null if no hostiles exist.
    pub fn selectNearestHostile(self: *TargetingSystem, player_pos: Vec3, targets: []const Target) ?usize {
        var best_dist_sq: f32 = std.math.floatMax(f32);
        var best_index: ?usize = null;

        for (targets, 0..) |t, i| {
            if (t.faction != .hostile) continue;
            const d = player_pos.sub(t.position);
            const dist_sq = d.dot(d);
            if (dist_sq < best_dist_sq) {
                best_dist_sq = dist_sq;
                best_index = i;
            }
        }

        self.current_target = best_index;
        return best_index;
    }

    /// Cycle to the next target in the list (all factions).
    /// Wraps around to the first target after the last.
    pub fn cycleTarget(self: *TargetingSystem, target_count: usize) void {
        if (target_count == 0) {
            self.current_target = null;
            return;
        }
        if (self.current_target) |idx| {
            self.current_target = (idx + 1) % target_count;
        } else {
            self.current_target = 0;
        }
    }

    /// Cycle to the next hostile target, skipping friendlies and neutrals.
    pub fn cycleHostile(self: *TargetingSystem, targets: []const Target) void {
        if (targets.len == 0) {
            self.current_target = null;
            return;
        }

        const start = if (self.current_target) |idx| (idx + 1) % targets.len else 0;
        var i: usize = 0;
        while (i < targets.len) : (i += 1) {
            const idx = (start + i) % targets.len;
            if (targets[idx].faction == .hostile) {
                self.current_target = idx;
                return;
            }
        }

        // No hostile targets found
        self.current_target = null;
    }

    /// Clear the current target selection.
    pub fn clearTarget(self: *TargetingSystem) void {
        self.current_target = null;
    }

    /// Get the currently selected target, if any.
    pub fn getTarget(self: *const TargetingSystem, targets: []const Target) ?Target {
        const idx = self.current_target orelse return null;
        if (idx >= targets.len) return null;
        return targets[idx];
    }
};

/// Compute the ITTS lead point for a moving target.
///
/// Solves the quadratic intercept equation to find where to aim so that a
/// projectile fired at `projectile_speed` will intercept the target moving
/// at its current velocity:
///
///   (|V|^2 - s^2) * t^2 + 2*(D . V)*t + |D|^2 = 0
///
/// where D = target_pos - player_pos, V = target velocity, s = projectile speed.
pub fn computeItts(
    player_pos: Vec3,
    target_pos: Vec3,
    target_vel: Vec3,
    projectile_speed: f32,
) IttsResult {
    const d = target_pos.sub(player_pos);
    const v = target_vel;

    // If target is at (or very near) the player, intercept is immediate.
    if (d.dot(d) < 1e-6) {
        return .{ .lead_point = target_pos, .time = 0, .valid = true };
    }

    // Quadratic coefficients
    const a = v.dot(v) - projectile_speed * projectile_speed;
    const b = 2.0 * d.dot(v);
    const c = d.dot(d);

    const discriminant = b * b - 4.0 * a * c;

    if (discriminant < 0) {
        return .{ .lead_point = target_pos, .time = 0, .valid = false };
    }

    const sqrt_disc = @sqrt(discriminant);

    var t: f32 = undefined;
    if (@abs(a) < 1e-6) {
        // Linear case (target speed ~ projectile speed)
        if (@abs(b) < 1e-6) {
            return .{ .lead_point = target_pos, .time = 0, .valid = false };
        }
        t = -c / b;
    } else {
        const t1 = (-b - sqrt_disc) / (2.0 * a);
        const t2 = (-b + sqrt_disc) / (2.0 * a);

        if (t1 > 0 and t2 > 0) {
            t = @min(t1, t2);
        } else if (t1 > 0) {
            t = t1;
        } else if (t2 > 0) {
            t = t2;
        } else {
            return .{ .lead_point = target_pos, .time = 0, .valid = false };
        }
    }

    const lead = target_pos.add(v.scale(t));
    return .{ .lead_point = lead, .time = t, .valid = true };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

// --- Target selection ---

test "selectNearestHostile picks closest hostile" {
    var ts = TargetingSystem{};
    const player_pos = Vec3.zero;

    const targets = [_]Target{
        .{ .position = .{ .x = 100, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .hostile },
        .{ .position = .{ .x = 50, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .hostile },
        .{ .position = .{ .x = 200, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .hostile },
    };

    const idx = ts.selectNearestHostile(player_pos, &targets);
    try testing.expectEqual(@as(?usize, 1), idx);
    try testing.expectEqual(@as(?usize, 1), ts.current_target);
}

test "selectNearestHostile ignores friendly and neutral" {
    var ts = TargetingSystem{};
    const player_pos = Vec3.zero;

    const targets = [_]Target{
        .{ .position = .{ .x = 10, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .friendly },
        .{ .position = .{ .x = 20, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .neutral },
        .{ .position = .{ .x = 200, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .hostile },
    };

    const idx = ts.selectNearestHostile(player_pos, &targets);
    try testing.expectEqual(@as(?usize, 2), idx);
}

test "selectNearestHostile returns null with no hostiles" {
    var ts = TargetingSystem{};
    const player_pos = Vec3.zero;

    const targets = [_]Target{
        .{ .position = .{ .x = 10, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .friendly },
        .{ .position = .{ .x = 20, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .neutral },
    };

    const idx = ts.selectNearestHostile(player_pos, &targets);
    try testing.expectEqual(@as(?usize, null), idx);
    try testing.expectEqual(@as(?usize, null), ts.current_target);
}

test "selectNearestHostile returns null with empty list" {
    var ts = TargetingSystem{};
    const idx = ts.selectNearestHostile(Vec3.zero, &[_]Target{});
    try testing.expectEqual(@as(?usize, null), idx);
}

// --- Cycle targets ---

test "cycleTarget cycles through all targets" {
    var ts = TargetingSystem{};

    ts.cycleTarget(3);
    try testing.expectEqual(@as(?usize, 0), ts.current_target);

    ts.cycleTarget(3);
    try testing.expectEqual(@as(?usize, 1), ts.current_target);

    ts.cycleTarget(3);
    try testing.expectEqual(@as(?usize, 2), ts.current_target);

    ts.cycleTarget(3);
    try testing.expectEqual(@as(?usize, 0), ts.current_target);
}

test "cycleTarget with empty list clears target" {
    var ts = TargetingSystem{ .current_target = 5 };
    ts.cycleTarget(0);
    try testing.expectEqual(@as(?usize, null), ts.current_target);
}

test "cycleTarget wraps from last to first" {
    var ts = TargetingSystem{ .current_target = 4 };
    ts.cycleTarget(5);
    try testing.expectEqual(@as(?usize, 0), ts.current_target);
}

// --- Cycle hostile ---

test "cycleHostile skips non-hostile targets" {
    var ts = TargetingSystem{};

    const targets = [_]Target{
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .friendly },
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .hostile },
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .neutral },
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .hostile },
    };

    ts.cycleHostile(&targets);
    try testing.expectEqual(@as(?usize, 1), ts.current_target);

    ts.cycleHostile(&targets);
    try testing.expectEqual(@as(?usize, 3), ts.current_target);

    ts.cycleHostile(&targets);
    try testing.expectEqual(@as(?usize, 1), ts.current_target);
}

test "cycleHostile returns null with no hostiles" {
    var ts = TargetingSystem{};

    const targets = [_]Target{
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .friendly },
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .neutral },
    };

    ts.cycleHostile(&targets);
    try testing.expectEqual(@as(?usize, null), ts.current_target);
}

test "cycleHostile with empty list clears target" {
    var ts = TargetingSystem{ .current_target = 0 };
    ts.cycleHostile(&[_]Target{});
    try testing.expectEqual(@as(?usize, null), ts.current_target);
}

// --- Clear and get target ---

test "clearTarget sets current to null" {
    var ts = TargetingSystem{ .current_target = 2 };
    ts.clearTarget();
    try testing.expectEqual(@as(?usize, null), ts.current_target);
}

test "getTarget returns selected target" {
    const ts = TargetingSystem{ .current_target = 1 };
    const targets = [_]Target{
        .{ .position = .{ .x = 10, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .friendly },
        .{ .position = .{ .x = 20, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .hostile },
    };
    const t = ts.getTarget(&targets);
    try testing.expect(t != null);
    try testing.expectEqual(@as(f32, 20), t.?.position.x);
    try testing.expectEqual(Faction.hostile, t.?.faction);
}

test "getTarget returns null when no selection" {
    const ts = TargetingSystem{};
    const targets = [_]Target{
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .hostile },
    };
    try testing.expect(ts.getTarget(&targets) == null);
}

test "getTarget returns null when index out of bounds" {
    const ts = TargetingSystem{ .current_target = 5 };
    const targets = [_]Target{
        .{ .position = Vec3.zero, .velocity = Vec3.zero, .faction = .hostile },
    };
    try testing.expect(ts.getTarget(&targets) == null);
}

// --- ITTS computation ---

test "ITTS for stationary target points directly at target" {
    const result = computeItts(
        Vec3.zero,
        .{ .x = 100, .y = 0, .z = 0 },
        Vec3.zero,
        500.0,
    );

    try testing.expect(result.valid);
    try testing.expect(result.time > 0);
    // Lead point should be at the target since it's not moving
    try testing.expectApproxEqAbs(@as(f32, 100), result.lead_point.x, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0), result.lead_point.y, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0), result.lead_point.z, 0.1);
}

test "ITTS for moving target shows lead offset" {
    // Target at (100, 0, 0) moving in +Z at 100 units/sec
    // Projectile speed 500 units/sec
    const result = computeItts(
        Vec3.zero,
        .{ .x = 100, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 100 },
        500.0,
    );

    try testing.expect(result.valid);
    try testing.expect(result.time > 0);
    // Lead point should be ahead of target in Z
    try testing.expect(result.lead_point.z > 0);
    // Lead point X should still be ~100 (target isn't moving in X)
    try testing.expectApproxEqAbs(@as(f32, 100), result.lead_point.x, 1.0);
}

test "ITTS lead offset is proportional to target speed" {
    // Slow target
    const slow = computeItts(
        Vec3.zero,
        .{ .x = 100, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 50 },
        500.0,
    );

    // Fast target (same position, same direction, double speed)
    const fast = computeItts(
        Vec3.zero,
        .{ .x = 100, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 100 },
        500.0,
    );

    try testing.expect(slow.valid);
    try testing.expect(fast.valid);
    // Faster target should have a larger Z lead offset
    try testing.expect(fast.lead_point.z > slow.lead_point.z);
}

test "ITTS returns invalid when projectile cannot catch target" {
    // Target moving away faster than the projectile
    const result = computeItts(
        Vec3.zero,
        .{ .x = 100, .y = 0, .z = 0 },
        .{ .x = 1000, .y = 0, .z = 0 },
        10.0, // very slow projectile
    );

    try testing.expect(!result.valid);
}

test "ITTS time to intercept is positive" {
    const result = computeItts(
        Vec3.zero,
        .{ .x = 0, .y = 0, .z = 200 },
        .{ .x = 50, .y = 0, .z = 0 },
        600.0,
    );

    try testing.expect(result.valid);
    try testing.expect(result.time > 0);
    // At 600 u/s over ~200 units, should be around 0.33s
    try testing.expect(result.time < 1.0);
}

test "ITTS with target at player position" {
    const result = computeItts(
        Vec3.zero,
        Vec3.zero,
        .{ .x = 100, .y = 0, .z = 0 },
        500.0,
    );

    // Should be valid with very short intercept time
    try testing.expect(result.valid);
    try testing.expectApproxEqAbs(@as(f32, 0), result.time, 0.01);
}
