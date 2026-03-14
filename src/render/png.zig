//! Minimal PNG encoder for sprite-to-image output.
//! Writes RGBA pixel data to valid PNG files for visual verification.
//! Uses uncompressed deflate blocks (stored mode) for simplicity.

const std = @import("std");

pub const PngError = error{
    InvalidDimensions,
    OutOfMemory,
};

/// PNG file signature (8 bytes).
pub const SIGNATURE = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// Encode RGBA pixel data as a PNG file.
/// pixels: width*height*4 bytes (RGBA, row-major, top-to-bottom).
/// Returns an owned byte slice containing the complete PNG file.
pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    if (width == 0 or height == 0) return PngError.InvalidDimensions;
    const expected_len = @as(usize, width) * @as(usize, height) * 4;
    if (pixels.len != expected_len) return PngError.InvalidDimensions;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // PNG signature
    try buf.appendSlice(allocator, &SIGNATURE);

    // IHDR chunk
    const ihdr = ihdrData(width, height);
    try writeChunk(allocator, &buf, "IHDR", &ihdr);

    // IDAT chunk - filtered image data in zlib stored blocks
    const filtered = try buildFilteredData(allocator, width, height, pixels);
    defer allocator.free(filtered);
    const compressed = try zlibStore(allocator, filtered);
    defer allocator.free(compressed);
    try writeChunk(allocator, &buf, "IDAT", compressed);

    // IEND chunk
    try writeChunk(allocator, &buf, "IEND", &[_]u8{});

    return buf.toOwnedSlice(allocator);
}

fn ihdrData(width: u32, height: u32) [13]u8 {
    var data: [13]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], width, .big);
    std.mem.writeInt(u32, data[4..8], height, .big);
    data[8] = 8; // bit depth
    data[9] = 6; // color type: RGBA
    data[10] = 0; // compression: deflate
    data[11] = 0; // filter: adaptive
    data[12] = 0; // interlace: none
    return data;
}

/// Build filtered scanlines: filter byte 0 (None) + row pixel data for each row.
fn buildFilteredData(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    const row_bytes = @as(usize, width) * 4;
    const filtered_row = 1 + row_bytes;
    const total = filtered_row * @as(usize, height);

    const out = try allocator.alloc(u8, total);
    for (0..@as(usize, height)) |y| {
        const out_off = y * filtered_row;
        const in_off = y * row_bytes;
        out[out_off] = 0; // filter type None
        @memcpy(out[out_off + 1 .. out_off + filtered_row], pixels[in_off .. in_off + row_bytes]);
    }
    return out;
}

/// Wrap data in zlib format using deflate stored (uncompressed) blocks.
fn zlibStore(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const max_block: usize = 65535;
    const num_blocks = if (data.len == 0) @as(usize, 1) else (data.len + max_block - 1) / max_block;
    const overhead = 2 + num_blocks * 5 + 4;
    const total = overhead + data.len;

    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;

    // Zlib header
    out[pos] = 0x78;
    pos += 1;
    out[pos] = 0x01;
    pos += 1;

    // Deflate stored blocks
    var remaining = data.len;
    var src_pos: usize = 0;
    if (data.len == 0) {
        // Empty final block
        out[pos] = 0x01;
        pos += 1;
        std.mem.writeInt(u16, out[pos..][0..2], 0, .little);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], 0xFFFF, .little);
        pos += 2;
    } else {
        while (remaining > 0) {
            const block_len = @min(remaining, max_block);
            out[pos] = if (remaining <= max_block) 0x01 else 0x00;
            pos += 1;
            const len16: u16 = @intCast(block_len);
            std.mem.writeInt(u16, out[pos..][0..2], len16, .little);
            pos += 2;
            std.mem.writeInt(u16, out[pos..][0..2], ~len16, .little);
            pos += 2;

            @memcpy(out[pos .. pos + block_len], data[src_pos .. src_pos + block_len]);
            pos += block_len;
            src_pos += block_len;
            remaining -= block_len;
        }
    }

    // Adler-32 checksum
    std.mem.writeInt(u32, out[pos..][0..4], adler32(data), .big);
    pos += 4;

    return out;
}

/// Compute Adler-32 checksum (used in zlib).
pub fn adler32(data: []const u8) u32 {
    const MOD = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % MOD;
        b = (b + a) % MOD;
    }
    return (b << 16) | a;
}

/// CRC-32 state for PNG chunk checksums (ISO 3309 polynomial).
const Crc32State = struct {
    crc: u32 = 0xFFFFFFFF,

    fn update(self: *Crc32State, data: []const u8) void {
        var c = self.crc;
        for (data) |byte| {
            c ^= byte;
            for (0..8) |_| {
                c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
            }
        }
        self.crc = c;
    }

    fn final(self: Crc32State) u32 {
        return self.crc ^ 0xFFFFFFFF;
    }
};

/// Write a PNG chunk: length(4B BE) + type(4B) + data + CRC32(4B BE).
fn writeChunk(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), chunk_type: *const [4]u8, data: []const u8) !void {
    // Length
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    try buf.appendSlice(allocator, &len_bytes);

    // Type
    try buf.appendSlice(allocator, chunk_type);

    // Data
    try buf.appendSlice(allocator, data);

    // CRC32 over type + data
    var crc = Crc32State{};
    crc.update(chunk_type);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try buf.appendSlice(allocator, &crc_bytes);
}

// --- Tests ---

test "encode produces valid PNG signature" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255 };
    const png_data = try encode(allocator, 1, 1, &pixels);
    defer allocator.free(png_data);

    try std.testing.expectEqualSlices(u8, &SIGNATURE, png_data[0..8]);
}

test "encode produces IHDR, IDAT, IEND chunks in order" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255 };
    const png_data = try encode(allocator, 1, 1, &pixels);
    defer allocator.free(png_data);

    // IHDR chunk type at offset 12 (after 8 sig + 4 length)
    try std.testing.expectEqualSlices(u8, "IHDR", png_data[12..16]);

    // IHDR chunk: 4(len) + 4(type) + 13(data) + 4(crc) = 25 bytes
    // IDAT chunk type at offset 8 + 25 + 4 = 37
    try std.testing.expectEqualSlices(u8, "IDAT", png_data[37..41]);

    // IEND is the last chunk: last 12 bytes
    const iend_start = png_data.len - 12;
    try std.testing.expectEqualSlices(u8, "IEND", png_data[iend_start + 4 .. iend_start + 8]);
}

test "encode IHDR contains correct dimensions" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        255, 0,   0,   255, 0, 255, 0, 255,
        0,   0,   255, 255, 0, 0,   0, 255,
    };
    const png_data = try encode(allocator, 2, 2, &pixels);
    defer allocator.free(png_data);

    // IHDR data starts at offset 16 (8 sig + 4 len + 4 type)
    const w = std.mem.readInt(u32, png_data[16..20], .big);
    const h = std.mem.readInt(u32, png_data[20..24], .big);
    try std.testing.expectEqual(@as(u32, 2), w);
    try std.testing.expectEqual(@as(u32, 2), h);
}

test "encode IEND has zero length" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255 };
    const png_data = try encode(allocator, 1, 1, &pixels);
    defer allocator.free(png_data);

    const iend_start = png_data.len - 12;
    const iend_len = std.mem.readInt(u32, png_data[iend_start..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 0), iend_len);
}

test "encode rejects zero width" {
    try std.testing.expectError(PngError.InvalidDimensions, encode(std.testing.allocator, 0, 1, &[_]u8{}));
}

test "encode rejects zero height" {
    try std.testing.expectError(PngError.InvalidDimensions, encode(std.testing.allocator, 1, 0, &[_]u8{}));
}

test "encode rejects mismatched pixel data length" {
    const pixels = [_]u8{ 255, 0, 0 }; // 3 bytes, need 4 for 1x1 RGBA
    try std.testing.expectError(PngError.InvalidDimensions, encode(std.testing.allocator, 1, 1, &pixels));
}

test "adler32 of empty data" {
    try std.testing.expectEqual(@as(u32, 1), adler32(&[_]u8{}));
}

test "adler32 of known string" {
    try std.testing.expectEqual(@as(u32, 0x11E60398), adler32("Wikipedia"));
}

test "CRC32 of IEND" {
    var crc = Crc32State{};
    crc.update("IEND");
    try std.testing.expectEqual(@as(u32, 0xAE426082), crc.final());
}

test "CRC32 incremental update matches single-shot" {
    var crc1 = Crc32State{};
    crc1.update("IE");
    crc1.update("ND");

    var crc2 = Crc32State{};
    crc2.update("IEND");

    try std.testing.expectEqual(crc2.final(), crc1.final());
}

test "encode 2x2 image produces valid PNG" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        255, 0, 0,   255, 0, 255, 0,   255,
        0,   0, 255, 255, 0, 0,   0,   255,
    };
    const png_data = try encode(allocator, 2, 2, &pixels);
    defer allocator.free(png_data);

    // Must start with PNG signature
    try std.testing.expectEqualSlices(u8, &SIGNATURE, png_data[0..8]);
    // Must be longer than just the signature
    try std.testing.expect(png_data.len > 8 + 25 + 12); // sig + IHDR + IEND minimum
}
