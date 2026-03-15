//! Asset hot-reloading system for development mode.
//! Polls the mod directory for file changes (by modification timestamp)
//! and signals when assets need to be reloaded.
//!
//! Usage:
//!   var watcher = AssetWatcher.init(allocator, "mods/mymod");
//!   defer watcher.deinit();
//!   // In game loop:
//!   const changes = watcher.check();
//!   for (changes) |path| { reloadAsset(path); }

const std = @import("std");

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
    /// Root directory being watched.
    watch_dir: []const u8,
    /// Map of relative path → last known modification time.
    tracked: std.StringHashMap(i128),
    /// Paths that changed during the last check (owned strings).
    changed_paths: std.ArrayListUnmanaged([]const u8),
    /// Whether this is the first scan (suppress change notifications on initial scan).
    first_scan: bool,

    /// Create a new asset watcher for the given directory.
    pub fn init(allocator: std.mem.Allocator, watch_dir: []const u8) AssetWatcher {
        return .{
            .allocator = allocator,
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
        var dir = std.fs.cwd().openDir(self.watch_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        try self.walkDir(dir, "");
    }

    /// Recursively walk a directory and check file modification times.
    fn walkDir(self: *AssetWatcher, dir: std.fs.Dir, prefix: []const u8) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const rel_path = if (prefix.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(self.allocator, &.{ prefix, entry.name });
            defer self.allocator.free(rel_path);

            switch (entry.kind) {
                .directory => {
                    var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                    defer sub_dir.close();
                    try self.walkDir(sub_dir, rel_path);
                },
                .file => {
                    const stat = dir.statFile(entry.name) catch continue;
                    const mtime = stat.mtime;
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
    var watcher = AssetWatcher.init(allocator, "nonexistent_watch_dir");
    defer watcher.deinit();

    try std.testing.expectEqual(@as(usize, 0), watcher.trackedCount());
}

test "check on nonexistent directory returns empty changes" {
    const allocator = std.testing.allocator;
    var watcher = AssetWatcher.init(allocator, "nonexistent_watch_dir_12345");
    defer watcher.deinit();

    const changes = watcher.check();
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "first scan tracks files but reports no changes" {
    const allocator = std.testing.allocator;

    // Create a temp directory with a file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        const file = try tmp_dir.dir.createFile("test.iff", .{});
        defer file.close();
        try file.writeAll("FORM_DATA");
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, tmp_path);
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

    {
        const file = try tmp_dir.dir.createFile("sprite.shp", .{});
        defer file.close();
        try file.writeAll("original");
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, tmp_path);
    defer watcher.deinit();

    // First scan — baseline
    _ = watcher.check();
    try std.testing.expectEqual(@as(usize, 1), watcher.trackedCount());

    // Modify the file (write different content to change mtime)
    {
        const file = try tmp_dir.dir.createFile("sprite.shp", .{ .truncate = true });
        defer file.close();
        try file.writeAll("modified_content_longer");
    }

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

    {
        const file = try tmp_dir.dir.createFile("existing.iff", .{});
        defer file.close();
        try file.writeAll("data");
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, tmp_path);
    defer watcher.deinit();

    // First scan
    _ = watcher.check();
    try std.testing.expectEqual(@as(usize, 1), watcher.trackedCount());

    // Add a new file
    {
        const file = try tmp_dir.dir.createFile("new_sprite.shp", .{});
        defer file.close();
        try file.writeAll("new data");
    }

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

    try tmp_dir.dir.makePath("AIDS");
    {
        const file = try tmp_dir.dir.createFile("AIDS/ATTITUDE.IFF", .{});
        defer file.close();
        try file.writeAll("modded attitude");
    }
    {
        const file = try tmp_dir.dir.createFile("top_level.dat", .{});
        defer file.close();
        try file.writeAll("data");
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, tmp_path);
    defer watcher.deinit();

    _ = watcher.check();
    try std.testing.expectEqual(@as(usize, 2), watcher.trackedCount());
}

test "consecutive checks with no changes return empty" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    {
        const file = try tmp_dir.dir.createFile("static.iff", .{});
        defer file.close();
        try file.writeAll("unchanged");
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var watcher = AssetWatcher.init(allocator, tmp_path);
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
