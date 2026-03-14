//! NPC spawning system for Wing Commander: Privateer.
//!
//! Manages spawning and despawning of NPC ships based on sector data
//! and faction presence. Ships are drawn from a fixed-size pool and
//! assigned faction-appropriate AI, ship stats, and health.
//!
//! Spawn rules are based on system properties:
//!   - Systems with military bases → more Confed/Militia patrols
//!   - Systems with pirate bases → more pirates
//!   - Trade routes (agricultural/mining/refinery) → merchants
//!   - Frontier systems (no bases) → pirates, Kilrathi, Retro

const std = @import("std");
const flight_physics = @import("../flight/flight_physics.zig");
const damage_mod = @import("damage.zig");
const ai_mod = @import("ai.zig");
const radar_mod = @import("../cockpit/radar.zig");
const explosions_mod = @import("explosions.zig");

const Vec3 = flight_physics.Vec3;
const FlightState = flight_physics.FlightState;
const ShipStats = flight_physics.ShipStats;
const ShipHealth = damage_mod.ShipHealth;
const ShipHealthSpec = damage_mod.ShipHealthSpec;
const AiController = ai_mod.AiController;
const AiConstants = ai_mod.AiConstants;
const Faction = radar_mod.Faction;
const RadarContact = radar_mod.RadarContact;
const ExplosionSystem = explosions_mod.ExplosionSystem;
const DebrisSystem = explosions_mod.DebrisSystem;
const ExplosionSize = explosions_mod.ExplosionSize;

// ── Constants ──────────────────────────────────────────────────────

/// Maximum number of NPC ships active at once.
pub const MAX_NPCS: u32 = 32;

/// Distance beyond which NPCs are despawned.
pub const DESPAWN_RANGE: f32 = 5000.0;

/// Minimum distance from player for new spawns.
pub const SPAWN_MIN_RANGE: f32 = 2000.0;

/// Maximum distance from player for new spawns.
pub const SPAWN_MAX_RANGE: f32 = 4000.0;

// ── Spawn Faction ──────────────────────────────────────────────────

/// Specific faction types for spawning (more granular than radar Faction).
pub const SpawnFaction = enum {
    pirate,
    kilrathi,
    confed,
    militia,
    merchant,
    retro,

    /// Map to radar display faction for IFF coloring.
    pub fn toRadarFaction(self: SpawnFaction) Faction {
        return switch (self) {
            .pirate, .kilrathi, .retro => .hostile,
            .confed, .militia => .friendly,
            .merchant => .neutral,
        };
    }

    /// Get the AI behavior preset for this faction.
    pub fn aiConstants(self: SpawnFaction) AiConstants {
        return switch (self) {
            .pirate => ai_mod.ai_presets.pirate,
            .kilrathi => ai_mod.ai_presets.kilrathi,
            .confed => ai_mod.ai_presets.confed,
            .militia => ai_mod.ai_presets.militia,
            .merchant => ai_mod.ai_presets.merchant,
            .retro => ai_mod.ai_presets.retro,
        };
    }

    /// Get ship performance stats for this faction's typical ship.
    pub fn shipStats(self: SpawnFaction) ShipStats {
        return switch (self) {
            .pirate => flight_physics.ship_stats.centurion,
            .kilrathi => flight_physics.ship_stats.centurion,
            .confed => flight_physics.ship_stats.centurion,
            .militia => flight_physics.ship_stats.orion,
            .merchant => flight_physics.ship_stats.galaxy,
            .retro => flight_physics.ship_stats.tarsus,
        };
    }

    /// Get health spec for this faction's typical ship.
    pub fn healthSpec(self: SpawnFaction) ShipHealthSpec {
        return switch (self) {
            .pirate => damage_mod.ship_health_specs.centurion,
            .kilrathi => damage_mod.ship_health_specs.centurion,
            .confed => damage_mod.ship_health_specs.centurion,
            .militia => damage_mod.ship_health_specs.orion,
            .merchant => damage_mod.ship_health_specs.galaxy,
            .retro => damage_mod.ship_health_specs.tarsus,
        };
    }
};

// ── NPC Ship ───────────────────────────────────────────────────────

/// A single NPC ship combining all required subsystems.
pub const NpcShip = struct {
    /// Whether this slot is currently in use.
    active: bool,
    /// Flight physics state.
    flight: FlightState,
    /// Health (shields + armor).
    health: ShipHealth,
    /// AI controller.
    ai: AiController,
    /// Spawn faction (for spawn rules and identification).
    spawn_faction: SpawnFaction,

    /// Create an inactive NPC ship (empty pool slot).
    pub fn empty() NpcShip {
        return .{
            .active = false,
            .flight = FlightState.init(flight_physics.ship_stats.tarsus),
            .health = ShipHealth.init(damage_mod.ship_health_specs.tarsus),
            .ai = AiController.init(ai_mod.ai_presets.pirate, .hostile),
            .spawn_faction = .pirate,
        };
    }

    /// Spawn a new NPC ship with the given faction at the given position.
    pub fn spawn(faction: SpawnFaction, position: Vec3) NpcShip {
        var flight = FlightState.init(faction.shipStats());
        flight.position = position;
        flight.setThrottle(0.5);

        var ai_ctrl = AiController.init(faction.aiConstants(), faction.toRadarFaction());
        ai_ctrl.patrol_center = position;

        return .{
            .active = true,
            .flight = flight,
            .health = ShipHealth.init(faction.healthSpec()),
            .ai = ai_ctrl,
            .spawn_faction = faction,
        };
    }

    /// Convert to a radar contact for display.
    pub fn toRadarContact(self: *const NpcShip) RadarContact {
        return .{
            .position = self.flight.position,
            .faction = self.spawn_faction.toRadarFaction(),
        };
    }
};

// ── Spawn Weights ──────────────────────────────────────────────────

/// Probability weights for each faction at a location. Higher = more likely.
pub const SpawnWeights = struct {
    pirate: u8 = 0,
    kilrathi: u8 = 0,
    confed: u8 = 0,
    militia: u8 = 0,
    merchant: u8 = 0,
    retro: u8 = 0,

    /// Total weight sum.
    pub fn total(self: SpawnWeights) u32 {
        return @as(u32, self.pirate) + @as(u32, self.kilrathi) +
            @as(u32, self.confed) + @as(u32, self.militia) +
            @as(u32, self.merchant) + @as(u32, self.retro);
    }

    /// Select a faction based on a roll value (0 to total-1).
    pub fn selectFaction(self: SpawnWeights, roll: u32) SpawnFaction {
        var accum: u32 = 0;

        accum += self.pirate;
        if (roll < accum) return .pirate;

        accum += self.kilrathi;
        if (roll < accum) return .kilrathi;

        accum += self.confed;
        if (roll < accum) return .confed;

        accum += self.militia;
        if (roll < accum) return .militia;

        accum += self.merchant;
        if (roll < accum) return .merchant;

        return .retro;
    }
};

// ── Base Type Constants ────────────────────────────────────────────

/// Base type IDs from the original game data.
pub const BaseType = struct {
    pub const agricultural: u8 = 0;
    pub const mining: u8 = 1;
    pub const pleasure: u8 = 2;
    pub const refinery: u8 = 3;
    pub const new_constantinople: u8 = 4;
    pub const pirate_base: u8 = 5;
    pub const military: u8 = 6;
};

/// Get spawn weights for a system based on whether it has a base and the base type.
/// Systems without bases use frontier weights (dangerous, pirate-heavy).
pub fn getSpawnWeights(has_base: bool, base_type: u8) SpawnWeights {
    if (!has_base) {
        // Frontier system: dangerous, pirate/kilrathi territory
        return .{
            .pirate = 40,
            .kilrathi = 25,
            .confed = 5,
            .militia = 0,
            .merchant = 15,
            .retro = 15,
        };
    }

    return switch (base_type) {
        BaseType.agricultural => .{
            .pirate = 20,
            .kilrathi = 5,
            .confed = 15,
            .militia = 10,
            .merchant = 40,
            .retro = 10,
        },
        BaseType.mining => .{
            .pirate = 25,
            .kilrathi = 10,
            .confed = 10,
            .militia = 10,
            .merchant = 35,
            .retro = 10,
        },
        BaseType.pleasure => .{
            .pirate = 15,
            .kilrathi = 5,
            .confed = 20,
            .militia = 15,
            .merchant = 35,
            .retro = 10,
        },
        BaseType.refinery => .{
            .pirate = 25,
            .kilrathi = 10,
            .confed = 10,
            .militia = 10,
            .merchant = 35,
            .retro = 10,
        },
        BaseType.new_constantinople => .{
            .pirate = 10,
            .kilrathi = 5,
            .confed = 30,
            .militia = 20,
            .merchant = 30,
            .retro = 5,
        },
        BaseType.pirate_base => .{
            .pirate = 50,
            .kilrathi = 10,
            .confed = 5,
            .militia = 0,
            .merchant = 15,
            .retro = 20,
        },
        BaseType.military => .{
            .pirate = 5,
            .kilrathi = 5,
            .confed = 40,
            .militia = 25,
            .merchant = 20,
            .retro = 5,
        },
        else => .{
            .pirate = 25,
            .kilrathi = 15,
            .confed = 15,
            .militia = 10,
            .merchant = 25,
            .retro = 10,
        },
    };
}

// ── Spawn System ───────────────────────────────────────────────────

/// Manages NPC ship spawning, despawning, and the active NPC pool.
pub const SpawnSystem = struct {
    /// Fixed pool of NPC ships.
    ships: [MAX_NPCS]NpcShip,
    /// Current spawn weights (set when entering a system).
    weights: SpawnWeights,
    /// Target number of active NPCs for the current system.
    target_count: u8,
    /// PRNG for spawn decisions.
    rng: std.Random.Xoshiro256,

    /// Initialize the spawn system with a seed.
    pub fn init(seed: u64) SpawnSystem {
        var sys = SpawnSystem{
            .ships = undefined,
            .weights = .{},
            .target_count = 8,
            .rng = std.Random.Xoshiro256.init(seed),
        };
        for (&sys.ships) |*ship| {
            ship.* = NpcShip.empty();
        }
        return sys;
    }

    /// Configure spawning for a new system.
    pub fn enterSystem(self: *SpawnSystem, has_base: bool, base_type: u8) void {
        self.weights = getSpawnWeights(has_base, base_type);

        // Target count varies by system type
        if (!has_base) {
            self.target_count = 6;
        } else if (base_type == BaseType.military or base_type == BaseType.new_constantinople) {
            self.target_count = 12;
        } else {
            self.target_count = 8;
        }

        // Clear all active NPCs when entering a new system
        for (&self.ships) |*ship| {
            ship.active = false;
        }
    }

    /// Count currently active NPCs.
    pub fn activeCount(self: *const SpawnSystem) u32 {
        var count: u32 = 0;
        for (self.ships) |ship| {
            if (ship.active) count += 1;
        }
        return count;
    }

    /// Find a free slot in the pool. Returns null if full.
    fn findFreeSlot(self: *SpawnSystem) ?usize {
        for (self.ships, 0..) |ship, i| {
            if (!ship.active) return i;
        }
        return null;
    }

    /// Spawn a single NPC of the given faction at the given position.
    /// Returns the slot index, or null if the pool is full.
    pub fn spawnNpc(self: *SpawnSystem, faction: SpawnFaction, position: Vec3) ?usize {
        const slot = self.findFreeSlot() orelse return null;
        self.ships[slot] = NpcShip.spawn(faction, position);
        return slot;
    }

    /// Despawn an NPC by slot index.
    pub fn despawnNpc(self: *SpawnSystem, index: usize) void {
        if (index < MAX_NPCS) {
            self.ships[index].active = false;
        }
    }

    /// Remove NPCs that are too far from the player.
    pub fn despawnOutOfRange(self: *SpawnSystem, player_pos: Vec3) void {
        for (&self.ships) |*ship| {
            if (!ship.active) continue;
            const dist = ship.flight.position.sub(player_pos).length();
            if (dist > DESPAWN_RANGE) {
                ship.active = false;
            }
        }
    }

    /// Generate a random spawn position around the player.
    fn randomSpawnPosition(self: *SpawnSystem, player_pos: Vec3) Vec3 {
        const random = self.rng.random();
        const angle = random.float(f32) * 2.0 * std.math.pi;
        const dist = SPAWN_MIN_RANGE + random.float(f32) * (SPAWN_MAX_RANGE - SPAWN_MIN_RANGE);
        const y_offset = (random.float(f32) - 0.5) * 500.0;

        return player_pos.add(.{
            .x = @cos(angle) * dist,
            .y = y_offset,
            .z = @sin(angle) * dist,
        });
    }

    /// Pick a random faction based on current weights.
    fn pickFaction(self: *SpawnSystem) SpawnFaction {
        const t = self.weights.total();
        if (t == 0) return .pirate;
        const random = self.rng.random();
        const roll = random.intRangeAtMost(u32, 0, t - 1);
        return self.weights.selectFaction(roll);
    }

    /// Attempt to spawn NPCs up to the target count. Call periodically.
    pub fn trySpawn(self: *SpawnSystem, player_pos: Vec3) void {
        if (self.weights.total() == 0) return;

        while (self.activeCount() < self.target_count) {
            const faction = self.pickFaction();
            const pos = self.randomSpawnPosition(player_pos);
            if (self.spawnNpc(faction, pos) == null) break;
        }
    }

    /// Update all active NPCs for one frame.
    /// If explosion/debris systems are provided, destroyed ships spawn effects.
    pub fn updateNpcs(
        self: *SpawnSystem,
        dt: f32,
        explosion_sys: ?*ExplosionSystem,
        debris_sys: ?*DebrisSystem,
    ) void {
        for (&self.ships) |*ship| {
            if (!ship.active) continue;

            _ = ship.ai.update(&ship.flight, &ship.health, &.{}, dt);
            ship.flight.update(dt);

            // Remove destroyed ships and spawn explosion/debris
            if (ship.health.isDestroyed()) {
                if (explosion_sys) |es| {
                    const size: ExplosionSize = .medium;
                    if (debris_sys) |ds| {
                        _ = explosions_mod.spawnDestructionEffect(
                            es,
                            ds,
                            ship.flight.position,
                            size,
                            &self.rng,
                        );
                    } else {
                        _ = es.spawn(ship.flight.position, size);
                    }
                }
                ship.active = false;
            }
        }
    }

    /// Fill a radar contacts buffer with active NPC positions.
    /// Returns the number of contacts written.
    pub fn getRadarContacts(self: *const SpawnSystem, buffer: []RadarContact) u32 {
        var count: u32 = 0;
        for (self.ships) |ship| {
            if (!ship.active) continue;
            if (count >= buffer.len) break;
            buffer[count] = ship.toRadarContact();
            count += 1;
        }
        return count;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

// --- SpawnFaction mapping ---

test "SpawnFaction.toRadarFaction maps pirates to hostile" {
    try testing.expectEqual(Faction.hostile, SpawnFaction.pirate.toRadarFaction());
    try testing.expectEqual(Faction.hostile, SpawnFaction.kilrathi.toRadarFaction());
    try testing.expectEqual(Faction.hostile, SpawnFaction.retro.toRadarFaction());
}

test "SpawnFaction.toRadarFaction maps confed/militia to friendly" {
    try testing.expectEqual(Faction.friendly, SpawnFaction.confed.toRadarFaction());
    try testing.expectEqual(Faction.friendly, SpawnFaction.militia.toRadarFaction());
}

test "SpawnFaction.toRadarFaction maps merchants to neutral" {
    try testing.expectEqual(Faction.neutral, SpawnFaction.merchant.toRadarFaction());
}

test "SpawnFaction.aiConstants returns valid constants for all factions" {
    const factions = [_]SpawnFaction{ .pirate, .kilrathi, .confed, .militia, .merchant, .retro };
    for (factions) |f| {
        const c = f.aiConstants();
        try testing.expect(c.aggression >= 0 and c.aggression <= 1.0);
        try testing.expect(c.flee_threshold >= 0 and c.flee_threshold <= 1.0);
        try testing.expect(c.engagement_range > 0);
    }
}

test "SpawnFaction.shipStats returns valid stats for all factions" {
    const factions = [_]SpawnFaction{ .pirate, .kilrathi, .confed, .militia, .merchant, .retro };
    for (factions) |f| {
        const s = f.shipStats();
        try testing.expect(s.max_speed > 0);
        try testing.expect(s.afterburner_speed > s.max_speed);
        try testing.expect(s.thrust > 0);
    }
}

test "SpawnFaction.healthSpec returns valid specs for all factions" {
    const factions = [_]SpawnFaction{ .pirate, .kilrathi, .confed, .militia, .merchant, .retro };
    for (factions) |f| {
        const h = f.healthSpec();
        try testing.expect(h.shield_front > 0);
        try testing.expect(h.armor_front > 0);
    }
}

// --- NpcShip ---

test "NpcShip.empty creates inactive ship" {
    const ship = NpcShip.empty();
    try testing.expect(!ship.active);
}

test "NpcShip.spawn creates active ship at position" {
    const pos = Vec3{ .x = 100, .y = 200, .z = 300 };
    const ship = NpcShip.spawn(.pirate, pos);

    try testing.expect(ship.active);
    try testing.expectEqual(SpawnFaction.pirate, ship.spawn_faction);
    try testing.expectEqual(@as(f32, 100), ship.flight.position.x);
    try testing.expectEqual(@as(f32, 200), ship.flight.position.y);
    try testing.expectEqual(@as(f32, 300), ship.flight.position.z);
    try testing.expect(!ship.health.isDestroyed());
}

test "NpcShip.spawn sets patrol center to spawn position" {
    const pos = Vec3{ .x = 500, .y = 0, .z = 500 };
    const ship = NpcShip.spawn(.confed, pos);

    try testing.expectEqual(@as(f32, 500), ship.ai.patrol_center.x);
    try testing.expectEqual(@as(f32, 500), ship.ai.patrol_center.z);
}

test "NpcShip.spawn uses faction-specific ship stats" {
    const merchant = NpcShip.spawn(.merchant, Vec3.zero);
    const pirate = NpcShip.spawn(.pirate, Vec3.zero);

    // Merchants use Galaxy stats, pirates use Centurion stats
    try testing.expectEqual(flight_physics.ship_stats.galaxy.max_speed, merchant.flight.stats.max_speed);
    try testing.expectEqual(flight_physics.ship_stats.centurion.max_speed, pirate.flight.stats.max_speed);
}

test "NpcShip.toRadarContact returns correct faction" {
    const ship = NpcShip.spawn(.kilrathi, .{ .x = 10, .y = 20, .z = 30 });
    const contact = ship.toRadarContact();

    try testing.expectEqual(Faction.hostile, contact.faction);
    try testing.expectEqual(@as(f32, 10), contact.position.x);
    try testing.expectEqual(@as(f32, 20), contact.position.y);
    try testing.expectEqual(@as(f32, 30), contact.position.z);
}

// --- SpawnWeights ---

test "SpawnWeights.total sums all weights" {
    const w = SpawnWeights{
        .pirate = 10,
        .kilrathi = 20,
        .confed = 30,
        .militia = 15,
        .merchant = 20,
        .retro = 5,
    };
    try testing.expectEqual(@as(u32, 100), w.total());
}

test "SpawnWeights.total zero when all weights zero" {
    const w = SpawnWeights{};
    try testing.expectEqual(@as(u32, 0), w.total());
}

test "SpawnWeights.selectFaction selects pirate for low roll" {
    const w = SpawnWeights{
        .pirate = 10,
        .kilrathi = 10,
        .confed = 10,
        .militia = 10,
        .merchant = 10,
        .retro = 10,
    };
    // Roll 0-9 should select pirate (weight 10)
    try testing.expectEqual(SpawnFaction.pirate, w.selectFaction(0));
    try testing.expectEqual(SpawnFaction.pirate, w.selectFaction(9));
}

test "SpawnWeights.selectFaction selects kilrathi for mid-low roll" {
    const w = SpawnWeights{
        .pirate = 10,
        .kilrathi = 10,
        .confed = 10,
        .militia = 10,
        .merchant = 10,
        .retro = 10,
    };
    // Roll 10-19 should select kilrathi
    try testing.expectEqual(SpawnFaction.kilrathi, w.selectFaction(10));
    try testing.expectEqual(SpawnFaction.kilrathi, w.selectFaction(19));
}

test "SpawnWeights.selectFaction selects retro for high roll" {
    const w = SpawnWeights{
        .pirate = 10,
        .kilrathi = 10,
        .confed = 10,
        .militia = 10,
        .merchant = 10,
        .retro = 10,
    };
    // Roll 50-59 should select retro
    try testing.expectEqual(SpawnFaction.retro, w.selectFaction(50));
    try testing.expectEqual(SpawnFaction.retro, w.selectFaction(59));
}

test "SpawnWeights.selectFaction skips zero-weight factions" {
    const w = SpawnWeights{
        .pirate = 0,
        .kilrathi = 0,
        .confed = 50,
        .militia = 0,
        .merchant = 50,
        .retro = 0,
    };
    // Roll 0-49 → confed, roll 50-99 → merchant
    try testing.expectEqual(SpawnFaction.confed, w.selectFaction(0));
    try testing.expectEqual(SpawnFaction.confed, w.selectFaction(49));
    try testing.expectEqual(SpawnFaction.merchant, w.selectFaction(50));
    try testing.expectEqual(SpawnFaction.merchant, w.selectFaction(99));
}

// --- getSpawnWeights ---

test "frontier system has highest pirate weight" {
    const w = getSpawnWeights(false, 0);
    try testing.expect(w.pirate > w.confed);
    try testing.expect(w.pirate > w.merchant);
    try testing.expect(w.pirate > w.militia);
    try testing.expectEqual(@as(u8, 40), w.pirate);
}

test "pirate base has highest pirate weight" {
    const w = getSpawnWeights(true, BaseType.pirate_base);
    try testing.expect(w.pirate > w.confed);
    try testing.expect(w.pirate > w.merchant);
    try testing.expect(w.pirate > w.kilrathi);
    try testing.expectEqual(@as(u8, 50), w.pirate);
}

test "military base has highest confed weight" {
    const w = getSpawnWeights(true, BaseType.military);
    try testing.expect(w.confed > w.pirate);
    try testing.expect(w.confed > w.kilrathi);
    try testing.expect(w.confed > w.retro);
    try testing.expectEqual(@as(u8, 40), w.confed);
}

test "agricultural base has highest merchant weight" {
    const w = getSpawnWeights(true, BaseType.agricultural);
    try testing.expect(w.merchant > w.pirate);
    try testing.expect(w.merchant > w.confed);
    try testing.expect(w.merchant > w.kilrathi);
    try testing.expectEqual(@as(u8, 40), w.merchant);
}

test "military base has zero militia for pirate base" {
    const w = getSpawnWeights(true, BaseType.pirate_base);
    try testing.expectEqual(@as(u8, 0), w.militia);
}

test "all spawn weight profiles have nonzero total" {
    const base_types = [_]u8{ 0, 1, 2, 3, 4, 5, 6 };
    for (base_types) |bt| {
        try testing.expect(getSpawnWeights(true, bt).total() > 0);
    }
    try testing.expect(getSpawnWeights(false, 0).total() > 0);
}

// --- SpawnSystem ---

test "SpawnSystem.init creates empty pool" {
    const sys = SpawnSystem.init(42);
    try testing.expectEqual(@as(u32, 0), sys.activeCount());
    try testing.expectEqual(@as(u8, 8), sys.target_count);
}

test "SpawnSystem.enterSystem configures weights and clears pool" {
    var sys = SpawnSystem.init(42);
    _ = sys.spawnNpc(.pirate, Vec3.zero);
    try testing.expectEqual(@as(u32, 1), sys.activeCount());

    sys.enterSystem(true, BaseType.military);
    try testing.expectEqual(@as(u32, 0), sys.activeCount());
    try testing.expectEqual(@as(u8, 40), sys.weights.confed);
    try testing.expectEqual(@as(u8, 12), sys.target_count);
}

test "SpawnSystem.enterSystem sets higher target for military base" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(true, BaseType.military);
    try testing.expectEqual(@as(u8, 12), sys.target_count);
}

test "SpawnSystem.enterSystem sets lower target for frontier" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(false, 0);
    try testing.expectEqual(@as(u8, 6), sys.target_count);
}

test "SpawnSystem.enterSystem sets normal target for agricultural" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(true, BaseType.agricultural);
    try testing.expectEqual(@as(u8, 8), sys.target_count);
}

test "SpawnSystem.spawnNpc adds NPC to pool" {
    var sys = SpawnSystem.init(42);
    const slot = sys.spawnNpc(.pirate, .{ .x = 100, .y = 0, .z = 200 });

    try testing.expect(slot != null);
    try testing.expectEqual(@as(u32, 1), sys.activeCount());
    try testing.expect(sys.ships[slot.?].active);
    try testing.expectEqual(SpawnFaction.pirate, sys.ships[slot.?].spawn_faction);
}

test "SpawnSystem.spawnNpc returns null when pool full" {
    var sys = SpawnSystem.init(42);
    // Fill the pool
    var i: u32 = 0;
    while (i < MAX_NPCS) : (i += 1) {
        _ = sys.spawnNpc(.pirate, Vec3.zero);
    }
    try testing.expectEqual(MAX_NPCS, sys.activeCount());

    // Next spawn should fail
    try testing.expect(sys.spawnNpc(.pirate, Vec3.zero) == null);
}

test "SpawnSystem.despawnNpc removes NPC" {
    var sys = SpawnSystem.init(42);
    const slot = sys.spawnNpc(.confed, Vec3.zero).?;
    try testing.expectEqual(@as(u32, 1), sys.activeCount());

    sys.despawnNpc(slot);
    try testing.expectEqual(@as(u32, 0), sys.activeCount());
}

test "SpawnSystem.despawnOutOfRange removes distant NPCs" {
    var sys = SpawnSystem.init(42);
    // Spawn a nearby NPC
    _ = sys.spawnNpc(.pirate, .{ .x = 100, .y = 0, .z = 0 });
    // Spawn a far NPC (beyond DESPAWN_RANGE)
    _ = sys.spawnNpc(.pirate, .{ .x = 6000, .y = 0, .z = 0 });

    try testing.expectEqual(@as(u32, 2), sys.activeCount());

    sys.despawnOutOfRange(Vec3.zero);

    try testing.expectEqual(@as(u32, 1), sys.activeCount());
    // The nearby one should still be active
    try testing.expect(sys.ships[0].active);
    try testing.expect(!sys.ships[1].active);
}

test "SpawnSystem.despawnOutOfRange keeps NPCs within range" {
    var sys = SpawnSystem.init(42);
    _ = sys.spawnNpc(.confed, .{ .x = 1000, .y = 0, .z = 0 });
    _ = sys.spawnNpc(.militia, .{ .x = 0, .y = 0, .z = 2000 });

    sys.despawnOutOfRange(Vec3.zero);

    try testing.expectEqual(@as(u32, 2), sys.activeCount());
}

test "SpawnSystem.trySpawn fills up to target count" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(true, BaseType.agricultural);

    sys.trySpawn(Vec3.zero);

    try testing.expectEqual(@as(u32, sys.target_count), sys.activeCount());
}

test "pirate sector spawns pirate ships" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(true, BaseType.pirate_base);

    sys.trySpawn(Vec3.zero);

    // Count pirates among spawned ships
    var pirate_count: u32 = 0;
    for (sys.ships) |ship| {
        if (ship.active and ship.spawn_faction == .pirate) pirate_count += 1;
    }
    // With 50% pirate weight and 8 ships, we expect several pirates
    try testing.expect(pirate_count > 0);
}

test "Confed patrol spawns in Confed systems" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(true, BaseType.military);

    sys.trySpawn(Vec3.zero);

    // Count Confed among spawned ships
    var confed_count: u32 = 0;
    for (sys.ships) |ship| {
        if (ship.active and ship.spawn_faction == .confed) confed_count += 1;
    }
    // With 40% confed weight and 12 ships, we expect several confed
    try testing.expect(confed_count > 0);
}

test "SpawnSystem.trySpawn respects pool capacity" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(true, BaseType.agricultural);
    sys.target_count = MAX_NPCS + 10; // More than pool can hold

    sys.trySpawn(Vec3.zero);

    // Should cap at MAX_NPCS
    try testing.expectEqual(MAX_NPCS, sys.activeCount());
}

test "SpawnSystem.trySpawn spawns at distance from player" {
    var sys = SpawnSystem.init(42);
    sys.enterSystem(true, BaseType.agricultural);

    const player_pos = Vec3{ .x = 1000, .y = 500, .z = 2000 };
    sys.trySpawn(player_pos);

    for (sys.ships) |ship| {
        if (!ship.active) continue;
        const dist = ship.flight.position.sub(player_pos).length();
        // All NPCs should be between min and max spawn range
        // Note: Y offset adds some variance, so use slightly relaxed bounds
        try testing.expect(dist >= SPAWN_MIN_RANGE * 0.8);
        try testing.expect(dist <= SPAWN_MAX_RANGE * 1.3);
    }
}

test "SpawnSystem.getRadarContacts fills buffer" {
    var sys = SpawnSystem.init(42);
    _ = sys.spawnNpc(.pirate, .{ .x = 100, .y = 0, .z = 0 });
    _ = sys.spawnNpc(.confed, .{ .x = 200, .y = 0, .z = 0 });
    _ = sys.spawnNpc(.merchant, .{ .x = 300, .y = 0, .z = 0 });

    var buffer: [10]RadarContact = undefined;
    const count = sys.getRadarContacts(&buffer);

    try testing.expectEqual(@as(u32, 3), count);
    try testing.expectEqual(Faction.hostile, buffer[0].faction);
    try testing.expectEqual(Faction.friendly, buffer[1].faction);
    try testing.expectEqual(Faction.neutral, buffer[2].faction);
}

test "SpawnSystem.getRadarContacts respects buffer size" {
    var sys = SpawnSystem.init(42);
    _ = sys.spawnNpc(.pirate, Vec3.zero);
    _ = sys.spawnNpc(.confed, Vec3.zero);
    _ = sys.spawnNpc(.merchant, Vec3.zero);

    var small_buffer: [2]RadarContact = undefined;
    const count = sys.getRadarContacts(&small_buffer);

    try testing.expectEqual(@as(u32, 2), count);
}

test "SpawnSystem.updateNpcs removes destroyed ships" {
    var sys = SpawnSystem.init(42);
    const slot = sys.spawnNpc(.retro, Vec3.zero).?;

    // Destroy the ship
    _ = sys.ships[slot].health.applyDamage(.front, 500);
    _ = sys.ships[slot].health.applyDamage(.rear, 500);
    _ = sys.ships[slot].health.applyDamage(.left, 500);
    _ = sys.ships[slot].health.applyDamage(.right, 500);
    try testing.expect(sys.ships[slot].health.isDestroyed());

    sys.updateNpcs(0.016, null, null);

    try testing.expectEqual(@as(u32, 0), sys.activeCount());
}

test "SpawnSystem.updateNpcs advances ship positions" {
    var sys = SpawnSystem.init(42);
    const slot = sys.spawnNpc(.merchant, Vec3.zero).?;
    sys.ships[slot].flight.setThrottle(1.0);

    const initial_pos = sys.ships[slot].flight.position;
    sys.updateNpcs(1.0, null, null);
    const final_pos = sys.ships[slot].flight.position;

    // Ship should have moved
    const dist = final_pos.sub(initial_pos).length();
    try testing.expect(dist > 0);
}

test "SpawnSystem.updateNpcs spawns explosion on ship destruction" {
    var sys = SpawnSystem.init(42);
    var expl_sys = ExplosionSystem.init();
    var debris_sys = DebrisSystem.init();

    const ship_pos = Vec3{ .x = 500, .y = 100, .z = 300 };
    const slot = sys.spawnNpc(.retro, ship_pos).?;

    // Destroy the ship
    _ = sys.ships[slot].health.applyDamage(.front, 500);

    try testing.expectEqual(@as(usize, 0), expl_sys.count());
    try testing.expectEqual(@as(usize, 0), debris_sys.count());

    sys.updateNpcs(0.016, &expl_sys, &debris_sys);

    // Ship should be removed
    try testing.expectEqual(@as(u32, 0), sys.activeCount());
    // Explosion should be spawned
    try testing.expectEqual(@as(usize, 1), expl_sys.count());
    // Debris should be spawned (medium explosion = 8 particles)
    try testing.expect(debris_sys.count() > 0);
}
