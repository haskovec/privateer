//! Random mission generator for Wing Commander: Privateer.
//!
//! Parses mission template files (FORM:RNDM) containing mission templates
//! (FORM:MISN) and generates random missions based on current base type
//! and faction standings.
//!
//! Structure:
//!   FORM:RNDM
//!     FORM:MISN (per mission template)
//!       INFO (4 bytes: type(u8), difficulty(u8), base_type_mask(u16 LE))
//!       TEXT (N bytes: null-terminated briefing text)
//!       PAYS (8 bytes: min_reward(i32 LE), max_reward(i32 LE))

const std = @import("std");
const iff = @import("../formats/iff.zig");

/// Mission types available in the Gemini Sector.
pub const MissionType = enum(u8) {
    patrol = 0, // Patrol nav points
    scout = 1, // Scout a system
    defend = 2, // Defend target from attackers
    attack = 3, // Attack enemy targets
    bounty = 4, // Bounty hunt specific NPC
    cargo = 5, // Cargo delivery

    pub fn name(self: MissionType) []const u8 {
        return switch (self) {
            .patrol => "Patrol",
            .scout => "Scout",
            .defend => "Defend",
            .attack => "Attack",
            .bounty => "Bounty Hunt",
            .cargo => "Cargo Delivery",
        };
    }
};

/// Base type bit flags for mission availability.
pub const BaseTypeMask = struct {
    pub const agricultural: u16 = 0x01; // bit 0
    pub const mining: u16 = 0x02; // bit 1
    pub const refinery: u16 = 0x04; // bit 2
    pub const pleasure: u16 = 0x08; // bit 3
    pub const pirate: u16 = 0x10; // bit 4
    pub const military: u16 = 0x20; // bit 5
    pub const all: u16 = 0x3F;

    /// Map base_type (1-6) to mask bit.
    pub fn fromBaseType(base_type: u8) u16 {
        if (base_type < 1 or base_type > 6) return 0;
        return @as(u16, 1) << @intCast(base_type - 1);
    }
};

/// A mission template parsed from FORM:MISN.
pub const MissionTemplate = struct {
    /// Mission type (patrol, cargo, bounty, etc.).
    mission_type: MissionType,
    /// Difficulty rating (1-5).
    difficulty: u8,
    /// Bitmask of base types that can offer this mission.
    base_type_mask: u16,
    /// Briefing text template (owned).
    briefing: []const u8,
    /// Minimum reward in credits.
    min_reward: i32,
    /// Maximum reward in credits.
    max_reward: i32,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *MissionTemplate) void {
        self.allocator.free(self.briefing);
    }

    /// Check if this template is available at the given base type.
    pub fn availableAtBase(self: MissionTemplate, base_type: u8) bool {
        return (self.base_type_mask & BaseTypeMask.fromBaseType(base_type)) != 0;
    }
};

/// All mission templates loaded from a FORM:RNDM file.
pub const MissionTemplateRegistry = struct {
    templates: []MissionTemplate,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MissionTemplateRegistry) void {
        for (self.templates) |*t| {
            t.deinit();
        }
        self.allocator.free(self.templates);
    }

    /// Get all templates available at the given base type.
    pub fn templatesForBase(self: MissionTemplateRegistry, allocator: std.mem.Allocator, base_type: u8) ![]const *const MissionTemplate {
        var count: usize = 0;
        for (self.templates) |t| {
            if (t.availableAtBase(base_type)) count += 1;
        }

        const result = try allocator.alloc(*const MissionTemplate, count);
        var idx: usize = 0;
        for (self.templates, 0..) |_, i| {
            if (self.templates[i].availableAtBase(base_type)) {
                result[idx] = &self.templates[i];
                idx += 1;
            }
        }
        return result;
    }
};

/// A concrete mission instance generated from a template.
pub const Mission = struct {
    /// Mission type.
    mission_type: MissionType,
    /// Difficulty rating.
    difficulty: u8,
    /// Briefing text (owned).
    briefing: []const u8,
    /// Reward in credits.
    reward: i32,
    /// Destination system index.
    destination_system: u8,
    /// Whether the mission has been accepted by the player.
    accepted: bool,
    /// Whether the mission has been completed.
    completed: bool,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Mission) void {
        self.allocator.free(self.briefing);
    }
};

pub const ParseError = error{
    InvalidFormat,
    MissingData,
    OutOfMemory,
    InvalidMissionType,
};

fn readU16LE(data: []const u8) u16 {
    return std.mem.readInt(u16, data[0..2], .little);
}

fn readI32LE(data: []const u8) i32 {
    return @bitCast(std.mem.readInt(u32, data[0..4], .little));
}

/// Parse a single FORM:MISN chunk into a MissionTemplate.
fn parseTemplate(allocator: std.mem.Allocator, form: *const iff.Chunk) ParseError!MissionTemplate {
    if (!form.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &form.form_type.?, "MISN")) return ParseError.InvalidFormat;

    // Parse INFO chunk (4 bytes: type(u8), difficulty(u8), base_type_mask(u16 LE))
    const info_chunk = form.findChild("INFO".*) orelse return ParseError.MissingData;
    if (info_chunk.data.len < 4) return ParseError.MissingData;

    const mission_type_raw = info_chunk.data[0];
    if (mission_type_raw > 5) return ParseError.InvalidMissionType;
    const mission_type: MissionType = @enumFromInt(mission_type_raw);
    const difficulty = info_chunk.data[1];
    const base_type_mask = readU16LE(info_chunk.data[2..4]);

    // Parse TEXT chunk (null-terminated briefing)
    const text_chunk = form.findChild("TEXT".*) orelse return ParseError.MissingData;
    const text_len = std.mem.indexOfScalar(u8, text_chunk.data, 0) orelse text_chunk.data.len;
    const briefing = allocator.dupe(u8, text_chunk.data[0..text_len]) catch return ParseError.OutOfMemory;
    errdefer allocator.free(briefing);

    // Parse PAYS chunk (8 bytes: min_reward(i32 LE), max_reward(i32 LE))
    const pays_chunk = form.findChild("PAYS".*) orelse return ParseError.MissingData;
    if (pays_chunk.data.len < 8) return ParseError.MissingData;
    const min_reward = readI32LE(pays_chunk.data[0..4]);
    const max_reward = readI32LE(pays_chunk.data[4..8]);

    return MissionTemplate{
        .mission_type = mission_type,
        .difficulty = difficulty,
        .base_type_mask = base_type_mask,
        .briefing = briefing,
        .min_reward = min_reward,
        .max_reward = max_reward,
        .allocator = allocator,
    };
}

/// Parse a FORM:RNDM file into a MissionTemplateRegistry.
pub fn parseTemplates(allocator: std.mem.Allocator, data: []const u8) ParseError!MissionTemplateRegistry {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "RNDM")) return ParseError.InvalidFormat;

    // Count FORM:MISN children
    var misn_count: usize = 0;
    for (root.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "MISN")) {
            misn_count += 1;
        }
    }

    const templates = allocator.alloc(MissionTemplate, misn_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(templates);

    var idx: usize = 0;
    errdefer {
        for (templates[0..idx]) |*t| {
            t.deinit();
        }
    }

    for (root.children) |*child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "MISN")) {
            templates[idx] = try parseTemplate(allocator, child);
            idx += 1;
        }
    }

    return MissionTemplateRegistry{
        .templates = templates,
        .allocator = allocator,
    };
}

/// Generate a concrete mission from a template.
pub fn generateMission(
    allocator: std.mem.Allocator,
    template: *const MissionTemplate,
    destination_system: u8,
    seed: u64,
) ParseError!Mission {
    // Use seed to deterministically pick a reward in [min, max]
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const range: u32 = @intCast(@max(template.max_reward - template.min_reward, 0));
    const offset: i32 = if (range > 0) @intCast(random.uintLessThan(u32, range + 1)) else 0;
    const reward = template.min_reward + offset;

    const briefing = allocator.dupe(u8, template.briefing) catch return ParseError.OutOfMemory;

    return Mission{
        .mission_type = template.mission_type,
        .difficulty = template.difficulty,
        .briefing = briefing,
        .reward = reward,
        .destination_system = destination_system,
        .accepted = false,
        .completed = false,
        .allocator = allocator,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

fn loadTestTemplates(allocator: std.mem.Allocator) !struct { registry: MissionTemplateRegistry, data: []const u8 } {
    const data = try testing_helpers.loadFixture(allocator, "test_mission_templates.bin");
    const registry = parseTemplates(allocator, data) catch {
        allocator.free(data);
        return error.TestFixtureError;
    };
    return .{ .registry = registry, .data = data };
}

test "parseTemplates loads 4 mission templates" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 4), registry.templates.len);
}

test "parseTemplates template 0 is patrol with correct properties" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    const patrol = registry.templates[0];
    try std.testing.expectEqual(MissionType.patrol, patrol.mission_type);
    try std.testing.expectEqual(@as(u8, 1), patrol.difficulty);
    try std.testing.expectEqual(@as(u16, 0x3F), patrol.base_type_mask);
    try std.testing.expectEqualStrings("Patrol the designated nav points in the sector.", patrol.briefing);
    try std.testing.expectEqual(@as(i32, 5000), patrol.min_reward);
    try std.testing.expectEqual(@as(i32, 15000), patrol.max_reward);
}

test "parseTemplates template 1 is cargo delivery" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    const cargo = registry.templates[1];
    try std.testing.expectEqual(MissionType.cargo, cargo.mission_type);
    try std.testing.expectEqual(@as(u8, 1), cargo.difficulty);
    try std.testing.expectEqual(@as(u16, 0x07), cargo.base_type_mask);
    try std.testing.expectEqual(@as(i32, 3000), cargo.min_reward);
    try std.testing.expectEqual(@as(i32, 10000), cargo.max_reward);
}

test "parseTemplates template 2 is bounty hunt" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    const bounty = registry.templates[2];
    try std.testing.expectEqual(MissionType.bounty, bounty.mission_type);
    try std.testing.expectEqual(@as(u8, 3), bounty.difficulty);
    try std.testing.expectEqual(@as(u16, 0x30), bounty.base_type_mask);
    try std.testing.expectEqual(@as(i32, 10000), bounty.min_reward);
    try std.testing.expectEqual(@as(i32, 25000), bounty.max_reward);
}

test "parseTemplates template 3 is defend mission" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    const defend = registry.templates[3];
    try std.testing.expectEqual(MissionType.defend, defend.mission_type);
    try std.testing.expectEqual(@as(u8, 2), defend.difficulty);
    try std.testing.expectEqual(@as(u16, 0x23), defend.base_type_mask);
    try std.testing.expectEqual(@as(i32, 8000), defend.min_reward);
    try std.testing.expectEqual(@as(i32, 20000), defend.max_reward);
}

test "MissionType.name returns correct string" {
    try std.testing.expectEqualStrings("Patrol", MissionType.patrol.name());
    try std.testing.expectEqualStrings("Bounty Hunt", MissionType.bounty.name());
    try std.testing.expectEqualStrings("Cargo Delivery", MissionType.cargo.name());
}

test "BaseTypeMask.fromBaseType maps base types correctly" {
    try std.testing.expectEqual(@as(u16, 0x01), BaseTypeMask.fromBaseType(1)); // agricultural
    try std.testing.expectEqual(@as(u16, 0x02), BaseTypeMask.fromBaseType(2)); // mining
    try std.testing.expectEqual(@as(u16, 0x04), BaseTypeMask.fromBaseType(3)); // refinery
    try std.testing.expectEqual(@as(u16, 0x08), BaseTypeMask.fromBaseType(4)); // pleasure
    try std.testing.expectEqual(@as(u16, 0x10), BaseTypeMask.fromBaseType(5)); // pirate
    try std.testing.expectEqual(@as(u16, 0x20), BaseTypeMask.fromBaseType(6)); // military
    try std.testing.expectEqual(@as(u16, 0), BaseTypeMask.fromBaseType(0)); // invalid
    try std.testing.expectEqual(@as(u16, 0), BaseTypeMask.fromBaseType(7)); // invalid
}

test "MissionTemplate.availableAtBase filters correctly" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    // Patrol (mask=0x3F) available everywhere
    try std.testing.expect(registry.templates[0].availableAtBase(1)); // agricultural
    try std.testing.expect(registry.templates[0].availableAtBase(6)); // military

    // Cargo (mask=0x07) only at agricultural, mining, refinery
    try std.testing.expect(registry.templates[1].availableAtBase(1)); // agricultural
    try std.testing.expect(registry.templates[1].availableAtBase(2)); // mining
    try std.testing.expect(registry.templates[1].availableAtBase(3)); // refinery
    try std.testing.expect(!registry.templates[1].availableAtBase(4)); // not pleasure
    try std.testing.expect(!registry.templates[1].availableAtBase(5)); // not pirate
    try std.testing.expect(!registry.templates[1].availableAtBase(6)); // not military

    // Bounty (mask=0x30) only at pirate and military
    try std.testing.expect(!registry.templates[2].availableAtBase(1)); // not agricultural
    try std.testing.expect(registry.templates[2].availableAtBase(5)); // pirate
    try std.testing.expect(registry.templates[2].availableAtBase(6)); // military
}

test "templatesForBase returns correct subset for agricultural base" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    // Agricultural (type 1): patrol (0x3F), cargo (0x07), defend (0x23)
    const agri = try registry.templatesForBase(allocator, 1);
    defer allocator.free(agri);
    try std.testing.expectEqual(@as(usize, 3), agri.len);
    try std.testing.expectEqual(MissionType.patrol, agri[0].mission_type);
    try std.testing.expectEqual(MissionType.cargo, agri[1].mission_type);
    try std.testing.expectEqual(MissionType.defend, agri[2].mission_type);
}

test "templatesForBase returns correct subset for pirate base" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    // Pirate (type 5): patrol (0x3F), bounty (0x30)
    const pirate = try registry.templatesForBase(allocator, 5);
    defer allocator.free(pirate);
    try std.testing.expectEqual(@as(usize, 2), pirate.len);
    try std.testing.expectEqual(MissionType.patrol, pirate[0].mission_type);
    try std.testing.expectEqual(MissionType.bounty, pirate[1].mission_type);
}

test "templatesForBase returns correct subset for military base" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    // Military (type 6): patrol (0x3F), bounty (0x30), defend (0x23)
    const mil = try registry.templatesForBase(allocator, 6);
    defer allocator.free(mil);
    try std.testing.expectEqual(@as(usize, 3), mil.len);
    try std.testing.expectEqual(MissionType.patrol, mil[0].mission_type);
    try std.testing.expectEqual(MissionType.bounty, mil[1].mission_type);
    try std.testing.expectEqual(MissionType.defend, mil[2].mission_type);
}

test "generateMission produces valid mission from template" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    var mission = try generateMission(allocator, &registry.templates[0], 5, 42);
    defer mission.deinit();

    try std.testing.expectEqual(MissionType.patrol, mission.mission_type);
    try std.testing.expectEqual(@as(u8, 1), mission.difficulty);
    try std.testing.expectEqual(@as(u8, 5), mission.destination_system);
    try std.testing.expect(mission.reward >= 5000);
    try std.testing.expect(mission.reward <= 15000);
    try std.testing.expect(!mission.accepted);
    try std.testing.expect(!mission.completed);
    try std.testing.expectEqualStrings("Patrol the designated nav points in the sector.", mission.briefing);
}

test "generateMission reward is within template bounds" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    // Generate many missions with different seeds, all should be in range
    for (0..20) |seed| {
        var mission = try generateMission(allocator, &registry.templates[2], 10, seed);
        defer mission.deinit();

        try std.testing.expect(mission.reward >= 10000);
        try std.testing.expect(mission.reward <= 25000);
    }
}

test "generateMission different seeds produce different rewards" {
    const allocator = std.testing.allocator;
    const loaded = try loadTestTemplates(allocator);
    defer allocator.free(loaded.data);
    var registry = loaded.registry;
    defer registry.deinit();

    var m1 = try generateMission(allocator, &registry.templates[0], 5, 1);
    defer m1.deinit();
    var m2 = try generateMission(allocator, &registry.templates[0], 5, 999);
    defer m2.deinit();

    // With different seeds and a 10000 range, rewards should differ
    // (vanishingly unlikely to be equal)
    try std.testing.expect(m1.reward != m2.reward);
}

test "parseTemplates rejects non-RNDM form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseTemplates(allocator, data));
}
