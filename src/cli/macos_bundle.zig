const std = @import("std");
const testing_helpers = @import("../testing.zig");

/// Validates that a macOS .app bundle has the required structure.
/// Returns an error description on failure, or null on success.
pub fn validateBundle(io: std.Io, allocator: std.mem.Allocator, bundle_path: []const u8) !?[]const u8 {
    const cwd: std.Io.Dir = .cwd();

    // Check bundle directory exists
    cwd.access(io, bundle_path, .{}) catch {
        return try std.fmt.allocPrint(allocator, "Bundle directory does not exist: {s}", .{bundle_path});
    };

    // Check Contents/
    const contents_path = try std.fs.path.join(allocator, &.{ bundle_path, "Contents" });
    defer allocator.free(contents_path);
    cwd.access(io, contents_path, .{}) catch {
        return try std.fmt.allocPrint(allocator, "Missing Contents directory in bundle", .{});
    };

    // Check Contents/MacOS/
    const macos_path = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "MacOS" });
    defer allocator.free(macos_path);
    cwd.access(io, macos_path, .{}) catch {
        return try std.fmt.allocPrint(allocator, "Missing Contents/MacOS directory in bundle", .{});
    };

    // Check Contents/Resources/
    const resources_path = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "Resources" });
    defer allocator.free(resources_path);
    cwd.access(io, resources_path, .{}) catch {
        return try std.fmt.allocPrint(allocator, "Missing Contents/Resources directory in bundle", .{});
    };

    // Check Contents/Info.plist
    const plist_path = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "Info.plist" });
    defer allocator.free(plist_path);
    const plist_data = cwd.readFileAlloc(io, plist_path, allocator, .limited(64 * 1024 + 1)) catch {
        return try std.fmt.allocPrint(allocator, "Missing Contents/Info.plist in bundle", .{});
    };
    defer allocator.free(plist_data);

    const required_keys = [_][]const u8{
        "CFBundleExecutable",
        "CFBundleIdentifier",
        "CFBundleName",
        "CFBundlePackageType",
    };

    for (required_keys) |key| {
        if (std.mem.indexOf(u8, plist_data, key) == null) {
            return try std.fmt.allocPrint(allocator, "Info.plist missing required key: {s}", .{key});
        }
    }

    // Check executable exists
    const exe_path = try std.fs.path.join(allocator, &.{ bundle_path, "Contents", "MacOS", "privateer" });
    defer allocator.free(exe_path);
    cwd.access(io, exe_path, .{}) catch {
        return try std.fmt.allocPrint(allocator, "Missing executable: Contents/MacOS/privateer", .{});
    };

    return null; // Valid bundle
}

/// Returns the expected bundle structure as a list of relative paths.
pub fn expectedPaths() []const []const u8 {
    return &.{
        "Contents",
        "Contents/Info.plist",
        "Contents/MacOS",
        "Contents/MacOS/privateer",
        "Contents/Resources",
    };
}

// --- Tests ---

test "validateBundle rejects missing bundle" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = try validateBundle(std.testing.io, allocator, "/tmp/nonexistent_test_bundle.app");
    try std.testing.expect(result != null);
    allocator.free(result.?);
}

test "validateBundle accepts valid bundle structure" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a temporary valid bundle
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create bundle structure
    try tmp.dir.createDirPath(std.testing.io, "Contents/MacOS");
    try tmp.dir.createDirPath(std.testing.io, "Contents/Resources");

    // Write Info.plist
    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key>
        \\  <string>privateer</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>com.privateer.game</string>
        \\  <key>CFBundleName</key>
        \\  <string>Privateer</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\</dict>
        \\</plist>
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Contents/Info.plist", .data = plist });

    // Write a dummy executable
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Contents/MacOS/privateer", .data = "#!/bin/sh\necho hello\n" });

    // Get absolute path to tmp dir
    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp);
    defer allocator.free(tmp_path);

    const result = try validateBundle(std.testing.io, allocator, tmp_path);
    if (result) |msg| {
        std.debug.print("Unexpected validation error: {s}\n", .{msg});
        allocator.free(msg);
    }
    try std.testing.expect(result == null);
}

test "validateBundle rejects bundle missing Info.plist" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create structure without Info.plist
    try tmp.dir.createDirPath(std.testing.io, "Contents/MacOS");
    try tmp.dir.createDirPath(std.testing.io, "Contents/Resources");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Contents/MacOS/privateer", .data = "" });

    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp);
    defer allocator.free(tmp_path);

    const result = try validateBundle(std.testing.io, allocator, tmp_path);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "Info.plist") != null);
    allocator.free(result.?);
}

test "validateBundle rejects bundle missing executable" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Contents/MacOS");
    try tmp.dir.createDirPath(std.testing.io, "Contents/Resources");

    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key>
        \\  <string>privateer</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>com.privateer.game</string>
        \\  <key>CFBundleName</key>
        \\  <string>Privateer</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\</dict>
        \\</plist>
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Contents/Info.plist", .data = plist });

    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp);
    defer allocator.free(tmp_path);

    const result = try validateBundle(std.testing.io, allocator, tmp_path);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "executable") != null);
    allocator.free(result.?);
}

test "expectedPaths returns correct bundle structure" {
    const paths = expectedPaths();
    try std.testing.expectEqual(@as(usize, 5), paths.len);
    try std.testing.expectEqualStrings("Contents", paths[0]);
    try std.testing.expectEqualStrings("Contents/Info.plist", paths[1]);
    try std.testing.expectEqualStrings("Contents/MacOS", paths[2]);
    try std.testing.expectEqualStrings("Contents/MacOS/privateer", paths[3]);
    try std.testing.expectEqualStrings("Contents/Resources", paths[4]);
}
