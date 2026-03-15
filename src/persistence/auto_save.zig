//! Auto-save system for Wing Commander: Privateer.
//!
//! Automatically saves game state when the player lands at a base.
//! Uses a dedicated `autosave.sav` file separate from the 10 manual
//! save slots. The file format is identical to manual save slots:
//! an 8-byte little-endian timestamp followed by 360 bytes of save data.

const std = @import("std");
const save_game = @import("save_game.zig");
const save_slots = @import("save_slots.zig");
const game_state = @import("../game/game_state.zig");

/// Auto-save file name on disk.
pub const AUTOSAVE_FILENAME = "autosave.sav";

pub const AutoSaveError = error{
    IoError,
    NoAutoSave,
    CorruptAutoSave,
};

/// Perform an auto-save, writing the current game state to `autosave.sav`.
/// `timestamp` is seconds since Unix epoch.
pub fn performAutoSave(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    data: *const save_game.SaveGameData,
    timestamp: i64,
) (AutoSaveError || save_game.SerializeError)!void {
    const save_bytes = save_game.serialize(allocator, data) catch |e| return e;
    defer allocator.free(save_bytes);

    var file_buf: [save_slots.SLOT_FILE_SIZE]u8 = undefined;
    std.mem.writeInt(i64, file_buf[0..8], timestamp, .little);
    @memcpy(file_buf[save_slots.SLOT_HEADER_SIZE..], save_bytes);

    const file = dir.createFile(AUTOSAVE_FILENAME, .{}) catch return AutoSaveError.IoError;
    defer file.close();
    file.writeAll(&file_buf) catch return AutoSaveError.IoError;
}

/// Load game state from the auto-save file.
/// Returns the deserialized save data and timestamp.
pub fn loadAutoSave(
    dir: std.fs.Dir,
) (AutoSaveError || save_game.DeserializeError)!struct { data: save_game.SaveGameData, timestamp: i64 } {
    const file = dir.openFile(AUTOSAVE_FILENAME, .{}) catch return AutoSaveError.NoAutoSave;
    defer file.close();

    var file_buf: [save_slots.SLOT_FILE_SIZE]u8 = undefined;
    const bytes_read = file.readAll(&file_buf) catch return AutoSaveError.IoError;
    if (bytes_read != save_slots.SLOT_FILE_SIZE) return AutoSaveError.CorruptAutoSave;

    const timestamp = std.mem.readInt(i64, file_buf[0..8], .little);
    const save_data = save_game.deserialize(file_buf[save_slots.SLOT_HEADER_SIZE..]) catch |e| return e;

    return .{ .data = save_data, .timestamp = timestamp };
}

/// Check whether an auto-save file exists and is valid.
pub fn hasAutoSave(dir: std.fs.Dir) bool {
    const file = dir.openFile(AUTOSAVE_FILENAME, .{}) catch return false;
    defer file.close();

    var header: [save_slots.SLOT_HEADER_SIZE + 4]u8 = undefined;
    const bytes_read = file.readAll(&header) catch return false;
    if (bytes_read < save_slots.SLOT_HEADER_SIZE + 4) return false;

    return std.mem.eql(u8, header[save_slots.SLOT_HEADER_SIZE..][0..4], &save_game.MAGIC);
}

/// Delete the auto-save file.
pub fn deleteAutoSave(dir: std.fs.Dir) AutoSaveError!void {
    dir.deleteFile(AUTOSAVE_FILENAME) catch |err| {
        if (err == error.FileNotFound) return AutoSaveError.NoAutoSave;
        return AutoSaveError.IoError;
    };
}

/// Landing hook: call this when the player lands at a base to trigger
/// an auto-save. Only saves if the game state is `landed`.
/// Returns true if auto-save was performed, false if skipped.
pub fn onLanding(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    data: *const save_game.SaveGameData,
    timestamp: i64,
) bool {
    if (data.state != .landed) return false;
    performAutoSave(allocator, dir, data, timestamp) catch return false;
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn openTmpDir() std.testing.TmpDir {
    return std.testing.tmpDir(.{});
}

fn closeTmpDir(tmp: *std.testing.TmpDir) void {
    tmp.cleanup();
}

fn makeLandedData() save_game.SaveGameData {
    var data = save_game.SaveGameData{};
    data.credits = 25000;
    data.current_ship_id = 1;
    data.current_system = 10;
    data.current_base = 5;
    data.state = .landed;
    data.current_room = 0;
    data.current_scene = 0;
    return data;
}

// -- performAutoSave tests --

test "performAutoSave creates autosave.sav file" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = makeLandedData();
    try performAutoSave(allocator, tmp.dir, &data, 1710500000);

    // Verify file exists with correct size
    const file = try tmp.dir.openFile(AUTOSAVE_FILENAME, .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expectEqual(save_slots.SLOT_FILE_SIZE, stat.size);
}

test "performAutoSave overwrites existing autosave" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    var data1 = makeLandedData();
    data1.credits = 1000;
    try performAutoSave(allocator, tmp.dir, &data1, 100);

    var data2 = makeLandedData();
    data2.credits = 9999;
    try performAutoSave(allocator, tmp.dir, &data2, 200);

    const result = try loadAutoSave(tmp.dir);
    try testing.expectEqual(@as(i32, 9999), result.data.credits);
    try testing.expectEqual(@as(i64, 200), result.timestamp);
}

// -- loadAutoSave tests --

test "loadAutoSave round-trips game data" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const original = makeLandedData();
    const timestamp: i64 = 1710500000;
    try performAutoSave(allocator, tmp.dir, &original, timestamp);

    const result = try loadAutoSave(tmp.dir);
    try testing.expectEqual(timestamp, result.timestamp);
    try testing.expectEqual(original.credits, result.data.credits);
    try testing.expectEqual(original.current_ship_id, result.data.current_ship_id);
    try testing.expectEqual(original.current_system, result.data.current_system);
    try testing.expectEqual(original.current_base, result.data.current_base);
    try testing.expectEqual(original.state, result.data.state);
}

test "loadAutoSave returns NoAutoSave when file missing" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expectError(AutoSaveError.NoAutoSave, loadAutoSave(tmp.dir));
}

test "loadAutoSave returns CorruptAutoSave for wrong size" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const file = try tmp.dir.createFile(AUTOSAVE_FILENAME, .{});
    defer file.close();
    try file.writeAll("too short");

    try testing.expectError(AutoSaveError.CorruptAutoSave, loadAutoSave(tmp.dir));
}

// -- hasAutoSave tests --

test "hasAutoSave returns false when no file" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expect(!hasAutoSave(tmp.dir));
}

test "hasAutoSave returns true for valid autosave" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = makeLandedData();
    try performAutoSave(allocator, tmp.dir, &data, 100);

    try testing.expect(hasAutoSave(tmp.dir));
}

test "hasAutoSave returns false for corrupt file" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const file = try tmp.dir.createFile(AUTOSAVE_FILENAME, .{});
    defer file.close();
    try file.writeAll("bad data");

    try testing.expect(!hasAutoSave(tmp.dir));
}

// -- deleteAutoSave tests --

test "deleteAutoSave removes autosave file" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = makeLandedData();
    try performAutoSave(allocator, tmp.dir, &data, 100);
    try testing.expect(hasAutoSave(tmp.dir));

    try deleteAutoSave(tmp.dir);
    try testing.expect(!hasAutoSave(tmp.dir));
}

test "deleteAutoSave returns NoAutoSave when missing" {
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    try testing.expectError(AutoSaveError.NoAutoSave, deleteAutoSave(tmp.dir));
}

// -- onLanding tests --

test "onLanding triggers auto-save for landed state" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    const data = makeLandedData();
    const saved = onLanding(allocator, tmp.dir, &data, 1710500000);
    try testing.expect(saved);
    try testing.expect(hasAutoSave(tmp.dir));

    // Verify saved data
    const result = try loadAutoSave(tmp.dir);
    try testing.expectEqual(@as(i32, 25000), result.data.credits);
    try testing.expectEqual(@as(i64, 1710500000), result.timestamp);
}

test "onLanding skips auto-save for non-landed state" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    var data = save_game.SaveGameData{};
    data.state = .space_flight;
    const saved = onLanding(allocator, tmp.dir, &data, 100);
    try testing.expect(!saved);
    try testing.expect(!hasAutoSave(tmp.dir));
}

test "onLanding skips auto-save for title state" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    var data = save_game.SaveGameData{};
    data.state = .title;
    const saved = onLanding(allocator, tmp.dir, &data, 100);
    try testing.expect(!saved);
    try testing.expect(!hasAutoSave(tmp.dir));
}

test "onLanding skips auto-save for combat state" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    var data = save_game.SaveGameData{};
    data.state = .combat;
    const saved = onLanding(allocator, tmp.dir, &data, 100);
    try testing.expect(!saved);
    try testing.expect(!hasAutoSave(tmp.dir));
}

// -- Auto-save does not interfere with manual slots --

test "autosave file is separate from manual save slots" {
    const allocator = testing.allocator;
    var tmp = openTmpDir();
    defer closeTmpDir(&tmp);

    // Save to manual slot 0
    var manual_data = save_game.SaveGameData{};
    manual_data.credits = 1000;
    try save_slots.saveToSlot(allocator, tmp.dir, 0, &manual_data, 100);

    // Auto-save with different data
    var auto_data = makeLandedData();
    auto_data.credits = 9999;
    try performAutoSave(allocator, tmp.dir, &auto_data, 200);

    // Verify both are independent
    const manual_result = try save_slots.loadFromSlot(tmp.dir, 0);
    try testing.expectEqual(@as(i32, 1000), manual_result.data.credits);

    const auto_result = try loadAutoSave(tmp.dir);
    try testing.expectEqual(@as(i32, 9999), auto_result.data.credits);
}
