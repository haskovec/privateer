//! VPK/VPF (Voice Pack) parser for Wing Commander: Privateer.
//! VPK/VPF files contain LZW-compressed VOC audio clips for conversation speech.
//! Structure: u32 file_size header, offset table (u32 entries with marker byte),
//! then LZW-compressed entries each prefixed with a u32 decompressed size.

const std = @import("std");

/// Minimum valid VPK file: file_size(4) + at least one offset entry(4) + minimal entry data.
pub const MIN_FILE_SIZE: usize = 12;

/// Marker byte in the high byte of offset table entries.
pub const ENTRY_MARKER: u8 = 0x20;

/// LZW special codes.
const LZW_CLEAR: u16 = 256;
const LZW_END: u16 = 257;
const LZW_FIRST_CODE: u16 = 258;
const LZW_MAX_CODE: u16 = 4095;
const LZW_INITIAL_CODE_SIZE: u4 = 9;
const LZW_MAX_CODE_SIZE: u4 = 12;

pub const VpkError = error{
    /// File too small to contain a valid VPK header.
    InvalidSize,
    /// File size field does not match actual data length.
    FileSizeMismatch,
    /// First offset is not aligned to entry table layout.
    InvalidOffsetTable,
    /// An entry offset points outside the file.
    EntryOverflow,
    /// Entry decompressed size field is missing or invalid.
    InvalidEntryHeader,
    /// LZW compressed data does not start with clear code (256).
    LzwMissingClearCode,
    /// LZW code is out of dictionary range.
    LzwBadCode,
    /// LZW decompression produced unexpected output size.
    LzwSizeMismatch,
    OutOfMemory,
};

/// A parsed VPK file with access to entry metadata.
pub const VpkFile = struct {
    /// Raw file data (not owned).
    data: []const u8,
    /// Offsets to each entry (low 24 bits of offset table values).
    entry_offsets: []const u32,
    /// Total file size from header.
    file_size: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VpkFile) void {
        self.allocator.free(self.entry_offsets);
    }

    /// Number of voice clip entries in this VPK.
    pub fn entryCount(self: VpkFile) usize {
        return self.entry_offsets.len;
    }

    /// Get the compressed entry data for a given index (includes the 4-byte decompressed size prefix).
    pub fn getEntryData(self: VpkFile, index: usize) VpkError![]const u8 {
        if (index >= self.entry_offsets.len) return VpkError.EntryOverflow;

        const start = self.entry_offsets[index];
        const end = if (index + 1 < self.entry_offsets.len)
            self.entry_offsets[index + 1]
        else
            self.file_size;

        if (start >= self.data.len or end > self.data.len or start >= end)
            return VpkError.EntryOverflow;

        return self.data[start..end];
    }

    /// Decompress entry at index, returning raw VOC file data.
    /// Caller must free the returned slice.
    pub fn decompressEntry(self: VpkFile, allocator: std.mem.Allocator, index: usize) VpkError![]const u8 {
        const entry_data = try self.getEntryData(index);
        return lzwDecompress(allocator, entry_data);
    }
};

/// Parse a VPK/VPF file header and offset table.
/// The returned VpkFile references the input data (does not copy it).
pub fn parse(allocator: std.mem.Allocator, data: []const u8) VpkError!VpkFile {
    if (data.len < MIN_FILE_SIZE) return VpkError.InvalidSize;

    const file_size = std.mem.readInt(u32, data[0..4], .little);
    if (file_size != data.len) return VpkError.FileSizeMismatch;

    // Read first offset to determine entry count
    const first_raw = std.mem.readInt(u32, data[4..8], .little);
    const first_offset = first_raw & 0x00FFFFFF;

    // Validate offset table layout
    if (first_offset < 8 or (first_offset - 4) % 4 != 0)
        return VpkError.InvalidOffsetTable;

    const entry_count = (first_offset - 4) / 4;
    if (entry_count == 0) return VpkError.InvalidOffsetTable;

    // Parse offset table
    const offsets = try allocator.alloc(u32, entry_count);
    errdefer allocator.free(offsets);

    for (0..entry_count) |i| {
        const table_pos = 4 + i * 4;
        if (table_pos + 4 > data.len) {
            allocator.free(offsets);
            return VpkError.InvalidOffsetTable;
        }
        const raw = std.mem.readInt(u32, data[table_pos..][0..4], .little);
        const offset = raw & 0x00FFFFFF;
        if (offset >= data.len) {
            allocator.free(offsets);
            return VpkError.EntryOverflow;
        }
        offsets[i] = offset;
    }

    return .{
        .data = data,
        .entry_offsets = offsets,
        .file_size = file_size,
        .allocator = allocator,
    };
}

/// LZW bit reader: extracts variable-width codes from a byte stream (LSB-first packing).
const LzwBitReader = struct {
    data: []const u8,
    bit_pos: usize,

    fn readCode(self: *LzwBitReader, code_size: u4) u16 {
        const byte_pos = self.bit_pos / 8;
        const bit_off: u5 = @intCast(self.bit_pos % 8);

        // Read up to 3 bytes to cover any code_size up to 12 bits
        var val: u32 = 0;
        inline for (0..3) |i| {
            if (byte_pos + i < self.data.len) {
                val |= @as(u32, self.data[byte_pos + i]) << @intCast(8 * i);
            }
        }

        const mask: u32 = (@as(u32, 1) << code_size) - 1;
        const code: u16 = @intCast((val >> bit_off) & mask);
        self.bit_pos += code_size;
        return code;
    }

    fn exhausted(self: LzwBitReader) bool {
        return self.bit_pos / 8 >= self.data.len;
    }
};

/// LZW dictionary entry stored as (prefix_code, append_byte) pairs for memory efficiency.
/// Single-byte entries (codes 0-255) have prefix = LZW_END as a sentinel.
const LzwDictEntry = struct {
    prefix: u16,
    byte_val: u8,
    len: u16, // length of the full string this entry represents
};

/// Decompress LZW data from a VPK entry.
/// Entry format: u32 LE decompressed_size + LZW compressed bytes.
fn lzwDecompress(allocator: std.mem.Allocator, entry_data: []const u8) VpkError![]const u8 {
    if (entry_data.len < 5) return VpkError.InvalidEntryHeader;

    const decompressed_size = std.mem.readInt(u32, entry_data[0..4], .little);
    if (decompressed_size == 0) return VpkError.InvalidEntryHeader;

    const lzw_data = entry_data[4..];

    var reader = LzwBitReader{ .data = lzw_data, .bit_pos = 0 };
    var code_size: u4 = LZW_INITIAL_CODE_SIZE;

    // Read first code -- must be clear
    const first_code = reader.readCode(code_size);
    if (first_code != LZW_CLEAR) return VpkError.LzwMissingClearCode;

    // Dictionary: entries 0-255 are single-byte literals; 256=clear, 257=end
    var dict: [LZW_MAX_CODE + 1]LzwDictEntry = undefined;
    for (0..256) |i| {
        dict[i] = .{ .prefix = LZW_END, .byte_val = @intCast(i), .len = 1 };
    }
    var next_code: u16 = LZW_FIRST_CODE;

    // Output buffer
    const output = allocator.alloc(u8, decompressed_size) catch return VpkError.OutOfMemory;
    errdefer allocator.free(output);
    var out_pos: usize = 0;

    // Temporary buffer for decoding dictionary chains
    var decode_buf: [LZW_MAX_CODE + 1]u8 = undefined;

    // Helper: decode a dictionary entry chain into decode_buf, return the slice
    const decodeDictEntry = struct {
        fn call(d: *const [LZW_MAX_CODE + 1]LzwDictEntry, buf: *[LZW_MAX_CODE + 1]u8, code: u16) []const u8 {
            const entry_len = d[code].len;
            var pos: usize = entry_len;
            var c = code;
            while (pos > 0) {
                pos -= 1;
                buf[pos] = d[c].byte_val;
                c = d[c].prefix;
            }
            return buf[0..entry_len];
        }
    }.call;

    // Read first real code (must be a literal)
    var code = reader.readCode(code_size);
    if (code >= 256) return VpkError.LzwBadCode;

    if (out_pos < decompressed_size) {
        output[out_pos] = @intCast(code);
        out_pos += 1;
    }
    var prev_code = code;

    while (out_pos < decompressed_size) {
        if (reader.exhausted()) break;

        code = reader.readCode(code_size);
        if (code == LZW_END) break;

        if (code == LZW_CLEAR) {
            // Reset dictionary
            next_code = LZW_FIRST_CODE;
            code_size = LZW_INITIAL_CODE_SIZE;

            code = reader.readCode(code_size);
            if (code == LZW_END) break;
            if (code >= 256) return VpkError.LzwBadCode;

            if (out_pos < decompressed_size) {
                output[out_pos] = @intCast(code);
                out_pos += 1;
            }
            prev_code = code;
            continue;
        }

        var entry_bytes: []const u8 = undefined;

        if (code < next_code) {
            // Code is in dictionary
            entry_bytes = decodeDictEntry(&dict, &decode_buf, code);
        } else if (code == next_code) {
            // Special case: code not yet in dictionary
            const prev_bytes = decodeDictEntry(&dict, &decode_buf, prev_code);
            // We need a separate buffer since decode_buf is shared
            var special_buf: [LZW_MAX_CODE + 1]u8 = undefined;
            @memcpy(special_buf[0..prev_bytes.len], prev_bytes);
            special_buf[prev_bytes.len] = prev_bytes[0];
            entry_bytes = special_buf[0 .. prev_bytes.len + 1];

            // Copy to output now before decode_buf might be reused
            const copy_len = @min(entry_bytes.len, decompressed_size - out_pos);
            @memcpy(output[out_pos .. out_pos + copy_len], entry_bytes[0..copy_len]);
            out_pos += copy_len;

            // Add to dictionary
            if (next_code <= LZW_MAX_CODE) {
                const prev_entry_bytes = decodeDictEntry(&dict, &decode_buf, prev_code);
                dict[next_code] = .{
                    .prefix = prev_code,
                    .byte_val = prev_entry_bytes[0],
                    .len = @intCast(prev_entry_bytes.len + 1),
                };
                next_code += 1;
                if (next_code > (@as(u16, 1) << code_size) - 1 and code_size < LZW_MAX_CODE_SIZE) {
                    code_size += 1;
                }
            }
            prev_code = code;
            continue;
        } else {
            return VpkError.LzwBadCode;
        }

        // Copy decoded bytes to output
        const copy_len = @min(entry_bytes.len, decompressed_size - out_pos);
        @memcpy(output[out_pos .. out_pos + copy_len], entry_bytes[0..copy_len]);
        out_pos += copy_len;

        // Add new dictionary entry: prev_string + first byte of current entry
        if (next_code <= LZW_MAX_CODE) {
            dict[next_code] = .{
                .prefix = prev_code,
                .byte_val = entry_bytes[0],
                .len = dict[prev_code].len + 1,
            };
            next_code += 1;
            if (next_code > (@as(u16, 1) << code_size) - 1 and code_size < LZW_MAX_CODE_SIZE) {
                code_size += 1;
            }
        }

        prev_code = code;
    }

    if (out_pos != decompressed_size) return VpkError.LzwSizeMismatch;

    return output;
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");
const voc = @import("voc.zig");

test "parse VPK header from fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk = try parse(allocator, data);
    defer vpk.deinit();

    // test_vpk.bin has 2 entries
    try std.testing.expectEqual(@as(usize, 2), vpk.entryCount());
    // First offset should be 12 (4 byte header + 2*4 offset entries)
    try std.testing.expectEqual(@as(u32, 12), vpk.entry_offsets[0]);
}

test "parse VPK single entry fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk_single.bin");
    defer allocator.free(data);

    var vpk = try parse(allocator, data);
    defer vpk.deinit();

    try std.testing.expectEqual(@as(usize, 1), vpk.entryCount());
    try std.testing.expectEqual(@as(u32, 8), vpk.entry_offsets[0]);
}

test "VPK LZW decompression produces valid VOC" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk = try parse(allocator, data);
    defer vpk.deinit();

    // Decompress first entry
    const voc_data = try vpk.decompressEntry(allocator, 0);
    defer allocator.free(voc_data);

    // Should be valid VOC data
    try std.testing.expect(voc_data.len >= voc.HEADER_SIZE);
    try std.testing.expect(std.mem.eql(u8, voc_data[0..voc.SIGNATURE_LEN], voc.SIGNATURE));

    // Parse as VOC
    var voc_file = try voc.parse(allocator, voc_data);
    defer voc_file.deinit();

    try std.testing.expectEqual(voc.CODEC_PCM_8BIT, voc_file.codec);
    try std.testing.expectEqual(@as(usize, 8), voc_file.samples.len);
    try std.testing.expectEqual(@as(u8, 128), voc_file.samples[0]);
}

test "VPK decompress all entries" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk.bin");
    defer allocator.free(data);

    var vpk = try parse(allocator, data);
    defer vpk.deinit();

    for (0..vpk.entryCount()) |i| {
        const voc_data = try vpk.decompressEntry(allocator, i);
        defer allocator.free(voc_data);

        // Each entry should decompress to valid VOC
        try std.testing.expect(std.mem.eql(u8, voc_data[0..voc.SIGNATURE_LEN], voc.SIGNATURE));
    }
}

test "VPK single entry decompresses to valid VOC" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_vpk_single.bin");
    defer allocator.free(data);

    var vpk = try parse(allocator, data);
    defer vpk.deinit();

    const voc_data = try vpk.decompressEntry(allocator, 0);
    defer allocator.free(voc_data);

    var voc_file = try voc.parse(allocator, voc_data);
    defer voc_file.deinit();

    try std.testing.expectEqual(@as(usize, 6), voc_file.samples.len);
    try std.testing.expectEqual(@as(u8, 128), voc_file.samples[0]);
    try std.testing.expectEqual(@as(u8, 255), voc_file.samples[1]);
}

test "parse rejects too-small data" {
    const allocator = std.testing.allocator;
    const data = [_]u8{0} ** 8;
    try std.testing.expectError(VpkError.InvalidSize, parse(allocator, &data));
}

test "parse rejects mismatched file size" {
    const allocator = std.testing.allocator;
    var data = [_]u8{0} ** 16;
    // Set file_size to 100 but actual data is only 16 bytes
    std.mem.writeInt(u32, data[0..4], 100, .little);
    try std.testing.expectError(VpkError.FileSizeMismatch, parse(allocator, &data));
}
