//! Explosion and debris system for Wing Commander: Privateer.
//!
//! Manages visual explosion effects and debris particles spawned when ships
//! are destroyed. Uses fixed-size pools (like the projectile system) with
//! frame-based animation for explosions and physics-based movement for debris.
//!
//! Data flow:
//!   1. Ship health reaches zero → damage.isDestroyed() returns true
//!   2. Caller spawns an explosion at the ship's position via ExplosionSystem.spawn()
//!   3. ExplosionSystem.update() advances animation frames and removes expired explosions
//!   4. Debris particles fly outward with randomized velocities and spin
//!
//! Data files:
//!   - EXPLTYPE.IFF (FORM:EXPL) defines explosion types: BIGEXPL, MEDEXPL, SMLEXPL, DETHEXPL
//!   - TRSHTYPE.IFF (FORM:TRSH) defines debris types: CDBRTYPE, BODYPRT1, BODYPRT2

const std = @import("std");
const iff = @import("../formats/iff.zig");
const flight_physics = @import("../flight/flight_physics.zig");

const Vec3 = flight_physics.Vec3;

// ── Explosion Types ──────────────────────────────────────────────────

/// Size class for explosions.
pub const ExplosionSize = enum(u8) {
    big = 0,
    medium = 1,
    small = 2,
    death = 3,
};

/// Definition of an explosion type loaded from EXPLTYPE.IFF.
pub const ExplosionType = struct {
    /// Explosion size class (maps to BIGEXPL/MEDEXPL/SMLEXPL/DETHEXPL).
    size: ExplosionSize,
    /// Type name (8 chars, null-padded).
    name: [8]u8,
    /// Total duration in seconds.
    duration: f32,
    /// Number of animation frames.
    num_frames: u16,
    /// Visual radius.
    radius: f32,
    /// Whether this explosion spawns debris particles.
    spawns_debris: bool,
    /// Number of debris particles to spawn.
    num_debris: u8,
};

/// Predefined explosion types matching the original game.
pub const explosion_types = struct {
    pub const big = ExplosionType{
        .size = .big,
        .name = .{ 'B', 'I', 'G', 'E', 'X', 'P', 'L', 0 },
        .duration = 1.5,
        .num_frames = 15,
        .radius = 80.0,
        .spawns_debris = true,
        .num_debris = 12,
    };
    pub const medium = ExplosionType{
        .size = .medium,
        .name = .{ 'M', 'E', 'D', 'E', 'X', 'P', 'L', 0 },
        .duration = 1.0,
        .num_frames = 10,
        .radius = 50.0,
        .spawns_debris = true,
        .num_debris = 8,
    };
    pub const small = ExplosionType{
        .size = .small,
        .name = .{ 'S', 'M', 'L', 'E', 'X', 'P', 'L', 0 },
        .duration = 0.6,
        .num_frames = 6,
        .radius = 25.0,
        .spawns_debris = true,
        .num_debris = 4,
    };
    pub const death = ExplosionType{
        .size = .death,
        .name = .{ 'D', 'E', 'T', 'H', 'E', 'X', 'P', 'L' },
        .duration = 2.0,
        .num_frames = 20,
        .radius = 100.0,
        .spawns_debris = true,
        .num_debris = 16,
    };
};

/// Get the default explosion type for a given size class.
pub fn getExplosionType(size: ExplosionSize) ExplosionType {
    return switch (size) {
        .big => explosion_types.big,
        .medium => explosion_types.medium,
        .small => explosion_types.small,
        .death => explosion_types.death,
    };
}

// ── Debris Types ──────────────────────────────────────────────────────

/// Definition of a debris type loaded from TRSHTYPE.IFF.
pub const DebrisType = struct {
    /// Type ID.
    id: u8,
    /// Type name (8 chars, null-padded).
    name: [8]u8,
    /// Minimum ejection speed.
    speed_min: f32,
    /// Maximum ejection speed.
    speed_max: f32,
    /// Lifetime in seconds.
    lifetime: f32,
    /// Spin rate in radians per second.
    spin_rate: f32,
};

/// Default debris type for combat debris.
pub const default_debris_type = DebrisType{
    .id = 0,
    .name = .{ 'C', 'D', 'B', 'R', 'T', 'Y', 'P', 'E' },
    .speed_min = 20.0,
    .speed_max = 80.0,
    .lifetime = 3.0,
    .spin_rate = std.math.pi,
};

// ── Active Explosion ──────────────────────────────────────────────────

/// A single active explosion effect in the game world.
pub const Explosion = struct {
    /// World-space position.
    position: Vec3,
    /// Explosion size class.
    size: ExplosionSize,
    /// Time elapsed since spawn (seconds).
    elapsed: f32,
    /// Total duration (seconds).
    duration: f32,
    /// Number of animation frames.
    num_frames: u16,
    /// Visual radius.
    radius: f32,

    /// Get the current animation frame index (0-based).
    pub fn currentFrame(self: *const Explosion) u16 {
        if (self.duration <= 0) return 0;
        const t = self.elapsed / self.duration;
        const frame_f = t * @as(f32, @floatFromInt(self.num_frames));
        const frame: u16 = @intFromFloat(@min(frame_f, @as(f32, @floatFromInt(self.num_frames - 1))));
        return frame;
    }

    /// Get animation progress as a 0.0-1.0 value.
    pub fn progress(self: *const Explosion) f32 {
        if (self.duration <= 0) return 1.0;
        return @min(self.elapsed / self.duration, 1.0);
    }

    /// Update the explosion for one frame. Returns true if still alive.
    pub fn update(self: *Explosion, dt: f32) bool {
        self.elapsed += dt;
        return self.elapsed < self.duration;
    }
};

// ── Active Debris Particle ────────────────────────────────────────────

/// A single debris particle in the game world.
pub const DebrisParticle = struct {
    /// World-space position.
    position: Vec3,
    /// Velocity vector.
    velocity: Vec3,
    /// Time elapsed since spawn.
    elapsed: f32,
    /// Total lifetime.
    lifetime: f32,
    /// Current rotation angle (radians).
    rotation: f32,
    /// Spin rate (radians per second).
    spin_rate: f32,

    /// Update the particle for one frame. Returns true if still alive.
    pub fn update(self: *DebrisParticle, dt: f32) bool {
        self.position = self.position.add(self.velocity.scale(dt));
        self.rotation += self.spin_rate * dt;
        self.elapsed += dt;
        return self.elapsed < self.lifetime;
    }

    /// Get remaining lifetime fraction (1.0 = just spawned, 0.0 = expired).
    pub fn remainingFraction(self: *const DebrisParticle) f32 {
        if (self.lifetime <= 0) return 0;
        return @max(0, 1.0 - self.elapsed / self.lifetime);
    }
};

// ── Explosion System ──────────────────────────────────────────────────

/// Maximum number of concurrent explosions.
const MAX_EXPLOSIONS = 64;

/// Manages all active explosions in the game world.
pub const ExplosionSystem = struct {
    /// Active explosion pool (fixed-size array, null = empty slot).
    explosions: [MAX_EXPLOSIONS]?Explosion,
    /// Number of currently active explosions.
    active_count: usize,

    /// Create a new empty explosion system.
    pub fn init() ExplosionSystem {
        return .{
            .explosions = [_]?Explosion{null} ** MAX_EXPLOSIONS,
            .active_count = 0,
        };
    }

    /// Spawn a new explosion at the given position. Returns true if spawned.
    pub fn spawn(self: *ExplosionSystem, position: Vec3, size: ExplosionSize) bool {
        const expl_type = getExplosionType(size);
        return self.spawnWithType(position, expl_type);
    }

    /// Spawn a new explosion with a specific type definition. Returns true if spawned.
    pub fn spawnWithType(self: *ExplosionSystem, position: Vec3, expl_type: ExplosionType) bool {
        for (&self.explosions) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .position = position,
                    .size = expl_type.size,
                    .elapsed = 0,
                    .duration = expl_type.duration,
                    .num_frames = expl_type.num_frames,
                    .radius = expl_type.radius,
                };
                self.active_count += 1;
                return true;
            }
        }
        return false;
    }

    /// Update all explosions for one frame. Removes expired explosions.
    pub fn update(self: *ExplosionSystem, dt: f32) void {
        for (&self.explosions) |*slot| {
            if (slot.*) |*expl| {
                if (!expl.update(dt)) {
                    slot.* = null;
                    self.active_count -= 1;
                }
            }
        }
    }

    /// Get the number of active explosions.
    pub fn count(self: *const ExplosionSystem) usize {
        return self.active_count;
    }

    /// Clear all active explosions.
    pub fn clear(self: *ExplosionSystem) void {
        for (&self.explosions) |*slot| {
            slot.* = null;
        }
        self.active_count = 0;
    }

    /// Get a slice view of active explosions (for rendering).
    /// Caller must provide a buffer to collect results.
    pub fn getActive(self: *const ExplosionSystem, buf: []Explosion) []Explosion {
        var n: usize = 0;
        for (self.explosions) |slot| {
            if (slot) |expl| {
                if (n >= buf.len) break;
                buf[n] = expl;
                n += 1;
            }
        }
        return buf[0..n];
    }
};

// ── Debris System ─────────────────────────────────────────────────────

/// Maximum number of concurrent debris particles.
const MAX_DEBRIS = 256;

/// Manages all active debris particles in the game world.
pub const DebrisSystem = struct {
    /// Active debris pool (fixed-size array, null = empty slot).
    particles: [MAX_DEBRIS]?DebrisParticle,
    /// Number of currently active particles.
    active_count: usize,

    /// Create a new empty debris system.
    pub fn init() DebrisSystem {
        return .{
            .particles = [_]?DebrisParticle{null} ** MAX_DEBRIS,
            .active_count = 0,
        };
    }

    /// Spawn a single debris particle. Returns true if spawned.
    pub fn spawn(self: *DebrisSystem, particle: DebrisParticle) bool {
        for (&self.particles) |*slot| {
            if (slot.* == null) {
                slot.* = particle;
                self.active_count += 1;
                return true;
            }
        }
        return false;
    }

    /// Spawn a burst of debris particles at a position using an RNG.
    /// Returns the number of particles actually spawned.
    pub fn spawnBurst(
        self: *DebrisSystem,
        position: Vec3,
        count_requested: u8,
        debris_type: DebrisType,
        rng: *std.Random.Xoshiro256,
    ) u8 {
        var spawned: u8 = 0;
        const random = rng.random();
        var i: u8 = 0;
        while (i < count_requested) : (i += 1) {
            // Random direction (uniform on sphere)
            const theta = random.float(f32) * 2.0 * std.math.pi;
            const phi = std.math.acos(1.0 - 2.0 * random.float(f32));
            const dir = Vec3{
                .x = @sin(phi) * @cos(theta),
                .y = @sin(phi) * @sin(theta),
                .z = @cos(phi),
            };

            // Random speed within range
            const speed = debris_type.speed_min +
                random.float(f32) * (debris_type.speed_max - debris_type.speed_min);

            // Random lifetime variation (+/- 20%)
            const lifetime_var = 0.8 + random.float(f32) * 0.4;

            // Random spin direction
            const spin_dir: f32 = if (random.boolean()) 1.0 else -1.0;

            const particle = DebrisParticle{
                .position = position,
                .velocity = dir.scale(speed),
                .elapsed = 0,
                .lifetime = debris_type.lifetime * lifetime_var,
                .rotation = random.float(f32) * 2.0 * std.math.pi,
                .spin_rate = debris_type.spin_rate * spin_dir,
            };

            if (self.spawn(particle)) {
                spawned += 1;
            } else {
                break; // Pool full
            }
        }
        return spawned;
    }

    /// Update all debris particles for one frame. Removes expired particles.
    pub fn update(self: *DebrisSystem, dt: f32) void {
        for (&self.particles) |*slot| {
            if (slot.*) |*particle| {
                if (!particle.update(dt)) {
                    slot.* = null;
                    self.active_count -= 1;
                }
            }
        }
    }

    /// Get the number of active particles.
    pub fn count(self: *const DebrisSystem) usize {
        return self.active_count;
    }

    /// Clear all active particles.
    pub fn clear(self: *DebrisSystem) void {
        for (&self.particles) |*slot| {
            slot.* = null;
        }
        self.active_count = 0;
    }

    /// Get a slice view of active particles (for rendering).
    /// Caller must provide a buffer to collect results.
    pub fn getActive(self: *const DebrisSystem, buf: []DebrisParticle) []DebrisParticle {
        var n: usize = 0;
        for (self.particles) |slot| {
            if (slot) |particle| {
                if (n >= buf.len) break;
                buf[n] = particle;
                n += 1;
            }
        }
        return buf[0..n];
    }
};

// ── IFF Parsers ───────────────────────────────────────────────────────

pub const ExplosionDataError = error{
    InvalidFormat,
    MissingData,
    OutOfMemory,
};

/// Parse explosion types from EXPLTYPE.IFF data.
///
/// FORM:EXPL containing UNIT chunks (17 bytes each):
///   byte 0: explosion type ID (0=big, 1=medium, 2=small, 3=death)
///   byte 1-8: name (8 chars, null-padded)
///   byte 9-10: u16 LE duration_ms
///   byte 11-12: u16 LE num_frames
///   byte 13-14: u16 LE radius
///   byte 15: spawn_debris flag
///   byte 16: num_debris count
pub fn parseExplosionTypes(allocator: std.mem.Allocator, data: []const u8) ExplosionDataError![]ExplosionType {
    var root = iff.parseFile(allocator, data) catch return ExplosionDataError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ExplosionDataError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "EXPL")) return ExplosionDataError.InvalidFormat;

    const units = root.findChildren(allocator, "UNIT".*) catch return ExplosionDataError.OutOfMemory;
    defer allocator.free(units);

    if (units.len == 0) return ExplosionDataError.MissingData;

    const types = allocator.alloc(ExplosionType, units.len) catch return ExplosionDataError.OutOfMemory;
    errdefer allocator.free(types);

    for (units, 0..) |unit, i| {
        if (unit.data.len < 17) return ExplosionDataError.InvalidFormat;
        const d = unit.data;

        var name: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        @memcpy(&name, d[1..9]);

        const duration_ms = std.mem.readInt(u16, d[9..11], .little);
        const num_frames = std.mem.readInt(u16, d[11..13], .little);
        const radius = std.mem.readInt(u16, d[13..15], .little);

        types[i] = .{
            .size = @enumFromInt(d[0]),
            .name = name,
            .duration = @as(f32, @floatFromInt(duration_ms)) / 1000.0,
            .num_frames = num_frames,
            .radius = @floatFromInt(radius),
            .spawns_debris = d[15] != 0,
            .num_debris = d[16],
        };
    }

    return types;
}

/// Parse debris types from TRSHTYPE.IFF data.
///
/// FORM:TRSH containing UNIT chunks (17 bytes each):
///   byte 0: debris type ID
///   byte 1-8: name (8 chars, null-padded)
///   byte 9-10: u16 LE speed_min
///   byte 11-12: u16 LE speed_max
///   byte 13-14: u16 LE lifetime_ms
///   byte 15-16: u16 LE spin_rate (degrees per second)
pub fn parseDebrisTypes(allocator: std.mem.Allocator, data: []const u8) ExplosionDataError![]DebrisType {
    var root = iff.parseFile(allocator, data) catch return ExplosionDataError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ExplosionDataError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "TRSH")) return ExplosionDataError.InvalidFormat;

    const units = root.findChildren(allocator, "UNIT".*) catch return ExplosionDataError.OutOfMemory;
    defer allocator.free(units);

    if (units.len == 0) return ExplosionDataError.MissingData;

    const types = allocator.alloc(DebrisType, units.len) catch return ExplosionDataError.OutOfMemory;
    errdefer allocator.free(types);

    for (units, 0..) |unit, i| {
        if (unit.data.len < 17) return ExplosionDataError.InvalidFormat;
        const d = unit.data;

        var name: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        @memcpy(&name, d[1..9]);

        const speed_min = std.mem.readInt(u16, d[9..11], .little);
        const speed_max = std.mem.readInt(u16, d[11..13], .little);
        const lifetime_ms = std.mem.readInt(u16, d[13..15], .little);
        const spin_rate_deg = std.mem.readInt(u16, d[15..17], .little);

        types[i] = .{
            .id = d[0],
            .name = name,
            .speed_min = @floatFromInt(speed_min),
            .speed_max = @floatFromInt(speed_max),
            .lifetime = @as(f32, @floatFromInt(lifetime_ms)) / 1000.0,
            .spin_rate = @as(f32, @floatFromInt(spin_rate_deg)) * std.math.pi / 180.0,
        };
    }

    return types;
}

// ── Destruction Helper ────────────────────────────────────────────────

/// Spawn an explosion and debris burst for a destroyed ship.
/// Returns true if the explosion was spawned (debris spawning is best-effort).
pub fn spawnDestructionEffect(
    explosion_sys: *ExplosionSystem,
    debris_sys: *DebrisSystem,
    position: Vec3,
    size: ExplosionSize,
    rng: *std.Random.Xoshiro256,
) bool {
    const expl_type = getExplosionType(size);
    if (!explosion_sys.spawnWithType(position, expl_type)) return false;

    if (expl_type.spawns_debris) {
        _ = debris_sys.spawnBurst(position, expl_type.num_debris, default_debris_type, rng);
    }

    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const testing_helpers = @import("../testing.zig");

// --- Explosion type defaults ---

test "getExplosionType returns correct type for each size" {
    const big = getExplosionType(.big);
    try testing.expectEqual(ExplosionSize.big, big.size);
    try testing.expectApproxEqAbs(@as(f32, 1.5), big.duration, 0.01);
    try testing.expectEqual(@as(u16, 15), big.num_frames);
    try testing.expectApproxEqAbs(@as(f32, 80.0), big.radius, 0.01);
    try testing.expect(big.spawns_debris);
    try testing.expectEqual(@as(u8, 12), big.num_debris);

    const small = getExplosionType(.small);
    try testing.expectEqual(ExplosionSize.small, small.size);
    try testing.expectApproxEqAbs(@as(f32, 0.6), small.duration, 0.01);
}

test "death explosion is largest" {
    const death = getExplosionType(.death);
    const big = getExplosionType(.big);
    try testing.expect(death.radius > big.radius);
    try testing.expect(death.duration > big.duration);
    try testing.expect(death.num_debris > big.num_debris);
}

// --- Explosion animation ---

test "Explosion.currentFrame returns 0 at start" {
    const expl = Explosion{
        .position = Vec3.zero,
        .size = .medium,
        .elapsed = 0,
        .duration = 1.0,
        .num_frames = 10,
        .radius = 50.0,
    };
    try testing.expectEqual(@as(u16, 0), expl.currentFrame());
}

test "Explosion.currentFrame advances with elapsed time" {
    const expl = Explosion{
        .position = Vec3.zero,
        .size = .medium,
        .elapsed = 0.5,
        .duration = 1.0,
        .num_frames = 10,
        .radius = 50.0,
    };
    try testing.expectEqual(@as(u16, 5), expl.currentFrame());
}

test "Explosion.currentFrame clamps to last frame" {
    const expl = Explosion{
        .position = Vec3.zero,
        .size = .medium,
        .elapsed = 1.0,
        .duration = 1.0,
        .num_frames = 10,
        .radius = 50.0,
    };
    try testing.expectEqual(@as(u16, 9), expl.currentFrame());
}

test "Explosion.progress returns 0 at start" {
    const expl = Explosion{
        .position = Vec3.zero,
        .size = .small,
        .elapsed = 0,
        .duration = 1.0,
        .num_frames = 6,
        .radius = 25.0,
    };
    try testing.expectApproxEqAbs(@as(f32, 0), expl.progress(), 0.01);
}

test "Explosion.progress returns 0.5 at midpoint" {
    const expl = Explosion{
        .position = Vec3.zero,
        .size = .small,
        .elapsed = 0.5,
        .duration = 1.0,
        .num_frames = 6,
        .radius = 25.0,
    };
    try testing.expectApproxEqAbs(@as(f32, 0.5), expl.progress(), 0.01);
}

test "Explosion.update advances elapsed time" {
    var expl = Explosion{
        .position = Vec3.zero,
        .size = .medium,
        .elapsed = 0,
        .duration = 1.0,
        .num_frames = 10,
        .radius = 50.0,
    };
    try testing.expect(expl.update(0.1));
    try testing.expectApproxEqAbs(@as(f32, 0.1), expl.elapsed, 0.001);
}

test "Explosion.update returns false when expired" {
    var expl = Explosion{
        .position = Vec3.zero,
        .size = .medium,
        .elapsed = 0.9,
        .duration = 1.0,
        .num_frames = 10,
        .radius = 50.0,
    };
    try testing.expect(!expl.update(0.2));
}

// --- DebrisParticle ---

test "DebrisParticle.update moves particle" {
    var p = DebrisParticle{
        .position = Vec3.zero,
        .velocity = .{ .x = 100, .y = 0, .z = 0 },
        .elapsed = 0,
        .lifetime = 3.0,
        .rotation = 0,
        .spin_rate = 1.0,
    };
    try testing.expect(p.update(1.0));
    try testing.expectApproxEqAbs(@as(f32, 100), p.position.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), p.rotation, 0.01);
}

test "DebrisParticle.update returns false when expired" {
    var p = DebrisParticle{
        .position = Vec3.zero,
        .velocity = .{ .x = 10, .y = 0, .z = 0 },
        .elapsed = 2.9,
        .lifetime = 3.0,
        .rotation = 0,
        .spin_rate = 1.0,
    };
    try testing.expect(!p.update(0.2));
}

test "DebrisParticle.remainingFraction at start" {
    const p = DebrisParticle{
        .position = Vec3.zero,
        .velocity = Vec3.zero,
        .elapsed = 0,
        .lifetime = 3.0,
        .rotation = 0,
        .spin_rate = 0,
    };
    try testing.expectApproxEqAbs(@as(f32, 1.0), p.remainingFraction(), 0.01);
}

test "DebrisParticle.remainingFraction at midpoint" {
    const p = DebrisParticle{
        .position = Vec3.zero,
        .velocity = Vec3.zero,
        .elapsed = 1.5,
        .lifetime = 3.0,
        .rotation = 0,
        .spin_rate = 0,
    };
    try testing.expectApproxEqAbs(@as(f32, 0.5), p.remainingFraction(), 0.01);
}

// --- ExplosionSystem ---

test "ExplosionSystem.init creates empty system" {
    const sys = ExplosionSystem.init();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "ExplosionSystem.spawn adds explosion" {
    var sys = ExplosionSystem.init();
    try testing.expect(sys.spawn(Vec3.zero, .medium));
    try testing.expectEqual(@as(usize, 1), sys.count());
}

test "ExplosionSystem.spawn multiple explosions" {
    var sys = ExplosionSystem.init();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(sys.spawn(.{ .x = @floatFromInt(i), .y = 0, .z = 0 }, .small));
    }
    try testing.expectEqual(@as(usize, 5), sys.count());
}

test "ExplosionSystem.spawn returns false when pool full" {
    var sys = ExplosionSystem.init();
    var i: usize = 0;
    while (i < MAX_EXPLOSIONS) : (i += 1) {
        try testing.expect(sys.spawn(Vec3.zero, .small));
    }
    try testing.expect(!sys.spawn(Vec3.zero, .small));
}

test "ExplosionSystem.update removes expired explosions" {
    var sys = ExplosionSystem.init();
    // Small explosion: 0.6s duration
    try testing.expect(sys.spawn(Vec3.zero, .small));
    try testing.expectEqual(@as(usize, 1), sys.count());

    sys.update(1.0); // Past duration
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "ExplosionSystem.update keeps active explosions" {
    var sys = ExplosionSystem.init();
    // Big explosion: 1.5s duration
    try testing.expect(sys.spawn(Vec3.zero, .big));

    sys.update(0.5);
    try testing.expectEqual(@as(usize, 1), sys.count());
}

test "ship destruction plays explosion animation" {
    var sys = ExplosionSystem.init();
    // Simulate ship destruction
    const destroy_pos = Vec3{ .x = 100, .y = 200, .z = 300 };
    try testing.expect(sys.spawn(destroy_pos, .medium));

    // Verify explosion is at correct position with animation frames
    var buf: [1]Explosion = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expectEqual(@as(f32, 100), active[0].position.x);
    try testing.expectEqual(@as(f32, 200), active[0].position.y);
    try testing.expectEqual(@as(f32, 300), active[0].position.z);
    try testing.expectEqual(@as(u16, 0), active[0].currentFrame());

    // Advance time - frame should progress
    sys.update(0.5);
    const active2 = sys.getActive(&buf);
    try testing.expect(active2[0].currentFrame() > 0);
}

test "ExplosionSystem.clear removes all explosions" {
    var sys = ExplosionSystem.init();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = sys.spawn(Vec3.zero, .small);
    }
    try testing.expectEqual(@as(usize, 10), sys.count());
    sys.clear();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "expired explosion slot is reused by new spawn" {
    var sys = ExplosionSystem.init();
    // Fill all slots with short-lived explosions
    var i: usize = 0;
    while (i < MAX_EXPLOSIONS) : (i += 1) {
        _ = sys.spawnWithType(Vec3.zero, .{
            .size = .small,
            .name = .{ 'T', 'E', 'S', 'T', 0, 0, 0, 0 },
            .duration = 0.1,
            .num_frames = 2,
            .radius = 10.0,
            .spawns_debris = false,
            .num_debris = 0,
        });
    }
    try testing.expectEqual(@as(usize, MAX_EXPLOSIONS), sys.count());

    // Expire all
    sys.update(1.0);
    try testing.expectEqual(@as(usize, 0), sys.count());

    // Should be able to spawn again
    try testing.expect(sys.spawn(Vec3.zero, .big));
    try testing.expectEqual(@as(usize, 1), sys.count());
}

test "ExplosionSystem.getActive fills buffer" {
    var sys = ExplosionSystem.init();
    _ = sys.spawn(.{ .x = 10, .y = 0, .z = 0 }, .big);
    _ = sys.spawn(.{ .x = 20, .y = 0, .z = 0 }, .medium);
    _ = sys.spawn(.{ .x = 30, .y = 0, .z = 0 }, .small);

    var buf: [10]Explosion = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 3), active.len);
    try testing.expectEqual(@as(f32, 10), active[0].position.x);
    try testing.expectEqual(@as(f32, 20), active[1].position.x);
    try testing.expectEqual(@as(f32, 30), active[2].position.x);
}

test "ExplosionSystem.getActive respects buffer size" {
    var sys = ExplosionSystem.init();
    _ = sys.spawn(Vec3.zero, .big);
    _ = sys.spawn(Vec3.zero, .medium);
    _ = sys.spawn(Vec3.zero, .small);

    var small_buf: [2]Explosion = undefined;
    const active = sys.getActive(&small_buf);
    try testing.expectEqual(@as(usize, 2), active.len);
}

// --- DebrisSystem ---

test "DebrisSystem.init creates empty system" {
    const sys = DebrisSystem.init();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "DebrisSystem.spawn adds particle" {
    var sys = DebrisSystem.init();
    const p = DebrisParticle{
        .position = Vec3.zero,
        .velocity = .{ .x = 50, .y = 0, .z = 0 },
        .elapsed = 0,
        .lifetime = 3.0,
        .rotation = 0,
        .spin_rate = 1.0,
    };
    try testing.expect(sys.spawn(p));
    try testing.expectEqual(@as(usize, 1), sys.count());
}

test "DebrisSystem.update removes expired particles" {
    var sys = DebrisSystem.init();
    const p = DebrisParticle{
        .position = Vec3.zero,
        .velocity = .{ .x = 10, .y = 0, .z = 0 },
        .elapsed = 0,
        .lifetime = 0.5,
        .rotation = 0,
        .spin_rate = 1.0,
    };
    _ = sys.spawn(p);
    try testing.expectEqual(@as(usize, 1), sys.count());

    sys.update(1.0);
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "DebrisSystem.update moves particles" {
    var sys = DebrisSystem.init();
    const p = DebrisParticle{
        .position = Vec3.zero,
        .velocity = .{ .x = 100, .y = 0, .z = 0 },
        .elapsed = 0,
        .lifetime = 5.0,
        .rotation = 0,
        .spin_rate = 0,
    };
    _ = sys.spawn(p);

    sys.update(1.0);

    var buf: [1]DebrisParticle = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expectApproxEqAbs(@as(f32, 100), active[0].position.x, 0.01);
}

test "DebrisSystem.spawnBurst creates multiple particles" {
    var sys = DebrisSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    const spawned = sys.spawnBurst(Vec3.zero, 8, default_debris_type, &rng);
    try testing.expectEqual(@as(u8, 8), spawned);
    try testing.expectEqual(@as(usize, 8), sys.count());
}

test "DebrisSystem.spawnBurst particles have varied velocities" {
    var sys = DebrisSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    _ = sys.spawnBurst(Vec3.zero, 4, default_debris_type, &rng);

    var buf: [4]DebrisParticle = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 4), active.len);

    // Check that velocities are different (not all identical)
    const v0 = active[0].velocity;
    var any_different = false;
    for (active[1..]) |p| {
        if (@abs(p.velocity.x - v0.x) > 0.1 or
            @abs(p.velocity.y - v0.y) > 0.1 or
            @abs(p.velocity.z - v0.z) > 0.1)
        {
            any_different = true;
            break;
        }
    }
    try testing.expect(any_different);
}

test "DebrisSystem.clear removes all particles" {
    var sys = DebrisSystem.init();
    var rng = std.Random.Xoshiro256.init(42);
    _ = sys.spawnBurst(Vec3.zero, 10, default_debris_type, &rng);
    try testing.expectEqual(@as(usize, 10), sys.count());

    sys.clear();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

// --- Destruction helper ---

test "spawnDestructionEffect creates explosion and debris" {
    var expl_sys = ExplosionSystem.init();
    var debris_sys = DebrisSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    const pos = Vec3{ .x = 500, .y = 100, .z = 300 };
    try testing.expect(spawnDestructionEffect(&expl_sys, &debris_sys, pos, .medium, &rng));

    // Should have 1 explosion
    try testing.expectEqual(@as(usize, 1), expl_sys.count());

    // Medium explosion spawns 8 debris particles
    try testing.expectEqual(@as(usize, 8), debris_sys.count());
}

test "spawnDestructionEffect with big explosion spawns more debris" {
    var expl_sys = ExplosionSystem.init();
    var debris_sys = DebrisSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    _ = spawnDestructionEffect(&expl_sys, &debris_sys, Vec3.zero, .big, &rng);

    try testing.expectEqual(@as(usize, 1), expl_sys.count());
    try testing.expectEqual(@as(usize, 12), debris_sys.count());
}

test "spawnDestructionEffect returns false when explosion pool full" {
    var expl_sys = ExplosionSystem.init();
    var debris_sys = DebrisSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    // Fill explosion pool
    var i: usize = 0;
    while (i < MAX_EXPLOSIONS) : (i += 1) {
        _ = expl_sys.spawn(Vec3.zero, .small);
    }

    try testing.expect(!spawnDestructionEffect(&expl_sys, &debris_sys, Vec3.zero, .medium, &rng));
    // No debris should be spawned either since explosion failed
    try testing.expectEqual(@as(usize, 0), debris_sys.count());
}

// --- IFF Parsing ---

test "parseExplosionTypes loads 4 types from fixture" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_expltype.bin");
    defer allocator.free(data);

    const types = try parseExplosionTypes(allocator, data);
    defer allocator.free(types);

    try testing.expectEqual(@as(usize, 4), types.len);
}

test "parseExplosionTypes BIGEXPL has correct stats" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_expltype.bin");
    defer allocator.free(data);

    const types = try parseExplosionTypes(allocator, data);
    defer allocator.free(types);

    const big = types[0];
    try testing.expectEqual(ExplosionSize.big, big.size);
    try testing.expectEqualStrings("BIGEXPL", big.name[0..7]);
    try testing.expectApproxEqAbs(@as(f32, 1.5), big.duration, 0.01);
    try testing.expectEqual(@as(u16, 15), big.num_frames);
    try testing.expectApproxEqAbs(@as(f32, 80.0), big.radius, 0.01);
    try testing.expect(big.spawns_debris);
    try testing.expectEqual(@as(u8, 12), big.num_debris);
}

test "parseExplosionTypes DETHEXPL is largest" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_expltype.bin");
    defer allocator.free(data);

    const types = try parseExplosionTypes(allocator, data);
    defer allocator.free(types);

    const death = types[3];
    try testing.expectEqual(ExplosionSize.death, death.size);
    try testing.expectApproxEqAbs(@as(f32, 2.0), death.duration, 0.01);
    try testing.expectEqual(@as(u16, 20), death.num_frames);
    try testing.expectApproxEqAbs(@as(f32, 100.0), death.radius, 0.01);
}

test "parseExplosionTypes rejects non-EXPL form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try testing.expectError(ExplosionDataError.InvalidFormat, parseExplosionTypes(testing.allocator, data));
}

test "parseDebrisTypes loads 3 types from fixture" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_trshtype.bin");
    defer allocator.free(data);

    const types = try parseDebrisTypes(allocator, data);
    defer allocator.free(types);

    try testing.expectEqual(@as(usize, 3), types.len);
}

test "parseDebrisTypes CDBRTYPE has correct stats" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_trshtype.bin");
    defer allocator.free(data);

    const types = try parseDebrisTypes(allocator, data);
    defer allocator.free(types);

    const cdbr = types[0];
    try testing.expectEqual(@as(u8, 0), cdbr.id);
    try testing.expectEqualStrings("CDBRTYPE", &cdbr.name);
    try testing.expectApproxEqAbs(@as(f32, 20.0), cdbr.speed_min, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 80.0), cdbr.speed_max, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 3.0), cdbr.lifetime, 0.01);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), cdbr.spin_rate, 0.01);
}

test "parseDebrisTypes rejects non-TRSH form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try testing.expectError(ExplosionDataError.InvalidFormat, parseDebrisTypes(testing.allocator, data));
}
