//! Commodity exchange system for Wing Commander: Privateer.
//!
//! Handles buy/sell transactions at base commodity exchanges.
//! Validates credits, cargo space, and commodity availability before
//! executing trades. Prices depend on the base type (agricultural,
//! mining, refinery, etc.) per the COMODTYP.IFF modifier tables.

const std = @import("std");
const commodities = @import("commodities.zig");
const tractor_cargo = @import("../combat/tractor_cargo.zig");

const CommodityRegistry = commodities.CommodityRegistry;
const Commodity = commodities.Commodity;
const CargoHold = tractor_cargo.CargoHold;
const CommodityId = tractor_cargo.CommodityId;

/// Errors that can occur during a commodity exchange transaction.
pub const ExchangeError = error{
    /// Player does not have enough credits for the purchase.
    InsufficientCredits,
    /// Not enough cargo space to hold the purchased goods.
    InsufficientCargoSpace,
    /// Player does not have enough of this commodity to sell.
    InsufficientCargo,
    /// This commodity is not available at this base type.
    CommodityUnavailable,
    /// The commodity ID was not found in the registry.
    CommodityNotFound,
};

/// Result of a buy or sell transaction.
pub const TransactionResult = struct {
    /// Total price paid or received.
    total_price: i32,
    /// New credit balance after the transaction.
    new_balance: i32,
    /// Quantity actually transacted.
    quantity: u16,
};

/// Manages commodity exchange transactions at a base.
pub const CommodityExchange = struct {
    /// Reference to the commodity registry (prices, availability).
    registry: *const CommodityRegistry,
    /// The base type ID of the current base (determines prices).
    base_type_id: i16,

    /// Create a new commodity exchange for a specific base type.
    pub fn init(registry: *const CommodityRegistry, base_type_id: i16) CommodityExchange {
        return .{
            .registry = registry,
            .base_type_id = base_type_id,
        };
    }

    /// Get the price of a commodity at this base. Returns null if unavailable.
    pub fn getPrice(self: *const CommodityExchange, commodity_id: u16) ?i16 {
        const commodity = self.registry.findById(commodity_id) orelse return null;
        return commodity.priceAtBase(self.base_type_id);
    }

    /// List all commodities available at this base with their prices.
    /// Returns the number of available commodities written to the buffer.
    pub fn listAvailable(self: *const CommodityExchange, buf: []AvailableCommodity) []AvailableCommodity {
        var n: usize = 0;
        for (self.registry.commodities) |commodity| {
            if (n >= buf.len) break;
            if (commodity.priceAtBase(self.base_type_id)) |price| {
                buf[n] = .{
                    .id = commodity.id,
                    .name = commodity.name,
                    .price = price,
                    .category = commodity.category,
                };
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// Buy a commodity: deduct credits, add to cargo hold.
    pub fn buy(
        self: *const CommodityExchange,
        commodity_id: u16,
        quantity: u16,
        credits: *i32,
        cargo: *CargoHold,
    ) ExchangeError!TransactionResult {
        // Look up commodity and price
        const commodity = self.registry.findById(commodity_id) orelse
            return ExchangeError.CommodityNotFound;
        const unit_price = commodity.priceAtBase(self.base_type_id) orelse
            return ExchangeError.CommodityUnavailable;

        const total_price: i32 = @as(i32, unit_price) * @as(i32, quantity);

        // Check credits
        if (credits.* < total_price) return ExchangeError.InsufficientCredits;

        // Check cargo space
        if (cargo.freeSpace() < quantity) return ExchangeError.InsufficientCargoSpace;

        // Execute transaction
        const cargo_id: CommodityId = @truncate(commodity_id);
        if (!cargo.addCargo(cargo_id, quantity)) return ExchangeError.InsufficientCargoSpace;

        credits.* -= total_price;

        return TransactionResult{
            .total_price = total_price,
            .new_balance = credits.*,
            .quantity = quantity,
        };
    }

    /// Sell a commodity: remove from cargo hold, add credits.
    pub fn sell(
        self: *const CommodityExchange,
        commodity_id: u16,
        quantity: u16,
        credits: *i32,
        cargo: *CargoHold,
    ) ExchangeError!TransactionResult {
        // Look up commodity and price
        const commodity = self.registry.findById(commodity_id) orelse
            return ExchangeError.CommodityNotFound;
        const unit_price = commodity.priceAtBase(self.base_type_id) orelse
            return ExchangeError.CommodityUnavailable;

        const total_price: i32 = @as(i32, unit_price) * @as(i32, quantity);

        // Check cargo
        const cargo_id: CommodityId = @truncate(commodity_id);
        if (cargo.getQuantity(cargo_id) < quantity) return ExchangeError.InsufficientCargo;

        // Execute transaction
        if (!cargo.removeCargo(cargo_id, quantity)) return ExchangeError.InsufficientCargo;

        credits.* += total_price;

        return TransactionResult{
            .total_price = total_price,
            .new_balance = credits.*,
            .quantity = quantity,
        };
    }
};

/// A commodity available for trade at the current base.
pub const AvailableCommodity = struct {
    id: u16,
    name: []const u8,
    price: i16,
    category: u16,
};

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

fn loadTestRegistry(allocator: std.mem.Allocator) !struct { registry: CommodityRegistry, data: []const u8 } {
    const data = try testing_helpers.loadFixture(allocator, "test_commodities.bin");
    const registry = commodities.parseCommodities(allocator, data) catch {
        allocator.free(data);
        return error.TestFixtureError;
    };
    return .{ .registry = registry, .data = data };
}

fn cleanupTestRegistry(allocator: std.mem.Allocator, reg: *CommodityRegistry, data: []const u8) void {
    reg.deinit();
    allocator.free(data);
}

test "buy commodity reduces credits and adds to cargo" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    // base_type 0x27: Grain price = 20 + (-13) = 7
    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 1000;
    var cargo = CargoHold.init(100);

    const result = try exchange.buy(0, 5, &credits, &cargo); // Buy 5 Grain

    try std.testing.expectEqual(@as(i32, 35), result.total_price); // 5 * 7
    try std.testing.expectEqual(@as(i32, 965), result.new_balance);
    try std.testing.expectEqual(@as(i32, 965), credits);
    try std.testing.expectEqual(@as(u16, 5), cargo.getQuantity(0));
}

test "sell commodity increases credits and removes from cargo" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 500;
    var cargo = CargoHold.init(100);
    _ = cargo.addCargo(0, 10); // Pre-load 10 Grain

    const result = try exchange.sell(0, 3, &credits, &cargo); // Sell 3 Grain

    try std.testing.expectEqual(@as(i32, 21), result.total_price); // 3 * 7
    try std.testing.expectEqual(@as(i32, 521), result.new_balance);
    try std.testing.expectEqual(@as(i32, 521), credits);
    try std.testing.expectEqual(@as(u16, 7), cargo.getQuantity(0));
}

test "buy fails with insufficient credits" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 10; // Only 10 credits
    var cargo = CargoHold.init(100);

    // Grain costs 7 per unit, trying to buy 5 = 35
    const result = exchange.buy(0, 5, &credits, &cargo);
    try std.testing.expectError(ExchangeError.InsufficientCredits, result);
    try std.testing.expectEqual(@as(i32, 10), credits); // Credits unchanged
    try std.testing.expectEqual(@as(u16, 0), cargo.getQuantity(0)); // Cargo unchanged
}

test "buy fails with insufficient cargo space" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 10000;
    var cargo = CargoHold.init(3); // Only 3 units capacity

    const result = exchange.buy(0, 5, &credits, &cargo);
    try std.testing.expectError(ExchangeError.InsufficientCargoSpace, result);
    try std.testing.expectEqual(@as(i32, 10000), credits); // Credits unchanged
}

test "sell fails with insufficient cargo" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 500;
    var cargo = CargoHold.init(100);
    _ = cargo.addCargo(0, 2); // Only 2 Grain

    const result = exchange.sell(0, 5, &credits, &cargo); // Try to sell 5
    try std.testing.expectError(ExchangeError.InsufficientCargo, result);
    try std.testing.expectEqual(@as(i32, 500), credits); // Credits unchanged
    try std.testing.expectEqual(@as(u16, 2), cargo.getQuantity(0)); // Cargo unchanged
}

test "buy fails for unavailable commodity at base type" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    // base_type 0x1f: Grain availability = -1 (unavailable)
    const exchange = CommodityExchange.init(&loaded.registry, 0x1f);
    var credits: i32 = 10000;
    var cargo = CargoHold.init(100);

    const result = exchange.buy(0, 1, &credits, &cargo);
    try std.testing.expectError(ExchangeError.CommodityUnavailable, result);
}

test "sell fails for unavailable commodity at base type" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x1f);
    var credits: i32 = 500;
    var cargo = CargoHold.init(100);
    _ = cargo.addCargo(0, 10);

    const result = exchange.sell(0, 5, &credits, &cargo);
    try std.testing.expectError(ExchangeError.CommodityUnavailable, result);
}

test "buy fails for nonexistent commodity" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 10000;
    var cargo = CargoHold.init(100);

    const result = exchange.buy(999, 1, &credits, &cargo);
    try std.testing.expectError(ExchangeError.CommodityNotFound, result);
}

test "getPrice returns correct price at base" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);

    // Grain: base_cost 20, modifier at 0x27 = -13, price = 7
    try std.testing.expectEqual(@as(i16, 7), exchange.getPrice(0).?);

    // Unavailable commodity returns null
    const exchange2 = CommodityExchange.init(&loaded.registry, 0x1f);
    try std.testing.expect(exchange2.getPrice(0) == null);

    // Nonexistent commodity returns null
    try std.testing.expect(exchange.getPrice(999) == null);
}

test "listAvailable returns only available commodities" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var buf: [10]AvailableCommodity = undefined;
    const available = exchange.listAvailable(&buf);

    // At least Grain should be available at base type 0x27
    try std.testing.expect(available.len > 0);

    // Verify Grain is in the list with correct price
    var found_grain = false;
    for (available) |item| {
        if (item.id == 0) {
            try std.testing.expectEqual(@as(i16, 7), item.price);
            try std.testing.expectEqualStrings("Grain", item.name);
            found_grain = true;
        }
    }
    try std.testing.expect(found_grain);
}

test "multiple buy transactions accumulate correctly" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 1000;
    var cargo = CargoHold.init(100);

    // Buy 3 Grain (3 * 7 = 21)
    _ = try exchange.buy(0, 3, &credits, &cargo);
    try std.testing.expectEqual(@as(i32, 979), credits);
    try std.testing.expectEqual(@as(u16, 3), cargo.getQuantity(0));

    // Buy 2 more Grain (2 * 7 = 14)
    _ = try exchange.buy(0, 2, &credits, &cargo);
    try std.testing.expectEqual(@as(i32, 965), credits);
    try std.testing.expectEqual(@as(u16, 5), cargo.getQuantity(0)); // Stacked
}

test "buy then sell round-trip" {
    const allocator = std.testing.allocator;
    var loaded = try loadTestRegistry(allocator);
    defer cleanupTestRegistry(allocator, &loaded.registry, loaded.data);

    const exchange = CommodityExchange.init(&loaded.registry, 0x27);
    var credits: i32 = 1000;
    var cargo = CargoHold.init(100);

    // Buy 10 Grain
    _ = try exchange.buy(0, 10, &credits, &cargo);
    try std.testing.expectEqual(@as(i32, 930), credits); // 1000 - 70

    // Sell 10 Grain at same base = same price
    _ = try exchange.sell(0, 10, &credits, &cargo);
    try std.testing.expectEqual(@as(i32, 1000), credits); // Back to 1000
    try std.testing.expectEqual(@as(u16, 0), cargo.getQuantity(0));
}
