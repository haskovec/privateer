//! IFF (Interchange File Format) chunk parser for Wing Commander: Privateer.
//! Parses EA IFF-85 variant used by Origin Systems: FORM/CAT/LIST containers
//! with big-endian sizes and odd-byte padding.

const std = @import("std");

pub const CHUNK_HEADER_SIZE: usize = 8; // 4-byte tag + 4-byte size

pub const Tag = [4]u8;

/// A parsed IFF chunk. Containers (FORM, CAT, LIST) have a form_type and children.
/// Leaf chunks have raw data and no children.
pub const Chunk = struct {
    tag: Tag,
    /// Data size from the header (does not include the 8-byte header itself).
    size: u32,
    /// Raw chunk data slice (size bytes). For containers, starts at the form_type.
    data: []const u8,
    /// Non-null for FORM/CAT/LIST containers (first 4 bytes of data).
    form_type: ?Tag,
    /// Child chunks (only for containers).
    children: []Chunk,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Chunk) void {
        for (self.children) |*child| {
            var c = child.*;
            c.deinit();
        }
        if (self.children.len > 0) {
            self.allocator.free(self.children);
        }
    }

    /// Check if this chunk is a container (FORM, CAT, LIST).
    pub fn isContainer(self: Chunk) bool {
        return self.form_type != null;
    }

    /// Find the first child chunk with the given tag.
    pub fn findChild(self: Chunk, tag: Tag) ?*const Chunk {
        for (self.children) |*child| {
            if (std.mem.eql(u8, &child.tag, &tag)) return child;
        }
        return null;
    }

    /// Find the first child FORM container with the given form_type.
    pub fn findForm(self: Chunk, form_type: Tag) ?*const Chunk {
        for (self.children) |*child| {
            if (std.mem.eql(u8, &child.tag, "FORM")) {
                if (child.form_type) |ft| {
                    if (std.mem.eql(u8, &ft, &form_type)) return child;
                }
            }
        }
        return null;
    }

    /// Find all child FORM containers with the given form_type.
    pub fn findForms(self: Chunk, allocator: std.mem.Allocator, form_type: Tag) ![]const *const Chunk {
        var results: std.ArrayListUnmanaged(*const Chunk) = .empty;
        errdefer results.deinit(allocator);
        for (self.children) |*child| {
            if (std.mem.eql(u8, &child.tag, "FORM")) {
                if (child.form_type) |ft| {
                    if (std.mem.eql(u8, &ft, &form_type)) {
                        try results.append(allocator, child);
                    }
                }
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// Find all children with the given tag.
    pub fn findChildren(self: Chunk, allocator: std.mem.Allocator, tag: Tag) ![]const *const Chunk {
        var results: std.ArrayListUnmanaged(*const Chunk) = .empty;
        errdefer results.deinit(allocator);
        for (self.children) |*child| {
            if (std.mem.eql(u8, &child.tag, &tag)) {
                try results.append(allocator, child);
            }
        }
        return results.toOwnedSlice(allocator);
    }
};

pub const IffError = error{
    InvalidChunk,
    UnexpectedEnd,
    OutOfMemory,
};

/// Returns true if the tag is a container type (FORM, CAT , LIST).
fn isContainerTag(tag: Tag) bool {
    return std.mem.eql(u8, &tag, "FORM") or
        std.mem.eql(u8, &tag, "CAT ") or
        std.mem.eql(u8, &tag, "LIST");
}

/// Returns true if the bytes look like a valid IFF chunk tag (printable ASCII).
fn isValidTag(tag: Tag) bool {
    for (tag) |b| {
        if (b < 0x20 or b > 0x7E) return false;
    }
    return true;
}

/// Parse a single chunk at the given offset, recursively parsing children for containers.
/// Returns the parsed chunk and the offset of the next byte after this chunk (including padding).
pub fn parseChunk(allocator: std.mem.Allocator, data: []const u8, offset: usize) IffError!struct { chunk: Chunk, next_offset: usize } {
    if (offset + CHUNK_HEADER_SIZE > data.len) return IffError.UnexpectedEnd;

    const tag: Tag = data[offset..][0..4].*;
    const size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big);

    const data_start = offset + CHUNK_HEADER_SIZE;
    const data_end = data_start + size;
    if (data_end > data.len) return IffError.UnexpectedEnd;

    const chunk_data = data[data_start..data_end];

    // Next chunk starts after data, padded to even boundary
    const next_offset = data_end + (size & 1); // add 1 if odd

    if (isContainerTag(tag)) {
        if (size < 4) return IffError.InvalidChunk;
        const form_type: Tag = chunk_data[0..4].*;

        // Parse children starting after the form_type
        var children: std.ArrayListUnmanaged(Chunk) = .empty;
        errdefer {
            for (children.items) |*c| c.deinit();
            children.deinit(allocator);
        }

        var child_offset = data_start + 4; // skip form_type
        while (child_offset + CHUNK_HEADER_SIZE <= data_end) {
            // Validate that the next tag looks like a valid IFF chunk.
            // Origin's IFF variant sometimes has raw binary data after chunks.
            const candidate_tag: Tag = data[child_offset..][0..4].*;
            if (!isValidTag(candidate_tag)) break;

            const result = try parseChunk(allocator, data, child_offset);
            try children.append(allocator, result.chunk);
            child_offset = result.next_offset;
        }

        return .{
            .chunk = .{
                .tag = tag,
                .size = size,
                .data = chunk_data,
                .form_type = form_type,
                .children = children.toOwnedSlice(allocator) catch return IffError.OutOfMemory,
                .allocator = allocator,
            },
            .next_offset = next_offset,
        };
    } else {
        // Leaf chunk
        return .{
            .chunk = .{
                .tag = tag,
                .size = size,
                .data = chunk_data,
                .form_type = null,
                .children = &.{},
                .allocator = allocator,
            },
            .next_offset = next_offset,
        };
    }
}

/// Parse an IFF file from the beginning. Expects a single root chunk (usually FORM).
pub fn parseFile(allocator: std.mem.Allocator, data: []const u8) IffError!Chunk {
    const result = try parseChunk(allocator, data, 0);
    return result.chunk;
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parseFile parses FORM container from test_iff.bin" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iff.bin");
    defer allocator.free(data);

    var root = try parseFile(allocator, data);
    defer root.deinit();

    // Root should be FORM with type ATTD
    try std.testing.expectEqualStrings("FORM", &root.tag);
    try std.testing.expect(root.isContainer());
    try std.testing.expectEqualStrings("ATTD", &root.form_type.?);
    try std.testing.expectEqual(@as(u32, 52), root.size);
}

test "parseFile parses leaf chunks (AROW, DISP) from ATTD FORM" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iff.bin");
    defer allocator.free(data);

    var root = try parseFile(allocator, data);
    defer root.deinit();

    // Should have 3 children: AROW, DISP, FORM(NEST)
    try std.testing.expectEqual(@as(usize, 3), root.children.len);

    // AROW chunk
    const arow = root.children[0];
    try std.testing.expectEqualStrings("AROW", &arow.tag);
    try std.testing.expectEqual(@as(u32, 4), arow.size);
    try std.testing.expect(!arow.isContainer());
    const expected_arow = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try testing_helpers.expectBytes(&expected_arow, arow.data);

    // DISP chunk (odd size = 3, with padding)
    const disp = root.children[1];
    try std.testing.expectEqualStrings("DISP", &disp.tag);
    try std.testing.expectEqual(@as(u32, 3), disp.size);
    const expected_disp = [_]u8{ 0x05, 0x06, 0x07 };
    try testing_helpers.expectBytes(&expected_disp, disp.data);
}

test "parseFile parses nested FORM" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iff.bin");
    defer allocator.free(data);

    var root = try parseFile(allocator, data);
    defer root.deinit();

    // Third child should be FORM(NEST) with INFO child
    const nested = root.children[2];
    try std.testing.expectEqualStrings("FORM", &nested.tag);
    try std.testing.expect(nested.isContainer());
    try std.testing.expectEqualStrings("NEST", &nested.form_type.?);
    try std.testing.expectEqual(@as(usize, 1), nested.children.len);

    // INFO chunk inside NEST
    const info = nested.children[0];
    try std.testing.expectEqualStrings("INFO", &info.tag);
    try std.testing.expectEqual(@as(u32, 4), info.size);
    const expected_info = [_]u8{ 0x08, 0x09, 0x0A, 0x0B };
    try testing_helpers.expectBytes(&expected_info, info.data);
}

test "IFF padding: odd-sized chunks pad to even boundary" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iff.bin");
    defer allocator.free(data);

    var root = try parseFile(allocator, data);
    defer root.deinit();

    // If padding is handled correctly, we get all 3 children.
    // DISP has size=3 (odd), so parser must skip the pad byte.
    try std.testing.expectEqual(@as(usize, 3), root.children.len);
    // The third child must be the nested FORM, not garbage
    try std.testing.expectEqualStrings("FORM", &root.children[2].tag);
}

test "parseFile parses CAT container" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iff_cat.bin");
    defer allocator.free(data);

    var root = try parseFile(allocator, data);
    defer root.deinit();

    try std.testing.expectEqualStrings("CAT ", &root.tag);
    try std.testing.expect(root.isContainer());
    try std.testing.expectEqualStrings("TYPX", &root.form_type.?);
    // Two child FORMs
    try std.testing.expectEqual(@as(usize, 2), root.children.len);

    const form1 = root.children[0];
    try std.testing.expectEqualStrings("FORM", &form1.tag);
    try std.testing.expectEqualStrings("TYPX", &form1.form_type.?);

    const form2 = root.children[1];
    try std.testing.expectEqualStrings("FORM", &form2.tag);
    try std.testing.expectEqualStrings("TYPY", &form2.form_type.?);
}

test "findChild returns matching child" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_iff.bin");
    defer allocator.free(data);

    var root = try parseFile(allocator, data);
    defer root.deinit();

    const arow = root.findChild("AROW".*);
    try std.testing.expect(arow != null);
    try std.testing.expectEqualStrings("AROW", &arow.?.tag);

    const missing = root.findChild("XXXX".*);
    try std.testing.expect(missing == null);
}

test "parseFile rejects truncated data" {
    const data = [_]u8{ 'F', 'O', 'R', 'M', 0, 0 }; // too short
    try std.testing.expectError(IffError.UnexpectedEnd, parseFile(std.testing.allocator, &data));
}

test "parseFile rejects size exceeding data" {
    // FORM with size=100 but only 4 bytes of data
    const data = [_]u8{ 'F', 'O', 'R', 'M', 0, 0, 0, 100, 'T', 'E', 'S', 'T' };
    try std.testing.expectError(IffError.UnexpectedEnd, parseFile(std.testing.allocator, &data));
}

test "parseChunk from test_header.bin fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_header.bin");
    defer allocator.free(data);

    // test_header.bin is FORM(size=8) TEST 0xDEADBEEF
    var chunk = try parseFile(allocator, data);
    defer chunk.deinit();

    try std.testing.expectEqualStrings("FORM", &chunk.tag);
    try std.testing.expectEqual(@as(u32, 8), chunk.size);
    try std.testing.expectEqualStrings("TEST", &chunk.form_type.?);
    // FORM with size=8 means 4 bytes subtype + 4 bytes data, but 4 bytes is too small for a chunk header
    // So it should have 0 children (the remaining 4 bytes aren't a valid chunk)
    // Actually, the DEADBEEF bytes after TEST are only 4 bytes which is less than CHUNK_HEADER_SIZE(8)
    // The parser should stop when there's not enough data for another chunk header
    try std.testing.expectEqual(@as(usize, 0), chunk.children.len);
}
