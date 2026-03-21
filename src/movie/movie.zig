//! FORM:MOVI IFF parser for Wing Commander: Privateer intro movie scripts.
//!
//! The intro cinematic is driven by a sequence of FORM:MOVI IFF files
//! (MID1A.IFF through MID1F.IFF) that control frame-by-frame animation
//! with sprite overlays, text, and audio triggers.
//!
//! FORM:MOVI structure:
//!   CLRC (2 bytes) — clear screen flag (big-endian u16, nonzero = clear)
//!   SPED (2 bytes) — frame speed in ticks per frame (big-endian u16)
//!   FILE (variable) — null-terminated indexed file path references
//!   FORM:ACTS (one or more) — animation action blocks containing:
//!     FILD — field/frame display commands
//!     SPRI — sprite positioning/animation commands
//!     BFOR — background/foreground layer ordering

const std = @import("std");
const iff = @import("../formats/iff.zig");

pub const MovieError = error{
    /// Not a FORM:MOVI container.
    InvalidFormat,
    /// Missing required SPED chunk.
    NoSpeedData,
    /// Missing required FILE chunk.
    NoFileData,
    /// No FORM:ACTS blocks found.
    NoActsBlocks,
    OutOfMemory,
};

/// A slot-indexed file reference from the FILE chunk.
/// Real format: [slot_id: u16 LE][null-terminated path] pairs.
/// Slot IDs can be sparse (e.g., 0, 1, 2, 4 — slot 3 skipped).
pub const FileSlot = struct {
    slot_id: u16,
    path: []const u8,
};

/// A FILD command: packed 10-byte record defining a field object.
/// Real format: [object_id: u16 LE][file_ref: u16 LE][param1: u16 LE][param2: u16 LE][param3: u16 LE]
/// Object IDs are referenced by BFOR commands to drive rendering order.
pub const FieldCommand = struct {
    /// Unique object ID (referenced by BFOR composition commands).
    object_id: u16,
    /// File reference slot (index into FILE slot table).
    file_ref: u16,
    /// Parameter 1 (sprite/resource index within the referenced file).
    param1: u16,
    /// Parameter 2.
    param2: u16,
    /// Parameter 3.
    param3: u16,
};

/// A SPRI command: position/animate a sprite with signed coordinates.
pub const SpriteCommand = struct {
    /// Index into the FILE reference list.
    file_ref: u8,
    /// Sprite index within the referenced file.
    sprite_index: u16,
    /// X position (signed, can be negative for off-screen).
    x: i16,
    /// Y position (signed).
    y: i16,
    /// Flags.
    flags: u8,
};

/// A BFOR command: background/foreground layer ordering.
pub const LayerOrder = struct {
    /// Layer ordering value.
    value: u16,
};

/// A single FORM:ACTS animation action block.
pub const ActsBlock = struct {
    /// FILD commands in this block.
    field_commands: []const FieldCommand,
    /// SPRI commands in this block.
    sprite_commands: []const SpriteCommand,
    /// BFOR layer orderings in this block.
    layer_orders: []const LayerOrder,
};

/// A parsed FORM:MOVI movie script.
pub const MovieScript = struct {
    /// Whether to clear the screen before this scene.
    clear_screen: bool,
    /// Frame speed in ticks per frame.
    frame_speed_ticks: u16,
    /// Slot-indexed file path references from the FILE chunk.
    /// Each entry has a slot_id and path. Slot IDs may be sparse.
    file_references: []const FileSlot,
    /// Animation action blocks.
    acts_blocks: []const ActsBlock,

    allocator: std.mem.Allocator,

    /// Return the number of slots needed (max slot_id + 1).
    /// Used to size arrays indexed by slot_id (e.g., loaded PAKs).
    pub fn fileSlotCount(self: *const MovieScript) usize {
        var max_id: usize = 0;
        for (self.file_references) |slot| {
            const id = @as(usize, slot.slot_id) + 1;
            if (id > max_id) max_id = id;
        }
        return max_id;
    }

    /// Look up a file path by slot ID.
    pub fn getFilePath(self: *const MovieScript, slot_id: u16) ?[]const u8 {
        for (self.file_references) |slot| {
            if (slot.slot_id == slot_id) return slot.path;
        }
        return null;
    }

    pub fn deinit(self: *MovieScript) void {
        for (self.acts_blocks) |block| {
            if (block.field_commands.len > 0) self.allocator.free(block.field_commands);
            if (block.sprite_commands.len > 0) self.allocator.free(block.sprite_commands);
            if (block.layer_orders.len > 0) self.allocator.free(block.layer_orders);
        }
        if (self.acts_blocks.len > 0) self.allocator.free(self.acts_blocks);
        if (self.file_references.len > 0) self.allocator.free(self.file_references);
    }
};

/// Check if raw bytes look like a FORM:MOVI file.
pub fn isMovi(data: []const u8) bool {
    if (data.len < 12) return false;
    return std.mem.eql(u8, data[0..4], "FORM") and std.mem.eql(u8, data[8..12], "MOVI");
}

/// Parse a FORM:MOVI IFF file into a MovieScript.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) (MovieError || iff.IffError)!MovieScript {
    if (data.len < 12) return MovieError.InvalidFormat;

    // Parse the IFF tree
    const result = iff.parseChunk(allocator, data, 0) catch |err| switch (err) {
        error.OutOfMemory => return MovieError.OutOfMemory,
        else => return MovieError.InvalidFormat,
    };
    var root = result.chunk;
    defer root.deinit();

    // Validate root is FORM:MOVI
    if (!std.mem.eql(u8, &root.tag, "FORM")) return MovieError.InvalidFormat;
    const ft = root.form_type orelse return MovieError.InvalidFormat;
    if (!std.mem.eql(u8, &ft, "MOVI")) return MovieError.InvalidFormat;

    // Extract CLRC (optional, default false)
    var clear_screen: bool = false;
    if (root.findChild("CLRC".*)) |clrc| {
        if (clrc.data.len >= 2) {
            const val = std.mem.readInt(u16, clrc.data[0..2], .big);
            clear_screen = val != 0;
        }
    }

    // Extract SPED (required)
    const sped_chunk = root.findChild("SPED".*) orelse return MovieError.NoSpeedData;
    if (sped_chunk.data.len < 2) return MovieError.NoSpeedData;
    const frame_speed_ticks = std.mem.readInt(u16, sped_chunk.data[0..2], .big);

    // Extract FILE paths (required)
    const file_chunk = root.findChild("FILE".*) orelse return MovieError.NoFileData;
    const file_references = try parseFileReferences(allocator, file_chunk.data);
    errdefer allocator.free(file_references);

    // Extract FORM:ACTS blocks (at least one required)
    const acts_forms = root.findForms(allocator, "ACTS".*) catch return MovieError.OutOfMemory;
    defer allocator.free(acts_forms);
    if (acts_forms.len == 0) return MovieError.NoActsBlocks;

    var acts_blocks: std.ArrayListUnmanaged(ActsBlock) = .empty;
    errdefer {
        for (acts_blocks.items) |block| {
            if (block.field_commands.len > 0) allocator.free(block.field_commands);
            if (block.sprite_commands.len > 0) allocator.free(block.sprite_commands);
            if (block.layer_orders.len > 0) allocator.free(block.layer_orders);
        }
        acts_blocks.deinit(allocator);
    }

    for (acts_forms) |acts_form| {
        const block = try parseActsBlock(allocator, acts_form);
        acts_blocks.append(allocator, block) catch return MovieError.OutOfMemory;
    }

    return .{
        .clear_screen = clear_screen,
        .frame_speed_ticks = frame_speed_ticks,
        .file_references = file_references,
        .acts_blocks = acts_blocks.toOwnedSlice(allocator) catch return MovieError.OutOfMemory,
        .allocator = allocator,
    };
}

/// Parse slot-indexed file references from a FILE chunk.
/// Real format: repeated [slot_id: u16 LE][null-terminated path] pairs.
/// Slot IDs can be sparse (e.g., 0, 1, 2, 4 — slot 3 skipped).
fn parseFileReferences(allocator: std.mem.Allocator, data: []const u8) MovieError![]const FileSlot {
    var refs: std.ArrayListUnmanaged(FileSlot) = .empty;
    errdefer refs.deinit(allocator);

    var pos: usize = 0;
    while (pos + 2 < data.len) {
        // Read u16 LE slot ID
        const slot_id = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        // Find null terminator for the path string
        const path_start = pos;
        while (pos < data.len and data[pos] != 0) {
            pos += 1;
        }
        if (pos <= path_start) break; // empty path = done
        const path = data[path_start..pos];

        // Skip past the null terminator
        if (pos < data.len and data[pos] == 0) {
            pos += 1;
        }

        refs.append(allocator, .{
            .slot_id = slot_id,
            .path = path,
        }) catch return MovieError.OutOfMemory;
    }

    return refs.toOwnedSlice(allocator) catch return MovieError.OutOfMemory;
}

/// Parse a single FORM:ACTS block into field, sprite, and layer commands.
fn parseActsBlock(allocator: std.mem.Allocator, acts_form: *const iff.Chunk) MovieError!ActsBlock {
    // Collect FILD commands
    const fild_chunks = acts_form.findChildren(allocator, "FILD".*) catch return MovieError.OutOfMemory;
    defer allocator.free(fild_chunks);

    var field_cmds: std.ArrayListUnmanaged(FieldCommand) = .empty;
    errdefer field_cmds.deinit(allocator);
    for (fild_chunks) |fild| {
        // Each FILD chunk contains packed 10-byte records:
        // [object_id: u16 LE][file_ref: u16 LE][param1: u16 LE][param2: u16 LE][param3: u16 LE]
        var pos: usize = 0;
        while (pos + 10 <= fild.data.len) {
            field_cmds.append(allocator, .{
                .object_id = std.mem.readInt(u16, fild.data[pos..][0..2], .little),
                .file_ref = std.mem.readInt(u16, fild.data[pos + 2 ..][0..2], .little),
                .param1 = std.mem.readInt(u16, fild.data[pos + 4 ..][0..2], .little),
                .param2 = std.mem.readInt(u16, fild.data[pos + 6 ..][0..2], .little),
                .param3 = std.mem.readInt(u16, fild.data[pos + 8 ..][0..2], .little),
            }) catch return MovieError.OutOfMemory;
            pos += 10;
        }
    }

    // Collect SPRI commands
    const spri_chunks = acts_form.findChildren(allocator, "SPRI".*) catch return MovieError.OutOfMemory;
    defer allocator.free(spri_chunks);

    var sprite_cmds: std.ArrayListUnmanaged(SpriteCommand) = .empty;
    errdefer sprite_cmds.deinit(allocator);
    for (spri_chunks) |spri| {
        if (spri.data.len >= 8) {
            sprite_cmds.append(allocator, .{
                .file_ref = spri.data[0],
                .sprite_index = std.mem.readInt(u16, spri.data[1..3], .big),
                .x = std.mem.readInt(i16, spri.data[3..5], .big),
                .y = std.mem.readInt(i16, spri.data[5..7], .big),
                .flags = spri.data[7],
            }) catch return MovieError.OutOfMemory;
        }
    }

    // Collect BFOR commands
    const bfor_chunks = acts_form.findChildren(allocator, "BFOR".*) catch return MovieError.OutOfMemory;
    defer allocator.free(bfor_chunks);

    var layer_cmds: std.ArrayListUnmanaged(LayerOrder) = .empty;
    errdefer layer_cmds.deinit(allocator);
    for (bfor_chunks) |bfor| {
        if (bfor.data.len >= 2) {
            layer_cmds.append(allocator, .{
                .value = std.mem.readInt(u16, bfor.data[0..2], .big),
            }) catch return MovieError.OutOfMemory;
        }
    }

    return .{
        .field_commands = field_cmds.toOwnedSlice(allocator) catch return MovieError.OutOfMemory,
        .sprite_commands = sprite_cmds.toOwnedSlice(allocator) catch return MovieError.OutOfMemory,
        .layer_orders = layer_cmds.toOwnedSlice(allocator) catch return MovieError.OutOfMemory,
    };
}

/// Normalize a DOS-style file path from a FILE chunk to a TRE-compatible path.
/// Strips the `..\..\data\` prefix and converts backslashes to forward slashes,
/// then uppercases the result.
pub fn normalizeFilePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Strip ..\..\data\ prefix (case-insensitive)
    var start: usize = 0;
    const prefix = "..\\..\\data\\";
    if (path.len >= prefix.len) {
        const candidate = path[0..prefix.len];
        if (std.ascii.eqlIgnoreCase(candidate, prefix)) {
            start = prefix.len;
        }
    }

    const result = try allocator.alloc(u8, path.len - start);
    for (path[start..], 0..) |c, i| {
        result[i] = if (c == '\\') '/' else std.ascii.toUpper(c);
    }
    return result;
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "isMovi identifies FORM:MOVI data" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_movi.bin");
    defer allocator.free(data);

    try std.testing.expect(isMovi(data));
}

test "isMovi rejects non-MOVI data" {
    try std.testing.expect(!isMovi("FORM\x00\x00\x00\x04XDIR"));
    try std.testing.expect(!isMovi("short"));
    try std.testing.expect(!isMovi(""));
}

test "parse FORM:MOVI from fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_movi.bin");
    defer allocator.free(data);

    var script = try parse(allocator, data);
    defer script.deinit();

    // CLRC = 1 (clear screen)
    try std.testing.expect(script.clear_screen);

    // SPED = 10
    try std.testing.expectEqual(@as(u16, 10), script.frame_speed_ticks);

    // FILE: 4 slot-indexed file references (slots 0, 1, 2, 4 — slot 3 skipped)
    try std.testing.expectEqual(@as(usize, 4), script.file_references.len);

    // Verify slot IDs
    try std.testing.expectEqual(@as(u16, 0), script.file_references[0].slot_id);
    try std.testing.expectEqual(@as(u16, 1), script.file_references[1].slot_id);
    try std.testing.expectEqual(@as(u16, 2), script.file_references[2].slot_id);
    try std.testing.expectEqual(@as(u16, 4), script.file_references[3].slot_id);

    // Verify paths
    try std.testing.expectEqualStrings("..\\..\\data\\midgames\\mid1.pak", script.file_references[0].path);
    try std.testing.expectEqualStrings("..\\..\\data\\midgames\\midtext.pak", script.file_references[1].path);
    try std.testing.expectEqualStrings("..\\..\\data\\fonts\\demofont.shp", script.file_references[2].path);
    try std.testing.expectEqualStrings("..\\..\\data\\sound\\opening", script.file_references[3].path);

    // Verify helper methods
    try std.testing.expectEqual(@as(usize, 5), script.fileSlotCount()); // max slot_id=4, so count=5
    try std.testing.expectEqualStrings("..\\..\\data\\midgames\\mid1.pak", script.getFilePath(0).?);
    try std.testing.expectEqualStrings("..\\..\\data\\sound\\opening", script.getFilePath(4).?);
    try std.testing.expect(script.getFilePath(3) == null); // sparse — slot 3 not present

    // 1 ACTS block
    try std.testing.expectEqual(@as(usize, 1), script.acts_blocks.len);
    const acts = script.acts_blocks[0];

    // FILD: 2 packed 10-byte records
    try std.testing.expectEqual(@as(usize, 2), acts.field_commands.len);
    // Record 0: object_id=23, file_ref=0, param1=5, param2=100, param3=50
    try std.testing.expectEqual(@as(u16, 23), acts.field_commands[0].object_id);
    try std.testing.expectEqual(@as(u16, 0), acts.field_commands[0].file_ref);
    try std.testing.expectEqual(@as(u16, 5), acts.field_commands[0].param1);
    try std.testing.expectEqual(@as(u16, 100), acts.field_commands[0].param2);
    try std.testing.expectEqual(@as(u16, 50), acts.field_commands[0].param3);
    // Record 1: object_id=24, file_ref=1, param1=3, param2=0, param3=0
    try std.testing.expectEqual(@as(u16, 24), acts.field_commands[1].object_id);
    try std.testing.expectEqual(@as(u16, 1), acts.field_commands[1].file_ref);
    try std.testing.expectEqual(@as(u16, 3), acts.field_commands[1].param1);
    try std.testing.expectEqual(@as(u16, 0), acts.field_commands[1].param2);
    try std.testing.expectEqual(@as(u16, 0), acts.field_commands[1].param3);

    // SPRI: file_ref=0, sprite_index=3, x=160, y=100, flags=1
    try std.testing.expectEqual(@as(usize, 1), acts.sprite_commands.len);
    try std.testing.expectEqual(@as(u8, 0), acts.sprite_commands[0].file_ref);
    try std.testing.expectEqual(@as(u16, 3), acts.sprite_commands[0].sprite_index);
    try std.testing.expectEqual(@as(i16, 160), acts.sprite_commands[0].x);
    try std.testing.expectEqual(@as(i16, 100), acts.sprite_commands[0].y);
    try std.testing.expectEqual(@as(u8, 1), acts.sprite_commands[0].flags);

    // BFOR: value=1
    try std.testing.expectEqual(@as(usize, 1), acts.layer_orders.len);
    try std.testing.expectEqual(@as(u16, 1), acts.layer_orders[0].value);
}

test "parse FORM:MOVI with multiple ACTS blocks" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_movi_multi_acts.bin");
    defer allocator.free(data);

    var script = try parse(allocator, data);
    defer script.deinit();

    // CLRC = 0 (no clear)
    try std.testing.expect(!script.clear_screen);

    // SPED = 5
    try std.testing.expectEqual(@as(u16, 5), script.frame_speed_ticks);

    // FILE: same 4 slot-indexed references as fixture 1
    try std.testing.expectEqual(@as(usize, 4), script.file_references.len);
    try std.testing.expectEqual(@as(u16, 0), script.file_references[0].slot_id);
    try std.testing.expectEqual(@as(u16, 4), script.file_references[3].slot_id);

    // 2 ACTS blocks
    try std.testing.expectEqual(@as(usize, 2), script.acts_blocks.len);

    // First ACTS block (same as fixture 1 — 2 FILD records)
    try std.testing.expectEqual(@as(usize, 2), script.acts_blocks[0].field_commands.len);
    try std.testing.expectEqual(@as(usize, 1), script.acts_blocks[0].sprite_commands.len);
    try std.testing.expectEqual(@as(usize, 1), script.acts_blocks[0].layer_orders.len);

    // Second ACTS block
    const acts2 = script.acts_blocks[1];
    try std.testing.expectEqual(@as(usize, 1), acts2.field_commands.len);
    try std.testing.expectEqual(@as(u16, 30), acts2.field_commands[0].object_id);
    try std.testing.expectEqual(@as(u16, 1), acts2.field_commands[0].file_ref);
    try std.testing.expectEqual(@as(u16, 10), acts2.field_commands[0].param1);
    try std.testing.expectEqual(@as(usize, 1), acts2.sprite_commands.len);
    try std.testing.expectEqual(@as(u8, 1), acts2.sprite_commands[0].file_ref);
    try std.testing.expectEqual(@as(u16, 7), acts2.sprite_commands[0].sprite_index);
    // No BFOR in second block
    try std.testing.expectEqual(@as(usize, 0), acts2.layer_orders.len);
}

test "normalizeFilePath strips prefix and converts separators" {
    const allocator = std.testing.allocator;

    const result1 = try normalizeFilePath(allocator, "..\\..\\data\\midgames\\mid1.pak");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("MIDGAMES/MID1.PAK", result1);

    const result2 = try normalizeFilePath(allocator, "..\\..\\data\\fonts\\demofont.shp");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("FONTS/DEMOFONT.SHP", result2);

    // Path without the prefix is just uppercased with separator conversion
    const result3 = try normalizeFilePath(allocator, "sound\\opening");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("SOUND/OPENING", result3);
}

test "parse rejects non-MOVI data" {
    const allocator = std.testing.allocator;

    // Load an XMIDI fixture (FORM:XDIR, not FORM:MOVI)
    const xmidi_data = try testing_helpers.loadFixture(allocator, "test_xmidi.bin");
    defer allocator.free(xmidi_data);

    const result = parse(allocator, xmidi_data);
    try std.testing.expectError(MovieError.InvalidFormat, result);
}

test "parse rejects too-short data" {
    const allocator = std.testing.allocator;
    const result = parse(allocator, "short");
    try std.testing.expectError(MovieError.InvalidFormat, result);
}
