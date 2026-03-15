//! Plot mission scripting engine for Wing Commander: Privateer.
//!
//! Parses plot mission files (FORM:MSSN) containing scripted storyline missions
//! with cast, flags, bytecode programs, NPC participants, and scene objectives.
//!
//! Structure:
//!   FORM:MSSN
//!     [CARG] (3 bytes: commodity_id(u8), byte1(u8), byte2(u8)) - optional
//!     [TYPE] (3 bytes) - mission type override, optional
//!     TEXT   (N bytes: null-terminated briefing text)
//!     PAYS   (4 bytes: reward(i32 LE))
//!     [JUMP] (2 bytes: system_id(u8), nav_point(u8)) - optional
//!     FORM:SCRP (script container)
//!       CAST (N*8 bytes: array of 8-byte null-padded character names)
//!       FLAG (N bytes: boolean flag array)
//!       PROG (variable: script bytecode)
//!       PART (N*45 bytes: array of 45-byte participant records)
//!       FORM:PLAY (objectives container)
//!         SCEN (variable: 9-byte header + u16 LE participant indices)
//!
//! Plot mission list (PLOTMSNS.IFF):
//!   FORM:MSNS
//!     TABL (N*4 bytes: array of u32 LE TRE offsets for each mission file)

const std = @import("std");
const iff = @import("../formats/iff.zig");

/// Size of a CAST entry (8 bytes: 6-char name + 2 null padding).
const CAST_ENTRY_SIZE = 8;

/// Size of a PART record (45 bytes per NPC participant).
const PART_RECORD_SIZE = 45;

/// Size of the SCEN header before participant indices.
const SCEN_HEADER_SIZE = 9;

/// A character name from the CAST chunk (up to 6 chars, null-padded to 8).
pub const CastEntry = struct {
    /// Raw 8-byte name (null-padded).
    raw: [CAST_ENTRY_SIZE]u8,

    /// Get the name as a trimmed string slice.
    pub fn name(self: *const CastEntry) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.raw, 0) orelse CAST_ENTRY_SIZE;
        return self.raw[0..end];
    }
};

/// Cargo requirement for cargo delivery missions.
pub const CargoInfo = struct {
    /// Commodity ID (index into COMODTYP.IFF).
    commodity_id: u8,
    /// Additional data bytes (meaning TBD from further RE).
    data: [2]u8,
};

/// Jump point reference for missions requiring inter-system travel.
pub const JumpInfo = struct {
    /// First byte (system or nav reference).
    byte0: u8,
    /// Second byte.
    byte1: u8,
};

/// A scene objective from a SCEN chunk inside FORM:PLAY.
pub const SceneObjective = struct {
    /// Scene type (0 = completion/return, 1 = encounter/waypoint).
    scene_type: u8,
    /// Nav point index (0xFF = no specific nav point).
    nav_point: u8,
    /// System ID (0xFF = no specific system).
    system_id: u8,
    /// Secondary location bytes.
    location_data: [2]u8,
    /// Reserved bytes (typically 0xFF).
    reserved: [4]u8,
    /// Participant indices referencing the CAST array (u16 LE values).
    participants: []const u16,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *SceneObjective) void {
        self.allocator.free(self.participants);
    }
};

/// A 45-byte NPC participant record from the PART chunk.
pub const Participant = struct {
    /// Raw 45-byte record data.
    raw: [PART_RECORD_SIZE]u8,

    /// Participant index (u16 LE at offset 0).
    pub fn index(self: *const Participant) u16 {
        return std.mem.readInt(u16, self.raw[0..2], .little);
    }
};

/// A fully parsed plot mission from FORM:MSSN.
pub const PlotMission = struct {
    /// Briefing text (owned).
    briefing: []const u8,
    /// Reward in credits.
    reward: i32,
    /// Cargo requirement (null if no CARG chunk).
    cargo: ?CargoInfo,
    /// Jump point info (null if no JUMP chunk).
    jump: ?JumpInfo,
    /// Cast member names.
    cast: []CastEntry,
    /// Boolean flag array (initial state, all zero).
    flags: []u8,
    /// Raw script bytecode from PROG chunk (owned).
    program: []const u8,
    /// NPC participant records.
    participants: []Participant,
    /// Scene objectives.
    objectives: []SceneObjective,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *PlotMission) void {
        self.allocator.free(self.briefing);
        self.allocator.free(self.cast);
        self.allocator.free(self.flags);
        self.allocator.free(self.program);
        self.allocator.free(self.participants);
        for (self.objectives) |*obj| {
            @constCast(obj).deinit();
        }
        self.allocator.free(self.objectives);
    }

    /// Number of cast members.
    pub fn castCount(self: *const PlotMission) usize {
        return self.cast.len;
    }

    /// Number of scene objectives.
    pub fn objectiveCount(self: *const PlotMission) usize {
        return self.objectives.len;
    }

    /// Get cast member name by index.
    pub fn castName(self: *const PlotMission, idx: usize) ?[]const u8 {
        if (idx >= self.cast.len) return null;
        return self.cast[idx].name();
    }
};

/// Plot mission list parsed from PLOTMSNS.IFF (FORM:MSNS > TABL).
pub const PlotMissionList = struct {
    /// TRE offsets for each plot mission file.
    offsets: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PlotMissionList) void {
        self.allocator.free(self.offsets);
    }

    /// Number of plot missions in the list.
    pub fn count(self: *const PlotMissionList) usize {
        return self.offsets.len;
    }
};

pub const ParseError = error{
    InvalidFormat,
    MissingData,
    OutOfMemory,
    InvalidSize,
};

fn readU16LE(data: []const u8) u16 {
    return std.mem.readInt(u16, data[0..2], .little);
}

fn readI32LE(data: []const u8) i32 {
    return @bitCast(std.mem.readInt(u32, data[0..4], .little));
}

fn readU32LE(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..4], .little);
}

/// Parse scene objectives from FORM:PLAY children (SCEN chunks).
fn parseObjectives(allocator: std.mem.Allocator, play_form: *const iff.Chunk) ParseError![]SceneObjective {
    const scen_chunks = play_form.findChildren(allocator, "SCEN".*) catch return ParseError.OutOfMemory;
    defer allocator.free(scen_chunks);

    const objectives = allocator.alloc(SceneObjective, scen_chunks.len) catch return ParseError.OutOfMemory;
    errdefer allocator.free(objectives);

    var idx: usize = 0;
    errdefer {
        for (objectives[0..idx]) |*obj| {
            obj.deinit();
        }
    }

    for (scen_chunks) |scen| {
        if (scen.data.len < SCEN_HEADER_SIZE) return ParseError.InvalidSize;

        const remaining = scen.data.len - SCEN_HEADER_SIZE;
        if (remaining % 2 != 0) return ParseError.InvalidSize;
        const participant_count = remaining / 2;

        const participants = allocator.alloc(u16, participant_count) catch return ParseError.OutOfMemory;
        errdefer allocator.free(participants);

        for (0..participant_count) |i| {
            const off = SCEN_HEADER_SIZE + i * 2;
            participants[i] = readU16LE(scen.data[off .. off + 2]);
        }

        objectives[idx] = SceneObjective{
            .scene_type = scen.data[0],
            .nav_point = scen.data[1],
            .system_id = scen.data[2],
            .location_data = scen.data[3..5].*,
            .reserved = scen.data[5..9].*,
            .participants = participants,
            .allocator = allocator,
        };
        idx += 1;
    }

    return objectives;
}

/// Parse a FORM:MSSN file into a PlotMission.
pub fn parsePlotMission(allocator: std.mem.Allocator, data: []const u8) ParseError!PlotMission {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "MSSN")) return ParseError.InvalidFormat;

    // Parse TEXT chunk (required)
    const text_chunk = root.findChild("TEXT".*) orelse return ParseError.MissingData;
    const text_len = std.mem.indexOfScalar(u8, text_chunk.data, 0) orelse text_chunk.data.len;
    const briefing = allocator.dupe(u8, text_chunk.data[0..text_len]) catch return ParseError.OutOfMemory;
    errdefer allocator.free(briefing);

    // Parse PAYS chunk (required, 4 bytes for plot missions)
    const pays_chunk = root.findChild("PAYS".*) orelse return ParseError.MissingData;
    if (pays_chunk.data.len < 4) return ParseError.MissingData;
    const reward = readI32LE(pays_chunk.data[0..4]);

    // Parse optional CARG chunk (3 bytes)
    const cargo: ?CargoInfo = blk: {
        const carg_chunk = root.findChild("CARG".*) orelse break :blk null;
        if (carg_chunk.data.len < 3) break :blk null;
        break :blk CargoInfo{
            .commodity_id = carg_chunk.data[0],
            .data = carg_chunk.data[1..3].*,
        };
    };

    // Parse optional JUMP chunk (2 bytes)
    const jump: ?JumpInfo = blk: {
        const jump_chunk = root.findChild("JUMP".*) orelse break :blk null;
        if (jump_chunk.data.len < 2) break :blk null;
        break :blk JumpInfo{
            .byte0 = jump_chunk.data[0],
            .byte1 = jump_chunk.data[1],
        };
    };

    // Parse FORM:SCRP container (required)
    const scrp_form = root.findForm("SCRP".*) orelse return ParseError.MissingData;

    // Parse CAST chunk (required, N*8 bytes)
    const cast_chunk = scrp_form.findChild("CAST".*) orelse return ParseError.MissingData;
    if (cast_chunk.data.len % CAST_ENTRY_SIZE != 0) return ParseError.InvalidSize;
    const cast_count = cast_chunk.data.len / CAST_ENTRY_SIZE;

    const cast = allocator.alloc(CastEntry, cast_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(cast);

    for (0..cast_count) |i| {
        const off = i * CAST_ENTRY_SIZE;
        cast[i] = CastEntry{
            .raw = cast_chunk.data[off..][0..CAST_ENTRY_SIZE].*,
        };
    }

    // Parse FLAG chunk (required)
    const flag_chunk = scrp_form.findChild("FLAG".*) orelse return ParseError.MissingData;
    const flags = allocator.dupe(u8, flag_chunk.data) catch return ParseError.OutOfMemory;
    errdefer allocator.free(flags);

    // Parse PROG chunk (required, raw bytecode)
    const prog_chunk = scrp_form.findChild("PROG".*) orelse return ParseError.MissingData;
    const program = allocator.dupe(u8, prog_chunk.data) catch return ParseError.OutOfMemory;
    errdefer allocator.free(program);

    // Parse PART chunk (required, N*45 bytes)
    const part_chunk = scrp_form.findChild("PART".*) orelse return ParseError.MissingData;
    if (part_chunk.data.len % PART_RECORD_SIZE != 0) return ParseError.InvalidSize;
    const part_count = part_chunk.data.len / PART_RECORD_SIZE;

    const participants = allocator.alloc(Participant, part_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(participants);

    for (0..part_count) |i| {
        const off = i * PART_RECORD_SIZE;
        participants[i] = Participant{
            .raw = part_chunk.data[off..][0..PART_RECORD_SIZE].*,
        };
    }

    // Parse FORM:PLAY objectives (required)
    const play_form = scrp_form.findForm("PLAY".*) orelse return ParseError.MissingData;
    const objectives = try parseObjectives(allocator, play_form);
    errdefer {
        for (objectives) |*obj| {
            @constCast(obj).deinit();
        }
        allocator.free(objectives);
    }

    return PlotMission{
        .briefing = briefing,
        .reward = reward,
        .cargo = cargo,
        .jump = jump,
        .cast = cast,
        .flags = flags,
        .program = program,
        .participants = participants,
        .objectives = objectives,
        .allocator = allocator,
    };
}

/// Parse a FORM:MSNS file (PLOTMSNS.IFF) into a PlotMissionList.
pub fn parsePlotMissionList(allocator: std.mem.Allocator, data: []const u8) ParseError!PlotMissionList {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "MSNS")) return ParseError.InvalidFormat;

    const tabl_chunk = root.findChild("TABL".*) orelse return ParseError.MissingData;
    if (tabl_chunk.data.len % 4 != 0) return ParseError.InvalidSize;
    const entry_count = tabl_chunk.data.len / 4;

    const offsets = allocator.alloc(u32, entry_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(offsets);

    for (0..entry_count) |i| {
        offsets[i] = readU32LE(tabl_chunk.data[i * 4 ..][0..4]);
    }

    return PlotMissionList{
        .offsets = offsets,
        .allocator = allocator,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

fn loadPlotMission(allocator: std.mem.Allocator) !struct { mission: PlotMission, data: []const u8 } {
    const data = try testing_helpers.loadFixture(allocator, "test_plot_mission.bin");
    const mission = parsePlotMission(allocator, data) catch {
        allocator.free(data);
        return error.TestFixtureError;
    };
    return .{ .mission = mission, .data = data };
}

test "parsePlotMission parses briefing text" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expectEqualStrings(
        "\nDeliver cargo of Iron to the refinery.\n\nPays 15000 credits.",
        mission.briefing,
    );
}

test "parsePlotMission parses reward" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expectEqual(@as(i32, 15000), mission.reward);
}

test "parsePlotMission parses cargo info" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expect(mission.cargo != null);
    try std.testing.expectEqual(@as(u8, 22), mission.cargo.?.commodity_id);
}

test "parsePlotMission parses cast members" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expectEqual(@as(usize, 2), mission.castCount());
    try std.testing.expectEqualStrings("PLAYER", mission.castName(0).?);
    try std.testing.expectEqualStrings("PIR_AA", mission.castName(1).?);
}

test "parsePlotMission parses flags" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expectEqual(@as(usize, 2), mission.flags.len);
    try std.testing.expectEqual(@as(u8, 0), mission.flags[0]);
    try std.testing.expectEqual(@as(u8, 0), mission.flags[1]);
}

test "parsePlotMission parses program bytecode" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expectEqual(@as(usize, 12), mission.program.len);
    // First instruction word should be 0x47
    try std.testing.expectEqual(@as(u8, 0x47), mission.program[0]);
}

test "parsePlotMission parses participants" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expectEqual(@as(usize, 2), mission.participants.len);
    // First participant (PLAYER) has index 0
    try std.testing.expectEqual(@as(u16, 0), mission.participants[0].index());
    // Second participant (NPC) has index 1
    try std.testing.expectEqual(@as(u16, 1), mission.participants[1].index());
}

test "parsePlotMission parses scene objectives" {
    const allocator = std.testing.allocator;
    const loaded = try loadPlotMission(allocator);
    defer allocator.free(loaded.data);
    var mission = loaded.mission;
    defer mission.deinit();

    try std.testing.expectEqual(@as(usize, 2), mission.objectiveCount());

    // First scene: starting scene (type=1, nav=ff, sys=ff, 1 participant)
    const obj0 = mission.objectives[0];
    try std.testing.expectEqual(@as(u8, 1), obj0.scene_type);
    try std.testing.expectEqual(@as(u8, 0xFF), obj0.nav_point);
    try std.testing.expectEqual(@as(u8, 0xFF), obj0.system_id);
    try std.testing.expectEqual(@as(usize, 1), obj0.participants.len);
    try std.testing.expectEqual(@as(u16, 0), obj0.participants[0]); // PLAYER

    // Second scene: encounter (type=1, nav=0, sys=0x29, 3 participants)
    const obj1 = mission.objectives[1];
    try std.testing.expectEqual(@as(u8, 1), obj1.scene_type);
    try std.testing.expectEqual(@as(u8, 0x00), obj1.nav_point);
    try std.testing.expectEqual(@as(u8, 0x29), obj1.system_id);
    try std.testing.expectEqual(@as(usize, 3), obj1.participants.len);
    try std.testing.expectEqual(@as(u16, 1), obj1.participants[0]); // PIR_AA
}

test "parsePlotMission with no cargo has null cargo" {
    const allocator = std.testing.allocator;
    // Build a minimal MSSN without CARG using comptime IFF builders
    comptime {
        @setEvalBranchQuota(10000);
    }
    const mssn_data = comptime blk: {
        @setEvalBranchQuota(10000);
        const text_chunk = iffChunk("TEXT", "Test briefing\x00");
        const pays_chunk = iffChunk("PAYS", &packI32LE(5000));
        const cast_chunk = iffChunk("CAST", "PLAYER\x00\x00");
        const flag_chunk = iffChunk("FLAG", &[_]u8{0});
        const prog_chunk = iffChunk("PROG", &[_]u8{ 0x47, 0x01, 0x00, 0x00 });
        const part_chunk = iffChunk("PART", &([_]u8{0} ** 45));
        const scen_chunk = iffChunk("SCEN", &[_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
        const play_form = iffForm("PLAY", &scen_chunk);
        const scrp_form = iffForm("SCRP", &(cast_chunk ++ flag_chunk ++ prog_chunk ++ part_chunk ++ play_form));
        break :blk iffForm("MSSN", &(text_chunk ++ pays_chunk ++ scrp_form));
    };

    var mission = try parsePlotMission(allocator, &mssn_data);
    defer mission.deinit();

    try std.testing.expect(mission.cargo == null);
    try std.testing.expect(mission.jump == null);
    try std.testing.expectEqual(@as(i32, 5000), mission.reward);
}

test "parsePlotMissionList parses mission table" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_plot_mission_list.bin");
    defer allocator.free(data);

    var list = try parsePlotMissionList(allocator, data);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 3), list.count());
    try std.testing.expectEqual(@as(u32, 0x74), list.offsets[0]);
    try std.testing.expectEqual(@as(u32, 0x8A), list.offsets[1]);
    try std.testing.expectEqual(@as(u32, 0xA0), list.offsets[2]);
}

test "parsePlotMission rejects non-MSSN form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parsePlotMission(allocator, data));
}

test "parsePlotMissionList rejects non-MSNS form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parsePlotMissionList(allocator, data));
}

test "CastEntry.name trims null padding" {
    const entry = CastEntry{ .raw = "PIR_AA\x00\x00".* };
    try std.testing.expectEqualStrings("PIR_AA", entry.name());
}

test "CastEntry.name handles full-length name" {
    const entry = CastEntry{ .raw = "ABCDEFGH".* };
    try std.testing.expectEqualStrings("ABCDEFGH", entry.name());
}

// ── Comptime test helpers ────────────────────────────────────────────

fn packI32LE(val: i32) [4]u8 {
    return @bitCast(std.mem.nativeTo(u32, @bitCast(val), .little));
}

fn iffChunk(comptime tag: *const [4]u8, comptime data: []const u8) [8 + data.len + (data.len % 2)]u8 {
    comptime {
        const padded_len = data.len + (data.len % 2);
        var buf: [8 + padded_len]u8 = undefined;
        buf[0..4].* = tag.*;
        buf[4..8].* = @bitCast(std.mem.nativeTo(u32, @as(u32, @intCast(data.len)), .big));
        @memcpy(buf[8..][0..data.len], data);
        if (data.len % 2 == 1) buf[8 + data.len] = 0;
        return buf;
    }
}

fn iffForm(comptime form_type: *const [4]u8, comptime children: []const u8) [12 + children.len]u8 {
    comptime {
        const body_len: u32 = 4 + children.len;
        var buf: [12 + children.len]u8 = undefined;
        buf[0..4].* = "FORM".*;
        buf[4..8].* = @bitCast(std.mem.nativeTo(u32, body_len, .big));
        buf[8..12].* = form_type.*;
        @memcpy(buf[12..], children);
        return buf;
    }
}
