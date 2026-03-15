//! Rumors system for Wing Commander: Privateer.
//!
//! Selects context-appropriate rumors to display at bars based on the
//! player's current base type and weighted random selection.
//!
//! Rumor selection flow:
//!   1. Use RUMORS.IFF chance weights (CHNC) to pick a rumor category
//!   2. Look up the category in the master rumor table (TABL)
//!   3. If the reference is "BASE", redirect to the base-type-specific table
//!   4. From the resolved table, select a random conversation reference
//!   5. The reference names a PFC conversation script to display
//!
//! Base type mapping (index → rumor table name):
//!   0 = agricultural → "agrirumr"
//!   1 = mining       → "minerumr"
//!   2 = refinery     → "refrumr"
//!   3 = pleasure     → "plearumr"
//!   4 = pirate       → "pirirumr"
//!   5 = military     → "milirumr"

const std = @import("std");
const conversations = @import("conversations.zig");

const ConvReference = conversations.ConvReference;
const RumorTable = conversations.RumorTable;
const RumorChances = conversations.RumorChances;

/// Number of known base types with rumor table mappings.
pub const BASE_TYPE_COUNT = 6;

/// Rumor table filename for each base type (0-5).
/// Each name is exactly 8 bytes, null-padded.
pub const BASE_TYPE_RUMOR_NAMES: [BASE_TYPE_COUNT][8]u8 = .{
    "agrirumr".*, // 0: agricultural
    "minerumr".*, // 1: mining
    "refrumr\x00".*, // 2: refinery
    "plearumr".*, // 3: pleasure
    "pirirumr".*, // 4: pirate
    "milirumr".*, // 5: military
};

/// Get the rumor table name for a base type.
/// Returns null for unknown base types (6+).
pub fn baseTypeRumorName(base_type: u8) ?[]const u8 {
    if (base_type >= BASE_TYPE_COUNT) return null;
    const raw = &BASE_TYPE_RUMOR_NAMES[base_type];
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse 8;
    return raw[0..end];
}

/// Perform weighted random selection from chance weights.
/// Returns the selected index, or null if weights are all zero or empty.
pub fn selectWeighted(weights: []const u16, rand: std.Random) ?usize {
    if (weights.len == 0) return null;

    var total: u32 = 0;
    for (weights) |w| {
        total += w;
    }
    if (total == 0) return null;

    var roll = rand.intRangeLessThan(u32, 0, total);
    for (weights, 0..) |w, i| {
        if (roll < w) return i;
        roll -= w;
    }

    // Shouldn't reach here, but return last valid index as fallback
    return weights.len - 1;
}

/// Select a non-null reference from a rumor table using uniform random.
/// Returns null if the table has no valid (non-null) entries.
pub fn selectFromTable(table: *const RumorTable, rand: std.Random) ?ConvReference {
    // Count non-null entries
    var valid_count: usize = 0;
    for (table.references) |ref| {
        if (ref != null) valid_count += 1;
    }
    if (valid_count == 0) return null;

    // Pick a random valid entry
    var target = rand.intRangeLessThan(usize, 0, valid_count);
    for (table.references) |ref| {
        if (ref) |r| {
            if (target == 0) return r;
            target -= 1;
        }
    }

    return null;
}

/// Result of rumor selection: either a direct conversation name or
/// a redirect to a base-type-specific rumor table.
pub const RumorSelection = union(enum) {
    /// Direct conversation reference (PFC filename to load).
    conversation: ConvReference,
    /// Base-type redirect: caller should load this rumor table and select again.
    base_redirect: ConvReference,
};

/// Select a rumor from the master table using weighted random selection.
/// Returns a RumorSelection indicating either a direct conversation or
/// a base-type redirect that the caller needs to resolve.
/// Returns null if selection fails (empty weights, empty table, etc.).
pub fn selectRumor(
    master_table: *const RumorTable,
    chances: *const RumorChances,
    rand: std.Random,
) ?RumorSelection {
    // Use weighted selection to pick a category index
    const idx = selectWeighted(chances.weights, rand) orelse return null;

    // Look up the reference at that index
    const ref = master_table.get(idx) orelse return null;

    if (ref.isBase()) {
        return .{ .base_redirect = ref };
    } else {
        return .{ .conversation = ref };
    }
}

// ── Tests ───────────────────────────────────────────────────────────

// -- Base type rumor name tests --

test "baseTypeRumorName returns correct name for agricultural" {
    try std.testing.expectEqualStrings("agrirumr", baseTypeRumorName(0).?);
}

test "baseTypeRumorName returns correct name for mining" {
    try std.testing.expectEqualStrings("minerumr", baseTypeRumorName(1).?);
}

test "baseTypeRumorName returns correct name for refinery" {
    try std.testing.expectEqualStrings("refrumr", baseTypeRumorName(2).?);
}

test "baseTypeRumorName returns correct name for pleasure" {
    try std.testing.expectEqualStrings("plearumr", baseTypeRumorName(3).?);
}

test "baseTypeRumorName returns correct name for pirate" {
    try std.testing.expectEqualStrings("pirirumr", baseTypeRumorName(4).?);
}

test "baseTypeRumorName returns correct name for military" {
    try std.testing.expectEqualStrings("milirumr", baseTypeRumorName(5).?);
}

test "baseTypeRumorName returns null for unknown base type" {
    try std.testing.expect(baseTypeRumorName(6) == null);
    try std.testing.expect(baseTypeRumorName(99) == null);
}

// -- Weighted selection tests --

test "selectWeighted returns null for empty weights" {
    const empty: []const u16 = &.{};
    var prng = std.Random.DefaultPrng.init(42);
    try std.testing.expect(selectWeighted(empty, prng.random()) == null);
}

test "selectWeighted returns null for all-zero weights" {
    const zeros: []const u16 = &.{ 0, 0, 0 };
    var prng = std.Random.DefaultPrng.init(42);
    try std.testing.expect(selectWeighted(zeros, prng.random()) == null);
}

test "selectWeighted with single weight always returns 0" {
    const single: []const u16 = &.{100};
    var prng = std.Random.DefaultPrng.init(42);
    for (0..10) |_| {
        try std.testing.expectEqual(@as(usize, 0), selectWeighted(single, prng.random()).?);
    }
}

test "selectWeighted distributes across categories" {
    // Weights: 50, 50 - should produce roughly equal distribution
    const weights: []const u16 = &.{ 50, 50 };
    var prng = std.Random.DefaultPrng.init(42);
    var counts = [_]u32{ 0, 0 };
    const trials = 1000;

    for (0..trials) |_| {
        const idx = selectWeighted(weights, prng.random()).?;
        counts[idx] += 1;
    }

    // Both categories should have significant representation
    try std.testing.expect(counts[0] > 100);
    try std.testing.expect(counts[1] > 100);
}

test "selectWeighted respects weight ratios" {
    // Weights: 90, 10 - first category should dominate
    const weights: []const u16 = &.{ 90, 10 };
    var prng = std.Random.DefaultPrng.init(42);
    var counts = [_]u32{ 0, 0 };
    const trials = 1000;

    for (0..trials) |_| {
        const idx = selectWeighted(weights, prng.random()).?;
        counts[idx] += 1;
    }

    // First category should have much more than second
    try std.testing.expect(counts[0] > counts[1] * 3);
}

test "selectWeighted skips zero-weight categories" {
    // Weights: 0, 100, 0 - only index 1 should be selected
    const weights: []const u16 = &.{ 0, 100, 0 };
    var prng = std.Random.DefaultPrng.init(42);

    for (0..20) |_| {
        try std.testing.expectEqual(@as(usize, 1), selectWeighted(weights, prng.random()).?);
    }
}

// -- selectFromTable tests --

test "selectFromTable returns a valid reference" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{
        ConvReference{ .category = "CONV".*, .name = "agrrum1\x00".* },
        ConvReference{ .category = "CONV".*, .name = "agrrum2\x00".* },
    };
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    const ref = selectFromTable(&table, prng.random());
    try std.testing.expect(ref != null);
    try std.testing.expect(ref.?.isConv());
}

test "selectFromTable skips null entries" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{
        null,
        ConvReference{ .category = "CONV".*, .name = "agrrum2\x00".* },
        null,
    };
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    // Should always return the one valid entry
    for (0..10) |_| {
        const ref = selectFromTable(&table, prng.random()).?;
        try std.testing.expectEqualStrings("agrrum2", ref.nameStr());
    }
}

test "selectFromTable returns null for all-null table" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{ null, null, null };
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    try std.testing.expect(selectFromTable(&table, prng.random()) == null);
}

test "selectFromTable returns null for empty table" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{};
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    try std.testing.expect(selectFromTable(&table, prng.random()) == null);
}

// -- selectRumor tests --

test "selectRumor returns conversation for CONV reference" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{
        ConvReference{ .category = "CONV".*, .name = "agrrum1\x00".* },
    };
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };
    var weights = [_]u16{100};
    var chances = RumorChances{
        .weights = &weights,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    const result = selectRumor(&table, &chances, prng.random()).?;
    try std.testing.expect(result == .conversation);
    try std.testing.expectEqualStrings("agrrum1", result.conversation.nameStr());
}

test "selectRumor returns base_redirect for BASE reference" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{
        ConvReference{ .category = "BASE".*, .name = "agrirumr".* },
    };
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };
    var weights = [_]u16{100};
    var chances = RumorChances{
        .weights = &weights,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    const result = selectRumor(&table, &chances, prng.random()).?;
    try std.testing.expect(result == .base_redirect);
    try std.testing.expect(result.base_redirect.isBase());
    try std.testing.expectEqualStrings("agrirumr", result.base_redirect.nameStr());
}

test "selectRumor returns null for empty chances" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{
        ConvReference{ .category = "CONV".*, .name = "agrrum1\x00".* },
    };
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };
    var weights = [_]u16{};
    var chances = RumorChances{
        .weights = &weights,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    try std.testing.expect(selectRumor(&table, &chances, prng.random()) == null);
}

test "selectRumor returns null when selected index has null reference" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{null};
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };
    var weights = [_]u16{100};
    var chances = RumorChances{
        .weights = &weights,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    try std.testing.expect(selectRumor(&table, &chances, prng.random()) == null);
}

test "selectRumor with multiple categories selects correctly" {
    const allocator = std.testing.allocator;
    var refs = [_]?ConvReference{
        ConvReference{ .category = "CONV".*, .name = "agrrum1\x00".* },
        ConvReference{ .category = "BASE".*, .name = "agrirumr".* },
        ConvReference{ .category = "CONV".*, .name = "pirrum1\x00".* },
    };
    var table = RumorTable{
        .references = &refs,
        .allocator = allocator,
    };
    // Give all weight to index 2
    var weights = [_]u16{ 0, 0, 100 };
    var chances = RumorChances{
        .weights = &weights,
        .allocator = allocator,
    };

    var prng = std.Random.DefaultPrng.init(42);
    const result = selectRumor(&table, &chances, prng.random()).?;
    try std.testing.expect(result == .conversation);
    try std.testing.expectEqualStrings("pirrum1", result.conversation.nameStr());
}
