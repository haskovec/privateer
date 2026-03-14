//! Damage model for Wing Commander: Privateer.
//!
//! Handles shield absorption, armor penetration, hit facing determination,
//! and ship destruction detection. Integrates with the projectile collision
//! system (HitResult) and the cockpit damage display (DamageStatus).
//!
//! Damage flow:
//!   1. Projectile hits target → HitResult with damage and hit_position
//!   2. determineFacing() classifies hit as front/rear/left/right
//!   3. ShipHealth.applyDamage() absorbs via shield, then armor
//!   4. ShipHealth.isDestroyed() checks for destruction
//!   5. ShipHealth.toDamageStatus() feeds the cockpit damage display

const std = @import("std");
const flight_physics = @import("../flight/flight_physics.zig");
const damage_display = @import("../cockpit/damage_display.zig");

const Vec3 = flight_physics.Vec3;
const DamageStatus = damage_display.DamageStatus;
const FacingStatus = damage_display.FacingStatus;

/// Ship facing direction (which side was hit).
pub const Facing = enum(u2) {
    front = 0,
    rear = 1,
    left = 2,
    right = 3,
};

/// Maximum shield and armor values defining a ship type's durability.
pub const ShipHealthSpec = struct {
    shield_front: f32,
    shield_rear: f32,
    shield_left: f32,
    shield_right: f32,
    armor_front: f32,
    armor_rear: f32,
    armor_left: f32,
    armor_right: f32,
};

/// Predefined health specs for the four playable ships.
pub const ship_health_specs = struct {
    pub const tarsus = ShipHealthSpec{
        .shield_front = 80,
        .shield_rear = 80,
        .shield_left = 60,
        .shield_right = 60,
        .armor_front = 60,
        .armor_rear = 40,
        .armor_left = 40,
        .armor_right = 40,
    };
    pub const galaxy = ShipHealthSpec{
        .shield_front = 100,
        .shield_rear = 100,
        .shield_left = 80,
        .shield_right = 80,
        .armor_front = 80,
        .armor_rear = 60,
        .armor_left = 60,
        .armor_right = 60,
    };
    pub const orion = ShipHealthSpec{
        .shield_front = 120,
        .shield_rear = 120,
        .shield_left = 100,
        .shield_right = 100,
        .armor_front = 100,
        .armor_rear = 80,
        .armor_left = 80,
        .armor_right = 80,
    };
    pub const centurion = ShipHealthSpec{
        .shield_front = 100,
        .shield_rear = 100,
        .shield_left = 80,
        .shield_right = 80,
        .armor_front = 80,
        .armor_rear = 60,
        .armor_left = 60,
        .armor_right = 60,
    };
};

/// Current health state for a ship.
pub const ShipHealth = struct {
    /// Current shield values per facing (indexed by Facing enum).
    shield: [4]f32,
    /// Current armor values per facing (indexed by Facing enum).
    armor: [4]f32,
    /// Maximum shield values per facing (for normalization to display).
    max_shield: [4]f32,
    /// Maximum armor values per facing (for normalization to display).
    max_armor: [4]f32,

    /// Create a fully healthy ship from a health spec.
    pub fn init(spec: ShipHealthSpec) ShipHealth {
        return .{
            .shield = .{ spec.shield_front, spec.shield_rear, spec.shield_left, spec.shield_right },
            .armor = .{ spec.armor_front, spec.armor_rear, spec.armor_left, spec.armor_right },
            .max_shield = .{ spec.shield_front, spec.shield_rear, spec.shield_left, spec.shield_right },
            .max_armor = .{ spec.armor_front, spec.armor_rear, spec.armor_left, spec.armor_right },
        };
    }

    /// Apply damage to a specific facing. Shield absorbs first; overflow hits armor.
    /// Returns overflow damage past zero armor (0 if fully absorbed).
    pub fn applyDamage(self: *ShipHealth, facing: Facing, amount: f32) f32 {
        const fi: usize = @intFromEnum(facing);

        // Shield absorbs first
        if (self.shield[fi] > 0) {
            if (self.shield[fi] >= amount) {
                self.shield[fi] -= amount;
                return 0;
            }
            const remainder = amount - self.shield[fi];
            self.shield[fi] = 0;
            return self.applyArmorDamage(fi, remainder);
        }

        return self.applyArmorDamage(fi, amount);
    }

    /// Apply damage directly to armor on a facing index.
    fn applyArmorDamage(self: *ShipHealth, fi: usize, amount: f32) f32 {
        if (self.armor[fi] >= amount) {
            self.armor[fi] -= amount;
            return 0;
        }
        const overflow = amount - self.armor[fi];
        self.armor[fi] = 0;
        return overflow;
    }

    /// Check if the ship is destroyed (any facing has zero armor).
    pub fn isDestroyed(self: *const ShipHealth) bool {
        for (self.armor) |a| {
            if (a <= 0) return true;
        }
        return false;
    }

    /// Get current shield value for a facing.
    pub fn getShield(self: *const ShipHealth, facing: Facing) f32 {
        return self.shield[@intFromEnum(facing)];
    }

    /// Get current armor value for a facing.
    pub fn getArmor(self: *const ShipHealth, facing: Facing) f32 {
        return self.armor[@intFromEnum(facing)];
    }

    /// Convert to normalized DamageStatus for the cockpit damage display.
    pub fn toDamageStatus(self: *const ShipHealth) DamageStatus {
        return .{
            .front = self.facingStatus(.front),
            .rear = self.facingStatus(.rear),
            .left = self.facingStatus(.left),
            .right = self.facingStatus(.right),
        };
    }

    fn facingStatus(self: *const ShipHealth, facing: Facing) FacingStatus {
        const fi: usize = @intFromEnum(facing);
        return .{
            .shield = if (self.max_shield[fi] > 0) self.shield[fi] / self.max_shield[fi] else 0,
            .armor = if (self.max_armor[fi] > 0) self.armor[fi] / self.max_armor[fi] else 0,
        };
    }
};

/// Determine which facing of a target was hit based on the hit position,
/// the target's position, and the target's yaw angle.
///
/// Projects the hit vector onto the target's local forward and right axes,
/// then picks the dominant direction.
pub fn determineFacing(
    hit_position: Vec3,
    target_position: Vec3,
    target_yaw: f32,
) Facing {
    // Vector from target center to hit point
    const to_hit = hit_position.sub(target_position);

    // Target's local axes (yaw only, ignoring pitch for facing classification)
    const cos_yaw = @cos(target_yaw);
    const sin_yaw = @sin(target_yaw);
    const fwd = Vec3{ .x = sin_yaw, .y = 0, .z = cos_yaw };
    const right_dir = Vec3{ .x = cos_yaw, .y = 0, .z = -sin_yaw };

    // Project onto local axes
    const forward_dot = to_hit.dot(fwd);
    const right_dot = to_hit.dot(right_dir);

    const abs_fwd = @abs(forward_dot);
    const abs_right = @abs(right_dot);

    if (abs_fwd >= abs_right) {
        return if (forward_dot >= 0) .front else .rear;
    } else {
        return if (right_dot >= 0) .right else .left;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

// --- ShipHealth creation ---

test "ShipHealth.init creates fully healthy ship" {
    const health = ShipHealth.init(ship_health_specs.tarsus);
    try testing.expectEqual(@as(f32, 80), health.getShield(.front));
    try testing.expectEqual(@as(f32, 80), health.getShield(.rear));
    try testing.expectEqual(@as(f32, 60), health.getShield(.left));
    try testing.expectEqual(@as(f32, 60), health.getShield(.right));
    try testing.expectEqual(@as(f32, 60), health.getArmor(.front));
    try testing.expectEqual(@as(f32, 40), health.getArmor(.rear));
    try testing.expectEqual(@as(f32, 40), health.getArmor(.left));
    try testing.expectEqual(@as(f32, 40), health.getArmor(.right));
}

test "new ship is not destroyed" {
    const health = ShipHealth.init(ship_health_specs.tarsus);
    try testing.expect(!health.isDestroyed());
}

// --- Shield damage ---

test "gun hit reduces target shield on hit facing" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    const overflow = health.applyDamage(.front, 20);
    try testing.expectEqual(@as(f32, 0), overflow);
    try testing.expectEqual(@as(f32, 60), health.getShield(.front));
    // Other facings untouched
    try testing.expectEqual(@as(f32, 80), health.getShield(.rear));
    try testing.expectEqual(@as(f32, 60), health.getArmor(.front));
}

test "multiple hits drain shield progressively" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    _ = health.applyDamage(.front, 30);
    try testing.expectEqual(@as(f32, 50), health.getShield(.front));
    _ = health.applyDamage(.front, 30);
    try testing.expectEqual(@as(f32, 20), health.getShield(.front));
    // Armor still untouched
    try testing.expectEqual(@as(f32, 60), health.getArmor(.front));
}

test "shield fully absorbs damage when sufficient" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    _ = health.applyDamage(.front, 80); // Exact shield value
    try testing.expectEqual(@as(f32, 0), health.getShield(.front));
    try testing.expectEqual(@as(f32, 60), health.getArmor(.front)); // Armor untouched
}

// --- Armor damage (shield overflow) ---

test "hit on depleted shield damages armor" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    // Deplete front shield
    _ = health.applyDamage(.front, 80);
    try testing.expectEqual(@as(f32, 0), health.getShield(.front));

    // Next hit goes straight to armor
    _ = health.applyDamage(.front, 15);
    try testing.expectEqual(@as(f32, 45), health.getArmor(.front));
}

test "damage overflows from shield to armor in single hit" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    // Front shield = 80, front armor = 60
    // Hit for 100: 80 absorbed by shield, 20 hits armor
    _ = health.applyDamage(.front, 100);
    try testing.expectEqual(@as(f32, 0), health.getShield(.front));
    try testing.expectEqual(@as(f32, 40), health.getArmor(.front));
}

test "overflow damage past zero armor is returned" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    // Front shield=80, front armor=60 → total 140
    // Hit for 160: overflow = 20
    const overflow = health.applyDamage(.front, 160);
    try testing.expectApproxEqAbs(@as(f32, 20), overflow, 0.01);
    try testing.expectEqual(@as(f32, 0), health.getShield(.front));
    try testing.expectEqual(@as(f32, 0), health.getArmor(.front));
}

// --- Ship destruction ---

test "ship destruction at zero armor" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    try testing.expect(!health.isDestroyed());

    // Destroy front facing (shield 80 + armor 60 = 140)
    _ = health.applyDamage(.front, 140);
    try testing.expect(health.isDestroyed());
}

test "ship not destroyed with shields down but armor intact" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    // Deplete all shields
    _ = health.applyDamage(.front, 80);
    _ = health.applyDamage(.rear, 80);
    _ = health.applyDamage(.left, 60);
    _ = health.applyDamage(.right, 60);
    // All shields gone but armor intact
    try testing.expect(!health.isDestroyed());
}

test "destruction on any single facing triggers destroyed" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    // Only destroy rear facing (shield 80 + armor 40 = 120)
    _ = health.applyDamage(.rear, 120);
    try testing.expectEqual(@as(f32, 0), health.getArmor(.rear));
    try testing.expect(health.isDestroyed());
    // Other facings still have armor
    try testing.expect(health.getArmor(.front) > 0);
}

// --- Damage to different facings ---

test "damage to different facings is independent" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    _ = health.applyDamage(.front, 30);
    _ = health.applyDamage(.rear, 20);
    _ = health.applyDamage(.left, 10);
    _ = health.applyDamage(.right, 40);

    try testing.expectEqual(@as(f32, 50), health.getShield(.front));
    try testing.expectEqual(@as(f32, 60), health.getShield(.rear));
    try testing.expectEqual(@as(f32, 50), health.getShield(.left));
    try testing.expectEqual(@as(f32, 20), health.getShield(.right));
}

// --- DamageStatus conversion ---

test "toDamageStatus returns normalized values" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    // Take 40 front shield damage (80 → 40 = 50%)
    _ = health.applyDamage(.front, 40);

    const status = health.toDamageStatus();
    try testing.expectApproxEqAbs(@as(f32, 0.5), status.front.shield, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), status.front.armor, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), status.rear.shield, 0.01);
}

test "toDamageStatus shows zero for depleted values" {
    var health = ShipHealth.init(ship_health_specs.tarsus);
    _ = health.applyDamage(.front, 140); // Deplete shield + armor
    const status = health.toDamageStatus();
    try testing.expectEqual(@as(f32, 0), status.front.shield);
    try testing.expectEqual(@as(f32, 0), status.front.armor);
}

test "full health produces all-1.0 DamageStatus" {
    const health = ShipHealth.init(ship_health_specs.centurion);
    const status = health.toDamageStatus();
    try testing.expectEqual(@as(f32, 1.0), status.front.shield);
    try testing.expectEqual(@as(f32, 1.0), status.front.armor);
    try testing.expectEqual(@as(f32, 1.0), status.rear.shield);
    try testing.expectEqual(@as(f32, 1.0), status.rear.armor);
    try testing.expectEqual(@as(f32, 1.0), status.left.shield);
    try testing.expectEqual(@as(f32, 1.0), status.left.armor);
    try testing.expectEqual(@as(f32, 1.0), status.right.shield);
    try testing.expectEqual(@as(f32, 1.0), status.right.armor);
}

// --- Hit facing determination ---

test "hit from front classified as front facing" {
    // Target at origin facing +Z (yaw=0), hit in front (+Z)
    const facing = determineFacing(
        .{ .x = 0, .y = 0, .z = 5 },
        Vec3.zero,
        0,
    );
    try testing.expectEqual(Facing.front, facing);
}

test "hit from rear classified as rear facing" {
    // Target at origin facing +Z, hit from behind (-Z)
    const facing = determineFacing(
        .{ .x = 0, .y = 0, .z = -5 },
        Vec3.zero,
        0,
    );
    try testing.expectEqual(Facing.rear, facing);
}

test "hit from left classified as left facing" {
    // Target at origin facing +Z, hit from left (-X)
    const facing = determineFacing(
        .{ .x = -5, .y = 0, .z = 0 },
        Vec3.zero,
        0,
    );
    try testing.expectEqual(Facing.left, facing);
}

test "hit from right classified as right facing" {
    // Target at origin facing +Z, hit from right (+X)
    const facing = determineFacing(
        .{ .x = 5, .y = 0, .z = 0 },
        Vec3.zero,
        0,
    );
    try testing.expectEqual(Facing.right, facing);
}

test "facing accounts for target yaw rotation" {
    // Target facing +X (yaw = pi/2), hit from +X direction = front
    const facing = determineFacing(
        .{ .x = 5, .y = 0, .z = 0 },
        Vec3.zero,
        std.math.pi / 2.0,
    );
    try testing.expectEqual(Facing.front, facing);
}

test "facing with rotated target rear hit" {
    // Target facing +X (yaw = pi/2), hit from -X = rear
    const facing = determineFacing(
        .{ .x = -5, .y = 0, .z = 0 },
        Vec3.zero,
        std.math.pi / 2.0,
    );
    try testing.expectEqual(Facing.rear, facing);
}

test "facing ignores Y component of hit position" {
    // Hit from above-front still counts as front
    const facing = determineFacing(
        .{ .x = 0, .y = 10, .z = 5 },
        Vec3.zero,
        0,
    );
    try testing.expectEqual(Facing.front, facing);
}

// --- Ship health spec presets ---

test "all ship health specs have positive values" {
    const specs = [_]ShipHealthSpec{
        ship_health_specs.tarsus,
        ship_health_specs.galaxy,
        ship_health_specs.orion,
        ship_health_specs.centurion,
    };
    for (specs) |spec| {
        try testing.expect(spec.shield_front > 0);
        try testing.expect(spec.shield_rear > 0);
        try testing.expect(spec.armor_front > 0);
        try testing.expect(spec.armor_rear > 0);
        try testing.expect(spec.armor_left > 0);
        try testing.expect(spec.armor_right > 0);
    }
}

test "orion is toughest ship" {
    const orion = ship_health_specs.orion;
    const tarsus = ship_health_specs.tarsus;
    try testing.expect(orion.shield_front > tarsus.shield_front);
    try testing.expect(orion.armor_front > tarsus.armor_front);
}
