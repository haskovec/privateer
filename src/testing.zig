const std = @import("std");

/// Load a test fixture file from the tests/fixtures/ directory.
/// Returns the file contents as a slice owned by the caller's allocator.
pub fn loadFixture(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ "tests/fixtures", name });
    defer allocator.free(path);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    const bytes_read = try file.readAll(buf);
    if (bytes_read != stat.size) {
        allocator.free(buf);
        return error.IncompleteRead;
    }
    return buf;
}

/// Assert two byte slices are equal, with a descriptive error on mismatch.
pub fn expectBytes(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |e, a, i| {
        if (e != a) {
            std.debug.print("byte mismatch at offset {d}: expected 0x{x:0>2}, got 0x{x:0>2}\n", .{ i, e, a });
            return error.TestExpectedEqual;
        }
    }
}

/// Assert two slices of any type are equal element-by-element.
pub fn expectSlice(comptime T: type, expected: []const T, actual: []const T) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |e, a, i| {
        if (e != a) {
            std.debug.print("element mismatch at index {d}\n", .{i});
            return error.TestExpectedEqual;
        }
    }
}

/// Assert two floats are approximately equal within a tolerance.
pub fn expectApproxEq(expected: f64, actual: f64, tolerance: f64) !void {
    const diff = @abs(expected - actual);
    if (diff > tolerance) {
        std.debug.print("expected ~{d}, got {d} (diff={d}, tolerance={d})\n", .{ expected, actual, diff, tolerance });
        return error.TestExpectedEqual;
    }
}

/// Read a big-endian u32 from a byte slice at the given offset.
pub fn readU32BE(data: []const u8, offset: usize) !u32 {
    if (offset + 4 > data.len) return error.OutOfBounds;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

/// Read a big-endian u16 from a byte slice at the given offset.
pub fn readU16BE(data: []const u8, offset: usize) !u16 {
    if (offset + 2 > data.len) return error.OutOfBounds;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

// --- Tests for the testing module itself ---

test "loadFixture reads test_header.bin" {
    const allocator = std.testing.allocator;
    const data = try loadFixture(allocator, "test_header.bin");
    defer allocator.free(data);

    // Fixture is 16 bytes: FORM + size(8) + TEST + 0xDEADBEEF
    try std.testing.expectEqual(@as(usize, 16), data.len);
}

test "expectBytes passes on matching data" {
    const a = [_]u8{ 0x46, 0x4F, 0x52, 0x4D };
    const b = [_]u8{ 0x46, 0x4F, 0x52, 0x4D };
    try expectBytes(&a, &b);
}

test "expectSlice passes on matching data" {
    const a = [_]u32{ 1, 2, 3 };
    const b = [_]u32{ 1, 2, 3 };
    try expectSlice(u32, &a, &b);
}

test "expectApproxEq passes for close values" {
    try expectApproxEq(3.14159, 3.14160, 0.001);
}

test "readU32BE reads big-endian from fixture" {
    const allocator = std.testing.allocator;
    const data = try loadFixture(allocator, "test_header.bin");
    defer allocator.free(data);

    // Bytes 0-3: "FORM" = 0x464F524D
    const magic = try readU32BE(data, 0);
    try std.testing.expectEqual(@as(u32, 0x464F524D), magic);

    // Bytes 4-7: size = 8
    const size = try readU32BE(data, 4);
    try std.testing.expectEqual(@as(u32, 8), size);

    // Bytes 8-11: "TEST" = 0x54455354
    const form_type = try readU32BE(data, 8);
    try std.testing.expectEqual(@as(u32, 0x54455354), form_type);

    // Bytes 12-15: 0xDEADBEEF
    const payload = try readU32BE(data, 12);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), payload);
}

test "readU16BE reads big-endian u16" {
    const data = [_]u8{ 0x00, 0x08, 0xFF, 0xFE };
    try std.testing.expectEqual(@as(u16, 8), try readU16BE(&data, 0));
    try std.testing.expectEqual(@as(u16, 0xFFFE), try readU16BE(&data, 2));
}
