//! Ship dealer system for Wing Commander: Privateer.
//!
//! Parses SHIPSTUF.IFF (FORM:SHPS) which defines all purchasable ships
//! and equipment. Handles ship purchases, equipment sales, and
//! hardpoint compatibility validation.
//!
//! Structure:
//!   FORM:SHPS
//!     FORM:SHPC (ship catalog)
//!       FORM:SHIP (per ship)
//!         INFO (4 bytes: id(u16 LE) + ship_class(u16 LE))
//!         LABL (null-terminated ship name)
//!         COST (4 bytes: price(i32 LE))
//!         STAT (12 bytes: speed(u16 LE) + shields(u16 LE) + armor(u16 LE) +
//!               cargo(u16 LE) + gun_mounts(u8) + missile_mounts(u8) +
//!               turret_mounts(u8) + pad(u8))
//!     FORM:EQPC (equipment catalog)
//!       FORM:EQUP (per equipment)
//!         INFO (4 bytes: id(u16 LE) + category(u16 LE))
//!         LABL (null-terminated equipment name)
//!         COST (4 bytes: price(i32 LE))
//!         CMPT (1 + N*2 bytes: count(u8) + ship_id(u16 LE) per compatible ship)

const std = @import("std");
const iff = @import("../formats/iff.zig");

// ── Data Types ──────────────────────────────────────────────────────

/// Equipment category.
pub const EquipmentCategory = enum(u16) {
    gun = 0,
    shield = 1,
    armor = 2,
    software = 3,
    _,
};

/// Ship specification from the ship catalog.
pub const ShipSpec = struct {
    id: u16,
    ship_class: u16,
    name: []const u8,
    price: i32,
    speed: u16,
    shields: u16,
    armor: u16,
    cargo_capacity: u16,
    gun_mounts: u8,
    missile_mounts: u8,
    turret_mounts: u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ShipSpec) void {
        self.allocator.free(self.name);
    }
};

/// Maximum number of compatible ships per equipment item.
const MAX_COMPATIBLE_SHIPS = 16;

/// Equipment specification from the equipment catalog.
pub const EquipmentSpec = struct {
    id: u16,
    category: EquipmentCategory,
    name: []const u8,
    price: i32,
    /// Ship IDs this equipment is compatible with.
    compatible_ships: [MAX_COMPATIBLE_SHIPS]u16,
    compatible_count: u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *EquipmentSpec) void {
        self.allocator.free(self.name);
    }

    /// Check if this equipment is compatible with a specific ship.
    pub fn isCompatibleWith(self: *const EquipmentSpec, ship_id: u16) bool {
        for (self.compatible_ships[0..self.compatible_count]) |sid| {
            if (sid == ship_id) return true;
        }
        return false;
    }
};

/// Ship and equipment catalog loaded from SHIPSTUF.IFF.
pub const ShipCatalog = struct {
    ships: []ShipSpec,
    equipment: []EquipmentSpec,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ShipCatalog) void {
        for (self.ships) |*s| s.deinit();
        self.allocator.free(self.ships);
        for (self.equipment) |*e| e.deinit();
        self.allocator.free(self.equipment);
    }

    pub fn findShipById(self: *const ShipCatalog, id: u16) ?*const ShipSpec {
        for (self.ships) |*s| {
            if (s.id == id) return s;
        }
        return null;
    }

    pub fn findEquipmentById(self: *const ShipCatalog, id: u16) ?*const EquipmentSpec {
        for (self.equipment) |*e| {
            if (e.id == id) return e;
        }
        return null;
    }

    pub fn findShipByName(self: *const ShipCatalog, name: []const u8) ?*const ShipSpec {
        for (self.ships) |*s| {
            if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
        }
        return null;
    }

    pub fn findEquipmentByName(self: *const ShipCatalog, name: []const u8) ?*const EquipmentSpec {
        for (self.equipment) |*e| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) return e;
        }
        return null;
    }
};

// ── Parsing ─────────────────────────────────────────────────────────

pub const ParseError = error{
    InvalidFormat,
    MissingChunk,
    OutOfMemory,
};

fn readU16LE(data: []const u8) u16 {
    return std.mem.readInt(u16, data[0..2], .little);
}

fn readI32LE(data: []const u8) i32 {
    return @bitCast(std.mem.readInt(u32, data[0..4], .little));
}

fn parseShip(allocator: std.mem.Allocator, form: *const iff.Chunk) ParseError!ShipSpec {
    if (!form.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &form.form_type.?, "SHIP")) return ParseError.InvalidFormat;

    const info = form.findChild("INFO".*) orelse return ParseError.MissingChunk;
    if (info.data.len < 4) return ParseError.MissingChunk;
    const id = readU16LE(info.data[0..2]);
    const ship_class = readU16LE(info.data[2..4]);

    const labl = form.findChild("LABL".*) orelse return ParseError.MissingChunk;
    const name_len = std.mem.indexOfScalar(u8, labl.data, 0) orelse labl.data.len;
    const name = allocator.dupe(u8, labl.data[0..name_len]) catch return ParseError.OutOfMemory;
    errdefer allocator.free(name);

    const cost = form.findChild("COST".*) orelse return ParseError.MissingChunk;
    if (cost.data.len < 4) return ParseError.MissingChunk;
    const price = readI32LE(cost.data[0..4]);

    const stat = form.findChild("STAT".*) orelse return ParseError.MissingChunk;
    if (stat.data.len < 11) return ParseError.MissingChunk;

    return ShipSpec{
        .id = id,
        .ship_class = ship_class,
        .name = name,
        .price = price,
        .speed = readU16LE(stat.data[0..2]),
        .shields = readU16LE(stat.data[2..4]),
        .armor = readU16LE(stat.data[4..6]),
        .cargo_capacity = readU16LE(stat.data[6..8]),
        .gun_mounts = stat.data[8],
        .missile_mounts = stat.data[9],
        .turret_mounts = stat.data[10],
        .allocator = allocator,
    };
}

fn parseEquipment(allocator: std.mem.Allocator, form: *const iff.Chunk) ParseError!EquipmentSpec {
    if (!form.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &form.form_type.?, "EQUP")) return ParseError.InvalidFormat;

    const info = form.findChild("INFO".*) orelse return ParseError.MissingChunk;
    if (info.data.len < 4) return ParseError.MissingChunk;
    const id = readU16LE(info.data[0..2]);
    const category: EquipmentCategory = @enumFromInt(readU16LE(info.data[2..4]));

    const labl = form.findChild("LABL".*) orelse return ParseError.MissingChunk;
    const name_len = std.mem.indexOfScalar(u8, labl.data, 0) orelse labl.data.len;
    const name = allocator.dupe(u8, labl.data[0..name_len]) catch return ParseError.OutOfMemory;
    errdefer allocator.free(name);

    const cost = form.findChild("COST".*) orelse return ParseError.MissingChunk;
    if (cost.data.len < 4) return ParseError.MissingChunk;
    const price = readI32LE(cost.data[0..4]);

    const cmpt = form.findChild("CMPT".*) orelse return ParseError.MissingChunk;
    if (cmpt.data.len < 1) return ParseError.MissingChunk;
    const compat_count = cmpt.data[0];
    if (cmpt.data.len < 1 + @as(usize, compat_count) * 2) return ParseError.MissingChunk;

    var compatible_ships: [MAX_COMPATIBLE_SHIPS]u16 = [_]u16{0} ** MAX_COMPATIBLE_SHIPS;
    const count = @min(compat_count, MAX_COMPATIBLE_SHIPS);
    for (0..count) |i| {
        const offset = 1 + i * 2;
        compatible_ships[i] = readU16LE(cmpt.data[offset .. offset + 2]);
    }

    return EquipmentSpec{
        .id = id,
        .category = category,
        .name = name,
        .price = price,
        .compatible_ships = compatible_ships,
        .compatible_count = count,
        .allocator = allocator,
    };
}

/// Parse a SHIPSTUF.IFF file (FORM:SHPS) into a ShipCatalog.
pub fn parseShipCatalog(allocator: std.mem.Allocator, data: []const u8) ParseError!ShipCatalog {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "SHPS")) return ParseError.InvalidFormat;

    // Find FORM:SHPC (ship catalog)
    var ship_count: usize = 0;
    var equip_count: usize = 0;
    var shpc_form: ?*const iff.Chunk = null;
    var eqpc_form: ?*const iff.Chunk = null;

    for (root.children) |*child| {
        if (child.isContainer()) {
            if (std.mem.eql(u8, &child.form_type.?, "SHPC")) {
                shpc_form = child;
                for (child.children) |sub| {
                    if (sub.isContainer() and std.mem.eql(u8, &sub.form_type.?, "SHIP")) {
                        ship_count += 1;
                    }
                }
            } else if (std.mem.eql(u8, &child.form_type.?, "EQPC")) {
                eqpc_form = child;
                for (child.children) |sub| {
                    if (sub.isContainer() and std.mem.eql(u8, &sub.form_type.?, "EQUP")) {
                        equip_count += 1;
                    }
                }
            }
        }
    }

    // Parse ships
    const ships = allocator.alloc(ShipSpec, ship_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(ships);
    var si: usize = 0;
    errdefer {
        for (ships[0..si]) |*s| s.deinit();
    }

    if (shpc_form) |shpc| {
        for (shpc.children) |*child| {
            if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "SHIP")) {
                ships[si] = try parseShip(allocator, child);
                si += 1;
            }
        }
    }

    // Parse equipment
    const equipment = allocator.alloc(EquipmentSpec, equip_count) catch return ParseError.OutOfMemory;
    errdefer {
        allocator.free(equipment);
        // Also clean up ships on error
        for (ships[0..si]) |*s| s.deinit();
        allocator.free(ships);
    }
    var ei: usize = 0;
    errdefer {
        for (equipment[0..ei]) |*e| e.deinit();
    }

    if (eqpc_form) |eqpc| {
        for (eqpc.children) |*child| {
            if (child.isContainer() and std.mem.eql(u8, &child.form_type.?, "EQUP")) {
                equipment[ei] = try parseEquipment(allocator, child);
                ei += 1;
            }
        }
    }

    return ShipCatalog{
        .ships = ships,
        .equipment = equipment,
        .allocator = allocator,
    };
}

// ── Ship Dealer (Transaction Logic) ─────────────────────────────────

pub const DealerError = error{
    /// Player does not have enough credits.
    InsufficientCredits,
    /// Ship not found in the catalog.
    ShipNotFound,
    /// Equipment not found in the catalog.
    EquipmentNotFound,
    /// Equipment is not compatible with the player's ship.
    IncompatibleEquipment,
};

/// Result of a ship or equipment purchase.
pub const PurchaseResult = struct {
    /// Price paid.
    price: i32,
    /// New credit balance.
    new_balance: i32,
};

/// Manages ship and equipment transactions.
pub const ShipDealer = struct {
    catalog: *const ShipCatalog,

    pub fn init(catalog: *const ShipCatalog) ShipDealer {
        return .{ .catalog = catalog };
    }

    /// Buy a ship. Returns trade-in value of old ship (half its catalog price).
    /// Net cost = new ship price - trade-in value.
    pub fn buyShip(
        self: *const ShipDealer,
        new_ship_id: u16,
        current_ship_id: u16,
        credits: *i32,
    ) DealerError!PurchaseResult {
        const new_ship = self.catalog.findShipById(new_ship_id) orelse
            return DealerError.ShipNotFound;
        const current_ship = self.catalog.findShipById(current_ship_id) orelse
            return DealerError.ShipNotFound;

        const trade_in: i32 = @divTrunc(current_ship.price, 2);
        const net_cost: i32 = new_ship.price - trade_in;

        if (credits.* < net_cost) return DealerError.InsufficientCredits;

        credits.* -= net_cost;
        return PurchaseResult{
            .price = net_cost,
            .new_balance = credits.*,
        };
    }

    /// Buy equipment. Checks compatibility with the player's current ship.
    pub fn buyEquipment(
        self: *const ShipDealer,
        equipment_id: u16,
        ship_id: u16,
        credits: *i32,
    ) DealerError!PurchaseResult {
        const equip = self.catalog.findEquipmentById(equipment_id) orelse
            return DealerError.EquipmentNotFound;

        if (!equip.isCompatibleWith(ship_id)) return DealerError.IncompatibleEquipment;

        if (credits.* < equip.price) return DealerError.InsufficientCredits;

        credits.* -= equip.price;
        return PurchaseResult{
            .price = equip.price,
            .new_balance = credits.*,
        };
    }

    /// Sell equipment. Returns half the catalog price.
    pub fn sellEquipment(
        self: *const ShipDealer,
        equipment_id: u16,
        credits: *i32,
    ) DealerError!PurchaseResult {
        const equip = self.catalog.findEquipmentById(equipment_id) orelse
            return DealerError.EquipmentNotFound;

        const sell_price: i32 = @divTrunc(equip.price, 2);
        credits.* += sell_price;

        return PurchaseResult{
            .price = sell_price,
            .new_balance = credits.*,
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

fn loadTestCatalog(allocator: std.mem.Allocator) !struct { catalog: ShipCatalog, data: []const u8 } {
    const data = try testing_helpers.loadFixture(allocator, "test_shipstuf.bin");
    const catalog = parseShipCatalog(allocator, data) catch {
        allocator.free(data);
        return error.TestFixtureError;
    };
    return .{ .catalog = catalog, .data = data };
}

fn cleanupTestCatalog(allocator: std.mem.Allocator, cat: *ShipCatalog, data: []const u8) void {
    cat.deinit();
    allocator.free(data);
}

// --- Parsing tests ---

test "parseShipCatalog loads 3 ships and 4 equipment items" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    try std.testing.expectEqual(@as(usize, 3), loaded.catalog.ships.len);
    try std.testing.expectEqual(@as(usize, 4), loaded.catalog.equipment.len);
}

test "parseShipCatalog Tarsus has correct properties" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const tarsus = loaded.catalog.ships[0];
    try std.testing.expectEqual(@as(u16, 0), tarsus.id);
    try std.testing.expectEqual(@as(u16, 0), tarsus.ship_class);
    try std.testing.expectEqualStrings("Tarsus", tarsus.name);
    try std.testing.expectEqual(@as(i32, 20000), tarsus.price);
    try std.testing.expectEqual(@as(u16, 200), tarsus.speed);
    try std.testing.expectEqual(@as(u16, 20), tarsus.cargo_capacity);
    try std.testing.expectEqual(@as(u8, 2), tarsus.gun_mounts);
    try std.testing.expectEqual(@as(u8, 1), tarsus.missile_mounts);
    try std.testing.expectEqual(@as(u8, 0), tarsus.turret_mounts);
}

test "parseShipCatalog Centurion has correct properties" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const cent = loaded.catalog.findShipById(2).?;
    try std.testing.expectEqualStrings("Centurion", cent.name);
    try std.testing.expectEqual(@as(i32, 200000), cent.price);
    try std.testing.expectEqual(@as(u16, 300), cent.speed);
    try std.testing.expectEqual(@as(u8, 4), cent.gun_mounts);
}

test "parseShipCatalog Laser is compatible with all ships" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const laser = loaded.catalog.findEquipmentById(0).?;
    try std.testing.expectEqualStrings("Laser", laser.name);
    try std.testing.expectEqual(@as(i32, 5000), laser.price);
    try std.testing.expectEqual(EquipmentCategory.gun, laser.category);
    try std.testing.expect(laser.isCompatibleWith(0)); // Tarsus
    try std.testing.expect(laser.isCompatibleWith(1)); // Galaxy
    try std.testing.expect(laser.isCompatibleWith(2)); // Centurion
}

test "parseShipCatalog Plasma Gun is Centurion-only" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const plasma = loaded.catalog.findEquipmentById(1).?;
    try std.testing.expectEqualStrings("Plasma Gun", plasma.name);
    try std.testing.expect(!plasma.isCompatibleWith(0)); // Not Tarsus
    try std.testing.expect(!plasma.isCompatibleWith(1)); // Not Galaxy
    try std.testing.expect(plasma.isCompatibleWith(2)); // Centurion only
}

test "findShipByName case-insensitive" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    try std.testing.expect(loaded.catalog.findShipByName("galaxy") != null);
    try std.testing.expect(loaded.catalog.findShipByName("CENTURION") != null);
    try std.testing.expect(loaded.catalog.findShipByName("Nonexistent") == null);
}

// --- Ship purchase tests ---

test "buying Centurion with sufficient credits succeeds" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 250000;

    // Buy Centurion (200000), trade in Tarsus (20000/2 = 10000 trade-in)
    // Net cost = 200000 - 10000 = 190000
    const result = try dealer.buyShip(2, 0, &credits);
    try std.testing.expectEqual(@as(i32, 190000), result.price);
    try std.testing.expectEqual(@as(i32, 60000), result.new_balance);
    try std.testing.expectEqual(@as(i32, 60000), credits);
}

test "buying ship with insufficient credits fails" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 50000;

    // Centurion costs 200000, trade-in Tarsus gives 10000, net 190000 > 50000
    const result = dealer.buyShip(2, 0, &credits);
    try std.testing.expectError(DealerError.InsufficientCredits, result);
    try std.testing.expectEqual(@as(i32, 50000), credits); // Unchanged
}

test "buying nonexistent ship fails" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 999999;

    try std.testing.expectError(DealerError.ShipNotFound, dealer.buyShip(99, 0, &credits));
}

// --- Equipment purchase tests ---

test "buying compatible equipment succeeds" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 50000;

    // Buy Laser (5000 cr) for Tarsus (compatible)
    const result = try dealer.buyEquipment(0, 0, &credits);
    try std.testing.expectEqual(@as(i32, 5000), result.price);
    try std.testing.expectEqual(@as(i32, 45000), result.new_balance);
}

test "equipment installation respects hardpoint compatibility" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 100000;

    // Plasma Gun (id=1) is Centurion-only, should fail on Tarsus
    const result = dealer.buyEquipment(1, 0, &credits);
    try std.testing.expectError(DealerError.IncompatibleEquipment, result);
    try std.testing.expectEqual(@as(i32, 100000), credits); // Unchanged

    // Plasma Gun should succeed on Centurion
    const ok = try dealer.buyEquipment(1, 2, &credits);
    try std.testing.expectEqual(@as(i32, 40000), ok.price);
    try std.testing.expectEqual(@as(i32, 60000), credits);
}

test "buying equipment with insufficient credits fails" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 1000;

    const result = dealer.buyEquipment(0, 0, &credits); // Laser costs 5000
    try std.testing.expectError(DealerError.InsufficientCredits, result);
}

// --- Equipment sell tests ---

test "selling equipment returns half price" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 10000;

    // Sell Laser (5000 / 2 = 2500)
    const result = try dealer.sellEquipment(0, &credits);
    try std.testing.expectEqual(@as(i32, 2500), result.price);
    try std.testing.expectEqual(@as(i32, 12500), result.new_balance);
}

test "selling nonexistent equipment fails" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestCatalog(allocator);
    defer cleanupTestCatalog(allocator, &loaded.catalog, loaded.data);

    const dealer = ShipDealer.init(&loaded.catalog);
    var credits: i32 = 10000;

    try std.testing.expectError(DealerError.EquipmentNotFound, dealer.sellEquipment(99, &credits));
}

test "parseShipCatalog rejects non-SHPS form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseShipCatalog(allocator, data));
}
