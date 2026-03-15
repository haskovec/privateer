//! Save slot management for Wing Commander: Privateer.
//!
//! Manages multiple save game slots on disk. Each slot stores a save file
//! with a timestamp header followed by the binary save data.
//!
//! Slot file format (368 bytes):
//!   timestamp: i64 LE (8 bytes) — seconds since Unix epoch
//!   save_data: [360]u8          — serialized SaveGameData (see save_game.zig)

const std = @import("std");
const save_game = @import("save_game.zig");

/// Maximum number of save slots.
pub const MAX_SLOTS: u8 = 10;

/// Size of the slot file header (timestamp only).
pub const SLOT_HEADER_SIZE: usize = 8;

/// Total size of a slot file on disk.
pub const SLOT_FILE_SIZE: usize = SLOT_HEADER_SIZE + save_game.SAVE_SIZE;

/// Metadata about a single save slot, extracted without loading full game state.
pub const SlotMetadata = struct {
    /// Slot number (0-based).
    slot: u8,
    /// Whether this slot contains a save.
    occupied: bool = false,
    /// Save timestamp (seconds since Unix epoch). 0 if unoccupied.
    timestamp: i64 = 0,
    /// Player credits at time of save.
    credits: i32 = 0,
    /// System ID where the player was located.
    current_system: u8 = 0,
    /// Base ID where the player was located (0xFF = not at base).
    current_base: u8 = 0xFF,
    /// Ship type ID.
    current_ship_id: u16 = 0,
};

pub const SlotError = error{
    InvalidSlot,
    SlotEmpty,
    CorruptSlotFile,
    IoError,
};

/// Generate the filename for a slot number (e.g. "slot_00.sav").
pub fn slotFileName(buf: *[12]u8, slot: u8) []const u8 {
    const digits = "0123456789";
    buf[0] = 's';
    buf[1] = 'l';
    buf[2] = 'o';
    buf[3] = 't';
    buf[4] = '_';
    buf[5] = digits[slot / 10];
    buf[6] = digits[slot % 10];
    buf[7] = '.';
    buf[8] = 's';
    buf[9] = 'a';
    buf[10] = 'v';
    return buf[0..11];
}

/// Save game data to a numbered slot.
/// `timestamp` is seconds since Unix epoch (use std.time.timestamp()).
/// `dir` is the save directory handle.
pub fn saveToSlot(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    slot: u8,
    data: *const save_game.SaveGameData,
    timestamp: i64,
) (SlotError || save_game.SerializeError)!void {
    if (slot >= MAX_SLOTS) return SlotError.InvalidSlot;

    // Serialize game data
    const save_bytes = save_game.serialize(allocator, data) catch |e| return e;
    defer allocator.free(save_bytes);

    // Build slot file: timestamp header + save data
    var file_buf: [SLOT_FILE_SIZE]u8 = undefined;
    std.mem.writeInt(i64, file_buf[0..8], timestamp, .little);
    @memcpy(file_buf[SLOT_HEADER_SIZE..], save_bytes);

    // Write to disk
    var name_buf: [12]u8 = undefined;
    const name = slotFileName(&name_buf, slot);
    const file = dir.createFile(name, .{}) catch return SlotError.IoError;
    defer file.close();
    file.writeAll(&file_buf) catch return SlotError.IoError;
}

/// Load game data from a numbered slot.
/// Returns the deserialized save data and timestamp.
pub fn loadFromSlot(
    dir: std.fs.Dir,
    slot: u8,
) (SlotError || save_game.DeserializeError)!struct { data: save_game.SaveGameData, timestamp: i64 } {
    if (slot >= MAX_SLOTS) return SlotError.InvalidSlot;

    var name_buf: [12]u8 = undefined;
    const name = slotFileName(&name_buf, slot);

    const file = dir.openFile(name, .{}) catch return SlotError.SlotEmpty;
    defer file.close();

    var file_buf: [SLOT_FILE_SIZE]u8 = undefined;
    const bytes_read = file.readAll(&file_buf) catch return SlotError.IoError;
    if (bytes_read != SLOT_FILE_SIZE) return SlotError.CorruptSlotFile;

    const timestamp = std.mem.readInt(i64, file_buf[0..8], .little);
    const save_data = save_game.deserialize(file_buf[SLOT_HEADER_SIZE..]) catch |e| return e;

    return .{ .data = save_data, .timestamp = timestamp };
}

/// Read metadata for a single slot without loading full game state.
/// Returns unoccupied metadata if slot file doesn't exist.
pub fn getSlotMetadata(dir: std.fs.Dir, slot: u8) SlotError!SlotMetadata {
    if (slot >= MAX_SLOTS) return SlotError.InvalidSlot;

    var name_buf: [12]u8 = undefined;
    const name = slotFileName(&name_buf, slot);

    const file = dir.openFile(name, .{}) catch {
        return SlotMetadata{ .slot = slot };
    };
    defer file.close();

    var file_buf: [SLOT_FILE_SIZE]u8 = undefined;
    const bytes_read = file.readAll(&file_buf) catch return SlotError.IoError;
    if (bytes_read != SLOT_FILE_SIZE) return SlotError.CorruptSlotFile;

    // Verify magic before extracting metadata
    if (!std.mem.eql(u8, file_buf[SLOT_HEADER_SIZE..][0..4], &save_game.MAGIC))
        return SlotError.CorruptSlotFile;

    const timestamp = std.mem.readInt(i64, file_buf[0..8], .little);
    // Extract fields directly from known offsets within save data
    // (avoids full deserialization)
    const save_start = SLOT_HEADER_SIZE;
    const credits = std.mem.readInt(i32, file_buf[save_start + 6 ..][0..4], .little);
    const ship_id = std.mem.readInt(u16, file_buf[save_start + 10 ..][0..2], .little);
    const system_id = file_buf[save_start + 12];
    const base_id = file_buf[save_start + 13];

    return SlotMetadata{
        .slot = slot,
        .occupied = true,
        .timestamp = timestamp,
        .credits = credits,
        .current_system = system_id,
        .current_base = base_id,
        .current_ship_id = ship_id,
    };
}

/// List metadata for all save slots.
pub fn listSlots(dir: std.fs.Dir) [MAX_SLOTS]SlotMetadata {
    var slots: [MAX_SLOTS]SlotMetadata = undefined;
    for (0..MAX_SLOTS) |i| {
        const slot: u8 = @intCast(i);
        slots[i] = getSlotMetadata(dir, slot) catch SlotMetadata{ .slot = slot };
    }
    return slots;
}

/// Delete a save slot.
pub fn deleteSlot(dir: std.fs.Dir, slot: u8) SlotError!void {
    if (slot >= MAX_SLOTS) return SlotError.InvalidSlot;

    var name_buf: [12]u8 = undefined;
    const name = slotFileName(&name_buf, slot);
    dir.deleteFile(name) catch |err| {
        if (err == error.FileNotFound) return SlotError.SlotEmpty;
        return SlotError.IoError;
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn openTmpDir() std.testing.TmpDir {
    return std.testing.tmpDir(.{});
}

fn closeTmpDir(tmp: *std.testing.TmpDir) void {
    tmp.cleanup();
}

fn makeSampleData() save_game.SaveGameData {
    var data = save_game.SaveGameData{};
    data.credits = 50000;
    data.current_ship_id = 2;
    data.current_system = 15;
    data.current_base = 3;
    data.state = .landed;
    data.current_room = 1;
    data.current_scene = 0;
    return data;
}

// -- slotFileName tests --

test "slotFileName generates correct name for slot 0" {
    var buf: [12]u8 = undefined;
    const name = slotFileName(&buf, 0);
    try testing.expectEqualStrings("slot_00.sav", name);
}

test "slotFileName generates correct name for slot 9" {
    var buf: [12]u8 = undefined;
    const name = slotFileName(&buf, 9);
    try testing.expectEqualStrings("slot_09.sav", name);
}

test "slotFileName generates correct name for slot 5" {
    var buf: [12]u8 = undefined;
    const name = slotFileName(&buf, 5);
    try testing.expectEqualStrings("slot_05.sav", name);
}

// -- saveToSlot / loadFromSlot round-trip tests --

test "save and load round-trips game data" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const original = makeSampleData();
    const timestamp: i64 = 1710500000;

    try saveToSlot(allocator, tmp.dir, 0, &original, timestamp);
    const result = try loadFromSlot(tmp.dir, 0);

    try testing.expectEqual(timestamp, result.timestamp);
    try testing.expectEqual(original.credits, result.data.credits);
    try testing.expectEqual(original.current_ship_id, result.data.current_ship_id);
    try testing.expectEqual(original.current_system, result.data.current_system);
    try testing.expectEqual(original.current_base, result.data.current_base);
    try testing.expectEqual(original.state, result.data.state);
}

test "save writes correct file size" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = save_game.SaveGameData{};
    try saveToSlot(allocator, tmp.dir, 0, &data, 0);

    const file = try tmp.dir.openFile("slot_00.sav", .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expectEqual(SLOT_FILE_SIZE, stat.size);
}

test "save to different slots creates separate files" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    var data1 = save_game.SaveGameData{};
    data1.credits = 1000;
    var data2 = save_game.SaveGameData{};
    data2.credits = 2000;

    try saveToSlot(allocator, tmp.dir, 0, &data1, 100);
    try saveToSlot(allocator, tmp.dir, 1, &data2, 200);

    const result0 = try loadFromSlot(tmp.dir, 0);
    const result1 = try loadFromSlot(tmp.dir, 1);

    try testing.expectEqual(@as(i32, 1000), result0.data.credits);
    try testing.expectEqual(@as(i64, 100), result0.timestamp);
    try testing.expectEqual(@as(i32, 2000), result1.data.credits);
    try testing.expectEqual(@as(i64, 200), result1.timestamp);
}

test "save overwrites existing slot" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    var data1 = save_game.SaveGameData{};
    data1.credits = 1000;
    try saveToSlot(allocator, tmp.dir, 0, &data1, 100);

    var data2 = save_game.SaveGameData{};
    data2.credits = 9999;
    try saveToSlot(allocator, tmp.dir, 0, &data2, 200);

    const result = try loadFromSlot(tmp.dir, 0);
    try testing.expectEqual(@as(i32, 9999), result.data.credits);
    try testing.expectEqual(@as(i64, 200), result.timestamp);
}

// -- Slot validation --

test "saveToSlot rejects invalid slot number" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = save_game.SaveGameData{};
    try testing.expectError(SlotError.InvalidSlot, saveToSlot(allocator, tmp.dir, MAX_SLOTS, &data, 0));
    try testing.expectError(SlotError.InvalidSlot, saveToSlot(allocator, tmp.dir, 255, &data, 0));
}

test "loadFromSlot rejects invalid slot number" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expectError(SlotError.InvalidSlot, loadFromSlot(tmp.dir, MAX_SLOTS));
}

test "loadFromSlot returns SlotEmpty for missing file" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expectError(SlotError.SlotEmpty, loadFromSlot(tmp.dir, 0));
}

test "loadFromSlot returns CorruptSlotFile for wrong size" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    // Write a too-short file
    const file = try tmp.dir.createFile("slot_00.sav", .{});
    defer file.close();
    try file.writeAll("too short");

    try testing.expectError(SlotError.CorruptSlotFile, loadFromSlot(tmp.dir, 0));
}

// -- getSlotMetadata tests --

test "getSlotMetadata returns unoccupied for missing slot" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const meta = try getSlotMetadata(tmp.dir, 0);
    try testing.expectEqual(@as(u8, 0), meta.slot);
    try testing.expect(!meta.occupied);
}

test "getSlotMetadata returns correct metadata for saved slot" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = makeSampleData();
    try saveToSlot(allocator, tmp.dir, 3, &data, 1710500000);

    const meta = try getSlotMetadata(tmp.dir, 3);
    try testing.expectEqual(@as(u8, 3), meta.slot);
    try testing.expect(meta.occupied);
    try testing.expectEqual(@as(i64, 1710500000), meta.timestamp);
    try testing.expectEqual(@as(i32, 50000), meta.credits);
    try testing.expectEqual(@as(u8, 15), meta.current_system);
    try testing.expectEqual(@as(u8, 3), meta.current_base);
    try testing.expectEqual(@as(u16, 2), meta.current_ship_id);
}

test "getSlotMetadata rejects invalid slot" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expectError(SlotError.InvalidSlot, getSlotMetadata(tmp.dir, MAX_SLOTS));
}

test "getSlotMetadata detects corrupt file" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    // Write correct size but bad magic
    var bad_data: [SLOT_FILE_SIZE]u8 = .{0} ** SLOT_FILE_SIZE;
    bad_data[SLOT_HEADER_SIZE] = 'X'; // corrupt magic
    const file = try tmp.dir.createFile("slot_00.sav", .{});
    defer file.close();
    try file.writeAll(&bad_data);

    try testing.expectError(SlotError.CorruptSlotFile, getSlotMetadata(tmp.dir, 0));
}

// -- listSlots tests --

test "listSlots returns all unoccupied for empty directory" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const slots = listSlots(tmp.dir);
    for (0..MAX_SLOTS) |i| {
        try testing.expectEqual(@as(u8, @intCast(i)), slots[i].slot);
        try testing.expect(!slots[i].occupied);
    }
}

test "listSlots shows occupied slots correctly" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    var data = save_game.SaveGameData{};
    data.credits = 10000;
    try saveToSlot(allocator, tmp.dir, 0, &data, 100);

    data.credits = 20000;
    try saveToSlot(allocator, tmp.dir, 5, &data, 200);

    const slots = listSlots(tmp.dir);

    try testing.expect(slots[0].occupied);
    try testing.expectEqual(@as(i32, 10000), slots[0].credits);

    try testing.expect(!slots[1].occupied);
    try testing.expect(!slots[2].occupied);
    try testing.expect(!slots[3].occupied);
    try testing.expect(!slots[4].occupied);

    try testing.expect(slots[5].occupied);
    try testing.expectEqual(@as(i32, 20000), slots[5].credits);

    for (6..MAX_SLOTS) |i| {
        try testing.expect(!slots[i].occupied);
    }
}

// -- deleteSlot tests --

test "deleteSlot removes saved file" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = save_game.SaveGameData{};
    try saveToSlot(allocator, tmp.dir, 0, &data, 100);

    // Verify it exists
    const meta = try getSlotMetadata(tmp.dir, 0);
    try testing.expect(meta.occupied);

    // Delete it
    try deleteSlot(tmp.dir, 0);

    // Verify it's gone
    const meta2 = try getSlotMetadata(tmp.dir, 0);
    try testing.expect(!meta2.occupied);
}

test "deleteSlot returns SlotEmpty for non-existent slot" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expectError(SlotError.SlotEmpty, deleteSlot(tmp.dir, 0));
}

test "deleteSlot rejects invalid slot number" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expectError(SlotError.InvalidSlot, deleteSlot(tmp.dir, MAX_SLOTS));
}

// -- Timestamp encoding tests --

test "timestamp is stored as little-endian i64 at file start" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = save_game.SaveGameData{};
    const ts: i64 = 0x0102030405060708;
    try saveToSlot(allocator, tmp.dir, 0, &data, ts);

    const file = try tmp.dir.openFile("slot_00.sav", .{});
    defer file.close();
    var header: [8]u8 = undefined;
    _ = try file.readAll(&header);
    const read_ts = std.mem.readInt(i64, &header, .little);
    try testing.expectEqual(ts, read_ts);
}

test "negative timestamp round-trips correctly" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = save_game.SaveGameData{};
    const ts: i64 = -1000;
    try saveToSlot(allocator, tmp.dir, 0, &data, ts);

    const result = try loadFromSlot(tmp.dir, 0);
    try testing.expectEqual(ts, result.timestamp);
}
