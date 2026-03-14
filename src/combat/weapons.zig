//! Weapon system for Wing Commander: Privateer.
//!
//! Parses weapon data from GUNS.IFF and WEAPONS.IFF and provides
//! the data types for guns, missiles, launchers, and projectiles.
//!
//! GUNS.IFF structure:
//!   FORM:GUNS
//!     TABL (N * u32 LE offsets to gun records)
//!     Gun records (u32 LE size + UNIT IFF chunk)
//!
//! WEAPONS.IFF structure:
//!   FORM:WEAP
//!     FORM:LNCH (launcher types with UNIT chunks)
//!     FORM:MISL (missile types with UNIT chunks)

const std = @import("std");
const iff = @import("../formats/iff.zig");
const flight_physics = @import("../flight/flight_physics.zig");

const Vec3 = flight_physics.Vec3;

// ── Data Types ──────────────────────────────────────────────────────

/// Gun type definition loaded from GUNS.IFF.
pub const GunType = struct {
    /// Gun type index (0-10 in original game).
    index: u8,
    /// Short name (e.g. "Lasr", "Mass").
    short_name: [5]u8,
    /// Type filename reference (8 chars, e.g. "LASRTYPE").
    type_file: [8]u8,
    /// Display name (e.g. "LASER", "PLASMA").
    display_name: [8]u8,
    /// Projectile speed (units per second).
    speed: u16,
    /// Damage per hit.
    damage: u16,
    /// Energy cost per shot.
    energy_cost: u16,
    /// Refire delay factor.
    refire_delay: u8,
    /// Velocity factor.
    velocity_factor: u16,
    /// Weapon range.
    range: u16,
};

/// Tracking type for missiles.
pub const TrackingType = enum(u8) {
    dumbfire = 1,
    heat_seeking = 2,
    image_recognition = 3,
    friend_or_foe = 4,
    torpedo = 5,
    _,
};

/// Missile type definition loaded from WEAPONS.IFF.
pub const MissileType = struct {
    /// Missile type ID.
    id: u8,
    /// Short name (8 chars, e.g. "HeatSeek").
    short_name: [8]u8,
    /// Type filename reference (8 chars, e.g. "MSSLTYPE").
    type_file: [8]u8,
    /// Display name (8 chars, e.g. "HEATSEEK").
    display_name: [8]u8,
    /// Projectile speed.
    speed: u16,
    /// Lock type.
    lock_type: u8,
    /// Lock-on range (0 for unguided).
    lock_range: u16,
    /// Damage on hit.
    damage: u16,
    /// Tracking behavior type.
    tracking: TrackingType,
};

/// Launcher type definition loaded from WEAPONS.IFF.
pub const LauncherType = struct {
    /// Launcher type ID (0x32=missile, 0x33=torpedo, 0x34=tractor).
    id: u8,
    /// First parameter value.
    value1: u16,
    /// Second parameter value.
    value2: u16,
};

/// A live projectile in the game world.
pub const Projectile = struct {
    /// World-space position.
    position: Vec3,
    /// Velocity vector (direction * speed).
    velocity: Vec3,
    /// Remaining lifetime in seconds.
    lifetime: f32,
    /// Damage this projectile deals on impact.
    damage: u16,
    /// Whether this is a missile (tracked) or gun projectile (linear).
    is_missile: bool,
    /// Tracking type for missiles.
    tracking: TrackingType,
    /// Target index for guided missiles (null for dumbfire/guns).
    target_index: ?usize,

    /// Update projectile position for one frame.
    /// Returns true if the projectile is still alive.
    pub fn update(self: *Projectile, dt: f32) bool {
        self.position = self.position.add(self.velocity.scale(dt));
        self.lifetime -= dt;
        return self.lifetime > 0;
    }
};

/// Complete weapon data loaded from game files.
pub const WeaponData = struct {
    gun_types: []GunType,
    missile_types: []MissileType,
    launcher_types: []LauncherType,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WeaponData) void {
        self.allocator.free(self.gun_types);
        self.allocator.free(self.missile_types);
        self.allocator.free(self.launcher_types);
    }

    /// Find a gun type by index.
    pub fn findGun(self: *const WeaponData, index: u8) ?*const GunType {
        for (self.gun_types) |*g| {
            if (g.index == index) return g;
        }
        return null;
    }

    /// Find a missile type by ID.
    pub fn findMissile(self: *const WeaponData, id: u8) ?*const MissileType {
        for (self.missile_types) |*m| {
            if (m.id == id) return m;
        }
        return null;
    }

    /// Find a launcher type by ID.
    pub fn findLauncher(self: *const WeaponData, id: u8) ?*const LauncherType {
        for (self.launcher_types) |*l| {
            if (l.id == id) return l;
        }
        return null;
    }
};

// ── Projectile Creation ─────────────────────────────────────────────

/// Create a gun projectile fired from a ship.
pub fn fireGun(
    gun: *const GunType,
    position: Vec3,
    direction: Vec3,
) Projectile {
    const speed_f: f32 = @floatFromInt(gun.speed);
    const vel = direction.normalize().scale(speed_f);
    const range_f: f32 = @floatFromInt(gun.range);
    const lifetime = if (speed_f > 0) range_f / speed_f else 1.0;

    return .{
        .position = position,
        .velocity = vel,
        .lifetime = lifetime,
        .damage = gun.damage,
        .is_missile = false,
        .tracking = .dumbfire,
        .target_index = null,
    };
}

/// Create a missile projectile launched from a ship.
pub fn fireMissile(
    missile: *const MissileType,
    position: Vec3,
    direction: Vec3,
    target_index: ?usize,
) Projectile {
    const speed_f: f32 = @floatFromInt(missile.speed);
    const vel = direction.normalize().scale(speed_f);
    // Missiles have longer lifetime than guns
    const lifetime: f32 = 10.0;

    return .{
        .position = position,
        .velocity = vel,
        .lifetime = lifetime,
        .damage = missile.damage,
        .is_missile = true,
        .tracking = missile.tracking,
        .target_index = target_index,
    };
}

// ── Parsers ─────────────────────────────────────────────────────────

pub const WeaponError = error{
    InvalidFormat,
    MissingData,
    OutOfMemory,
};

/// Parse gun types from GUNS.IFF data.
///
/// The file has FORM:GUNS with a TABL of offsets followed by
/// raw gun records (u32 LE size + UNIT IFF chunk).
pub fn parseGuns(allocator: std.mem.Allocator, data: []const u8) WeaponError![]GunType {
    // Minimum: FORM(4) + size(4) + GUNS(4) + TABL(4) + tabl_size(4) + at_least_4_bytes
    if (data.len < 24) return WeaponError.InvalidFormat;

    // Check FORM:GUNS header
    if (!std.mem.eql(u8, data[0..4], "FORM")) return WeaponError.InvalidFormat;
    if (!std.mem.eql(u8, data[8..12], "GUNS")) return WeaponError.InvalidFormat;

    // Parse TABL chunk
    if (!std.mem.eql(u8, data[12..16], "TABL")) return WeaponError.InvalidFormat;
    const tabl_size = std.mem.readInt(u32, data[16..20], .big);
    if (tabl_size % 4 != 0) return WeaponError.InvalidFormat;

    const num_guns = tabl_size / 4;
    if (num_guns == 0) return WeaponError.MissingData;

    // Read offsets
    const tabl_start: usize = 20;
    const guns = allocator.alloc(GunType, num_guns) catch return WeaponError.OutOfMemory;
    errdefer allocator.free(guns);

    for (0..num_guns) |i| {
        const off_pos = tabl_start + i * 4;
        if (off_pos + 4 > data.len) return WeaponError.InvalidFormat;
        const offset = std.mem.readInt(u32, data[off_pos..][0..4], .little);

        guns[i] = try parseGunRecord(data, offset, @intCast(i));
    }

    return guns;
}

/// Parse a single gun record at the given file offset.
fn parseGunRecord(data: []const u8, offset: u32, index: u8) WeaponError!GunType {
    const pos: usize = offset;

    // Skip u32 LE record_data_size
    if (pos + 4 > data.len) return WeaponError.InvalidFormat;

    // Check UNIT tag
    if (pos + 12 > data.len) return WeaponError.InvalidFormat;
    if (!std.mem.eql(u8, data[pos + 4 .. pos + 8], "UNIT")) return WeaponError.InvalidFormat;

    const unit_size = std.mem.readInt(u32, data[pos + 8 ..][0..4], .big);
    const unit_start = pos + 12;
    if (unit_start + unit_size > data.len) return WeaponError.InvalidFormat;
    if (unit_size < 39) return WeaponError.InvalidFormat;

    const ud = data[unit_start .. unit_start + unit_size];

    // String section: 21 bytes
    var short_name: [5]u8 = .{ 0, 0, 0, 0, 0 };
    var type_file: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var display_name: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };

    // Short name: bytes 0-4 (null-terminated, max 5 bytes incl null)
    const short_end = std.mem.indexOfScalar(u8, ud[0..5], 0) orelse 4;
    @memcpy(short_name[0..short_end], ud[0..short_end]);

    // Type filename: bytes after short_name null, always 8 bytes
    const type_start = short_end + 1;
    if (type_start + 8 > 21) return WeaponError.InvalidFormat;
    @memcpy(&type_file, ud[type_start .. type_start + 8]);

    // Display name: remaining bytes up to byte 21
    const disp_start = type_start + 8;
    const disp_end_max: usize = 21;
    const disp_data = ud[disp_start..disp_end_max];
    const disp_len = std.mem.indexOfScalar(u8, disp_data, 0) orelse disp_data.len;
    const copy_len = @min(disp_len, 8);
    @memcpy(display_name[0..copy_len], disp_data[0..copy_len]);

    // Stats: bytes 21-38 (18 bytes)
    const stats = ud[21..39];

    return GunType{
        .index = index,
        .short_name = short_name,
        .type_file = type_file,
        .display_name = display_name,
        .velocity_factor = std.mem.readInt(u16, stats[0..2], .little),
        .speed = std.mem.readInt(u16, stats[3..5], .little),
        .range = std.mem.readInt(u16, stats[6..8], .little),
        .energy_cost = std.mem.readInt(u16, stats[10..12], .little),
        .refire_delay = stats[14],
        .damage = std.mem.readInt(u16, stats[16..18], .little),
    };
}

/// Parse launcher and missile types from WEAPONS.IFF data.
///
/// Returns a struct with both launcher_types and missile_types arrays.
pub fn parseWeapons(allocator: std.mem.Allocator, data: []const u8) WeaponError!struct {
    launcher_types: []LauncherType,
    missile_types: []MissileType,
} {
    var root = iff.parseFile(allocator, data) catch return WeaponError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return WeaponError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "WEAP")) return WeaponError.InvalidFormat;

    // Parse FORM:LNCH for launcher types
    const lnch_form = root.findForm("LNCH".*) orelse return WeaponError.MissingData;
    const launcher_units = lnch_form.findChildren(allocator, "UNIT".*) catch return WeaponError.OutOfMemory;
    defer allocator.free(launcher_units);

    const launchers = allocator.alloc(LauncherType, launcher_units.len) catch return WeaponError.OutOfMemory;
    errdefer allocator.free(launchers);

    for (launcher_units, 0..) |unit, i| {
        if (unit.data.len < 7) return WeaponError.InvalidFormat;
        launchers[i] = .{
            .id = unit.data[0],
            .value1 = std.mem.readInt(u16, unit.data[1..3], .little),
            .value2 = std.mem.readInt(u16, unit.data[3..5], .little),
        };
    }

    // Parse FORM:MISL for missile types
    const misl_form = root.findForm("MISL".*) orelse return WeaponError.MissingData;
    const missile_units = misl_form.findChildren(allocator, "UNIT".*) catch return WeaponError.OutOfMemory;
    defer allocator.free(missile_units);

    const missiles = allocator.alloc(MissileType, missile_units.len) catch return WeaponError.OutOfMemory;
    errdefer allocator.free(missiles);

    for (missile_units, 0..) |unit, i| {
        if (unit.data.len < 35) return WeaponError.InvalidFormat;
        const d = unit.data;
        var short_name: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var type_file: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var display_name: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        @memcpy(&short_name, d[1..9]);
        @memcpy(&type_file, d[9..17]);
        @memcpy(&display_name, d[17..25]);

        missiles[i] = .{
            .id = d[0],
            .short_name = short_name,
            .type_file = type_file,
            .display_name = display_name,
            .speed = std.mem.readInt(u16, d[25..27], .little),
            .lock_type = d[27],
            .lock_range = std.mem.readInt(u16, d[29..31], .little),
            .damage = std.mem.readInt(u16, d[31..33], .little),
            .tracking = @enumFromInt(d[33]),
        };
    }

    return .{
        .launcher_types = launchers,
        .missile_types = missiles,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const testing_helpers = @import("../testing.zig");

// --- Gun parsing ---

test "parseGuns loads 3 guns from fixture" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_guns.bin");
    defer allocator.free(data);

    const guns = try parseGuns(allocator, data);
    defer allocator.free(guns);

    try testing.expectEqual(@as(usize, 3), guns.len);
}

test "parseGuns gun 0 is Laser with correct stats" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_guns.bin");
    defer allocator.free(data);

    const guns = try parseGuns(allocator, data);
    defer allocator.free(guns);

    const laser = guns[0];
    try testing.expectEqual(@as(u8, 0), laser.index);
    try testing.expectEqualStrings("Lasr", laser.short_name[0..4]);
    try testing.expectEqualStrings("LASRTYPE", &laser.type_file);
    try testing.expectEqualStrings("LASER", laser.display_name[0..5]);
    try testing.expectEqual(@as(u16, 1400), laser.speed);
    try testing.expectEqual(@as(u16, 20), laser.damage);
    try testing.expectEqual(@as(u16, 76), laser.energy_cost);
    try testing.expectEqual(@as(u8, 4), laser.refire_delay);
}

test "parseGuns gun 2 is Plasma with correct stats" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_guns.bin");
    defer allocator.free(data);

    const guns = try parseGuns(allocator, data);
    defer allocator.free(guns);

    const plasma = guns[2];
    try testing.expectEqual(@as(u8, 2), plasma.index);
    try testing.expectEqualStrings("Plas", plasma.short_name[0..4]);
    try testing.expectEqual(@as(u16, 940), plasma.speed);
    try testing.expectEqual(@as(u16, 72), plasma.damage);
    try testing.expectEqual(@as(u16, 184), plasma.energy_cost);
    try testing.expectEqual(@as(u8, 19), plasma.refire_delay);
}

test "parseGuns rejects non-GUNS form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try testing.expectError(WeaponError.InvalidFormat, parseGuns(testing.allocator, data));
}

test "parseGuns rejects truncated data" {
    try testing.expectError(WeaponError.InvalidFormat, parseGuns(testing.allocator, "FORM"));
}

// --- Weapon (launcher/missile) parsing ---

test "parseWeapons loads launchers and missiles from fixture" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_weapons.bin");
    defer allocator.free(data);

    const result = try parseWeapons(allocator, data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    try testing.expectEqual(@as(usize, 2), result.launcher_types.len);
    try testing.expectEqual(@as(usize, 3), result.missile_types.len);
}

test "parseWeapons launcher 0 is missile launcher" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_weapons.bin");
    defer allocator.free(data);

    const result = try parseWeapons(allocator, data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    const ml = result.launcher_types[0];
    try testing.expectEqual(@as(u8, 0x32), ml.id);
    try testing.expectEqual(@as(u16, 360), ml.value1);
    try testing.expectEqual(@as(u16, 640), ml.value2);
}

test "parseWeapons launcher 1 is torpedo launcher" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_weapons.bin");
    defer allocator.free(data);

    const result = try parseWeapons(allocator, data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    const tl = result.launcher_types[1];
    try testing.expectEqual(@as(u8, 0x33), tl.id);
}

test "parseWeapons missile 0 is torpedo with correct stats" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_weapons.bin");
    defer allocator.free(data);

    const result = try parseWeapons(allocator, data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    const torp = result.missile_types[0];
    try testing.expectEqual(@as(u8, 1), torp.id);
    try testing.expectEqualStrings("PrtnTorp", &torp.short_name);
    try testing.expectEqualStrings("TORPTYPE", &torp.type_file);
    try testing.expectEqual(@as(u16, 1200), torp.speed);
    try testing.expectEqual(@as(u16, 200), torp.damage);
    try testing.expectEqual(@as(u16, 0), torp.lock_range);
    try testing.expectEqual(TrackingType.torpedo, torp.tracking);
}

test "parseWeapons missile 1 is heat-seeker with lock range" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_weapons.bin");
    defer allocator.free(data);

    const result = try parseWeapons(allocator, data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    const heat = result.missile_types[1];
    try testing.expectEqual(@as(u8, 2), heat.id);
    try testing.expectEqual(@as(u16, 800), heat.speed);
    try testing.expectEqual(@as(u16, 160), heat.damage);
    try testing.expectEqual(@as(u16, 3000), heat.lock_range);
    try testing.expectEqual(TrackingType.heat_seeking, heat.tracking);
}

test "parseWeapons missile 2 is dumbfire with no lock range" {
    const allocator = testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_weapons.bin");
    defer allocator.free(data);

    const result = try parseWeapons(allocator, data);
    defer allocator.free(result.launcher_types);
    defer allocator.free(result.missile_types);

    const dumb = result.missile_types[2];
    try testing.expectEqual(@as(u8, 4), dumb.id);
    try testing.expectEqual(@as(u16, 1000), dumb.speed);
    try testing.expectEqual(@as(u16, 130), dumb.damage);
    try testing.expectEqual(@as(u16, 0), dumb.lock_range);
    try testing.expectEqual(TrackingType.dumbfire, dumb.tracking);
}

test "parseWeapons rejects non-WEAP form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try testing.expectError(WeaponError.InvalidFormat, parseWeapons(testing.allocator, data));
}

// --- Projectile creation ---

test "fireGun creates projectile with correct velocity" {
    const gun = GunType{
        .index = 0,
        .short_name = .{ 'L', 'a', 's', 'r', 0 },
        .type_file = .{ 'L', 'A', 'S', 'R', 'T', 'Y', 'P', 'E' },
        .display_name = .{ 'L', 'A', 'S', 'E', 'R', 0, 0, 0 },
        .speed = 1400,
        .damage = 20,
        .energy_cost = 76,
        .refire_delay = 4,
        .velocity_factor = 370,
        .range = 870,
    };

    const pos = Vec3{ .x = 10, .y = 0, .z = 0 };
    const dir = Vec3{ .x = 0, .y = 0, .z = 1 }; // forward

    const proj = fireGun(&gun, pos, dir);

    // Projectile should be at firing position
    try testing.expectApproxEqAbs(@as(f32, 10), proj.position.x, 0.01);
    // Velocity should be in Z direction at gun speed
    try testing.expectApproxEqAbs(@as(f32, 1400), proj.velocity.z, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), proj.velocity.x, 0.01);
    // Damage matches gun
    try testing.expectEqual(@as(u16, 20), proj.damage);
    // Not a missile
    try testing.expect(!proj.is_missile);
    // Lifetime based on range/speed
    try testing.expectApproxEqAbs(@as(f32, 870.0 / 1400.0), proj.lifetime, 0.01);
}

test "fireMissile creates tracking projectile" {
    const missile = MissileType{
        .id = 2,
        .short_name = .{ 'H', 'e', 'a', 't', 'S', 'e', 'e', 'k' },
        .type_file = .{ 'M', 'S', 'S', 'L', 'T', 'Y', 'P', 'E' },
        .display_name = .{ 'H', 'E', 'A', 'T', 'S', 'E', 'E', 'K' },
        .speed = 800,
        .lock_type = 9,
        .lock_range = 3000,
        .damage = 160,
        .tracking = .heat_seeking,
    };

    const pos = Vec3.zero;
    const dir = Vec3{ .x = 1, .y = 0, .z = 0 };

    const proj = fireMissile(&missile, pos, dir, 3);

    // Velocity in X direction at missile speed
    try testing.expectApproxEqAbs(@as(f32, 800), proj.velocity.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), proj.velocity.z, 0.01);
    // Damage matches missile
    try testing.expectEqual(@as(u16, 160), proj.damage);
    // Is a missile with tracking
    try testing.expect(proj.is_missile);
    try testing.expectEqual(TrackingType.heat_seeking, proj.tracking);
    // Has target
    try testing.expectEqual(@as(?usize, 3), proj.target_index);
}

test "fireMissile torpedo has no target tracking" {
    const torpedo = MissileType{
        .id = 1,
        .short_name = .{ 'P', 'r', 't', 'n', 'T', 'o', 'r', 'p' },
        .type_file = .{ 'T', 'O', 'R', 'P', 'T', 'Y', 'P', 'E' },
        .display_name = .{ 'T', 'O', 'R', 'P', 'E', 'D', 'O', 0 },
        .speed = 1200,
        .lock_type = 3,
        .lock_range = 0,
        .damage = 200,
        .tracking = .torpedo,
    };

    const proj = fireMissile(&torpedo, Vec3.zero, .{ .x = 0, .y = 0, .z = 1 }, null);

    try testing.expectEqual(@as(u16, 200), proj.damage);
    try testing.expect(proj.is_missile);
    try testing.expectEqual(TrackingType.torpedo, proj.tracking);
    try testing.expectEqual(@as(?usize, null), proj.target_index);
    try testing.expectApproxEqAbs(@as(f32, 1200), proj.velocity.z, 0.01);
}

// --- Projectile update ---

test "projectile moves along velocity each frame" {
    var proj = Projectile{
        .position = Vec3.zero,
        .velocity = .{ .x = 100, .y = 0, .z = 0 },
        .lifetime = 5.0,
        .damage = 10,
        .is_missile = false,
        .tracking = .dumbfire,
        .target_index = null,
    };

    const alive = proj.update(1.0);

    try testing.expect(alive);
    try testing.expectApproxEqAbs(@as(f32, 100), proj.position.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 4.0), proj.lifetime, 0.01);
}

test "projectile dies when lifetime expires" {
    var proj = Projectile{
        .position = Vec3.zero,
        .velocity = .{ .x = 100, .y = 0, .z = 0 },
        .lifetime = 0.5,
        .damage = 10,
        .is_missile = false,
        .tracking = .dumbfire,
        .target_index = null,
    };

    const alive = proj.update(1.0);
    try testing.expect(!alive);
}

test "projectile accumulates position over frames" {
    var proj = Projectile{
        .position = Vec3.zero,
        .velocity = .{ .x = 0, .y = 0, .z = 500 },
        .lifetime = 10.0,
        .damage = 10,
        .is_missile = false,
        .tracking = .dumbfire,
        .target_index = null,
    };

    _ = proj.update(0.016); // ~60fps
    _ = proj.update(0.016);
    _ = proj.update(0.016);

    try testing.expectApproxEqAbs(@as(f32, 24.0), proj.position.z, 0.1);
}

// --- WeaponData lookup ---

test "WeaponData.findGun returns matching gun" {
    var guns = [_]GunType{
        .{ .index = 0, .short_name = .{ 'L', 'a', 's', 'r', 0 }, .type_file = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .display_name = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .speed = 1400, .damage = 20, .energy_cost = 76, .refire_delay = 4, .velocity_factor = 370, .range = 870 },
        .{ .index = 5, .short_name = .{ 'P', 'l', 'a', 's', 0 }, .type_file = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .display_name = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .speed = 940, .damage = 72, .energy_cost = 184, .refire_delay = 19, .velocity_factor = 500, .range = 870 },
    };
    const wd = WeaponData{
        .gun_types = &guns,
        .missile_types = &.{},
        .launcher_types = &.{},
        .allocator = testing.allocator,
    };

    const found = wd.findGun(5);
    try testing.expect(found != null);
    try testing.expectEqual(@as(u16, 940), found.?.speed);
    try testing.expect(wd.findGun(99) == null);
}
