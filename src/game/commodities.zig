//! Commodity system for Wing Commander: Privateer.
//! Parses COMODTYP.IFF (FORM:COMD) which defines all tradeable commodities,
//! their base prices, and price/availability modifiers per base type.
//!
//! Structure (from real game data analysis):
//!   FORM:COMD
//!     FORM:COMM (per commodity, 42 in real data)
//!       INFO (4 bytes: id(u16 LE) + category(u16 LE))
//!       LABL (N bytes: null-terminated commodity name)
//!       COST (38 bytes: base_price(i16 LE) + 9 × {base_type_id(i16 LE), modifier(i16 LE)})
//!       AVAL (38 bytes: base_avail(i16 LE) + 9 × {base_type_id(i16 LE), quantity(i16 LE)})

const std = @import("std");
const iff = @import("../formats/iff.zig");

/// Number of base type entries in COST/AVAL chunks.
pub const NUM_BASE_TYPES = 9;

/// A price or availability modifier for a specific base type.
pub const BaseModifier = struct {
    /// Base type identifier (e.g. 0x1f, 0x20, 0x27, 0x29, 1-5).
    base_type_id: i16,
    /// Price modifier or availability quantity. -1 (0xFFFF) = unavailable.
    value: i16,
};

/// A tradeable commodity in the Gemini Sector.
pub const Commodity = struct {
    /// Commodity ID (matches CommodityId used by tractor_cargo system).
    id: u16,
    /// Commodity category (0=food, 1=raw materials, 2=manufactured, etc.).
    category: u16,
    /// Commodity name (owned).
    name: []const u8,
    /// Base cost in credits.
    base_cost: i16,
    /// Price modifiers per base type.
    cost_modifiers: [NUM_BASE_TYPES]BaseModifier,
    /// Base availability quantity.
    base_availability: i16,
    /// Availability quantities per base type (-1 = unavailable).
    avail_modifiers: [NUM_BASE_TYPES]BaseModifier,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Commodity) void {
        self.allocator.free(self.name);
    }

    /// Calculate the price at a given base type. Returns null if unavailable.
    pub fn priceAtBase(self: Commodity, base_type_id: i16) ?i16 {
        for (self.avail_modifiers) |avail| {
            if (avail.base_type_id == base_type_id) {
                if (avail.value == -1) return null;
                break;
            }
        }
        for (self.cost_modifiers) |cost| {
            if (cost.base_type_id == base_type_id) {
                return self.base_cost + cost.value;
            }
        }
        return null;
    }
};

/// All commodities loaded from COMODTYP.IFF.
pub const CommodityRegistry = struct {
    /// All commodities, ordered by appearance in the file.
    commodities: []Commodity,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommodityRegistry) void {
        for (self.commodities) |*c| {
            c.deinit();
        }
        self.allocator.free(self.commodities);
    }

    /// Find a commodity by its ID. Returns null if not found.
    pub fn findById(self: CommodityRegistry, id: u16) ?*const Commodity {
        for (self.commodities) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// Find a commodity by name (case-insensitive). Returns null if not found.
    pub fn findByName(self: CommodityRegistry, name: []const u8) ?*const Commodity {
        for (self.commodities) |*c| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
        }
        return null;
    }
};

pub const CommodityError = error{
    InvalidFormat,
    MissingInfo,
    OutOfMemory,
};

fn readI16LE(data: []const u8) i16 {
    return @bitCast(std.mem.readInt(u16, data[0..2], .little));
}

fn readU16LE(data: []const u8) u16 {
    return std.mem.readInt(u16, data[0..2], .little);
}

/// Parse COST or AVAL chunk data (38 bytes) into base value + 9 modifiers.
fn parseModifiers(data: []const u8) CommodityError!struct { base: i16, entries: [NUM_BASE_TYPES]BaseModifier } {
    if (data.len < 38) return CommodityError.MissingInfo;

    const base = readI16LE(data[0..2]);
    var entries: [NUM_BASE_TYPES]BaseModifier = undefined;

    for (0..NUM_BASE_TYPES) |i| {
        const offset = 2 + i * 4;
        entries[i] = .{
            .base_type_id = readI16LE(data[offset .. offset + 2]),
            .value = readI16LE(data[offset + 2 .. offset + 4]),
        };
    }

    return .{ .base = base, .entries = entries };
}

/// Parse a single FORM:COMM chunk into a Commodity.
fn parseCommodity(allocator: std.mem.Allocator, form: *const iff.Chunk) CommodityError!Commodity {
    if (!form.isContainer()) return CommodityError.InvalidFormat;
    if (!std.mem.eql(u8, &form.form_type.?, "COMM")) return CommodityError.InvalidFormat;

    // Parse INFO chunk (4 bytes: id u16 LE + category u16 LE)
    const info_chunk = form.findChild("INFO".*) orelse return CommodityError.MissingInfo;
    if (info_chunk.data.len < 4) return CommodityError.MissingInfo;
    const id = readU16LE(info_chunk.data[0..2]);
    const category = readU16LE(info_chunk.data[2..4]);

    // Parse LABL chunk (null-terminated name)
    const labl_chunk = form.findChild("LABL".*) orelse return CommodityError.MissingInfo;
    const name_len = std.mem.indexOfScalar(u8, labl_chunk.data, 0) orelse labl_chunk.data.len;
    const name = allocator.dupe(u8, labl_chunk.data[0..name_len]) catch return CommodityError.OutOfMemory;
    errdefer allocator.free(name);

    // Parse COST chunk (38 bytes)
    const cost_chunk = form.findChild("COST".*) orelse return CommodityError.MissingInfo;
    const cost = try parseModifiers(cost_chunk.data);

    // Parse AVAL chunk (38 bytes)
    const aval_chunk = form.findChild("AVAL".*) orelse return CommodityError.MissingInfo;
    const avail = try parseModifiers(aval_chunk.data);

    return Commodity{
        .id = id,
        .category = category,
        .name = name,
        .base_cost = cost.base,
        .cost_modifiers = cost.entries,
        .base_availability = avail.base,
        .avail_modifiers = avail.entries,
        .allocator = allocator,
    };
}

/// Parse a COMODTYP.IFF file (FORM:COMD) into a CommodityRegistry.
pub fn parseCommodities(allocator: std.mem.Allocator, data: []const u8) CommodityError!CommodityRegistry {
    var root = iff.parseFile(allocator, data) catch return CommodityError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return CommodityError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "COMD")) return CommodityError.InvalidFormat;

    // Count FORM:COMM children
    var comm_count: usize = 0;
    for (root.children) |child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "COMM")) {
            comm_count += 1;
        }
    }

    const commodities = allocator.alloc(Commodity, comm_count) catch return CommodityError.OutOfMemory;
    errdefer allocator.free(commodities);

    var idx: usize = 0;
    errdefer {
        for (commodities[0..idx]) |*c| {
            c.deinit();
        }
    }

    for (root.children) |*child| {
        if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "COMM")) {
            commodities[idx] = try parseCommodity(allocator, child);
            idx += 1;
        }
    }

    return CommodityRegistry{
        .commodities = commodities,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parseCommodities loads test fixture with 3 commodities" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 3), registry.commodities.len);
}

test "parseCommodities commodity 0 is Grain with correct properties" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const grain = registry.commodities[0];
    try std.testing.expectEqual(@as(u16, 0), grain.id);
    try std.testing.expectEqual(@as(u16, 0), grain.category);
    try std.testing.expectEqualStrings("Grain", grain.name);
    try std.testing.expectEqual(@as(i16, 20), grain.base_cost);
}

test "parseCommodities commodity 1 is Iron with category 1" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const iron = registry.commodities[1];
    try std.testing.expectEqual(@as(u16, 5), iron.id);
    try std.testing.expectEqual(@as(u16, 1), iron.category);
    try std.testing.expectEqualStrings("Iron", iron.name);
    try std.testing.expectEqual(@as(i16, 50), iron.base_cost);
}

test "parseCommodities Tobacco is contraband category 6" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const tobacco = registry.commodities[2];
    try std.testing.expectEqual(@as(u16, 34), tobacco.id);
    try std.testing.expectEqual(@as(u16, 6), tobacco.category);
    try std.testing.expectEqualStrings("Tobacco", tobacco.name);
    try std.testing.expectEqual(@as(i16, 100), tobacco.base_cost);
}

test "parseCommodities cost modifiers parsed correctly for Grain" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const grain = registry.commodities[0];
    // First cost modifier: base_type_id=0x1f(31), value=3
    try std.testing.expectEqual(@as(i16, 0x1f), grain.cost_modifiers[0].base_type_id);
    try std.testing.expectEqual(@as(i16, 3), grain.cost_modifiers[0].value);
    // Third cost modifier: base_type_id=0x27(39), value=-13
    try std.testing.expectEqual(@as(i16, 0x27), grain.cost_modifiers[2].base_type_id);
    try std.testing.expectEqual(@as(i16, -13), grain.cost_modifiers[2].value);
}

test "parseCommodities availability modifiers parsed correctly" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const grain = registry.commodities[0];
    try std.testing.expectEqual(@as(i16, 50), grain.base_availability);
    // base_type 0x1f: unavailable (-1)
    try std.testing.expectEqual(@as(i16, -1), grain.avail_modifiers[0].value);
    // base_type 0x27: quantity 20
    try std.testing.expectEqual(@as(i16, 20), grain.avail_modifiers[2].value);
    // base_type 0x04: quantity 60
    try std.testing.expectEqual(@as(i16, 60), grain.avail_modifiers[6].value);
}

test "Commodity.priceAtBase calculates correct price" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const grain = registry.commodities[0];
    // base_type 0x27: available (avail=20), cost modifier=-13, price = 20 + (-13) = 7
    try std.testing.expectEqual(@as(i16, 7), grain.priceAtBase(0x27).?);
    // base_type 0x04: available (avail=60), cost modifier=-15, price = 20 + (-15) = 5
    try std.testing.expectEqual(@as(i16, 5), grain.priceAtBase(0x04).?);
    // base_type 0x1f: unavailable (avail=-1), should return null
    try std.testing.expect(grain.priceAtBase(0x1f) == null);
}

test "CommodityRegistry.findById finds existing commodity" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const iron = registry.findById(5);
    try std.testing.expect(iron != null);
    try std.testing.expectEqualStrings("Iron", iron.?.name);

    try std.testing.expect(registry.findById(99) == null);
}

test "CommodityRegistry.findByName finds commodity case-insensitively" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    defer allocator.free(data);

    var registry = try parseCommodities(allocator, data);
    defer registry.deinit();

    const tobacco = registry.findByName("tobacco");
    try std.testing.expect(tobacco != null);
    try std.testing.expectEqual(@as(u16, 34), tobacco.?.id);

    try std.testing.expect(registry.findByName("Nonexistent") == null);
}

test "parseCommodities rejects non-COMD form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(CommodityError.InvalidFormat, parseCommodities(allocator, data));
}
