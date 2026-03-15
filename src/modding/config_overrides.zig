//! Config override system for game balance values.
//! Loads JSON override files from the mod directory that allow tweaking
//! hardcoded game constants (ship stats, trade-in multiplier, missile lifetime).
//!
//! JSON format:
//!   {
//!     "ship_stats": {
//!       "tarsus": {"max_speed": 300.0, "thrust": 200.0},
//!       "centurion": {"afterburner_speed": 600.0}
//!     },
//!     "trade_in_multiplier": 0.6,
//!     "missile_lifetime": 12.0
//!   }
//! All fields are optional — only specified values are overridden.

const std = @import("std");
const flight_physics = @import("../flight/flight_physics.zig");

pub const ConfigOverrideError = error{
    InvalidJson,
    InvalidConfig,
    ReadError,
    OutOfMemory,
};

/// Default values for overridable game constants.
pub const defaults = struct {
    pub const trade_in_multiplier: f32 = 0.5;
    pub const missile_lifetime: f32 = 10.0;
};

/// Ship names recognized in the override file.
pub const ShipName = enum {
    tarsus,
    galaxy,
    orion,
    centurion,
};

/// All overridable game balance values.
pub const ConfigOverrides = struct {
    /// Per-ship stat overrides (null = use built-in default).
    ship_stats: [4]flight_physics.ShipStats,
    /// Whether each ship has been overridden.
    ship_overridden: [4]bool,
    /// Trade-in/sell price multiplier (default 0.5 = 50%).
    trade_in_multiplier: f32,
    /// Missile projectile lifetime in seconds.
    missile_lifetime: f32,

    /// Create a ConfigOverrides with all default values (no overrides active).
    pub fn initDefaults() ConfigOverrides {
        return .{
            .ship_stats = .{
                flight_physics.ship_stats.tarsus,
                flight_physics.ship_stats.galaxy,
                flight_physics.ship_stats.orion,
                flight_physics.ship_stats.centurion,
            },
            .ship_overridden = .{ false, false, false, false },
            .trade_in_multiplier = defaults.trade_in_multiplier,
            .missile_lifetime = defaults.missile_lifetime,
        };
    }

    /// Get ship stats for the given ship, with any overrides applied.
    pub fn getShipStats(self: *const ConfigOverrides, ship: ShipName) flight_physics.ShipStats {
        return self.ship_stats[@intFromEnum(ship)];
    }

    /// Check if a specific ship's stats have been overridden.
    pub fn isShipOverridden(self: *const ConfigOverrides, ship: ShipName) bool {
        return self.ship_overridden[@intFromEnum(ship)];
    }
};

/// Parse a config overrides JSON string.
/// Only fields present in the JSON are applied; missing fields keep defaults.
pub fn parseOverrides(json_str: []const u8) ConfigOverrideError!ConfigOverrides {
    var overrides = ConfigOverrides.initDefaults();

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_str, .{}) catch return ConfigOverrideError.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return ConfigOverrideError.InvalidConfig;

    // Parse trade_in_multiplier
    if (root.object.get("trade_in_multiplier")) |v| {
        overrides.trade_in_multiplier = jsonToF32(v) orelse return ConfigOverrideError.InvalidConfig;
    }

    // Parse missile_lifetime
    if (root.object.get("missile_lifetime")) |v| {
        overrides.missile_lifetime = jsonToF32(v) orelse return ConfigOverrideError.InvalidConfig;
    }

    // Parse ship_stats
    if (root.object.get("ship_stats")) |ship_stats_val| {
        if (ship_stats_val != .object) return ConfigOverrideError.InvalidConfig;

        const ship_names = [_]struct { name: []const u8, idx: usize }{
            .{ .name = "tarsus", .idx = 0 },
            .{ .name = "galaxy", .idx = 1 },
            .{ .name = "orion", .idx = 2 },
            .{ .name = "centurion", .idx = 3 },
        };

        for (ship_names) |entry| {
            if (ship_stats_val.object.get(entry.name)) |ship_val| {
                if (ship_val != .object) return ConfigOverrideError.InvalidConfig;
                try applyShipOverride(&overrides.ship_stats[entry.idx], ship_val.object);
                overrides.ship_overridden[entry.idx] = true;
            }
        }
    }

    return overrides;
}

/// Load config overrides from a JSON file. Returns defaults if file doesn't exist.
pub fn loadFromFile(path: []const u8) ConfigOverrideError!ConfigOverrides {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return ConfigOverrides.initDefaults();
        return ConfigOverrideError.ReadError;
    };
    defer file.close();

    const stat = file.stat() catch return ConfigOverrideError.ReadError;
    if (stat.size > 1024 * 1024) return ConfigOverrideError.InvalidConfig;
    const content = std.heap.page_allocator.alloc(u8, stat.size) catch return ConfigOverrideError.OutOfMemory;
    defer std.heap.page_allocator.free(content);
    const bytes_read = file.readAll(content) catch return ConfigOverrideError.ReadError;

    return parseOverrides(content[0..bytes_read]);
}

/// Apply individual ship stat overrides from a JSON object.
fn applyShipOverride(stats: *flight_physics.ShipStats, obj: std.json.ObjectMap) ConfigOverrideError!void {
    if (obj.get("max_speed")) |v| {
        stats.max_speed = jsonToF32(v) orelse return ConfigOverrideError.InvalidConfig;
    }
    if (obj.get("afterburner_speed")) |v| {
        stats.afterburner_speed = jsonToF32(v) orelse return ConfigOverrideError.InvalidConfig;
    }
    if (obj.get("thrust")) |v| {
        stats.thrust = jsonToF32(v) orelse return ConfigOverrideError.InvalidConfig;
    }
    if (obj.get("rotation_rate")) |v| {
        stats.rotation_rate = jsonToF32(v) orelse return ConfigOverrideError.InvalidConfig;
    }
}

/// Convert a JSON value to f32, handling both integer and float JSON numbers.
fn jsonToF32(v: std.json.Value) ?f32 {
    return switch (v) {
        .float => @floatCast(v.float),
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

// --- Tests ---

test "initDefaults returns built-in values" {
    const cfg = ConfigOverrides.initDefaults();

    try std.testing.expectEqual(defaults.trade_in_multiplier, cfg.trade_in_multiplier);
    try std.testing.expectEqual(defaults.missile_lifetime, cfg.missile_lifetime);
    try std.testing.expectEqual(flight_physics.ship_stats.tarsus.max_speed, cfg.getShipStats(.tarsus).max_speed);
    try std.testing.expectEqual(flight_physics.ship_stats.centurion.thrust, cfg.getShipStats(.centurion).thrust);
    try std.testing.expect(!cfg.isShipOverridden(.tarsus));
    try std.testing.expect(!cfg.isShipOverridden(.centurion));
}

test "parseOverrides with empty JSON returns defaults" {
    const cfg = try parseOverrides("{}");

    try std.testing.expectEqual(defaults.trade_in_multiplier, cfg.trade_in_multiplier);
    try std.testing.expectEqual(defaults.missile_lifetime, cfg.missile_lifetime);
    try std.testing.expect(!cfg.isShipOverridden(.tarsus));
}

test "parseOverrides changes trade_in_multiplier" {
    const json =
        \\{"trade_in_multiplier": 0.75}
    ;
    const cfg = try parseOverrides(json);

    try std.testing.expectApproxEqAbs(@as(f32, 0.75), cfg.trade_in_multiplier, 0.001);
    // Other values remain default
    try std.testing.expectEqual(defaults.missile_lifetime, cfg.missile_lifetime);
}

test "parseOverrides changes missile_lifetime" {
    const json =
        \\{"missile_lifetime": 15.0}
    ;
    const cfg = try parseOverrides(json);

    try std.testing.expectApproxEqAbs(@as(f32, 15.0), cfg.missile_lifetime, 0.001);
}

test "parseOverrides overrides ship max_speed" {
    const json =
        \\{"ship_stats": {"tarsus": {"max_speed": 300.0}}}
    ;
    const cfg = try parseOverrides(json);

    try std.testing.expectApproxEqAbs(@as(f32, 300.0), cfg.getShipStats(.tarsus).max_speed, 0.001);
    // Other tarsus stats remain default
    try std.testing.expectEqual(flight_physics.ship_stats.tarsus.thrust, cfg.getShipStats(.tarsus).thrust);
    try std.testing.expect(cfg.isShipOverridden(.tarsus));
    // Galaxy not overridden
    try std.testing.expect(!cfg.isShipOverridden(.galaxy));
    try std.testing.expectEqual(flight_physics.ship_stats.galaxy.max_speed, cfg.getShipStats(.galaxy).max_speed);
}

test "parseOverrides handles multiple ship overrides" {
    const json =
        \\{
        \\  "ship_stats": {
        \\    "tarsus": {"max_speed": 300.0, "thrust": 200.0},
        \\    "centurion": {"afterburner_speed": 600.0, "rotation_rate": 2.5}
        \\  }
        \\}
    ;
    const cfg = try parseOverrides(json);

    // Tarsus overrides
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), cfg.getShipStats(.tarsus).max_speed, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), cfg.getShipStats(.tarsus).thrust, 0.001);
    // Tarsus non-overridden stats stay default
    try std.testing.expectEqual(flight_physics.ship_stats.tarsus.afterburner_speed, cfg.getShipStats(.tarsus).afterburner_speed);

    // Centurion overrides
    try std.testing.expectApproxEqAbs(@as(f32, 600.0), cfg.getShipStats(.centurion).afterburner_speed, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), cfg.getShipStats(.centurion).rotation_rate, 0.001);
    // Centurion non-overridden stats stay default
    try std.testing.expectEqual(flight_physics.ship_stats.centurion.max_speed, cfg.getShipStats(.centurion).max_speed);
}

test "parseOverrides handles integer values" {
    const json =
        \\{"trade_in_multiplier": 1, "missile_lifetime": 20}
    ;
    const cfg = try parseOverrides(json);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.trade_in_multiplier, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), cfg.missile_lifetime, 0.001);
}

test "parseOverrides rejects non-object root" {
    const result = parseOverrides("\"not an object\"");
    try std.testing.expectError(ConfigOverrideError.InvalidConfig, result);
}

test "parseOverrides rejects non-numeric trade_in_multiplier" {
    const json =
        \\{"trade_in_multiplier": "fast"}
    ;
    const result = parseOverrides(json);
    try std.testing.expectError(ConfigOverrideError.InvalidConfig, result);
}

test "parseOverrides rejects non-object ship_stats" {
    const json =
        \\{"ship_stats": "invalid"}
    ;
    const result = parseOverrides(json);
    try std.testing.expectError(ConfigOverrideError.InvalidConfig, result);
}

test "parseOverrides rejects non-object ship entry" {
    const json =
        \\{"ship_stats": {"tarsus": 42}}
    ;
    const result = parseOverrides(json);
    try std.testing.expectError(ConfigOverrideError.InvalidConfig, result);
}

test "loadFromFile returns defaults for missing file" {
    const cfg = try loadFromFile("nonexistent_balance_override_file.json");

    try std.testing.expectEqual(defaults.trade_in_multiplier, cfg.trade_in_multiplier);
    try std.testing.expectEqual(defaults.missile_lifetime, cfg.missile_lifetime);
}

test "parseOverrides with all fields" {
    const json =
        \\{
        \\  "trade_in_multiplier": 0.6,
        \\  "missile_lifetime": 12.0,
        \\  "ship_stats": {
        \\    "tarsus": {"max_speed": 280.0, "afterburner_speed": 500.0, "thrust": 190.0, "rotation_rate": 2.0},
        \\    "galaxy": {"max_speed": 220.0},
        \\    "orion": {"thrust": 150.0},
        \\    "centurion": {"afterburner_speed": 550.0}
        \\  }
        \\}
    ;
    const cfg = try parseOverrides(json);

    try std.testing.expectApproxEqAbs(@as(f32, 0.6), cfg.trade_in_multiplier, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), cfg.missile_lifetime, 0.001);

    try std.testing.expectApproxEqAbs(@as(f32, 280.0), cfg.getShipStats(.tarsus).max_speed, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), cfg.getShipStats(.tarsus).afterburner_speed, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 190.0), cfg.getShipStats(.tarsus).thrust, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), cfg.getShipStats(.tarsus).rotation_rate, 0.001);

    try std.testing.expectApproxEqAbs(@as(f32, 220.0), cfg.getShipStats(.galaxy).max_speed, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150.0), cfg.getShipStats(.orion).thrust, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 550.0), cfg.getShipStats(.centurion).afterburner_speed, 0.001);

    try std.testing.expect(cfg.isShipOverridden(.tarsus));
    try std.testing.expect(cfg.isShipOverridden(.galaxy));
    try std.testing.expect(cfg.isShipOverridden(.orion));
    try std.testing.expect(cfg.isShipOverridden(.centurion));
}
