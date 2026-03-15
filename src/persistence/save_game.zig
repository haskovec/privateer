//! Save game serialization for Wing Commander: Privateer.
//!
//! Defines a portable binary format for persisting all game state.
//! All multi-byte values are stored in little-endian byte order.
//!
//! Format (version 1, 360 bytes fixed size):
//!   Header:     "PSVG" magic (4) + u16 version (2)
//!   Player:     credits(i32) + ship_id(u16) + system(u8) + base(u8)
//!   State:      game_state(u8) + room(u8) + scene(u8)
//!   Flight:     position(3×f32) + velocity(3×f32) + yaw(f32) + pitch(f32) +
//!               throttle(f32) + afterburner(u8)
//!   Health:     shield(4×f32) + armor(4×f32) + max_shield(4×f32) + max_armor(4×f32)
//!   Cargo:      capacity(u16) + count(u8) + entries(32×3 bytes)
//!   Tractor:    installed(u8) + active(u8)
//!   Reputation: standings(8×i16)
//!   Plot:       series(u8) + mission(u8) + completed(u8) + flag_count(u8) + flags(32)
//!   Equipment:  count(u8) + ids(32×u16)
//!   Kills:      per_faction(6×u32)

const std = @import("std");
const game_state = @import("../game/game_state.zig");
const flight_physics = @import("../flight/flight_physics.zig");
const reputation_mod = @import("../economy/reputation.zig");

const Vec3 = flight_physics.Vec3;

/// Save file magic number.
pub const MAGIC = "PSVG".*;

/// Current save format version.
pub const FORMAT_VERSION: u16 = 1;

/// Maximum cargo entry slots in a save file.
pub const MAX_CARGO_ENTRIES: usize = 32;

/// Maximum equipment slots in a save file.
pub const MAX_EQUIPMENT: usize = 32;

/// Maximum plot flag slots in a save file.
pub const MAX_PLOT_FLAGS: usize = 32;

/// Exact byte size of a version-1 save file.
pub const SAVE_SIZE: usize = 360;

/// A serializable cargo slot (value type, no pointers).
pub const CargoSlot = struct {
    commodity_id: u8 = 0,
    quantity: u16 = 0,
};

/// All persistent game state captured in a single value-type struct.
/// No pointers, no allocations — designed for direct serialization.
pub const SaveGameData = struct {
    // -- Player identity --
    credits: i32 = 0,
    current_ship_id: u16 = 0,
    current_system: u8 = 0,
    /// 0xFF when not at a base.
    current_base: u8 = 0xFF,

    // -- State machine --
    state: game_state.State = .title,
    /// 0xFF encodes null in the binary format.
    current_room: ?u8 = null,
    /// 0xFF encodes null in the binary format.
    current_scene: ?u8 = null,

    // -- Flight --
    position: Vec3 = Vec3.zero,
    velocity: Vec3 = Vec3.zero,
    yaw: f32 = 0,
    pitch: f32 = 0,
    throttle: f32 = 0,
    afterburner_active: bool = false,

    // -- Ship health --
    shield: [4]f32 = .{ 0, 0, 0, 0 },
    armor: [4]f32 = .{ 0, 0, 0, 0 },
    max_shield: [4]f32 = .{ 0, 0, 0, 0 },
    max_armor: [4]f32 = .{ 0, 0, 0, 0 },

    // -- Cargo --
    cargo_capacity: u16 = 0,
    cargo_entry_count: u8 = 0,
    cargo_entries: [MAX_CARGO_ENTRIES]CargoSlot = .{CargoSlot{}} ** MAX_CARGO_ENTRIES,

    // -- Tractor beam --
    tractor_installed: bool = false,
    tractor_active: bool = false,

    // -- Reputation --
    standings: [reputation_mod.MAX_FACTIONS]i16 = .{0} ** reputation_mod.MAX_FACTIONS,

    // -- Plot state --
    plot_series: u8 = 0,
    plot_mission: u8 = 0,
    plot_completed: bool = false,
    plot_flag_count: u8 = 0,
    plot_flags: [MAX_PLOT_FLAGS]u8 = .{0} ** MAX_PLOT_FLAGS,

    // -- Equipment --
    equipment_count: u8 = 0,
    equipment_ids: [MAX_EQUIPMENT]u16 = .{0} ** MAX_EQUIPMENT,

    // -- Kill statistics --
    kills_by_faction: [reputation_mod.FACTION_COUNT]u32 = .{0} ** reputation_mod.FACTION_COUNT,
};

pub const SerializeError = error{OutOfMemory};

pub const DeserializeError = error{
    InvalidMagic,
    UnsupportedVersion,
    UnexpectedEof,
    InvalidState,
};

/// Serialize a SaveGameData into an owned byte slice.
/// Caller owns the returned memory and must free it with the same allocator.
pub fn serialize(allocator: std.mem.Allocator, data: *const SaveGameData) SerializeError![]u8 {
    const buf = allocator.alloc(u8, SAVE_SIZE) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var off: usize = 0;

    // Header
    putSlice(buf, &off, &MAGIC);
    putU16(buf, &off, FORMAT_VERSION);

    // Player identity
    putI32(buf, &off, data.credits);
    putU16(buf, &off, data.current_ship_id);
    putU8(buf, &off, data.current_system);
    putU8(buf, &off, data.current_base);

    // State machine
    putU8(buf, &off, @intFromEnum(data.state));
    putU8(buf, &off, data.current_room orelse 0xFF);
    putU8(buf, &off, data.current_scene orelse 0xFF);

    // Flight
    putF32(buf, &off, data.position.x);
    putF32(buf, &off, data.position.y);
    putF32(buf, &off, data.position.z);
    putF32(buf, &off, data.velocity.x);
    putF32(buf, &off, data.velocity.y);
    putF32(buf, &off, data.velocity.z);
    putF32(buf, &off, data.yaw);
    putF32(buf, &off, data.pitch);
    putF32(buf, &off, data.throttle);
    putU8(buf, &off, if (data.afterburner_active) @as(u8, 1) else 0);

    // Ship health
    for (data.shield) |v| putF32(buf, &off, v);
    for (data.armor) |v| putF32(buf, &off, v);
    for (data.max_shield) |v| putF32(buf, &off, v);
    for (data.max_armor) |v| putF32(buf, &off, v);

    // Cargo
    putU16(buf, &off, data.cargo_capacity);
    putU8(buf, &off, data.cargo_entry_count);
    for (data.cargo_entries) |entry| {
        putU8(buf, &off, entry.commodity_id);
        putU16(buf, &off, entry.quantity);
    }

    // Tractor beam
    putU8(buf, &off, if (data.tractor_installed) @as(u8, 1) else 0);
    putU8(buf, &off, if (data.tractor_active) @as(u8, 1) else 0);

    // Reputation
    for (data.standings) |s| putI16(buf, &off, s);

    // Plot state
    putU8(buf, &off, data.plot_series);
    putU8(buf, &off, data.plot_mission);
    putU8(buf, &off, if (data.plot_completed) @as(u8, 1) else 0);
    putU8(buf, &off, data.plot_flag_count);
    putSlice(buf, &off, &data.plot_flags);

    // Equipment
    putU8(buf, &off, data.equipment_count);
    for (data.equipment_ids) |id| putU16(buf, &off, id);

    // Kill stats
    for (data.kills_by_faction) |k| putU32(buf, &off, k);

    std.debug.assert(off == SAVE_SIZE);
    return buf;
}

/// Deserialize a SaveGameData from a byte slice.
pub fn deserialize(bytes: []const u8) DeserializeError!SaveGameData {
    var off: usize = 0;

    // Header
    const magic = getSlice(4, bytes, &off) orelse return error.InvalidMagic;
    if (!std.mem.eql(u8, magic, &MAGIC)) return error.InvalidMagic;
    const version = getU16(bytes, &off) orelse return error.UnexpectedEof;
    if (version != FORMAT_VERSION) return error.UnsupportedVersion;

    var data = SaveGameData{};

    // Player identity
    data.credits = getI32(bytes, &off) orelse return error.UnexpectedEof;
    data.current_ship_id = getU16(bytes, &off) orelse return error.UnexpectedEof;
    data.current_system = getU8(bytes, &off) orelse return error.UnexpectedEof;
    data.current_base = getU8(bytes, &off) orelse return error.UnexpectedEof;

    // State machine
    const state_byte = getU8(bytes, &off) orelse return error.UnexpectedEof;
    const max_state = @intFromEnum(game_state.State.animation);
    if (state_byte > max_state) return error.InvalidState;
    data.state = @enumFromInt(state_byte);
    const room = getU8(bytes, &off) orelse return error.UnexpectedEof;
    data.current_room = if (room == 0xFF) null else room;
    const scene = getU8(bytes, &off) orelse return error.UnexpectedEof;
    data.current_scene = if (scene == 0xFF) null else scene;

    // Flight
    data.position.x = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.position.y = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.position.z = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.velocity.x = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.velocity.y = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.velocity.z = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.yaw = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.pitch = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.throttle = getF32(bytes, &off) orelse return error.UnexpectedEof;
    data.afterburner_active = (getU8(bytes, &off) orelse return error.UnexpectedEof) != 0;

    // Ship health
    for (&data.shield) |*v| v.* = getF32(bytes, &off) orelse return error.UnexpectedEof;
    for (&data.armor) |*v| v.* = getF32(bytes, &off) orelse return error.UnexpectedEof;
    for (&data.max_shield) |*v| v.* = getF32(bytes, &off) orelse return error.UnexpectedEof;
    for (&data.max_armor) |*v| v.* = getF32(bytes, &off) orelse return error.UnexpectedEof;

    // Cargo
    data.cargo_capacity = getU16(bytes, &off) orelse return error.UnexpectedEof;
    data.cargo_entry_count = getU8(bytes, &off) orelse return error.UnexpectedEof;
    for (&data.cargo_entries) |*entry| {
        entry.commodity_id = getU8(bytes, &off) orelse return error.UnexpectedEof;
        entry.quantity = getU16(bytes, &off) orelse return error.UnexpectedEof;
    }

    // Tractor beam
    data.tractor_installed = (getU8(bytes, &off) orelse return error.UnexpectedEof) != 0;
    data.tractor_active = (getU8(bytes, &off) orelse return error.UnexpectedEof) != 0;

    // Reputation
    for (&data.standings) |*s| s.* = getI16(bytes, &off) orelse return error.UnexpectedEof;

    // Plot state
    data.plot_series = getU8(bytes, &off) orelse return error.UnexpectedEof;
    data.plot_mission = getU8(bytes, &off) orelse return error.UnexpectedEof;
    data.plot_completed = (getU8(bytes, &off) orelse return error.UnexpectedEof) != 0;
    data.plot_flag_count = getU8(bytes, &off) orelse return error.UnexpectedEof;
    const flags = getSlice(MAX_PLOT_FLAGS, bytes, &off) orelse return error.UnexpectedEof;
    @memcpy(&data.plot_flags, flags);

    // Equipment
    data.equipment_count = getU8(bytes, &off) orelse return error.UnexpectedEof;
    for (&data.equipment_ids) |*id| id.* = getU16(bytes, &off) orelse return error.UnexpectedEof;

    // Kill stats
    for (&data.kills_by_faction) |*k| k.* = getU32(bytes, &off) orelse return error.UnexpectedEof;

    return data;
}

// ── Write helpers ────────────────────────────────────────────────────

fn putU8(buf: []u8, off: *usize, val: u8) void {
    buf[off.*] = val;
    off.* += 1;
}

fn putU16(buf: []u8, off: *usize, val: u16) void {
    std.mem.writeInt(u16, buf[off.*..][0..2], val, .little);
    off.* += 2;
}

fn putI16(buf: []u8, off: *usize, val: i16) void {
    std.mem.writeInt(i16, buf[off.*..][0..2], val, .little);
    off.* += 2;
}

fn putU32(buf: []u8, off: *usize, val: u32) void {
    std.mem.writeInt(u32, buf[off.*..][0..4], val, .little);
    off.* += 4;
}

fn putI32(buf: []u8, off: *usize, val: i32) void {
    std.mem.writeInt(i32, buf[off.*..][0..4], val, .little);
    off.* += 4;
}

fn putF32(buf: []u8, off: *usize, val: f32) void {
    putU32(buf, off, @bitCast(val));
}

fn putSlice(buf: []u8, off: *usize, data: []const u8) void {
    @memcpy(buf[off.* .. off.* + data.len], data);
    off.* += data.len;
}

// ── Read helpers ─────────────────────────────────────────────────────

fn getU8(bytes: []const u8, off: *usize) ?u8 {
    if (off.* + 1 > bytes.len) return null;
    const val = bytes[off.*];
    off.* += 1;
    return val;
}

fn getU16(bytes: []const u8, off: *usize) ?u16 {
    if (off.* + 2 > bytes.len) return null;
    const val = std.mem.readInt(u16, bytes[off.*..][0..2], .little);
    off.* += 2;
    return val;
}

fn getI16(bytes: []const u8, off: *usize) ?i16 {
    if (off.* + 2 > bytes.len) return null;
    const val = std.mem.readInt(i16, bytes[off.*..][0..2], .little);
    off.* += 2;
    return val;
}

fn getU32(bytes: []const u8, off: *usize) ?u32 {
    if (off.* + 4 > bytes.len) return null;
    const val = std.mem.readInt(u32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return val;
}

fn getI32(bytes: []const u8, off: *usize) ?i32 {
    if (off.* + 4 > bytes.len) return null;
    const val = std.mem.readInt(i32, bytes[off.*..][0..4], .little);
    off.* += 4;
    return val;
}

fn getF32(bytes: []const u8, off: *usize) ?f32 {
    const bits = getU32(bytes, off) orelse return null;
    return @bitCast(bits);
}

fn getSlice(comptime N: usize, bytes: []const u8, off: *usize) ?*const [N]u8 {
    if (off.* + N > bytes.len) return null;
    const ptr = bytes[off.*..][0..N];
    off.* += N;
    return ptr;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectVec3Equal(expected: Vec3, actual: Vec3) !void {
    try testing.expectEqual(expected.x, actual.x);
    try testing.expectEqual(expected.y, actual.y);
    try testing.expectEqual(expected.z, actual.z);
}

fn expectSaveEqual(expected: *const SaveGameData, actual: *const SaveGameData) !void {
    // Player identity
    try testing.expectEqual(expected.credits, actual.credits);
    try testing.expectEqual(expected.current_ship_id, actual.current_ship_id);
    try testing.expectEqual(expected.current_system, actual.current_system);
    try testing.expectEqual(expected.current_base, actual.current_base);
    // State machine
    try testing.expectEqual(expected.state, actual.state);
    try testing.expectEqual(expected.current_room, actual.current_room);
    try testing.expectEqual(expected.current_scene, actual.current_scene);
    // Flight (exact comparison since f32 round-trips through u32 bits losslessly)
    try expectVec3Equal(expected.position, actual.position);
    try expectVec3Equal(expected.velocity, actual.velocity);
    try testing.expectEqual(expected.yaw, actual.yaw);
    try testing.expectEqual(expected.pitch, actual.pitch);
    try testing.expectEqual(expected.throttle, actual.throttle);
    try testing.expectEqual(expected.afterburner_active, actual.afterburner_active);
    // Ship health
    for (0..4) |i| {
        try testing.expectEqual(expected.shield[i], actual.shield[i]);
        try testing.expectEqual(expected.armor[i], actual.armor[i]);
        try testing.expectEqual(expected.max_shield[i], actual.max_shield[i]);
        try testing.expectEqual(expected.max_armor[i], actual.max_armor[i]);
    }
    // Cargo
    try testing.expectEqual(expected.cargo_capacity, actual.cargo_capacity);
    try testing.expectEqual(expected.cargo_entry_count, actual.cargo_entry_count);
    for (0..MAX_CARGO_ENTRIES) |i| {
        try testing.expectEqual(expected.cargo_entries[i].commodity_id, actual.cargo_entries[i].commodity_id);
        try testing.expectEqual(expected.cargo_entries[i].quantity, actual.cargo_entries[i].quantity);
    }
    // Tractor beam
    try testing.expectEqual(expected.tractor_installed, actual.tractor_installed);
    try testing.expectEqual(expected.tractor_active, actual.tractor_active);
    // Reputation
    for (0..reputation_mod.MAX_FACTIONS) |i| {
        try testing.expectEqual(expected.standings[i], actual.standings[i]);
    }
    // Plot state
    try testing.expectEqual(expected.plot_series, actual.plot_series);
    try testing.expectEqual(expected.plot_mission, actual.plot_mission);
    try testing.expectEqual(expected.plot_completed, actual.plot_completed);
    try testing.expectEqual(expected.plot_flag_count, actual.plot_flag_count);
    try testing.expectEqualSlices(u8, &expected.plot_flags, &actual.plot_flags);
    // Equipment
    try testing.expectEqual(expected.equipment_count, actual.equipment_count);
    for (0..MAX_EQUIPMENT) |i| {
        try testing.expectEqual(expected.equipment_ids[i], actual.equipment_ids[i]);
    }
    // Kill stats
    for (0..reputation_mod.FACTION_COUNT) |i| {
        try testing.expectEqual(expected.kills_by_faction[i], actual.kills_by_faction[i]);
    }
}

// -- Round-trip tests --

test "serialize produces correct size" {
    const allocator = testing.allocator;
    const data = SaveGameData{};
    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    try testing.expectEqual(SAVE_SIZE, bytes.len);
}

test "serialize writes correct magic and version" {
    const allocator = testing.allocator;
    const data = SaveGameData{};
    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    try testing.expectEqualSlices(u8, "PSVG", bytes[0..4]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[4..6], .little));
}

test "round-trip default state produces identical data" {
    const allocator = testing.allocator;
    const original = SaveGameData{};
    const bytes = try serialize(allocator, &original);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try expectSaveEqual(&original, &loaded);
}

test "round-trip fully populated state produces identical data" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.credits = 250000;
    data.current_ship_id = 3;
    data.current_system = 42;
    data.current_base = 7;
    data.state = .landed;
    data.current_room = 3;
    data.current_scene = 7;
    data.position = .{ .x = 100.5, .y = -50.0, .z = 200.75 };
    data.velocity = .{ .x = 10.0, .y = 0, .z = -5.0 };
    data.yaw = 1.5;
    data.pitch = -0.3;
    data.throttle = 0.75;
    data.afterburner_active = true;
    data.shield = .{ 80, 80, 60, 60 };
    data.armor = .{ 45, 30, 35, 40 };
    data.max_shield = .{ 100, 100, 80, 80 };
    data.max_armor = .{ 80, 60, 60, 60 };
    data.cargo_capacity = 50;
    data.cargo_entry_count = 2;
    data.cargo_entries[0] = .{ .commodity_id = 3, .quantity = 10 };
    data.cargo_entries[1] = .{ .commodity_id = 7, .quantity = 25 };
    data.tractor_installed = true;
    data.tractor_active = false;
    data.standings = .{ 30, 25, 10, -50, -75, -50, 0, 0 };
    data.plot_series = 3;
    data.plot_mission = 2;
    data.plot_completed = false;
    data.plot_flag_count = 3;
    data.plot_flags[0] = 1;
    data.plot_flags[1] = 0;
    data.plot_flags[2] = 1;
    data.equipment_count = 3;
    data.equipment_ids[0] = 100;
    data.equipment_ids[1] = 205;
    data.equipment_ids[2] = 310;
    data.kills_by_faction = .{ 15, 8, 0, 42, 67, 23 };

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try expectSaveEqual(&data, &loaded);
}

test "round-trip space_flight state with null room/scene" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.state = .space_flight;
    data.current_room = null;
    data.current_scene = null;
    data.position = .{ .x = 500, .y = 100, .z = -300 };

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try testing.expectEqual(game_state.State.space_flight, loaded.state);
    try testing.expect(loaded.current_room == null);
    try testing.expect(loaded.current_scene == null);
}

test "round-trip negative credits" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.credits = -5000;

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try testing.expectEqual(@as(i32, -5000), loaded.credits);
}

test "round-trip negative reputation standings" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.standings = .{ -100, -75, -50, 0, 25, 50, 75, 100 };

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    for (0..reputation_mod.MAX_FACTIONS) |i| {
        try testing.expectEqual(data.standings[i], loaded.standings[i]);
    }
}

test "round-trip all game states" {
    const allocator = testing.allocator;
    const states = [_]game_state.State{
        .title,      .loading,  .space_flight, .landed,
        .conversation, .combat, .dead,         .animation,
    };
    for (states) |s| {
        var data = SaveGameData{};
        data.state = s;
        const bytes = try serialize(allocator, &data);
        defer allocator.free(bytes);
        const loaded = try deserialize(bytes);
        try testing.expectEqual(s, loaded.state);
    }
}

test "round-trip plot completed flag" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.plot_completed = true;
    data.plot_series = 7;
    data.plot_mission = 1;

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try testing.expect(loaded.plot_completed);
    try testing.expectEqual(@as(u8, 7), loaded.plot_series);
    try testing.expectEqual(@as(u8, 1), loaded.plot_mission);
}

// -- Error handling tests --

test "deserialize rejects invalid magic" {
    var bytes = [_]u8{0} ** SAVE_SIZE;
    bytes[0] = 'X'; // Bad magic
    bytes[1] = 'X';
    bytes[2] = 'X';
    bytes[3] = 'X';
    try testing.expectError(error.InvalidMagic, deserialize(&bytes));
}

test "deserialize rejects unsupported version" {
    const allocator = testing.allocator;
    const data = SaveGameData{};
    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    // Patch version to 99
    std.mem.writeInt(u16, bytes[4..6], 99, .little);
    try testing.expectError(error.UnsupportedVersion, deserialize(bytes));
}

test "deserialize rejects truncated data" {
    const allocator = testing.allocator;
    const data = SaveGameData{};
    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    // Truncate at various points
    try testing.expectError(error.InvalidMagic, deserialize(bytes[0..2]));
    try testing.expectError(error.UnexpectedEof, deserialize(bytes[0..6]));
    try testing.expectError(error.UnexpectedEof, deserialize(bytes[0..50]));
}

test "deserialize rejects empty input" {
    try testing.expectError(error.InvalidMagic, deserialize(&[_]u8{}));
}

test "deserialize rejects invalid state enum value" {
    const allocator = testing.allocator;
    const data = SaveGameData{};
    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    // State byte is at offset 14 (magic:4 + version:2 + credits:4 + ship_id:2 + system:1 + base:1)
    bytes[14] = 99; // Invalid state
    try testing.expectError(error.InvalidState, deserialize(bytes));
}

// -- Specific field encoding tests --

test "credits encoded as little-endian i32" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.credits = 0x12345678;
    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    // credits at offset 6 (after magic + version)
    try testing.expectEqual(@as(u8, 0x78), bytes[6]);
    try testing.expectEqual(@as(u8, 0x56), bytes[7]);
    try testing.expectEqual(@as(u8, 0x34), bytes[8]);
    try testing.expectEqual(@as(u8, 0x12), bytes[9]);
}

test "cargo entries round-trip correctly" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.cargo_capacity = 100;
    data.cargo_entry_count = 3;
    data.cargo_entries[0] = .{ .commodity_id = 1, .quantity = 50 };
    data.cargo_entries[1] = .{ .commodity_id = 5, .quantity = 200 };
    data.cargo_entries[2] = .{ .commodity_id = 12, .quantity = 1 };

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try testing.expectEqual(@as(u16, 100), loaded.cargo_capacity);
    try testing.expectEqual(@as(u8, 3), loaded.cargo_entry_count);
    try testing.expectEqual(@as(u8, 1), loaded.cargo_entries[0].commodity_id);
    try testing.expectEqual(@as(u16, 50), loaded.cargo_entries[0].quantity);
    try testing.expectEqual(@as(u8, 5), loaded.cargo_entries[1].commodity_id);
    try testing.expectEqual(@as(u16, 200), loaded.cargo_entries[1].quantity);
    try testing.expectEqual(@as(u8, 12), loaded.cargo_entries[2].commodity_id);
    try testing.expectEqual(@as(u16, 1), loaded.cargo_entries[2].quantity);
}

test "equipment ids round-trip correctly" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.equipment_count = 4;
    data.equipment_ids[0] = 100;
    data.equipment_ids[1] = 200;
    data.equipment_ids[2] = 300;
    data.equipment_ids[3] = 65535;

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try testing.expectEqual(@as(u8, 4), loaded.equipment_count);
    try testing.expectEqual(@as(u16, 100), loaded.equipment_ids[0]);
    try testing.expectEqual(@as(u16, 200), loaded.equipment_ids[1]);
    try testing.expectEqual(@as(u16, 300), loaded.equipment_ids[2]);
    try testing.expectEqual(@as(u16, 65535), loaded.equipment_ids[3]);
}

test "kill stats round-trip correctly" {
    const allocator = testing.allocator;
    var data = SaveGameData{};
    data.kills_by_faction = .{ 100, 200, 0, 999, 50000, 1 };

    const bytes = try serialize(allocator, &data);
    defer allocator.free(bytes);
    const loaded = try deserialize(bytes);
    try testing.expectEqual(@as(u32, 100), loaded.kills_by_faction[0]);
    try testing.expectEqual(@as(u32, 200), loaded.kills_by_faction[1]);
    try testing.expectEqual(@as(u32, 0), loaded.kills_by_faction[2]);
    try testing.expectEqual(@as(u32, 999), loaded.kills_by_faction[3]);
    try testing.expectEqual(@as(u32, 50000), loaded.kills_by_faction[4]);
    try testing.expectEqual(@as(u32, 1), loaded.kills_by_faction[5]);
}
