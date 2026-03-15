//! Conversation data loader for Wing Commander: Privateer.
//!
//! Parses conversation-related data files:
//!
//! 1. CONV/*.IFF rumor/info tables (FORM:RUMR, FORM:INFO)
//!    - TABL chunk: array of u32 LE file offsets to 20-byte records
//!    - Each record: { data_size(u32 LE), category([4]u8), name_len(u32 LE), name([8]u8) }
//!    - CHNC chunk (RUMORS.IFF only): u16 LE chance weights for category selection
//!
//! 2. CONV/*.PFC dialogue scripts
//!    - Null-separated string table, grouped in 7-string lines:
//!      speaker, mood, costume, unknown, unknown, text, unknown
//!
//! 3. OPTIONS/COMPTEXT.IFF (FORM:COMP) mission computer text
//!    - FORM:MRCH/MERC/AUTO guild sub-containers
//!    - Named text chunks: JOIN, WELC, UNAV, SCAN, NROM, PTRL, SCOU, DFND, ATAK, BOUN, CRGO, ACPT, CMIS
//!
//! 4. OPTIONS/COMMTXT.IFF (FORM:STRG) exchange text strings
//!    - SNUM chunk: u16 LE string count
//!    - DATA chunk: null-separated strings

const std = @import("std");
const iff = @import("../formats/iff.zig");

/// Strings per dialogue line in PFC files.
const STRINGS_PER_LINE = 7;

/// Maximum conversation name length in records.
const CONV_NAME_SIZE = 8;

/// A conversation file reference from a RUMR/INFO TABL record.
pub const ConvReference = struct {
    /// Category tag: "CONV" (direct conversation) or "BASE" (base-type rumor table).
    category: [4]u8,
    /// Null-padded conversation filename (up to 8 chars).
    name: [CONV_NAME_SIZE]u8,

    /// Get the name as a trimmed string slice (up to first null).
    pub fn nameStr(self: *const ConvReference) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse CONV_NAME_SIZE;
        return self.name[0..end];
    }

    /// Check if this is a "CONV" (direct conversation) reference.
    pub fn isConv(self: *const ConvReference) bool {
        return std.mem.eql(u8, &self.category, "CONV");
    }

    /// Check if this is a "BASE" (base-type redirect) reference.
    pub fn isBase(self: *const ConvReference) bool {
        return std.mem.eql(u8, &self.category, "BASE");
    }
};

/// A rumor/info table parsed from FORM:RUMR or FORM:INFO with a TABL chunk.
pub const RumorTable = struct {
    /// Conversation references (may include null entries from empty records).
    references: []?ConvReference,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RumorTable) void {
        self.allocator.free(self.references);
    }

    /// Number of entries in the table.
    pub fn count(self: *const RumorTable) usize {
        return self.references.len;
    }

    /// Get a non-null reference by index.
    pub fn get(self: *const RumorTable, idx: usize) ?ConvReference {
        if (idx >= self.references.len) return null;
        return self.references[idx];
    }
};

/// Rumor category chance weights from RUMORS.IFF (FORM:RUMR with CHNC).
pub const RumorChances = struct {
    /// u16 chance weights for each rumor category.
    weights: []u16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RumorChances) void {
        self.allocator.free(self.weights);
    }

    /// Number of category weights.
    pub fn count(self: *const RumorChances) usize {
        return self.weights.len;
    }
};

/// A single line of dialogue from a PFC conversation script.
pub const DialogueLine = struct {
    /// Speaker type (e.g., "rand_npc").
    speaker: []const u8,
    /// Mood/animation state (e.g., "normal").
    mood: []const u8,
    /// Costume/sprite reference (e.g., "randcu_3").
    costume: []const u8,
    /// The actual dialogue text.
    text: []const u8,
};

/// A conversation script parsed from a PFC file.
pub const ConversationScript = struct {
    /// Parsed dialogue lines.
    lines: []DialogueLine,
    /// All raw string data (owned, backing storage for DialogueLine slices).
    raw_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConversationScript) void {
        self.allocator.free(self.lines);
        self.allocator.free(self.raw_data);
    }

    /// Number of dialogue lines.
    pub fn lineCount(self: *const ConversationScript) usize {
        return self.lines.len;
    }
};

/// Text strings for a single guild in the mission computer (FORM:MRCH/MERC/AUTO).
pub const GuildText = struct {
    join: ?[]const u8 = null,
    welcome: ?[]const u8 = null,
    unavailable: ?[]const u8 = null,
    scan: ?[]const u8 = null,
    normal: ?[]const u8 = null,
    patrol: ?[]const u8 = null,
    scout: ?[]const u8 = null,
    defend: ?[]const u8 = null,
    attack: ?[]const u8 = null,
    bounty: ?[]const u8 = null,
    cargo: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    complete: ?[]const u8 = null,
};

/// Mission computer text from COMPTEXT.IFF (FORM:COMP).
pub const ComputerText = struct {
    merchant: GuildText = .{},
    mercenary: GuildText = .{},
    automated: GuildText = .{},
    /// Raw IFF data backing the string slices.
    raw_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ComputerText) void {
        self.allocator.free(self.raw_data);
    }
};

/// Exchange text strings from COMMTXT.IFF (FORM:STRG).
pub const StringTable = struct {
    strings: [][]const u8,
    /// Raw IFF data backing the string slices.
    raw_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StringTable) void {
        self.allocator.free(self.strings);
        self.allocator.free(self.raw_data);
    }

    /// Number of strings.
    pub fn count(self: *const StringTable) usize {
        return self.strings.len;
    }

    /// Get a string by index.
    pub fn get(self: *const StringTable, idx: usize) ?[]const u8 {
        if (idx >= self.strings.len) return null;
        return self.strings[idx];
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

fn readU32LE(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..4], .little);
}

/// Parse a rumor/info table from FORM:RUMR or FORM:INFO data.
/// Accepts either form type since both use the same TABL + record structure.
pub fn parseRumorTable(allocator: std.mem.Allocator, data: []const u8) ParseError!RumorTable {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    // Accept RUMR or INFO form types
    const ft = root.form_type orelse return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &ft, "RUMR") and !std.mem.eql(u8, &ft, "INFO")) {
        return ParseError.InvalidFormat;
    }

    const tabl = root.findChild("TABL".*) orelse return ParseError.MissingData;
    if (tabl.data.len % 4 != 0) return ParseError.InvalidSize;
    const entry_count = tabl.data.len / 4;

    const references = allocator.alloc(?ConvReference, entry_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(references);

    for (0..entry_count) |i| {
        const file_offset = readU32LE(tabl.data[i * 4 ..][0..4]);

        // Read the record at the given file offset
        if (file_offset + 4 > data.len) return ParseError.InvalidSize;
        const data_size = readU32LE(data[file_offset..][0..4]);

        if (data_size == 0) {
            // Null/empty record
            references[i] = null;
        } else if (data_size == 16) {
            // Standard 20-byte record: size(4) + category(4) + name_len(4) + name(8)
            if (file_offset + 20 > data.len) return ParseError.InvalidSize;
            const rec = data[file_offset + 4 ..];
            references[i] = ConvReference{
                .category = rec[0..4].*,
                .name = rec[8..16].*,
            };
        } else {
            // Unknown record size - treat as null
            references[i] = null;
        }
    }

    return RumorTable{
        .references = references,
        .allocator = allocator,
    };
}

/// Parse rumor chance weights from FORM:RUMR with CHNC chunk (RUMORS.IFF).
pub fn parseRumorChances(allocator: std.mem.Allocator, data: []const u8) ParseError!RumorChances {
    var root = iff.parseFile(allocator, data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "RUMR")) return ParseError.InvalidFormat;

    const chnc = root.findChild("CHNC".*) orelse return ParseError.MissingData;
    if (chnc.data.len % 2 != 0) return ParseError.InvalidSize;
    const weight_count = chnc.data.len / 2;

    const weights = allocator.alloc(u16, weight_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(weights);

    for (0..weight_count) |i| {
        weights[i] = readU16LE(chnc.data[i * 2 ..][0..2]);
    }

    return RumorChances{
        .weights = weights,
        .allocator = allocator,
    };
}

/// Parse a PFC conversation script file into dialogue lines.
/// PFC files are null-separated string tables grouped in 7-string lines.
pub fn parseConversationScript(allocator: std.mem.Allocator, data: []const u8) ParseError!ConversationScript {
    // Own a copy of the raw data so slices remain valid
    const raw_data = allocator.dupe(u8, data) catch return ParseError.OutOfMemory;
    errdefer allocator.free(raw_data);

    // Split into null-separated strings (find boundaries)
    var string_offsets: std.ArrayListUnmanaged(struct { start: usize, end: usize }) = .empty;
    defer string_offsets.deinit(allocator);

    var pos: usize = 0;
    while (pos < raw_data.len) {
        const end = std.mem.indexOfScalarPos(u8, raw_data, pos, 0) orelse raw_data.len;
        if (end > pos) {
            string_offsets.append(allocator, .{ .start = pos, .end = end }) catch return ParseError.OutOfMemory;
        }
        pos = end + 1;
    }

    const total_strings = string_offsets.items.len;
    const line_count = total_strings / STRINGS_PER_LINE;

    const lines = allocator.alloc(DialogueLine, line_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(lines);

    for (0..line_count) |i| {
        const base = i * STRINGS_PER_LINE;
        const offsets = string_offsets.items;
        lines[i] = DialogueLine{
            .speaker = raw_data[offsets[base].start..offsets[base].end],
            .mood = raw_data[offsets[base + 1].start..offsets[base + 1].end],
            .costume = raw_data[offsets[base + 2].start..offsets[base + 2].end],
            .text = raw_data[offsets[base + 5].start..offsets[base + 5].end],
        };
    }

    return ConversationScript{
        .lines = lines,
        .raw_data = raw_data,
        .allocator = allocator,
    };
}

/// Extract a null-terminated string from chunk data (or the full data if no null).
fn chunkText(chunk_data: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, chunk_data, 0) orelse chunk_data.len;
    return chunk_data[0..end];
}

/// Parse guild text from a FORM:MRCH/MERC/AUTO container.
fn parseGuildText(form: *const iff.Chunk) GuildText {
    var gt = GuildText{};
    if (form.findChild("JOIN".*)) |c| gt.join = chunkText(c.data);
    if (form.findChild("WELC".*)) |c| gt.welcome = chunkText(c.data);
    if (form.findChild("UNAV".*)) |c| gt.unavailable = chunkText(c.data);
    if (form.findChild("SCAN".*)) |c| gt.scan = chunkText(c.data);
    if (form.findChild("NROM".*)) |c| gt.normal = chunkText(c.data);
    if (form.findChild("PTRL".*)) |c| gt.patrol = chunkText(c.data);
    if (form.findChild("SCOU".*)) |c| gt.scout = chunkText(c.data);
    if (form.findChild("DFND".*)) |c| gt.defend = chunkText(c.data);
    if (form.findChild("ATAK".*)) |c| gt.attack = chunkText(c.data);
    if (form.findChild("BOUN".*)) |c| gt.bounty = chunkText(c.data);
    if (form.findChild("CRGO".*)) |c| gt.cargo = chunkText(c.data);
    if (form.findChild("ACPT".*)) |c| gt.accept = chunkText(c.data);
    if (form.findChild("CMIS".*)) |c| gt.complete = chunkText(c.data);
    return gt;
}

/// Parse mission computer text from COMPTEXT.IFF (FORM:COMP).
pub fn parseComputerText(allocator: std.mem.Allocator, data: []const u8) ParseError!ComputerText {
    // Own the data so string slices into IFF chunk data remain valid
    const raw_data = allocator.dupe(u8, data) catch return ParseError.OutOfMemory;
    errdefer allocator.free(raw_data);

    var root = iff.parseFile(allocator, raw_data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "COMP")) return ParseError.InvalidFormat;

    var result = ComputerText{
        .raw_data = raw_data,
        .allocator = allocator,
    };

    if (root.findForm("MRCH".*)) |mrch| result.merchant = parseGuildText(mrch);
    if (root.findForm("MERC".*)) |merc| result.mercenary = parseGuildText(merc);
    if (root.findForm("AUTO".*)) |auto| result.automated = parseGuildText(auto);

    return result;
}

/// Parse exchange text strings from COMMTXT.IFF (FORM:STRG).
pub fn parseStringTable(allocator: std.mem.Allocator, data: []const u8) ParseError!StringTable {
    const raw_data = allocator.dupe(u8, data) catch return ParseError.OutOfMemory;
    errdefer allocator.free(raw_data);

    var root = iff.parseFile(allocator, raw_data) catch return ParseError.InvalidFormat;
    defer root.deinit();

    if (!root.isContainer()) return ParseError.InvalidFormat;
    if (!std.mem.eql(u8, &root.form_type.?, "STRG")) return ParseError.InvalidFormat;

    const data_chunk = root.findChild("DATA".*) orelse return ParseError.MissingData;

    // Count strings by splitting on null bytes
    var string_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer string_list.deinit(allocator);

    var pos: usize = 0;
    while (pos < data_chunk.data.len) {
        const end = std.mem.indexOfScalarPos(u8, data_chunk.data, pos, 0) orelse data_chunk.data.len;
        if (end > pos) {
            // data_chunk.data points into raw_data, so slices are valid after root.deinit()
            string_list.append(allocator, data_chunk.data[pos..end]) catch return ParseError.OutOfMemory;
        }
        pos = end + 1;
    }

    const strings = string_list.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    errdefer allocator.free(strings);

    return StringTable{
        .strings = strings,
        .raw_data = raw_data,
        .allocator = allocator,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing_helpers = @import("../testing.zig");

// -- RumorTable tests --

fn loadRumorTable(allocator: std.mem.Allocator) !struct { table: RumorTable, data: []const u8 } {
    const data = try testing_helpers.loadFixture(allocator, "test_rumor_table.bin");
    const table = parseRumorTable(allocator, data) catch {
        allocator.free(data);
        return error.TestFixtureError;
    };
    return .{ .table = table, .data = data };
}

test "parseRumorTable parses 3 conversation references" {
    const allocator = std.testing.allocator;
    const loaded = try loadRumorTable(allocator);
    defer allocator.free(loaded.data);
    var table = loaded.table;
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 3), table.count());
}

test "parseRumorTable first reference is CONV/agrrum1" {
    const allocator = std.testing.allocator;
    const loaded = try loadRumorTable(allocator);
    defer allocator.free(loaded.data);
    var table = loaded.table;
    defer table.deinit();

    const ref0 = table.get(0) orelse return error.NullReference;
    try std.testing.expect(ref0.isConv());
    try std.testing.expectEqualStrings("agrrum1", ref0.nameStr());
}

test "parseRumorTable second reference is CONV/agrrum2" {
    const allocator = std.testing.allocator;
    const loaded = try loadRumorTable(allocator);
    defer allocator.free(loaded.data);
    var table = loaded.table;
    defer table.deinit();

    const ref1 = table.get(1) orelse return error.NullReference;
    try std.testing.expect(ref1.isConv());
    try std.testing.expectEqualStrings("agrrum2", ref1.nameStr());
}

test "parseRumorTable third reference is CONV/agrrum3" {
    const allocator = std.testing.allocator;
    const loaded = try loadRumorTable(allocator);
    defer allocator.free(loaded.data);
    var table = loaded.table;
    defer table.deinit();

    const ref2 = table.get(2) orelse return error.NullReference;
    try std.testing.expect(ref2.isConv());
    try std.testing.expectEqualStrings("agrrum3", ref2.nameStr());
}

// -- Base rumor table with null entries --

test "parseRumorTable handles null entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_base_rumor_table.bin");
    defer allocator.free(data);

    var table = try parseRumorTable(allocator, data);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 3), table.count());

    // First entry is null
    try std.testing.expect(table.get(0) == null);

    // Second entry is BASE/agrirumr
    const ref1 = table.get(1) orelse return error.NullReference;
    try std.testing.expect(ref1.isBase());
    try std.testing.expectEqualStrings("agrirumr", ref1.nameStr());

    // Third entry is BASE/minerumr
    const ref2 = table.get(2) orelse return error.NullReference;
    try std.testing.expect(ref2.isBase());
    try std.testing.expectEqualStrings("minerumr", ref2.nameStr());
}

// -- RumorChances tests --

test "parseRumorChances parses 4 weights" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_rumor_chances.bin");
    defer allocator.free(data);

    var chances = try parseRumorChances(allocator, data);
    defer chances.deinit();

    try std.testing.expectEqual(@as(usize, 4), chances.count());
    try std.testing.expectEqual(@as(u16, 20), chances.weights[0]);
    try std.testing.expectEqual(@as(u16, 40), chances.weights[1]);
    try std.testing.expectEqual(@as(u16, 40), chances.weights[2]);
    try std.testing.expectEqual(@as(u16, 40), chances.weights[3]);
}

// -- ConversationScript (PFC) tests --

test "parseConversationScript parses 2 dialogue lines" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_conv.pfc");
    defer allocator.free(data);

    var script = try parseConversationScript(allocator, data);
    defer script.deinit();

    try std.testing.expectEqual(@as(usize, 2), script.lineCount());
}

test "parseConversationScript first line has correct speaker" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_conv.pfc");
    defer allocator.free(data);

    var script = try parseConversationScript(allocator, data);
    defer script.deinit();

    const line0 = script.lines[0];
    try std.testing.expectEqualStrings("rand_npc", line0.speaker);
    try std.testing.expectEqualStrings("normal", line0.mood);
    try std.testing.expectEqualStrings("randcu_3", line0.costume);
    try std.testing.expectEqualStrings(
        "I just heard that the fleet was lost around Midgard...",
        line0.text,
    );
}

test "parseConversationScript second line has correct text" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_conv.pfc");
    defer allocator.free(data);

    var script = try parseConversationScript(allocator, data);
    defer script.deinit();

    const line1 = script.lines[1];
    try std.testing.expectEqualStrings("rand_npc", line1.speaker);
    try std.testing.expectEqualStrings(
        "Gone! The Kilrathi must've destroyed them!",
        line1.text,
    );
}

// -- ComputerText (COMPTEXT.IFF) tests --

test "parseComputerText parses merchant guild text" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_comptext.bin");
    defer allocator.free(data);

    var ct = try parseComputerText(allocator, data);
    defer ct.deinit();

    try std.testing.expectEqualStrings(
        "You must first join\nthe Merchants' Guild.",
        ct.merchant.join.?,
    );
    try std.testing.expectEqualStrings(
        "Welcome to the\nMerchants' Guild.",
        ct.merchant.welcome.?,
    );
    try std.testing.expectEqualStrings("Mission not available.", ct.merchant.unavailable.?);
    try std.testing.expectEqualStrings("Scanning for missions.", ct.merchant.scan.?);
    try std.testing.expectEqualStrings("Schedule full.", ct.merchant.normal.?);
    try std.testing.expectEqualStrings("BOUNTY MISSION (%d of %d)", ct.merchant.bounty.?);
    try std.testing.expectEqualStrings("CARGO MISSION (%d of %d)", ct.merchant.cargo.?);
    try std.testing.expectEqualStrings("Mission accepted.", ct.merchant.accept.?);
}

test "parseComputerText mercenary guild is empty when not present" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_comptext.bin");
    defer allocator.free(data);

    var ct = try parseComputerText(allocator, data);
    defer ct.deinit();

    // Fixture only has MRCH, no MERC or AUTO
    try std.testing.expect(ct.mercenary.join == null);
    try std.testing.expect(ct.automated.join == null);
}

// -- StringTable (COMMTXT.IFF) tests --

test "parseStringTable parses 3 exchange strings" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_commtxt.bin");
    defer allocator.free(data);

    var st = try parseStringTable(allocator, data);
    defer st.deinit();

    try std.testing.expectEqual(@as(usize, 3), st.count());
    try std.testing.expectEqualStrings("Price: ", st.get(0).?);
    try std.testing.expectEqualStrings("Quantity: ", st.get(1).?);
    try std.testing.expectEqualStrings("Cost: ", st.get(2).?);
}

// -- Error handling tests --

test "parseRumorTable rejects non-RUMR form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseRumorTable(std.testing.allocator, data));
}

test "parseRumorChances rejects non-RUMR form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseRumorChances(std.testing.allocator, data));
}

test "parseComputerText rejects non-COMP form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseComputerText(std.testing.allocator, data));
}

test "parseStringTable rejects non-STRG form" {
    const data = "FORM" ++ "\x00\x00\x00\x04" ++ "XXXX";
    try std.testing.expectError(ParseError.InvalidFormat, parseStringTable(std.testing.allocator, data));
}

test "ConvReference.nameStr trims null padding" {
    const ref = ConvReference{
        .category = "CONV".*,
        .name = "test\x00\x00\x00\x00".*,
    };
    try std.testing.expectEqualStrings("test", ref.nameStr());
}

test "ConvReference.nameStr handles full-length name" {
    const ref = ConvReference{
        .category = "CONV".*,
        .name = "agrirumr".*,
    };
    try std.testing.expectEqualStrings("agrirumr", ref.nameStr());
}
