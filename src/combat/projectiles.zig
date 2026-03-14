//! Projectile physics system for Wing Commander: Privateer.
//!
//! Manages a pool of active projectiles, updates their positions each frame,
//! removes expired projectiles, and performs bounding-sphere collision
//! detection against ships/targets in the game world.

const std = @import("std");
const weapons = @import("weapons.zig");
const flight_physics = @import("../flight/flight_physics.zig");

const Vec3 = flight_physics.Vec3;
const Projectile = weapons.Projectile;
const TrackingType = weapons.TrackingType;

/// Result of a projectile hitting a target.
pub const HitResult = struct {
    /// Index of the target that was hit.
    target_index: usize,
    /// Damage dealt by the projectile.
    damage: u16,
    /// Position where the hit occurred.
    hit_position: Vec3,
};

/// A target that can be hit by projectiles.
pub const Target = struct {
    /// Position in world space.
    position: Vec3,
    /// Bounding sphere radius for collision detection.
    radius: f32,
};

/// Maximum number of active projectiles.
const MAX_PROJECTILES = 128;

/// Manages all active projectiles in the game world.
pub const ProjectileSystem = struct {
    /// Active projectile pool (fixed-size array, null = empty slot).
    projectiles: [MAX_PROJECTILES]?Projectile,
    /// Number of currently active projectiles.
    active_count: usize,

    /// Create a new empty projectile system.
    pub fn init() ProjectileSystem {
        return .{
            .projectiles = [_]?Projectile{null} ** MAX_PROJECTILES,
            .active_count = 0,
        };
    }

    /// Spawn a new projectile. Returns true if spawned, false if pool is full.
    pub fn spawn(self: *ProjectileSystem, proj: Projectile) bool {
        for (&self.projectiles) |*slot| {
            if (slot.* == null) {
                slot.* = proj;
                self.active_count += 1;
                return true;
            }
        }
        return false;
    }

    /// Update all projectiles for one frame. Removes expired projectiles.
    /// For guided missiles, steers them toward their targets.
    pub fn update(self: *ProjectileSystem, dt: f32, targets: []const Target) void {
        for (&self.projectiles) |*slot| {
            if (slot.*) |*proj| {
                // Guided missile tracking
                if (proj.is_missile and proj.target_index != null) {
                    const ti = proj.target_index.?;
                    if (ti < targets.len) {
                        self.updateTracking(proj, targets[ti], dt);
                    }
                }

                // Move projectile and check lifetime
                if (!proj.update(dt)) {
                    slot.* = null;
                    self.active_count -= 1;
                }
            }
        }
    }

    /// Steer a guided missile toward its target.
    fn updateTracking(_: *ProjectileSystem, proj: *Projectile, target: Target, dt: f32) void {
        const to_target = target.position.sub(proj.position);
        const dist = to_target.length();
        if (dist < 0.001) return;

        const desired_dir = to_target.normalize();
        const current_speed = proj.velocity.length();
        if (current_speed < 0.001) return;

        const current_dir = proj.velocity.normalize();

        // Turn rate depends on tracking type
        const turn_rate: f32 = switch (proj.tracking) {
            .heat_seeking => 2.0,
            .image_recognition => 3.0,
            .friend_or_foe => 2.5,
            .torpedo => 1.0,
            else => 0.0,
        };

        if (turn_rate == 0.0) return;

        // Interpolate direction toward target
        const t = @min(turn_rate * dt, 1.0);
        const interp = Vec3{
            .x = current_dir.x + (desired_dir.x - current_dir.x) * t,
            .y = current_dir.y + (desired_dir.y - current_dir.y) * t,
            .z = current_dir.z + (desired_dir.z - current_dir.z) * t,
        };
        const new_dir = interp.normalize();

        proj.velocity = new_dir.scale(current_speed);
    }

    /// Check all projectiles against all targets for bounding-sphere collisions.
    /// Returns a list of hits. Collided projectiles are removed.
    pub fn checkCollisions(
        self: *ProjectileSystem,
        targets: []const Target,
        allocator: std.mem.Allocator,
    ) ![]HitResult {
        // Count hits first to allocate exact size
        var hit_count: usize = 0;
        for (self.projectiles) |slot| {
            if (slot) |proj| {
                for (targets) |target| {
                    const diff = proj.position.sub(target.position);
                    const dist = diff.length();
                    if (dist <= target.radius) {
                        hit_count += 1;
                        break;
                    }
                }
            }
        }

        if (hit_count == 0) {
            return allocator.alloc(HitResult, 0);
        }

        const hits = try allocator.alloc(HitResult, hit_count);
        var hi: usize = 0;

        for (&self.projectiles) |*slot| {
            if (slot.*) |proj| {
                for (targets, 0..) |target, ti| {
                    const diff = proj.position.sub(target.position);
                    const dist = diff.length();
                    if (dist <= target.radius) {
                        hits[hi] = .{
                            .target_index = ti,
                            .damage = proj.damage,
                            .hit_position = proj.position,
                        };
                        hi += 1;
                        slot.* = null;
                        self.active_count -= 1;
                        break;
                    }
                }
            }
        }

        return hits;
    }

    /// Get the number of active projectiles.
    pub fn count(self: *const ProjectileSystem) usize {
        return self.active_count;
    }

    /// Clear all active projectiles.
    pub fn clear(self: *ProjectileSystem) void {
        for (&self.projectiles) |*slot| {
            slot.* = null;
        }
        self.active_count = 0;
    }

    /// Get a slice view of active projectiles (for rendering).
    /// Caller must provide a buffer to collect results.
    pub fn getActive(self: *const ProjectileSystem, buf: []Projectile) []Projectile {
        var n: usize = 0;
        for (self.projectiles) |slot| {
            if (slot) |proj| {
                if (n >= buf.len) break;
                buf[n] = proj;
                n += 1;
            }
        }
        return buf[0..n];
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// --- System creation ---

test "ProjectileSystem.init creates empty system" {
    const sys = ProjectileSystem.init();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

// --- Spawning ---

test "spawn adds projectile to system" {
    var sys = ProjectileSystem.init();
    const proj = makeTestProjectile(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 100 }, 5.0, 10);
    try testing.expect(sys.spawn(proj));
    try testing.expectEqual(@as(usize, 1), sys.count());
}

test "spawn multiple projectiles" {
    var sys = ProjectileSystem.init();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const proj = makeTestProjectile(.{ .x = @floatFromInt(i), .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 100 }, 5.0, 10);
        try testing.expect(sys.spawn(proj));
    }
    try testing.expectEqual(@as(usize, 5), sys.count());
}

test "spawn returns false when pool is full" {
    var sys = ProjectileSystem.init();
    var i: usize = 0;
    while (i < MAX_PROJECTILES) : (i += 1) {
        try testing.expect(sys.spawn(makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 1 }, 10.0, 1)));
    }
    // Pool is full
    try testing.expect(!sys.spawn(makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 1 }, 10.0, 1)));
}

// --- Movement ---

test "update moves projectiles in their velocity direction" {
    var sys = ProjectileSystem.init();
    const proj = makeTestProjectile(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 100, .y = 0, .z = 0 }, 5.0, 10);
    _ = sys.spawn(proj);

    sys.update(1.0, &.{});

    var buf: [1]Projectile = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expectApproxEqAbs(@as(f32, 100.0), active[0].position.x, 0.01);
}

test "projectile moves at weapon speed along fired direction" {
    var sys = ProjectileSystem.init();
    // Fire at 500 units/sec along Z
    const proj = makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 500 }, 10.0, 20);
    _ = sys.spawn(proj);

    // One frame at 60fps
    sys.update(1.0 / 60.0, &.{});

    var buf: [1]Projectile = undefined;
    const active = sys.getActive(&buf);
    try testing.expectApproxEqAbs(@as(f32, 500.0 / 60.0), active[0].position.z, 0.01);
}

// --- Lifetime / range ---

test "projectile despawns after lifetime expires" {
    var sys = ProjectileSystem.init();
    const proj = makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 100 }, 0.5, 10);
    _ = sys.spawn(proj);
    try testing.expectEqual(@as(usize, 1), sys.count());

    // Update past lifetime
    sys.update(1.0, &.{});
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "projectile with range-based lifetime despawns at max range" {
    var sys = ProjectileSystem.init();
    // Speed 1000, range 500 → lifetime = 0.5s
    // After 0.5s at speed 1000, projectile has traveled 500 units
    const proj = makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 1000 }, 0.5, 10);
    _ = sys.spawn(proj);

    // Update in small steps
    sys.update(0.25, &.{});
    try testing.expectEqual(@as(usize, 1), sys.count()); // Still alive
    sys.update(0.26, &.{});
    try testing.expectEqual(@as(usize, 0), sys.count()); // Gone
}

// --- Collision detection ---

test "projectile-ship bounding sphere collision detected" {
    var sys = ProjectileSystem.init();
    // Projectile at origin moving toward target at (10, 0, 0)
    const proj = makeTestProjectile(.{ .x = 9.5, .y = 0, .z = 0 }, .{ .x = 100, .y = 0, .z = 0 }, 5.0, 25);
    _ = sys.spawn(proj);

    const targets = [_]Target{
        .{ .position = .{ .x = 10, .y = 0, .z = 0 }, .radius = 1.0 },
    };

    const hits = try sys.checkCollisions(&targets, testing.allocator);
    defer testing.allocator.free(hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(usize, 0), hits[0].target_index);
    try testing.expectEqual(@as(u16, 25), hits[0].damage);
}

test "projectile outside bounding sphere no collision" {
    var sys = ProjectileSystem.init();
    // Projectile far from target
    const proj = makeTestProjectile(.{ .x = 100, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 100 }, 5.0, 10);
    _ = sys.spawn(proj);

    const targets = [_]Target{
        .{ .position = .{ .x = 0, .y = 0, .z = 0 }, .radius = 5.0 },
    };

    const hits = try sys.checkCollisions(&targets, testing.allocator);
    defer testing.allocator.free(hits);

    try testing.expectEqual(@as(usize, 0), hits.len);
    try testing.expectEqual(@as(usize, 1), sys.count()); // Projectile still alive
}

test "collision removes projectile from system" {
    var sys = ProjectileSystem.init();
    const proj = makeTestProjectile(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 100 }, 5.0, 10);
    _ = sys.spawn(proj);
    try testing.expectEqual(@as(usize, 1), sys.count());

    const targets = [_]Target{
        .{ .position = .{ .x = 0, .y = 0, .z = 0 }, .radius = 5.0 },
    };

    const hits = try sys.checkCollisions(&targets, testing.allocator);
    defer testing.allocator.free(hits);

    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(usize, 0), sys.count()); // Projectile removed
}

test "multiple projectiles can hit different targets" {
    var sys = ProjectileSystem.init();
    // Projectile near target 0
    _ = sys.spawn(makeTestProjectile(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 100 }, 5.0, 10));
    // Projectile near target 1
    _ = sys.spawn(makeTestProjectile(.{ .x = 50, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 100 }, 5.0, 20));
    try testing.expectEqual(@as(usize, 2), sys.count());

    const targets = [_]Target{
        .{ .position = .{ .x = 0, .y = 0, .z = 0 }, .radius = 3.0 },
        .{ .position = .{ .x = 50, .y = 0, .z = 0 }, .radius = 3.0 },
    };

    const hits = try sys.checkCollisions(&targets, testing.allocator);
    defer testing.allocator.free(hits);

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "projectile only hits first overlapping target" {
    var sys = ProjectileSystem.init();
    // Projectile at origin, two overlapping targets at origin
    _ = sys.spawn(makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 100 }, 5.0, 15));

    const targets = [_]Target{
        .{ .position = Vec3.zero, .radius = 5.0 },
        .{ .position = Vec3.zero, .radius = 5.0 },
    };

    const hits = try sys.checkCollisions(&targets, testing.allocator);
    defer testing.allocator.free(hits);

    // Only one hit per projectile
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(@as(usize, 0), hits[0].target_index);
}

// --- Missile tracking ---

test "heat-seeking missile steers toward target" {
    var sys = ProjectileSystem.init();
    // Missile moving in +Z, target is off to the right at +X
    var proj = makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 800 }, 10.0, 160);
    proj.is_missile = true;
    proj.tracking = .heat_seeking;
    proj.target_index = 0;
    _ = sys.spawn(proj);

    const targets = [_]Target{
        .{ .position = .{ .x = 100, .y = 0, .z = 100 }, .radius = 5.0 },
    };

    // After update, velocity should have some +X component (turning toward target)
    sys.update(0.5, &targets);

    var buf: [1]Projectile = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expect(active[0].velocity.x > 0); // Turned toward target
}

test "dumbfire missile does not track" {
    var sys = ProjectileSystem.init();
    var proj = makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 1000 }, 10.0, 130);
    proj.is_missile = true;
    proj.tracking = .dumbfire;
    proj.target_index = 0;
    _ = sys.spawn(proj);

    const targets = [_]Target{
        .{ .position = .{ .x = 100, .y = 0, .z = 0 }, .radius = 5.0 },
    };

    sys.update(0.5, &targets);

    var buf: [1]Projectile = undefined;
    const active = sys.getActive(&buf);
    // Should still be going straight in +Z, no X drift
    try testing.expectApproxEqAbs(@as(f32, 0), active[0].velocity.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1000), active[0].velocity.z, 0.01);
}

// --- Clear ---

test "clear removes all projectiles" {
    var sys = ProjectileSystem.init();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = sys.spawn(makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 1 }, 10.0, 1));
    }
    try testing.expectEqual(@as(usize, 10), sys.count());
    sys.clear();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

// --- Slot reuse ---

test "expired projectile slot is reused by new spawn" {
    var sys = ProjectileSystem.init();
    // Fill all slots
    var i: usize = 0;
    while (i < MAX_PROJECTILES) : (i += 1) {
        _ = sys.spawn(makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 1 }, 0.1, 1));
    }
    try testing.expectEqual(@as(usize, MAX_PROJECTILES), sys.count());

    // Expire all
    sys.update(1.0, &.{});
    try testing.expectEqual(@as(usize, 0), sys.count());

    // Should be able to spawn again
    try testing.expect(sys.spawn(makeTestProjectile(Vec3.zero, .{ .x = 0, .y = 0, .z = 1 }, 5.0, 1)));
    try testing.expectEqual(@as(usize, 1), sys.count());
}

// --- Test helpers ---

fn makeTestProjectile(pos: Vec3, vel: Vec3, lifetime: f32, damage: u16) Projectile {
    return .{
        .position = pos,
        .velocity = vel,
        .lifetime = lifetime,
        .damage = damage,
        .is_missile = false,
        .tracking = .dumbfire,
        .target_index = null,
    };
}
