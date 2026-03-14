//! Landing fee system for Wing Commander: Privateer.
//!
//! Parses LANDFEE.IFF (FORM:LFEE) which defines the landing fee
//! deducted from the player's credits when landing at a base.
//!
//! Structure:
//!   FORM:LFEE
//!     DATA (4 bytes: fee(i32 LE))

const std = @import("std");
const iff = @import("../formats/iff.zig");

pub const ParseError = error{
    InvalidFormat,
    MissingData,
};

pub const LandingFeeError = error{
    InsufficientCredits,
};

/// Landing fee configuration loaded from LANDFEE.IFF.
pub const LandingFees = struct {
    /// The fee charged when landing at any base.
    fee: i32,

    /// Deduct the landing fee from the player's credits.
    /// Returns the fee amount deducted.
    pub fn deductFee(self: *const LandingFees, credits: *i32) LandingFeeError!i32 {
        if (credits.* < self.fee) return LandingFeeError.InsufficientCredits;
        credits.* -= self.fee;
        return self.fee;
    }
};

/// Parse a LANDFEE.IFF file (FORM:LFEE) into a LandingFees struct.
pub fn parseLandingFees(allocator: std.mem.Allocator, data: []const u8) ParseError!LandingFees {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "LFEE")) return ParseError.InvalidFormat;

    const data_chunk = root.findChild("DATA".*) orelse return ParseError.MissingData;
    if (data_chunk.data.len < 4) return ParseError.MissingData;

    const fee: i32 = @bitCast(std.mem.readInt(u32, data_chunk.data[0..4], .little));

    return LandingFees{ .fee = fee };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

test "parseLandingFees loads fee of 50 from fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_landfee.bin");
    defer allocator.free(data);

    const fees = try parseLandingFees(allocator, data);
    try std.testing.expectEqual(@as(i32, 50), fees.fee);
}

test "landing at base deducts correct fee" {
    const fees = LandingFees{ .fee = 50 };
    var credits: i32 = 1000;

    const deducted = try fees.deductFee(&credits);
    try std.testing.expectEqual(@as(i32, 50), deducted);
    try std.testing.expectEqual(@as(i32, 950), credits);
}

test "landing fee deduction fails with insufficient credits" {
    const fees = LandingFees{ .fee = 50 };
    var credits: i32 = 30;

    const result = fees.deductFee(&credits);
    try std.testing.expectError(LandingFeeError.InsufficientCredits, result);
    try std.testing.expectEqual(@as(i32, 30), credits); // Unchanged
}

test "multiple landings deduct fee each time" {
    const fees = LandingFees{ .fee = 50 };
    var credits: i32 = 200;

    _ = try fees.deductFee(&credits);
    try std.testing.expectEqual(@as(i32, 150), credits);

    _ = try fees.deductFee(&credits);
    try std.testing.expectEqual(@as(i32, 100), credits);

    _ = try fees.deductFee(&credits);
    try std.testing.expectEqual(@as(i32, 50), credits);

    _ = try fees.deductFee(&credits);
    try std.testing.expectEqual(@as(i32, 0), credits);

    // Now insufficient
    try std.testing.expectError(LandingFeeError.InsufficientCredits, fees.deductFee(&credits));
}

test "parseLandingFees rejects non-LFEE form" {
    const allocator = std.testing.allocator;
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseLandingFees(allocator, data));
}
