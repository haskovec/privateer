//! Scene data loader for Wing Commander: Privateer.
//! Parses GAMEFLOW.IFF (FORM:GAME) which defines the room/scene navigation graph
//! used for landing screens and base interiors.
//!
//! Structure:
//!   FORM:GAME
//!     FORM:MISS (per room type)
//!       INFO (1 byte: room type ID)
//!       TUNE (1 byte: music track)
//!       EFCT (N bytes: sound effect data)
//!       FORM:SCEN (per scene in room)
//!         INFO (1 byte: scene ID)
//!         FORM:SPRT (per interactive sprite/hotspot)
//!           INFO (1 byte: sprite ID)
//!           EFCT (N bytes: effect data)
//!           [REQU] (optional: access requirements)

const std = @import("std");
const iff = @import("../formats/iff.zig");

/// An interactive sprite/hotspot within a scene.
pub const SceneSprite = struct {
    /// Sprite identifier byte from INFO chunk.
    info: u8,
    /// Raw effect data from EFCT chunk.
    effect: []const u8,
    /// Raw requirements data from REQU chunk (null if no requirements).
    requirements: ?[]const u8,
};

/// A scene within a room (one screen/view the player can see).
pub const Scene = struct {
    /// Scene identifier byte from INFO chunk.
    info: u8,
    /// Interactive sprites/hotspots in this scene.
    sprites: []SceneSprite,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Scene) void {
        self.allocator.free(self.sprites);
    }
};

/// A room type (e.g., bar, commodity exchange, ship dealer).
pub const Room = struct {
    /// Room type identifier byte from INFO chunk.
    info: u8,
    /// Music track byte from TUNE chunk (null if absent).
    tune: ?u8,
    /// Raw sound effect data from EFCT chunk.
    effect: []const u8,
    /// Scenes within this room.
    scenes: []Scene,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Room) void {
        for (self.scenes) |*s| {
            var scn = s.*;
            scn.deinit();
        }
        self.allocator.free(self.scenes);
    }
};

/// The complete game flow / room navigation graph.
pub const GameFlow = struct {
    /// All room types defined in the game.
    rooms: []Room,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *GameFlow) void {
        for (self.rooms) |*r| {
            var room = r.*;
            room.deinit();
        }
        self.allocator.free(self.rooms);
    }

    /// Find a room by its info (type ID) byte.
    pub fn findRoom(self: GameFlow, info: u8) ?*const Room {
        for (self.rooms) |*room| {
            if (room.info == info) return room;
        }
        return null;
    }

    /// Count total scenes across all rooms.
    pub fn totalScenes(self: GameFlow) usize {
        var count: usize = 0;
        for (self.rooms) |room| {
            count += room.scenes.len;
        }
        return count;
    }

    /// Count total interactive sprites across all scenes.
    pub fn totalSprites(self: GameFlow) usize {
        var count: usize = 0;
        for (self.rooms) |room| {
            for (room.scenes) |scn| {
                count += scn.sprites.len;
            }
        }
        return count;
    }
};

pub const SceneError = error{
    InvalidFormat,
    MissingInfo,
    OutOfMemory,
};

/// Parse a FORM:SPRT chunk into a SceneSprite.
fn parseSprite(chunk: iff.Chunk) SceneError!SceneSprite {
    if (!chunk.isContainer()) return SceneError.InvalidFormat;
    if (!std.mem.eql(u8, &chunk.form_type.?, "SPRT")) return SceneError.InvalidFormat;

    const info_chunk = chunk.findChild("INFO".*) orelse return SceneError.MissingInfo;
    if (info_chunk.data.len < 1) return SceneError.MissingInfo;

    const efct_chunk = chunk.findChild("EFCT".*);
    const requ_chunk = chunk.findChild("REQU".*);

    return SceneSprite{
        .info = info_chunk.data[0],
        .effect = if (efct_chunk) |e| e.data else &.{},
        .requirements = if (requ_chunk) |r| r.data else null,
    };
}

/// Parse a FORM:SCEN chunk into a Scene.
fn parseScene(allocator: std.mem.Allocator, chunk: iff.Chunk) SceneError!Scene {
    if (!chunk.isContainer()) return SceneError.InvalidFormat;
    if (!std.mem.eql(u8, &chunk.form_type.?, "SCEN")) return SceneError.InvalidFormat;

    const info_chunk = chunk.findChild("INFO".*) orelse return SceneError.MissingInfo;
    if (info_chunk.data.len < 1) return SceneError.MissingInfo;

    // Count FORM:SPRT children
    var sprite_count: usize = 0;
    for (chunk.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SPRT")) {
            sprite_count += 1;
        }
    }

    const sprites = allocator.alloc(SceneSprite, sprite_count) catch return SceneError.OutOfMemory;
    errdefer allocator.free(sprites);

    var idx: usize = 0;
    for (chunk.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SPRT")) {
            sprites[idx] = try parseSprite(child);
            idx += 1;
        }
    }

    return Scene{
        .info = info_chunk.data[0],
        .sprites = sprites,
        .allocator = allocator,
    };
}

/// Parse a FORM:MISS chunk into a Room.
fn parseRoom(allocator: std.mem.Allocator, chunk: iff.Chunk) SceneError!Room {
    if (!chunk.isContainer()) return SceneError.InvalidFormat;
    if (!std.mem.eql(u8, &chunk.form_type.?, "MISS")) return SceneError.InvalidFormat;

    const info_chunk = chunk.findChild("INFO".*) orelse return SceneError.MissingInfo;
    if (info_chunk.data.len < 1) return SceneError.MissingInfo;

    const tune_chunk = chunk.findChild("TUNE".*);
    const efct_chunk = chunk.findChild("EFCT".*);

    // Count FORM:SCEN children
    var scene_count: usize = 0;
    for (chunk.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SCEN")) {
            scene_count += 1;
        }
    }

    const scenes = allocator.alloc(Scene, scene_count) catch return SceneError.OutOfMemory;
    errdefer {
        for (scenes[0..scene_count]) |*s| {
            // Only deinit scenes that were successfully parsed
            _ = s;
        }
        allocator.free(scenes);
    }

    var idx: usize = 0;
    errdefer {
        // Clean up successfully parsed scenes on error
        for (scenes[0..idx]) |*s| {
            var scn = s.*;
            scn.deinit();
        }
    }
    for (chunk.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SCEN")) {
            scenes[idx] = try parseScene(allocator, child);
            idx += 1;
        }
    }

    return Room{
        .info = info_chunk.data[0],
        .tune = if (tune_chunk) |t| (if (t.data.len > 0) t.data[0] else null) else null,
        .effect = if (efct_chunk) |e| e.data else &.{},
        .scenes = scenes,
        .allocator = allocator,
    };
}

/// Parse a GAMEFLOW.IFF file (FORM:GAME) into a GameFlow structure.
/// The input data should be the raw IFF file bytes.
pub fn parseGameFlow(allocator: std.mem.Allocator, data: []const u8) SceneError!GameFlow {
    var root = iff.parseFile(allocator, data) catch return SceneError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return SceneError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "GAME")) return SceneError.InvalidFormat;

    // Count FORM:MISS children
    var room_count: usize = 0;
    for (root.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "MISS")) {
            room_count += 1;
        }
    }

    const rooms = allocator.alloc(Room, room_count) catch return SceneError.OutOfMemory;
    errdefer allocator.free(rooms);

    var idx: usize = 0;
    errdefer {
        for (rooms[0..idx]) |*r| {
            var room = r.*;
            room.deinit();
        }
    }
    for (root.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "MISS")) {
            rooms[idx] = try parseRoom(allocator, child);
            idx += 1;
        }
    }

    return GameFlow{
        .rooms = rooms,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parseGameFlow loads test fixture with 2 rooms" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    try std.testing.expectEqual(@as(usize, 2), gameflow.rooms.len);
}

test "parseGameFlow room 0 has correct info and tune" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    const room0 = gameflow.rooms[0];
    try std.testing.expectEqual(@as(u8, 0x01), room0.info);
    try std.testing.expectEqual(@as(u8, 0x03), room0.tune.?);
    try std.testing.expectEqual(@as(usize, 2), room0.effect.len);
    try std.testing.expectEqual(@as(u8, 0x05), room0.effect[0]);
    try std.testing.expectEqual(@as(u8, 0x0A), room0.effect[1]);
}

test "parseGameFlow room 0 has 2 scenes" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    try std.testing.expectEqual(@as(usize, 2), gameflow.rooms[0].scenes.len);
    try std.testing.expectEqual(@as(u8, 0x00), gameflow.rooms[0].scenes[0].info);
    try std.testing.expectEqual(@as(u8, 0x01), gameflow.rooms[0].scenes[1].info);
}

test "parseGameFlow room 0 scene 0 has 2 sprites" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    const scn = gameflow.rooms[0].scenes[0];
    try std.testing.expectEqual(@as(usize, 2), scn.sprites.len);
    try std.testing.expectEqual(@as(u8, 0x01), scn.sprites[0].info);
    try std.testing.expectEqual(@as(u8, 0x02), scn.sprites[1].info);

    // Sprite 0 effects
    try std.testing.expectEqual(@as(usize, 2), scn.sprites[0].effect.len);
    try std.testing.expectEqual(@as(u8, 0x10), scn.sprites[0].effect[0]);
    try std.testing.expectEqual(@as(u8, 0x20), scn.sprites[0].effect[1]);

    // No requirements on these sprites
    try std.testing.expect(scn.sprites[0].requirements == null);
    try std.testing.expect(scn.sprites[1].requirements == null);
}

test "parseGameFlow room 0 scene 1 has 1 sprite" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    const scn = gameflow.rooms[0].scenes[1];
    try std.testing.expectEqual(@as(usize, 1), scn.sprites.len);
    try std.testing.expectEqual(@as(u8, 0x03), scn.sprites[0].info);
}

test "parseGameFlow room 1 has sprite with requirements" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    const room1 = gameflow.rooms[1];
    try std.testing.expectEqual(@as(u8, 0x02), room1.info);
    try std.testing.expectEqual(@as(u8, 0x07), room1.tune.?);
    try std.testing.expectEqual(@as(usize, 1), room1.scenes.len);

    const scn = room1.scenes[0];
    try std.testing.expectEqual(@as(usize, 2), scn.sprites.len);

    // First sprite has no requirements
    try std.testing.expect(scn.sprites[0].requirements == null);

    // Second sprite has requirements
    const reqs = scn.sprites[1].requirements.?;
    try std.testing.expectEqual(@as(usize, 4), reqs.len);
    try std.testing.expectEqual(@as(u8, 0x01), reqs[0]);
    try std.testing.expectEqual(@as(u8, 0x04), reqs[3]);
}

test "GameFlow.findRoom returns correct room" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    const room1 = gameflow.findRoom(0x01);
    try std.testing.expect(room1 != null);
    try std.testing.expectEqual(@as(u8, 0x01), room1.?.info);

    const room2 = gameflow.findRoom(0x02);
    try std.testing.expect(room2 != null);
    try std.testing.expectEqual(@as(u8, 0x02), room2.?.info);

    // Non-existent room
    try std.testing.expect(gameflow.findRoom(0xFF) == null);
}

test "GameFlow.totalScenes and totalSprites" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_gameflow.bin");
    defer allocator.free(data);

    var gameflow = try parseGameFlow(allocator, data);
    defer gameflow.deinit();

    try std.testing.expectEqual(@as(usize, 3), gameflow.totalScenes());
    try std.testing.expectEqual(@as(usize, 5), gameflow.totalSprites());
}

test "parseGameFlow rejects non-GAME form" {
    const allocator = std.testing.allocator;
    // Build a FORM:XXXX that isn't GAME
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(SceneError.InvalidFormat, parseGameFlow(allocator, data));
}

test "parseGameFlow rejects truncated data" {
    try std.testing.expectError(SceneError.InvalidFormat, parseGameFlow(std.testing.allocator, "FORM"));
}
