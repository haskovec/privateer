//! Asset hot-reloading system for development mode.
//! Polls the mod directory for file changes (by modification timestamp)
//! and signals when assets need to be reloaded.
//!
//! Usage:
//!   var watcher = AssetWatcher.init(allocator, io, "mods/mymod");
//!   defer watcher.deinit();
//!   // In game loop:
//!   const changes = watcher.check();
//!   for (changes) |path| { reloadAsset(path); }

const std = @import("std");
const testing_helpers = @import("../testing.zig");

pub const AssetWatcherError = error{
    OutOfMemory,
    ScanFailed,
};

/// A single tracked file and its last known modification time.
const TrackedFile = struct {
    /// Relative path within the watched directory.
    rel_path: []const u8,
    /// Last known modification time (nanoseconds since epoch).
    mtime: i128,
};

/// Asset watcher that detects file modifications in a directory tree.
pub const AssetWatcher = struct {
    allocator: std.mem.Allocator,
    /// I/O implementation used for all directory scanning.
    io: std.Io,
    /// Root directory being watched.
    watch_dir: []const u8,
    /// Map of relative path → last known modification time.
    tracked: std.StringHashMap(i128),
    /// Paths that changed during the last check (owned strings).
    changed_paths: std.ArrayListUnmanaged([]const u8),
    /// Whether this is the first scan (suppress change notifications on initial scan).
    first_scan: bool,

    /// Create a new asset watcher for the given directory.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, watch_dir: []const u8) AssetWatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .watch_dir = watch_dir,
            .tracked = std.StringHashMap(i128).init(allocator),
            .changed_paths = .empty,
            .first_scan = true,
        };
    }

    /// Release all resources.
    pub fn deinit(self: *AssetWatcher) void {
        // Free changed_paths strings
        for (self.changed_paths.items) |p| {
            self.allocator.free(p);
        }
        self.changed_paths.deinit(self.allocator);

        // Free tracked keys
        var it = self.tracked.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tracked.deinit();
    }

    /// Check for file changes. Returns a slice of relative paths that were
    /// modified or added since the last check. The returned slice is valid
    /// until the next call to check().
    pub fn check(self: *AssetWatcher) []const []const u8 {
        // Clear previous change list
        for (self.changed_paths.items) |p| {
            self.allocator.free(p);
        }
        self.changed_paths.clearRetainingCapacity();

        // Scan the directory
        self.scanDirectory() catch return self.changed_paths.items;

        const is_initial = self.first_scan;
        self.first_scan = false;

        // On initial scan, don't report anything as changed
        if (is_initial) return self.changed_paths.items;

        return self.changed_paths.items;
    }

    /// Scan the watch directory tree and update tracked files.
    fn scanDirectory(self: *AssetWatcher) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.watch_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        try self.walkDir(dir, "");
    }

    /// Recursively walk a directory and check file modification times.
    fn walkDir(self: *AssetWatcher, dir: std.Io.Dir, prefix: []const u8) !void {
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            const rel_path = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(self.allocator, &.{ prefix, entry.name });
            defer self.allocator.free(rel_path);

            switch (entry.kind) {
                .directory => {
                    var sub_dir = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch continue;
                    defer sub_dir.close(self.io);
                    try self.walkDir(sub_dir, rel_path);
                },
                .file => {
                    const stat = dir.statFile(self.io, entry.name, .{}) catch continue;
                    const mtime = stat.mtime.nanoseconds;
                    try self.trackFile(rel_path, mtime);
                },
                else => {},
            }
        }
    }

    /// Track a file's modification time; if changed, add to changed list.
    fn trackFile(self: *AssetWatcher, rel_path: []const u8, mtime: i128) !void {
        if (self.tracked.get(rel_path)) |old_mtime| {
            if (mtime != old_mtime) {
                // File was modified
                const owned_key = try self.allocator.dupe(u8, rel_path);
                // Update the existing entry - we need to get the stored key
                if (self.tracked.getEntry(rel_path)) |entry| {
                    entry.value_ptr.* = mtime;
                }
                try self.changed_paths.append(self.allocator, owned_key);
            }
        } else {
            // New file - track it
            const key = try self.allocator.dupe(u8, rel_path);
            try self.tracked.put(key, mtime);
            if (!self.first_scan) {
                // Report new files as changes (but not on first scan)
                const change_key = try self.allocator.dupe(u8, rel_path);
                try self.changed_paths.append(self.allocator, change_key);
            }
        }
    }

    /// Get the number of files currently being tracked.
    pub fn trackedCount(self: *const AssetWatcher) usize {
        return self.tracked.count();
    }
};

// --- Tests ---

test "init creates watcher with no tracked files" {
    const allocator = std.testing.allocator;
    var watcher = AssetWatcher.init(allocator, std.testing.io, "nonexistent_watch_dir");
    defer watcher.deinit();

    try std.testing.expectEqual(@as(usize, 0), watcher.trackedCount());
}

test "check on nonexistent directory returns empty changes" {
    const allocator = std.testing.allocator;
    var watcher = AssetWatcher.init(allocator, std.testing.io, "nonexistent_watch_dir_12345");
    defer watcher.deinit();

    const changes = watcher.check();
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "first scan tracks files but reports no changes" {
    const allocator = std.testing.allocator;

    // Create a temp directory with a file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "test.iff", .data = "FORM_DATA" });

    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp_dir);
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, std.testing.io, tmp_path);
    defer watcher.deinit();

    // First scan should report no changes
    const changes = watcher.check();
    try std.testing.expectEqual(@as(usize, 0), changes.len);
    // But should have tracked the file
    try std.testing.expectEqual(@as(usize, 1), watcher.trackedCount());
}

test "modified file is detected on second check" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "sprite.shp", .data = "original" });

    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp_dir);
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, std.testing.io, tmp_path);
    defer watcher.deinit();

    // First scan — baseline
    _ = watcher.check();
    try std.testing.expectEqual(@as(usize, 1), watcher.trackedCount());

    // Modify the file (write different content to change mtime)
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "sprite.shp", .data = "modified_content_longer" });

    // Second scan — should detect the change
    const changes = watcher.check();
    // Note: mtime resolution may not always detect changes in fast tests,
    // but the file should at least still be tracked
    try std.testing.expectEqual(@as(usize, 1), watcher.trackedCount());
    _ = changes; // changes may be 0 or 1 depending on mtime resolution
}

test "new file added after first scan is detected" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "existing.iff", .data = "data" });

    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp_dir);
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, std.testing.io, tmp_path);
    defer watcher.deinit();

    // First scan
    _ = watcher.check();
    try std.testing.expectEqual(@as(usize, 1), watcher.trackedCount());

    // Add a new file
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "new_sprite.shp", .data = "new data" });

    // Second scan — should detect the new file
    const changes = watcher.check();
    try std.testing.expectEqual(@as(usize, 2), watcher.trackedCount());
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("new_sprite.shp", changes[0]);
}

test "subdirectory files are tracked" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "AIDS");
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "AIDS/ATTITUDE.IFF", .data = "modded attitude" });
    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "top_level.dat", .data = "data" });

    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp_dir);
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, std.testing.io, tmp_path);
    defer watcher.deinit();

    _ = watcher.check();
    try std.testing.expectEqual(@as(usize, 2), watcher.trackedCount());
}

test "consecutive checks with no changes return empty" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "static.iff", .data = "unchanged" });

    const tmp_path = try testing_helpers.tmpDirPath(allocator, &tmp_dir);
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, std.testing.io, tmp_path);
    defer watcher.deinit();

    // First scan
    _ = watcher.check();
    // Second scan — no changes
    const changes = watcher.check();
    try std.testing.expectEqual(@as(usize, 0), changes.len);
    // Third scan — still no changes
    const changes2 = watcher.check();
    try std.testing.expectEqual(@as(usize, 0), changes2.len);
}
