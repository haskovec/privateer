//! AI flight behavior for Wing Commander: Privateer.
//!
//! Implements NPC ship AI with a state machine (patrol, attack, flee, escort),
//! pursuit/flee steering, weapon engagement logic, and configurable behavior
//! constants. AI constants (aggression, flee threshold, etc.) are designed to
//! be loaded from AIDS/*.IFF CNST chunks in the original game data.
//!
//! AI behavior flow:
//!   1. Evaluate situation (targets, health, state)
//!   2. Transition state if conditions are met
//!   3. Execute state behavior (steer, set throttle)
//!   4. Return action (fire guns/missiles)

const std = @import("std");
const flight_physics = @import("../flight/flight_physics.zig");
const damage_mod = @import("damage.zig");
const radar_mod = @import("../cockpit/radar.zig");

const Vec3 = flight_physics.Vec3;
const FlightState = flight_physics.FlightState;
const ShipHealth = damage_mod.ShipHealth;
const Faction = radar_mod.Faction;

// ── Data Types ──────────────────────────────────────────────────────

/// AI behavior constants. In the original game these come from CNST chunks
/// in AIDS/*.IFF files. Each faction/variant has its own constants.
pub const AiConstants = struct {
    /// How aggressively the AI pursues and attacks (0.0 = passive, 1.0 = maximum).
    aggression: f32 = 0.7,
    /// Shield fraction (0-1) below which the AI will flee combat.
    flee_threshold: f32 = 0.25,
    /// Maximum distance at which the AI will engage a target.
    engagement_range: f32 = 1500.0,
    /// Distance at which the AI opens fire with guns.
    firing_range: f32 = 800.0,
    /// Missile lock range (fire missile when in range and locked).
    missile_range: f32 = 1200.0,
    /// Radius of patrol orbit around patrol center.
    patrol_radius: f32 = 500.0,
    /// Steering gain for pursuit/flee (higher = more responsive).
    steering_gain: f32 = 2.0,
};

/// Predefined AI constants for different faction archetypes.
pub const ai_presets = struct {
    /// Aggressive pirates: high aggression, low flee threshold.
    pub const pirate = AiConstants{
        .aggression = 0.8,
        .flee_threshold = 0.15,
        .engagement_range = 1500.0,
        .firing_range = 800.0,
        .missile_range = 1200.0,
        .patrol_radius = 500.0,
        .steering_gain = 2.0,
    };
    /// Kilrathi: very aggressive, rarely flee.
    pub const kilrathi = AiConstants{
        .aggression = 0.9,
        .flee_threshold = 0.10,
        .engagement_range = 1800.0,
        .firing_range = 900.0,
        .missile_range = 1400.0,
        .patrol_radius = 600.0,
        .steering_gain = 2.2,
    };
    /// Confed patrol: moderate aggression, will break off if damaged.
    pub const confed = AiConstants{
        .aggression = 0.6,
        .flee_threshold = 0.30,
        .engagement_range = 1200.0,
        .firing_range = 700.0,
        .missile_range = 1000.0,
        .patrol_radius = 400.0,
        .steering_gain = 1.8,
    };
    /// Militia: cautious, patrol-oriented.
    pub const militia = AiConstants{
        .aggression = 0.5,
        .flee_threshold = 0.35,
        .engagement_range = 1000.0,
        .firing_range = 600.0,
        .missile_range = 900.0,
        .patrol_radius = 350.0,
        .steering_gain = 1.6,
    };
    /// Merchants: defensive only, flee quickly.
    pub const merchant = AiConstants{
        .aggression = 0.2,
        .flee_threshold = 0.50,
        .engagement_range = 600.0,
        .firing_range = 400.0,
        .missile_range = 500.0,
        .patrol_radius = 300.0,
        .steering_gain = 1.5,
    };
    /// Retro: suicidal fanatics, never flee.
    pub const retro = AiConstants{
        .aggression = 1.0,
        .flee_threshold = 0.0,
        .engagement_range = 2000.0,
        .firing_range = 900.0,
        .missile_range = 1500.0,
        .patrol_radius = 600.0,
        .steering_gain = 2.5,
    };
};

/// AI behavior state.
pub const AiState = enum {
    /// Cruising around patrol center, scanning for targets.
    patrol,
    /// Pursuing and engaging a hostile target.
    attack,
    /// Retreating from combat due to critical damage.
    flee,
    /// Escorting a friendly ship (staying near it).
    escort,
};

/// A target visible to the AI for decision-making.
pub const AiTarget = struct {
    /// World-space position.
    position: Vec3,
    /// World-space velocity.
    velocity: Vec3,
    /// Faction affiliation.
    faction: Faction,
};

/// Actions the AI wants to perform this frame.
pub const AiAction = struct {
    /// Whether to fire guns this frame.
    fire_guns: bool = false,
    /// Whether to fire a missile this frame.
    fire_missile: bool = false,
};

// ── AI Controller ───────────────────────────────────────────────────

/// Wrap an angle to the range [-pi, pi].
fn normalizeAngle(angle: f32) f32 {
    const tau: f32 = 2.0 * std.math.pi;
    return angle - tau * @floor(angle / tau + 0.5);
}

/// AI controller for a single NPC ship.
pub const AiController = struct {
    /// Current behavior state.
    state: AiState,
    /// Behavior constants (from CNST data or presets).
    constants: AiConstants,
    /// Index of the current target in the targets array.
    target_index: ?usize,
    /// Center of patrol area.
    patrol_center: Vec3,
    /// Faction of this AI ship (determines who is hostile).
    faction: Faction,

    /// Create a new AI controller in patrol state.
    pub fn init(constants: AiConstants, faction: Faction) AiController {
        return .{
            .state = .patrol,
            .constants = constants,
            .target_index = null,
            .patrol_center = Vec3.zero,
            .faction = faction,
        };
    }

    /// Update the AI for one frame. Evaluates the situation, transitions
    /// state if needed, steers the ship, and returns desired actions.
    pub fn update(
        self: *AiController,
        flight: *FlightState,
        health: *const ShipHealth,
        targets: []const AiTarget,
        dt: f32,
    ) AiAction {
        // Step 1: Check if we should flee (health critical)
        if (self.shouldFlee(health)) {
            self.state = .flee;
        }

        // Step 2: Find/validate target
        self.updateTarget(flight, targets);

        // Step 3: State transitions based on target availability
        self.evaluateStateTransitions(flight, targets);

        // Step 4: Execute current state behavior
        return switch (self.state) {
            .patrol => self.executePatrol(flight, dt),
            .attack => self.executeAttack(flight, targets, dt),
            .flee => self.executeFlee(flight, targets, dt),
            .escort => self.executeEscort(flight, dt),
        };
    }

    /// Check if the AI should flee based on shield levels.
    fn shouldFlee(self: *const AiController, health: *const ShipHealth) bool {
        if (self.constants.flee_threshold <= 0) return false;

        // Average shield fraction across all facings
        var total_shield: f32 = 0;
        var total_max: f32 = 0;
        for (health.shield, health.max_shield) |s, m| {
            total_shield += s;
            total_max += m;
        }

        if (total_max <= 0) return true;
        const shield_fraction = total_shield / total_max;
        return shield_fraction < self.constants.flee_threshold;
    }

    /// Find the nearest hostile target, or clear target if invalid.
    fn updateTarget(self: *AiController, flight: *const FlightState, targets: []const AiTarget) void {
        // Clear target if out of range or no longer valid
        if (self.target_index) |ti| {
            if (ti >= targets.len) {
                self.target_index = null;
            } else {
                const dist = flight.position.sub(targets[ti].position).length();
                if (dist > self.constants.engagement_range * 1.5) {
                    self.target_index = null;
                }
            }
        }

        // If no target, scan for nearest hostile
        if (self.target_index == null and self.state != .flee) {
            self.target_index = self.findNearestHostile(flight.position, targets);
        }
    }

    /// Find the nearest hostile target within engagement range.
    fn findNearestHostile(self: *const AiController, position: Vec3, targets: []const AiTarget) ?usize {
        var best_dist_sq: f32 = std.math.floatMax(f32);
        var best_index: ?usize = null;
        const range_sq = self.constants.engagement_range * self.constants.engagement_range;

        for (targets, 0..) |t, i| {
            if (!self.isHostile(t.faction)) continue;

            const delta = position.sub(t.position);
            const dist_sq = delta.dot(delta);
            if (dist_sq < best_dist_sq and dist_sq <= range_sq) {
                best_dist_sq = dist_sq;
                best_index = i;
            }
        }

        return best_index;
    }

    /// Check if a given faction is hostile to this AI.
    fn isHostile(self: *const AiController, other: Faction) bool {
        // Simple faction hostility: hostile faction ships are always hostile.
        // Friendly and neutral are not hostile to each other.
        return switch (self.faction) {
            .hostile => other != .hostile,
            .friendly => other == .hostile,
            .neutral => other == .hostile,
        };
    }

    /// Evaluate whether state transitions should occur.
    fn evaluateStateTransitions(self: *AiController, flight: *const FlightState, targets: []const AiTarget) void {
        switch (self.state) {
            .patrol => {
                // Transition to attack if we have a hostile target in range
                if (self.target_index) |ti| {
                    if (ti < targets.len and self.isHostile(targets[ti].faction)) {
                        const dist = flight.position.sub(targets[ti].position).length();
                        if (dist <= self.constants.engagement_range) {
                            self.state = .attack;
                        }
                    }
                }
            },
            .attack => {
                // Return to patrol if no valid target
                if (self.target_index == null) {
                    self.state = .patrol;
                }
            },
            .flee => {
                // Stay in flee state (only manual intervention or health recovery exits it)
            },
            .escort => {
                // Transition to attack if hostile in range
                if (self.target_index) |ti| {
                    if (ti < targets.len and self.isHostile(targets[ti].faction)) {
                        self.state = .attack;
                    }
                }
            },
        }
    }

    /// Execute patrol behavior: orbit around patrol center.
    fn executePatrol(self: *AiController, flight: *FlightState, dt: f32) AiAction {
        // Steer toward patrol center
        steerToward(flight, self.patrol_center, self.constants.steering_gain, dt);

        // Cruise at half throttle
        flight.setThrottle(0.5);

        return .{};
    }

    /// Execute attack behavior: pursue target and fire when in range.
    fn executeAttack(self: *AiController, flight: *FlightState, targets: []const AiTarget, dt: f32) AiAction {
        const ti = self.target_index orelse return .{};
        if (ti >= targets.len) return .{};

        const target = targets[ti];
        const to_target = target.position.sub(flight.position);
        const dist = to_target.length();

        // Steer toward target (pursuit)
        steerToward(flight, target.position, self.constants.steering_gain, dt);

        // Full throttle in attack
        flight.setThrottle(1.0);

        // Fire decision
        var action = AiAction{};

        if (dist <= self.constants.firing_range) {
            // Check if roughly aimed at target (within ~30 degrees)
            const fwd = flight.forward();
            const to_target_norm = to_target.normalize();
            const aim_dot = fwd.dot(to_target_norm);

            if (aim_dot > 0.85) { // cos(~32 degrees)
                action.fire_guns = true;
            }
        }

        if (dist <= self.constants.missile_range and dist > self.constants.firing_range * 0.5) {
            const fwd = flight.forward();
            const to_target_norm = to_target.normalize();
            const aim_dot = fwd.dot(to_target_norm);

            if (aim_dot > 0.9) { // Tighter aim for missiles
                action.fire_missile = true;
            }
        }

        return action;
    }

    /// Execute flee behavior: fly away from the nearest threat.
    fn executeFlee(self: *AiController, flight: *FlightState, targets: []const AiTarget, dt: f32) AiAction {
        // Find nearest hostile to flee from
        const threat_idx = self.findNearestHostile(flight.position, targets);

        if (threat_idx) |ti| {
            // Steer away from the threat
            const away = flight.position.sub(targets[ti].position);
            const flee_target = flight.position.add(away.normalize().scale(1000.0));
            steerToward(flight, flee_target, self.constants.steering_gain, dt);
        }

        // Maximum throttle when fleeing
        flight.setThrottle(1.0);
        flight.afterburner_active = true;

        return .{};
    }

    /// Execute escort behavior: stay near patrol center (escort target position).
    fn executeEscort(self: *AiController, flight: *FlightState, dt: f32) AiAction {
        steerToward(flight, self.patrol_center, self.constants.steering_gain, dt);
        flight.setThrottle(0.7);
        return .{};
    }
};

/// Steer a flight state toward a target position using proportional control.
fn steerToward(flight: *FlightState, target: Vec3, gain: f32, dt: f32) void {
    const delta = target.sub(flight.position);
    const dist = delta.length();
    if (dist < 0.001) return;

    // Desired heading toward target
    const desired_yaw = std.math.atan2(delta.x, delta.z);
    const horiz_dist = @sqrt(delta.x * delta.x + delta.z * delta.z);
    const desired_pitch = std.math.atan2(delta.y, horiz_dist);

    // Steering errors (wrapped to -pi..pi)
    const yaw_error = normalizeAngle(desired_yaw - flight.yaw);
    const pitch_error = desired_pitch - flight.pitch;

    // Proportional steering
    const yaw_input = std.math.clamp(yaw_error * gain, @as(f32, -1.0), @as(f32, 1.0));
    const pitch_input = std.math.clamp(pitch_error * gain, @as(f32, -1.0), @as(f32, 1.0));

    flight.applyYaw(yaw_input, dt);
    flight.applyPitch(pitch_input, dt);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const ship_stats = flight_physics.ship_stats;
const ship_health_specs = damage_mod.ship_health_specs;

// --- Initialization ---

test "AI controller initializes in patrol state" {
    const ai = AiController.init(ai_presets.pirate, .hostile);
    try testing.expectEqual(AiState.patrol, ai.state);
    try testing.expect(ai.target_index == null);
    try testing.expectEqual(Faction.hostile, ai.faction);
}

test "AI presets have valid values" {
    const presets = [_]AiConstants{
        ai_presets.pirate,
        ai_presets.kilrathi,
        ai_presets.confed,
        ai_presets.militia,
        ai_presets.merchant,
        ai_presets.retro,
    };
    for (presets) |p| {
        try testing.expect(p.aggression >= 0 and p.aggression <= 1.0);
        try testing.expect(p.flee_threshold >= 0 and p.flee_threshold <= 1.0);
        try testing.expect(p.engagement_range > 0);
        try testing.expect(p.firing_range > 0);
        try testing.expect(p.firing_range <= p.engagement_range);
        try testing.expect(p.steering_gain > 0);
    }
}

// --- Pursuit maneuver: hostile AI turns toward player ---

test "hostile AI turns toward player" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Player (friendly) is at +X relative to AI
    const targets = [_]AiTarget{
        .{ .position = .{ .x = 500, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    // Run several frames
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        _ = ai.update(&flight, &health, &targets, 0.016);
        flight.update(0.016);
    }

    // AI should have turned toward the player (positive yaw toward +X)
    try testing.expect(flight.yaw > 0);
    // Should be in attack state
    try testing.expectEqual(AiState.attack, ai.state);
}

test "AI pursuit steers yaw toward target to the left" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Target is to the left (-X)
    const targets = [_]AiTarget{
        .{ .position = .{ .x = -500, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        _ = ai.update(&flight, &health, &targets, 0.016);
        flight.update(0.016);
    }

    // Should have turned left (negative yaw)
    try testing.expect(flight.yaw < 0);
}

test "AI pursuit moves ship closer to target" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Target is directly ahead along +Z
    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 1000 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    const initial_dist = flight.position.sub(targets[0].position).length();

    // Run frames
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        _ = ai.update(&flight, &health, &targets, 0.016);
        flight.update(0.016);
    }

    const final_dist = flight.position.sub(targets[0].position).length();
    try testing.expect(final_dist < initial_dist);
}

// --- Engagement logic: AI fires weapons when in range ---

test "AI fires guns when in range and aimed at target" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Target is directly ahead, within firing range
    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 400 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    // AI should be aimed at target (both at yaw=0, target is along +Z)
    const action = ai.update(&flight, &health, &targets, 0.016);

    try testing.expect(action.fire_guns);
    try testing.expectEqual(AiState.attack, ai.state);
}

test "AI does not fire when out of range" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Target is far beyond firing range
    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 5000 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    const action = ai.update(&flight, &health, &targets, 0.016);

    try testing.expect(!action.fire_guns);
    try testing.expect(!action.fire_missile);
}

test "AI does not fire when not aimed at target" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Target is within range but perpendicular (to the side)
    const targets = [_]AiTarget{
        .{ .position = .{ .x = 400, .y = 0, .z = 0 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    // First frame only - AI hasn't turned yet
    const action = ai.update(&flight, &health, &targets, 0.016);

    try testing.expect(!action.fire_guns);
}

// --- Flee behavior: AI flees when shields critical ---

test "AI flees when shields critical" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Deplete shields below flee threshold (pirate threshold = 0.15)
    // Total max shield = 80+80+60+60 = 280
    // 15% of 280 = 42, so drain to below 42 total
    _ = health.applyDamage(.front, 75); // front shield 80 → 5
    _ = health.applyDamage(.rear, 75); // rear shield 80 → 5
    _ = health.applyDamage(.left, 55); // left shield 60 → 5
    _ = health.applyDamage(.right, 55); // right shield 60 → 5
    // Total shield = 20 out of 280 ≈ 7.1% < 15%

    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 400 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    _ = ai.update(&flight, &health, &targets, 0.016);

    try testing.expectEqual(AiState.flee, ai.state);
}

test "AI flees away from nearest threat" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Deplete shields to trigger flee
    _ = health.applyDamage(.front, 75);
    _ = health.applyDamage(.rear, 75);
    _ = health.applyDamage(.left, 55);
    _ = health.applyDamage(.right, 55);

    // Threat is ahead along +Z
    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 500 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    // Run several frames - AI should flee (turn away from +Z threat)
    // AI needs ~1.75s to turn 180 degrees (pi / rotation_rate 1.8), so run 180 frames (~2.88s)
    var i: u32 = 0;
    while (i < 180) : (i += 1) {
        _ = ai.update(&flight, &health, &targets, 0.016);
        flight.update(0.016);
    }

    // AI's velocity should have a negative Z component (moving away from threat)
    try testing.expect(flight.velocity.z < 0);
    try testing.expect(flight.afterburner_active);
}

test "AI does not fire while fleeing" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Deplete shields
    _ = health.applyDamage(.front, 75);
    _ = health.applyDamage(.rear, 75);
    _ = health.applyDamage(.left, 55);
    _ = health.applyDamage(.right, 55);

    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 400 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    const action = ai.update(&flight, &health, &targets, 0.016);

    try testing.expectEqual(AiState.flee, ai.state);
    try testing.expect(!action.fire_guns);
    try testing.expect(!action.fire_missile);
}

test "retro AI never flees (flee_threshold = 0)" {
    var ai = AiController.init(ai_presets.retro, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // Deplete shields severely
    _ = health.applyDamage(.front, 79);
    _ = health.applyDamage(.rear, 79);
    _ = health.applyDamage(.left, 59);
    _ = health.applyDamage(.right, 59);

    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 400 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    _ = ai.update(&flight, &health, &targets, 0.016);

    // Retro should never flee
    try testing.expect(ai.state != .flee);
}

// --- State transitions ---

test "AI transitions from patrol to attack when hostile in range" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    try testing.expectEqual(AiState.patrol, ai.state);

    // Hostile target within engagement range
    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 1000 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    _ = ai.update(&flight, &health, &targets, 0.016);

    try testing.expectEqual(AiState.attack, ai.state);
    try testing.expect(ai.target_index != null);
}

test "AI returns to patrol when no targets" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // First: get into attack state
    const targets_with_hostile = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 1000 }, .velocity = Vec3.zero, .faction = .friendly },
    };
    _ = ai.update(&flight, &health, &targets_with_hostile, 0.016);
    try testing.expectEqual(AiState.attack, ai.state);

    // Now: no targets at all
    const no_targets = [_]AiTarget{};
    _ = ai.update(&flight, &health, &no_targets, 0.016);

    try testing.expectEqual(AiState.patrol, ai.state);
    try testing.expect(ai.target_index == null);
}

test "AI ignores friendly targets" {
    // Friendly AI should not attack other friendlies
    var ai = AiController.init(ai_presets.confed, .friendly);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 500 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    _ = ai.update(&flight, &health, &targets, 0.016);

    try testing.expectEqual(AiState.patrol, ai.state);
    try testing.expect(ai.target_index == null);
}

test "friendly AI attacks hostile targets" {
    var ai = AiController.init(ai_presets.confed, .friendly);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 500 }, .velocity = Vec3.zero, .faction = .hostile },
    };

    _ = ai.update(&flight, &health, &targets, 0.016);

    try testing.expectEqual(AiState.attack, ai.state);
    try testing.expectEqual(@as(?usize, 0), ai.target_index);
}

// --- Patrol behavior ---

test "patrol mode sets moderate throttle" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // No targets - stays in patrol
    const no_targets = [_]AiTarget{};
    _ = ai.update(&flight, &health, &no_targets, 0.016);

    try testing.expectEqual(AiState.patrol, ai.state);
    try testing.expectEqual(@as(f32, 0.5), flight.throttle);
}

test "attack mode sets full throttle" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 500 }, .velocity = Vec3.zero, .faction = .friendly },
    };

    _ = ai.update(&flight, &health, &targets, 0.016);

    try testing.expectEqual(AiState.attack, ai.state);
    try testing.expectEqual(@as(f32, 1.0), flight.throttle);
}

// --- Steering helper ---

test "steerToward turns ship toward target position" {
    var flight = FlightState.init(ship_stats.tarsus);

    // Target to the right (+X)
    steerToward(&flight, .{ .x = 1000, .y = 0, .z = 0 }, 2.0, 0.1);

    try testing.expect(flight.yaw > 0);
}

test "steerToward adjusts pitch for target above" {
    var flight = FlightState.init(ship_stats.tarsus);

    // Target above and ahead
    steerToward(&flight, .{ .x = 0, .y = 500, .z = 500 }, 2.0, 0.1);

    try testing.expect(flight.pitch > 0);
}

// --- Engagement edge cases ---

test "AI selects nearest hostile among multiple targets" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    const targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 1000 }, .velocity = Vec3.zero, .faction = .friendly }, // far
        .{ .position = .{ .x = 0, .y = 0, .z = 300 }, .velocity = Vec3.zero, .faction = .friendly }, // near
        .{ .position = .{ .x = 0, .y = 0, .z = 500 }, .velocity = Vec3.zero, .faction = .hostile }, // not hostile to pirate
    };

    _ = ai.update(&flight, &health, &targets, 0.016);

    // Should target the nearest hostile (index 1, the closest friendly - hostile to pirates)
    try testing.expectEqual(@as(?usize, 1), ai.target_index);
}

test "AI drops target that goes out of range" {
    var ai = AiController.init(ai_presets.pirate, .hostile);
    var flight = FlightState.init(ship_stats.tarsus);
    var health = ShipHealth.init(ship_health_specs.tarsus);

    // First: acquire target
    const near_targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 500 }, .velocity = Vec3.zero, .faction = .friendly },
    };
    _ = ai.update(&flight, &health, &near_targets, 0.016);
    try testing.expect(ai.target_index != null);

    // Now: same target but far away (beyond disengage range = 1.5x engagement)
    const far_targets = [_]AiTarget{
        .{ .position = .{ .x = 0, .y = 0, .z = 5000 }, .velocity = Vec3.zero, .faction = .friendly },
    };
    _ = ai.update(&flight, &health, &far_targets, 0.016);
    try testing.expect(ai.target_index == null);
}
