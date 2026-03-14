//! Tractor beam and floating cargo system for Wing Commander: Privateer.
//!
//! Manages floating cargo items in space (spawned when ships are destroyed)
//! and the tractor beam that pulls them toward the player's ship for collection.
//!
//! Data flow:
//!   1. Ship destroyed → floating cargo spawns at destruction site
//!   2. Player activates tractor beam → beam pulls nearby cargo toward ship
//!   3. Cargo enters pickup radius → item added to cargo hold
//!
//! Cargo items drift slowly with randomized velocities and spin,
//! similar to debris particles but with longer lifetimes.

const std = @import("std");
const flight_physics = @import("../flight/flight_physics.zig");

const Vec3 = flight_physics.Vec3;

// ── Cargo Types ─────────────────────────────────────────────────────

/// A commodity type that can float in space and be collected.
pub const CommodityId = u8;

/// A single floating cargo item in the game world.
pub const FloatingCargo = struct {
    /// World-space position.
    position: Vec3,
    /// Velocity vector (slow drift from explosion).
    velocity: Vec3,
    /// Commodity type identifier.
    commodity_id: CommodityId,
    /// Quantity of this commodity (usually 1).
    quantity: u8,
    /// Time elapsed since spawn (seconds).
    elapsed: f32,
    /// Total lifetime before despawning (seconds).
    lifetime: f32,
    /// Current rotation angle (radians, for visual spin).
    rotation: f32,
    /// Spin rate (radians per second).
    spin_rate: f32,

    /// Update the cargo item for one frame. Returns true if still alive.
    pub fn update(self: *FloatingCargo, dt: f32) bool {
        self.position = self.position.add(self.velocity.scale(dt));
        self.rotation += self.spin_rate * dt;
        self.elapsed += dt;
        return self.elapsed < self.lifetime;
    }

    /// Get remaining lifetime fraction (1.0 = just spawned, 0.0 = expired).
    pub fn remainingFraction(self: *const FloatingCargo) f32 {
        if (self.lifetime <= 0) return 0;
        return @max(0, 1.0 - self.elapsed / self.lifetime);
    }
};

// ── Floating Cargo System ───────────────────────────────────────────

/// Maximum number of concurrent floating cargo items.
const MAX_FLOATING_CARGO = 64;

/// Default lifetime for floating cargo (seconds).
pub const DEFAULT_CARGO_LIFETIME: f32 = 30.0;

/// Default drift speed range for spawned cargo.
pub const DEFAULT_CARGO_DRIFT_MIN: f32 = 5.0;
pub const DEFAULT_CARGO_DRIFT_MAX: f32 = 20.0;

/// Default spin rate for floating cargo (radians per second).
pub const DEFAULT_CARGO_SPIN_RATE: f32 = 0.5;

/// Manages all floating cargo items in the game world.
pub const FloatingCargoSystem = struct {
    /// Active cargo pool (fixed-size array, null = empty slot).
    items: [MAX_FLOATING_CARGO]?FloatingCargo,
    /// Number of currently active items.
    active_count: usize,

    /// Create a new empty floating cargo system.
    pub fn init() FloatingCargoSystem {
        return .{
            .items = [_]?FloatingCargo{null} ** MAX_FLOATING_CARGO,
            .active_count = 0,
        };
    }

    /// Spawn a single floating cargo item. Returns true if spawned.
    pub fn spawn(self: *FloatingCargoSystem, item: FloatingCargo) bool {
        for (&self.items) |*slot| {
            if (slot.* == null) {
                slot.* = item;
                self.active_count += 1;
                return true;
            }
        }
        return false;
    }

    /// Spawn a burst of cargo items at a position (e.g. from ship destruction).
    /// Returns the number of items actually spawned.
    pub fn spawnBurst(
        self: *FloatingCargoSystem,
        position: Vec3,
        commodity_id: CommodityId,
        count_requested: u8,
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

            // Random drift speed
            const drift_speed = DEFAULT_CARGO_DRIFT_MIN +
                random.float(f32) * (DEFAULT_CARGO_DRIFT_MAX - DEFAULT_CARGO_DRIFT_MIN);

            // Random lifetime variation (+/- 20%)
            const lifetime_var = 0.8 + random.float(f32) * 0.4;

            // Random spin direction
            const spin_dir: f32 = if (random.boolean()) 1.0 else -1.0;

            const item = FloatingCargo{
                .position = position,
                .velocity = dir.scale(drift_speed),
                .commodity_id = commodity_id,
                .quantity = 1,
                .elapsed = 0,
                .lifetime = DEFAULT_CARGO_LIFETIME * lifetime_var,
                .rotation = random.float(f32) * 2.0 * std.math.pi,
                .spin_rate = DEFAULT_CARGO_SPIN_RATE * spin_dir,
            };

            if (self.spawn(item)) {
                spawned += 1;
            } else {
                break; // Pool full
            }
        }
        return spawned;
    }

    /// Update all floating cargo items for one frame. Removes expired items.
    pub fn update(self: *FloatingCargoSystem, dt: f32) void {
        for (&self.items) |*slot| {
            if (slot.*) |*item| {
                if (!item.update(dt)) {
                    slot.* = null;
                    self.active_count -= 1;
                }
            }
        }
    }

    /// Get the number of active floating cargo items.
    pub fn count(self: *const FloatingCargoSystem) usize {
        return self.active_count;
    }

    /// Clear all active cargo items.
    pub fn clear(self: *FloatingCargoSystem) void {
        for (&self.items) |*slot| {
            slot.* = null;
        }
        self.active_count = 0;
    }

    /// Get a slice view of active cargo items (for rendering).
    /// Caller must provide a buffer to collect results.
    pub fn getActive(self: *const FloatingCargoSystem, buf: []FloatingCargo) []FloatingCargo {
        var n: usize = 0;
        for (self.items) |slot| {
            if (slot) |item| {
                if (n >= buf.len) break;
                buf[n] = item;
                n += 1;
            }
        }
        return buf[0..n];
    }
};

// ── Tractor Beam ────────────────────────────────────────────────────

/// Tractor beam range in world units.
pub const TRACTOR_RANGE: f32 = 500.0;

/// Tractor beam pull acceleration (units per second squared).
pub const TRACTOR_PULL_STRENGTH: f32 = 120.0;

/// Distance at which cargo is automatically collected (world units).
pub const PICKUP_RADIUS: f32 = 15.0;

/// Tractor beam state for a ship.
pub const TractorBeam = struct {
    /// Whether the tractor beam is currently active.
    active: bool,
    /// Whether the ship has a tractor beam installed.
    installed: bool,

    /// Create a new tractor beam (not installed by default).
    pub fn init() TractorBeam {
        return .{
            .active = false,
            .installed = false,
        };
    }

    /// Create a new installed tractor beam.
    pub fn initInstalled() TractorBeam {
        return .{
            .active = false,
            .installed = true,
        };
    }

    /// Toggle tractor beam on/off. Only works if installed.
    pub fn toggle(self: *TractorBeam) void {
        if (self.installed) {
            self.active = !self.active;
        }
    }

    /// Apply tractor beam pull to all cargo items within range.
    /// Pulls items toward ship_position. Returns number of items being pulled.
    pub fn applyPull(
        self: *const TractorBeam,
        ship_position: Vec3,
        cargo_sys: *FloatingCargoSystem,
        dt: f32,
    ) usize {
        if (!self.active or !self.installed) return 0;

        var pulled: usize = 0;
        for (&cargo_sys.items) |*slot| {
            if (slot.*) |*item| {
                const to_ship = ship_position.sub(item.position);
                const dist = to_ship.length();

                if (dist > 0.001 and dist <= TRACTOR_RANGE) {
                    // Pull toward ship with acceleration inversely proportional to distance
                    const dir = to_ship.normalize();
                    const pull = dir.scale(TRACTOR_PULL_STRENGTH * dt);
                    item.velocity = item.velocity.add(pull);
                    pulled += 1;
                }
            }
        }
        return pulled;
    }

    /// Check for cargo items within pickup radius and collect them.
    /// Returns collected items via the provided buffer.
    pub fn collectCargo(
        self: *const TractorBeam,
        ship_position: Vec3,
        cargo_sys: *FloatingCargoSystem,
        collected_buf: []CollectedItem,
    ) []CollectedItem {
        // Collection works whether beam is active or not (proximity-based)
        _ = self;
        var n: usize = 0;
        for (&cargo_sys.items) |*slot| {
            if (slot.*) |item| {
                const dist = ship_position.sub(item.position).length();
                if (dist <= PICKUP_RADIUS) {
                    if (n < collected_buf.len) {
                        collected_buf[n] = .{
                            .commodity_id = item.commodity_id,
                            .quantity = item.quantity,
                        };
                        n += 1;
                    }
                    slot.* = null;
                    cargo_sys.active_count -= 1;
                }
            }
        }
        return collected_buf[0..n];
    }
};

/// Result of collecting a floating cargo item.
pub const CollectedItem = struct {
    commodity_id: CommodityId,
    quantity: u8,
};

// ── Cargo Hold ──────────────────────────────────────────────────────

/// Maximum number of distinct commodity types in a cargo hold.
const MAX_CARGO_TYPES = 32;

/// A single cargo hold entry (commodity type + quantity).
pub const CargoEntry = struct {
    commodity_id: CommodityId,
    quantity: u16,
};

/// Ship cargo hold for storing collected commodities.
pub const CargoHold = struct {
    /// Stored cargo entries.
    entries: [MAX_CARGO_TYPES]?CargoEntry,
    /// Maximum cargo capacity in units.
    capacity: u16,
    /// Current total units stored.
    used: u16,

    /// Create a new empty cargo hold with the given capacity.
    pub fn init(capacity: u16) CargoHold {
        return .{
            .entries = [_]?CargoEntry{null} ** MAX_CARGO_TYPES,
            .capacity = capacity,
            .used = 0,
        };
    }

    /// Add cargo to the hold. Returns true if added, false if full.
    pub fn addCargo(self: *CargoHold, commodity_id: CommodityId, quantity: u16) bool {
        if (self.used + quantity > self.capacity) return false;

        // Try to stack with existing entry
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.commodity_id == commodity_id) {
                    entry.quantity += quantity;
                    self.used += quantity;
                    return true;
                }
            }
        }

        // Find empty slot
        for (&self.entries) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .commodity_id = commodity_id,
                    .quantity = quantity,
                };
                self.used += quantity;
                return true;
            }
        }

        return false; // No empty slots
    }

    /// Remove cargo from the hold. Returns true if removed, false if insufficient.
    pub fn removeCargo(self: *CargoHold, commodity_id: CommodityId, quantity: u16) bool {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.commodity_id == commodity_id) {
                    if (entry.quantity < quantity) return false;
                    entry.quantity -= quantity;
                    self.used -= quantity;
                    if (entry.quantity == 0) {
                        slot.* = null;
                    }
                    return true;
                }
            }
        }
        return false;
    }

    /// Get the quantity of a specific commodity in the hold.
    pub fn getQuantity(self: *const CargoHold, commodity_id: CommodityId) u16 {
        for (self.entries) |slot| {
            if (slot) |entry| {
                if (entry.commodity_id == commodity_id) return entry.quantity;
            }
        }
        return 0;
    }

    /// Get the number of distinct commodity types stored.
    pub fn typeCount(self: *const CargoHold) usize {
        var n: usize = 0;
        for (self.entries) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    /// Get remaining free capacity.
    pub fn freeSpace(self: *const CargoHold) u16 {
        return self.capacity - self.used;
    }

    /// Check if the hold is full.
    pub fn isFull(self: *const CargoHold) bool {
        return self.used >= self.capacity;
    }

    /// Clear all cargo from the hold.
    pub fn clear(self: *CargoHold) void {
        for (&self.entries) |*slot| {
            slot.* = null;
        }
        self.used = 0;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// --- FloatingCargo ---

test "FloatingCargo.update moves cargo" {
    var cargo = FloatingCargo{
        .position = Vec3.zero,
        .velocity = .{ .x = 10, .y = 0, .z = 0 },
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 1.0,
    };
    try testing.expect(cargo.update(1.0));
    try testing.expectApproxEqAbs(@as(f32, 10), cargo.position.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), cargo.rotation, 0.01);
}

test "FloatingCargo.update returns false when expired" {
    var cargo = FloatingCargo{
        .position = Vec3.zero,
        .velocity = .{ .x = 10, .y = 0, .z = 0 },
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 29.5,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 1.0,
    };
    try testing.expect(!cargo.update(1.0));
}

test "FloatingCargo.remainingFraction at start" {
    const cargo = FloatingCargo{
        .position = Vec3.zero,
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    };
    try testing.expectApproxEqAbs(@as(f32, 1.0), cargo.remainingFraction(), 0.01);
}

test "FloatingCargo.remainingFraction at midpoint" {
    const cargo = FloatingCargo{
        .position = Vec3.zero,
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 15.0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    };
    try testing.expectApproxEqAbs(@as(f32, 0.5), cargo.remainingFraction(), 0.01);
}

// --- FloatingCargoSystem ---

test "FloatingCargoSystem.init creates empty system" {
    const sys = FloatingCargoSystem.init();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "FloatingCargoSystem.spawn adds cargo item" {
    var sys = FloatingCargoSystem.init();
    const item = FloatingCargo{
        .position = Vec3.zero,
        .velocity = .{ .x = 10, .y = 0, .z = 0 },
        .commodity_id = 5,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0.5,
    };
    try testing.expect(sys.spawn(item));
    try testing.expectEqual(@as(usize, 1), sys.count());
}

test "FloatingCargoSystem.spawn returns false when pool full" {
    var sys = FloatingCargoSystem.init();
    var i: usize = 0;
    while (i < MAX_FLOATING_CARGO) : (i += 1) {
        try testing.expect(sys.spawn(.{
            .position = Vec3.zero,
            .velocity = Vec3.zero,
            .commodity_id = 1,
            .quantity = 1,
            .elapsed = 0,
            .lifetime = 30.0,
            .rotation = 0,
            .spin_rate = 0,
        }));
    }
    try testing.expect(!sys.spawn(.{
        .position = Vec3.zero,
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    }));
}

test "FloatingCargoSystem.update removes expired items" {
    var sys = FloatingCargoSystem.init();
    _ = sys.spawn(.{
        .position = Vec3.zero,
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 0.5,
        .rotation = 0,
        .spin_rate = 0,
    });
    try testing.expectEqual(@as(usize, 1), sys.count());
    sys.update(1.0);
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "FloatingCargoSystem.update moves cargo items" {
    var sys = FloatingCargoSystem.init();
    _ = sys.spawn(.{
        .position = Vec3.zero,
        .velocity = .{ .x = 100, .y = 0, .z = 0 },
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    sys.update(1.0);

    var buf: [1]FloatingCargo = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expectApproxEqAbs(@as(f32, 100), active[0].position.x, 0.01);
}

test "FloatingCargoSystem.spawnBurst creates multiple items" {
    var sys = FloatingCargoSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    const spawned = sys.spawnBurst(Vec3.zero, 3, 5, &rng);
    try testing.expectEqual(@as(u8, 5), spawned);
    try testing.expectEqual(@as(usize, 5), sys.count());
}

test "FloatingCargoSystem.spawnBurst items have varied velocities" {
    var sys = FloatingCargoSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    _ = sys.spawnBurst(Vec3.zero, 1, 4, &rng);

    var buf: [4]FloatingCargo = undefined;
    const active = sys.getActive(&buf);
    try testing.expectEqual(@as(usize, 4), active.len);

    // Check that velocities differ
    const v0 = active[0].velocity;
    var any_different = false;
    for (active[1..]) |item| {
        if (@abs(item.velocity.x - v0.x) > 0.1 or
            @abs(item.velocity.y - v0.y) > 0.1 or
            @abs(item.velocity.z - v0.z) > 0.1)
        {
            any_different = true;
            break;
        }
    }
    try testing.expect(any_different);
}

test "FloatingCargoSystem.spawnBurst items have correct commodity" {
    var sys = FloatingCargoSystem.init();
    var rng = std.Random.Xoshiro256.init(42);

    _ = sys.spawnBurst(Vec3.zero, 7, 3, &rng);

    var buf: [3]FloatingCargo = undefined;
    const active = sys.getActive(&buf);
    for (active) |item| {
        try testing.expectEqual(@as(CommodityId, 7), item.commodity_id);
        try testing.expectEqual(@as(u8, 1), item.quantity);
    }
}

test "FloatingCargoSystem.clear removes all items" {
    var sys = FloatingCargoSystem.init();
    var rng = std.Random.Xoshiro256.init(42);
    _ = sys.spawnBurst(Vec3.zero, 1, 10, &rng);
    try testing.expectEqual(@as(usize, 10), sys.count());

    sys.clear();
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "expired cargo slot is reused by new spawn" {
    var sys = FloatingCargoSystem.init();
    // Fill all slots with short-lived cargo
    var i: usize = 0;
    while (i < MAX_FLOATING_CARGO) : (i += 1) {
        _ = sys.spawn(.{
            .position = Vec3.zero,
            .velocity = Vec3.zero,
            .commodity_id = 1,
            .quantity = 1,
            .elapsed = 0,
            .lifetime = 0.1,
            .rotation = 0,
            .spin_rate = 0,
        });
    }
    try testing.expectEqual(@as(usize, MAX_FLOATING_CARGO), sys.count());

    // Expire all
    sys.update(1.0);
    try testing.expectEqual(@as(usize, 0), sys.count());

    // Should be able to spawn again
    try testing.expect(sys.spawn(.{
        .position = Vec3.zero,
        .velocity = Vec3.zero,
        .commodity_id = 2,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    }));
    try testing.expectEqual(@as(usize, 1), sys.count());
}

// --- TractorBeam ---

test "TractorBeam.init creates inactive uninstalled beam" {
    const beam = TractorBeam.init();
    try testing.expect(!beam.active);
    try testing.expect(!beam.installed);
}

test "TractorBeam.initInstalled creates inactive installed beam" {
    const beam = TractorBeam.initInstalled();
    try testing.expect(!beam.active);
    try testing.expect(beam.installed);
}

test "TractorBeam.toggle activates when installed" {
    var beam = TractorBeam.initInstalled();
    beam.toggle();
    try testing.expect(beam.active);
    beam.toggle();
    try testing.expect(!beam.active);
}

test "TractorBeam.toggle does nothing when not installed" {
    var beam = TractorBeam.init();
    beam.toggle();
    try testing.expect(!beam.active);
}

test "tractor beam pulls cargo toward ship" {
    var beam = TractorBeam.initInstalled();
    beam.active = true;

    var sys = FloatingCargoSystem.init();
    // Place cargo at (100, 0, 0), ship at origin
    _ = sys.spawn(.{
        .position = .{ .x = 100, .y = 0, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    const ship_pos = Vec3.zero;
    const pulled = beam.applyPull(ship_pos, &sys, 1.0);
    try testing.expectEqual(@as(usize, 1), pulled);

    // Cargo velocity should now have negative X (moving toward origin)
    var buf: [1]FloatingCargo = undefined;
    const active = sys.getActive(&buf);
    try testing.expect(active[0].velocity.x < 0);
}

test "tractor beam does not pull cargo beyond range" {
    var beam = TractorBeam.initInstalled();
    beam.active = true;

    var sys = FloatingCargoSystem.init();
    // Place cargo beyond tractor range
    _ = sys.spawn(.{
        .position = .{ .x = TRACTOR_RANGE + 100, .y = 0, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    const pulled = beam.applyPull(Vec3.zero, &sys, 1.0);
    try testing.expectEqual(@as(usize, 0), pulled);

    // Velocity unchanged
    var buf: [1]FloatingCargo = undefined;
    const active = sys.getActive(&buf);
    try testing.expectApproxEqAbs(@as(f32, 0), active[0].velocity.x, 0.01);
}

test "inactive tractor beam does not pull cargo" {
    var beam = TractorBeam.initInstalled();
    // beam.active is false

    var sys = FloatingCargoSystem.init();
    _ = sys.spawn(.{
        .position = .{ .x = 100, .y = 0, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    const pulled = beam.applyPull(Vec3.zero, &sys, 1.0);
    try testing.expectEqual(@as(usize, 0), pulled);
}

test "uninstalled tractor beam does not pull cargo" {
    var beam = TractorBeam.init();
    beam.active = true; // Force active but not installed

    var sys = FloatingCargoSystem.init();
    _ = sys.spawn(.{
        .position = .{ .x = 100, .y = 0, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    const pulled = beam.applyPull(Vec3.zero, &sys, 1.0);
    try testing.expectEqual(@as(usize, 0), pulled);
}

test "tractor beam pulls multiple cargo items" {
    var beam = TractorBeam.initInstalled();
    beam.active = true;

    var sys = FloatingCargoSystem.init();
    // Spawn 3 cargo items at different positions within range
    _ = sys.spawn(.{
        .position = .{ .x = 100, .y = 0, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });
    _ = sys.spawn(.{
        .position = .{ .x = 0, .y = 200, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 2,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });
    _ = sys.spawn(.{
        .position = .{ .x = 0, .y = 0, .z = 300 },
        .velocity = Vec3.zero,
        .commodity_id = 3,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    const pulled = beam.applyPull(Vec3.zero, &sys, 1.0);
    try testing.expectEqual(@as(usize, 3), pulled);
}

// --- Cargo collection ---

test "cargo collection adds to cargo hold" {
    const beam = TractorBeam.initInstalled();

    var sys = FloatingCargoSystem.init();
    // Place cargo within pickup radius
    _ = sys.spawn(.{
        .position = .{ .x = 5, .y = 0, .z = 0 }, // Within PICKUP_RADIUS
        .velocity = Vec3.zero,
        .commodity_id = 3,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    var collected_buf: [8]CollectedItem = undefined;
    const collected = beam.collectCargo(Vec3.zero, &sys, &collected_buf);

    try testing.expectEqual(@as(usize, 1), collected.len);
    try testing.expectEqual(@as(CommodityId, 3), collected[0].commodity_id);
    try testing.expectEqual(@as(u8, 1), collected[0].quantity);
    // Cargo removed from system
    try testing.expectEqual(@as(usize, 0), sys.count());
}

test "cargo outside pickup radius not collected" {
    const beam = TractorBeam.initInstalled();

    var sys = FloatingCargoSystem.init();
    _ = sys.spawn(.{
        .position = .{ .x = PICKUP_RADIUS + 10, .y = 0, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    var collected_buf: [8]CollectedItem = undefined;
    const collected = beam.collectCargo(Vec3.zero, &sys, &collected_buf);

    try testing.expectEqual(@as(usize, 0), collected.len);
    try testing.expectEqual(@as(usize, 1), sys.count()); // Still floating
}

test "multiple cargo items collected at once" {
    const beam = TractorBeam.initInstalled();

    var sys = FloatingCargoSystem.init();
    _ = sys.spawn(.{
        .position = .{ .x = 5, .y = 0, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 1,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });
    _ = sys.spawn(.{
        .position = .{ .x = 0, .y = 3, .z = 0 },
        .velocity = Vec3.zero,
        .commodity_id = 2,
        .quantity = 1,
        .elapsed = 0,
        .lifetime = 30.0,
        .rotation = 0,
        .spin_rate = 0,
    });

    var collected_buf: [8]CollectedItem = undefined;
    const collected = beam.collectCargo(Vec3.zero, &sys, &collected_buf);

    try testing.expectEqual(@as(usize, 2), collected.len);
    try testing.expectEqual(@as(usize, 0), sys.count());
}

// --- CargoHold ---

test "CargoHold.init creates empty hold with capacity" {
    const hold = CargoHold.init(50);
    try testing.expectEqual(@as(u16, 50), hold.capacity);
    try testing.expectEqual(@as(u16, 0), hold.used);
    try testing.expectEqual(@as(u16, 50), hold.freeSpace());
    try testing.expect(!hold.isFull());
    try testing.expectEqual(@as(usize, 0), hold.typeCount());
}

test "CargoHold.addCargo adds commodity" {
    var hold = CargoHold.init(50);
    try testing.expect(hold.addCargo(1, 5));
    try testing.expectEqual(@as(u16, 5), hold.getQuantity(1));
    try testing.expectEqual(@as(u16, 5), hold.used);
    try testing.expectEqual(@as(u16, 45), hold.freeSpace());
    try testing.expectEqual(@as(usize, 1), hold.typeCount());
}

test "CargoHold.addCargo stacks same commodity" {
    var hold = CargoHold.init(50);
    try testing.expect(hold.addCargo(1, 5));
    try testing.expect(hold.addCargo(1, 3));
    try testing.expectEqual(@as(u16, 8), hold.getQuantity(1));
    try testing.expectEqual(@as(u16, 8), hold.used);
    try testing.expectEqual(@as(usize, 1), hold.typeCount());
}

test "CargoHold.addCargo different commodities" {
    var hold = CargoHold.init(50);
    try testing.expect(hold.addCargo(1, 5));
    try testing.expect(hold.addCargo(2, 10));
    try testing.expectEqual(@as(u16, 5), hold.getQuantity(1));
    try testing.expectEqual(@as(u16, 10), hold.getQuantity(2));
    try testing.expectEqual(@as(u16, 15), hold.used);
    try testing.expectEqual(@as(usize, 2), hold.typeCount());
}

test "CargoHold.addCargo returns false when full" {
    var hold = CargoHold.init(10);
    try testing.expect(hold.addCargo(1, 8));
    try testing.expect(!hold.addCargo(2, 5)); // Would exceed capacity
    try testing.expectEqual(@as(u16, 8), hold.used);
    try testing.expectEqual(@as(u16, 0), hold.getQuantity(2));
}

test "CargoHold.addCargo exact capacity" {
    var hold = CargoHold.init(10);
    try testing.expect(hold.addCargo(1, 10));
    try testing.expect(hold.isFull());
    try testing.expect(!hold.addCargo(2, 1));
}

test "CargoHold.removeCargo removes commodity" {
    var hold = CargoHold.init(50);
    _ = hold.addCargo(1, 10);
    try testing.expect(hold.removeCargo(1, 3));
    try testing.expectEqual(@as(u16, 7), hold.getQuantity(1));
    try testing.expectEqual(@as(u16, 7), hold.used);
}

test "CargoHold.removeCargo removes entry when quantity reaches zero" {
    var hold = CargoHold.init(50);
    _ = hold.addCargo(1, 5);
    try testing.expect(hold.removeCargo(1, 5));
    try testing.expectEqual(@as(u16, 0), hold.getQuantity(1));
    try testing.expectEqual(@as(usize, 0), hold.typeCount());
    try testing.expectEqual(@as(u16, 0), hold.used);
}

test "CargoHold.removeCargo returns false for insufficient quantity" {
    var hold = CargoHold.init(50);
    _ = hold.addCargo(1, 5);
    try testing.expect(!hold.removeCargo(1, 10));
    try testing.expectEqual(@as(u16, 5), hold.getQuantity(1)); // Unchanged
}

test "CargoHold.removeCargo returns false for nonexistent commodity" {
    var hold = CargoHold.init(50);
    try testing.expect(!hold.removeCargo(99, 1));
}

test "CargoHold.getQuantity returns 0 for absent commodity" {
    const hold = CargoHold.init(50);
    try testing.expectEqual(@as(u16, 0), hold.getQuantity(42));
}

test "CargoHold.clear empties the hold" {
    var hold = CargoHold.init(50);
    _ = hold.addCargo(1, 10);
    _ = hold.addCargo(2, 5);
    hold.clear();
    try testing.expectEqual(@as(u16, 0), hold.used);
    try testing.expectEqual(@as(usize, 0), hold.typeCount());
}

// --- Integration: tractor beam + cargo hold ---

test "full tractor beam cargo collection flow" {
    // 1. Spawn floating cargo from destroyed ship
    var cargo_sys = FloatingCargoSystem.init();
    var rng = std.Random.Xoshiro256.init(42);
    _ = cargo_sys.spawnBurst(.{ .x = 100, .y = 0, .z = 0 }, 5, 3, &rng);
    try testing.expectEqual(@as(usize, 3), cargo_sys.count());

    // 2. Activate tractor beam and pull cargo
    var beam = TractorBeam.initInstalled();
    beam.active = true;
    const ship_pos = Vec3.zero;

    // 3. Pull for several seconds, collecting each frame (like a real game loop)
    var hold = CargoHold.init(50);
    var t: u32 = 0;
    while (t < 300) : (t += 1) {
        _ = beam.applyPull(ship_pos, &cargo_sys, 0.016);
        cargo_sys.update(0.016);

        var collected_buf: [8]CollectedItem = undefined;
        const collected = beam.collectCargo(ship_pos, &cargo_sys, &collected_buf);
        for (collected) |item| {
            _ = hold.addCargo(item.commodity_id, @as(u16, item.quantity));
        }
    }

    // 4. Verify cargo was collected into the hold
    try testing.expect(hold.used > 0);
    try testing.expectEqual(@as(u16, 3), hold.getQuantity(5));
}
