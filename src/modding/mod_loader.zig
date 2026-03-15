//! Mod file loader with priority override system.
//! Checks mod directories for loose files before falling back to the TRE archive.
//! Mod files use the same directory structure as extracted TRE assets
//! (e.g., `mods/mymod/AIDS/ATTITUDE.IFF` overrides the TRE's `AIDS\ATTITUDE.IFF`).

const std = @import("std");
const tre = @import("../formats/tre.zig");
const extract = @import("../cli/extract.zig");

pub const ModLoaderError = error{
    FileNotFound,
    OutOfMemory,
    ReadError,
};

/// Result of a file load, indicating where the data came from.
pub const LoadSource = enum {
    mod,
    tre,
};

pub const LoadResult = struct {
    /// The file data (owned by the caller, must be freed with the allocator).
    data: []const u8,
    /// Where the data was loaded from.
    source: LoadSource,
};

pub const ModLoader = struct {
    allocator: std.mem.Allocator,
    /// Active mod directory path, or null if no mod is active.
    mod_dir: ?[]const u8,
    /// TRE archive data (the full PRIV.TRE contents).
    tre_data: []const u8,

    /// Initialize a ModLoader with an optional mod directory and TRE archive data.
    pub fn init(allocator: std.mem.Allocator, mod_dir: ?[]const u8, tre_data: []const u8) ModLoader {
        return .{
            .allocator = allocator,
            .mod_dir = mod_dir,
            .tre_data = tre_data,
        };
    }

    /// Load a file by its TRE filename (e.g., "ATTITUDE.IFF").
    /// Checks the mod directory first (if set), then falls back to the TRE archive.
    /// Returns owned data that the caller must free with the allocator.
    pub fn loadFile(self: *const ModLoader, filename: []const u8) !LoadResult {
        // Try mod directory first
        if (self.mod_dir) |mod_dir| {
            if (self.loadFromMod(mod_dir, filename)) |data| {
                return .{ .data = data, .source = .mod };
            } else |_| {}
        }

        // Fall back to TRE
        const data = try self.loadFromTre(filename);
        return .{ .data = data, .source = .tre };
    }

    /// Load a file by its full TRE path (e.g., "AIDS/ATTITUDE.IFF" or "AIDS\\ATTITUDE.IFF").
    /// The path is matched against mod files using forward slashes.
    /// Checks the mod directory first, then falls back to TRE.
    pub fn loadFilePath(self: *const ModLoader, tre_path: []const u8) !LoadResult {
        // Normalize the TRE path: strip DATA\ prefix and convert to forward slashes
        const normalized = extract.normalizeTrePath(tre_path) orelse return ModLoaderError.FileNotFound;

        // Try mod directory first
        if (self.mod_dir) |mod_dir| {
            if (self.loadFromModPath(mod_dir, normalized)) |data| {
                return .{ .data = data, .source = .mod };
            } else |_| {}
        }

        // Fall back to TRE by extracting the basename
        const basename = std.fs.path.basename(normalized);
        const data = try self.loadFromTre(basename);
        return .{ .data = data, .source = .tre };
    }

    /// Try to load a file from the mod directory by scanning for matching basename.
    fn loadFromMod(self: *const ModLoader, mod_dir: []const u8, filename: []const u8) ![]const u8 {
        // Search TRE entries to find the normalized path for this filename
        const header = try tre.readHeader(self.tre_data);
        for (0..header.entry_count) |i| {
            var entry = try tre.readEntry(self.allocator, self.tre_data, @intCast(i));
            defer entry.deinit();

            const basename = std.fs.path.basename(entry.path);
            if (std.ascii.eqlIgnoreCase(basename, filename)) {
                const normalized = extract.normalizeTrePath(entry.path) orelse continue;
                const fwd = try extract.toForwardSlashes(self.allocator, normalized);
                defer self.allocator.free(fwd);

                return self.readModFile(mod_dir, fwd);
            }
        }
        return ModLoaderError.FileNotFound;
    }

    /// Try to load a file from the mod directory by its normalized relative path.
    fn loadFromModPath(self: *const ModLoader, mod_dir: []const u8, rel_path: []const u8) ![]const u8 {
        const fwd = try extract.toForwardSlashes(self.allocator, rel_path);
        defer self.allocator.free(fwd);
        return self.readModFile(mod_dir, fwd);
    }

    /// Read a file from the mod directory at the given relative path.
    fn readModFile(self: *const ModLoader, mod_dir: []const u8, rel_path: []const u8) ![]const u8 {
        const full_path = try std.fs.path.join(self.allocator, &.{ mod_dir, rel_path });
        defer self.allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch return ModLoaderError.FileNotFound;
        defer file.close();

        const stat = try file.stat();
        const buf = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(buf);
        const bytes_read = try file.readAll(buf);
        if (bytes_read != stat.size) {
            self.allocator.free(buf);
            return ModLoaderError.ReadError;
        }
        return buf;
    }

    /// Load a file from the TRE archive by filename.
    fn loadFromTre(self: *const ModLoader, filename: []const u8) ![]const u8 {
        var entry = tre.findEntry(self.allocator, self.tre_data, filename) catch return ModLoaderError.FileNotFound;
        defer entry.deinit();

        const file_data = tre.extractFileData(self.tre_data, entry.offset, entry.size) catch return ModLoaderError.ReadError;
        // Return a copy that the caller owns
        return self.allocator.dupe(u8, file_data);
    }
};

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "loadFile returns data from TRE when no mod dir" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    const loader = ModLoader.init(allocator, null, tre_data);
    const result = try loader.loadFile("ATTITUDE.IFF");
    defer allocator.free(result.data);

    try std.testing.expectEqual(LoadSource.tre, result.source);
    try std.testing.expectEqualStrings("FORM", result.data[0..4]);
    try std.testing.expectEqual(@as(usize, 16), result.data.len);
}

test "loadFile returns data from TRE when mod dir has no matching file" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    // Use a non-existent mod directory
    const loader = ModLoader.init(allocator, "tests/fixtures/nonexistent_mod_dir", tre_data);
    const result = try loader.loadFile("ATTITUDE.IFF");
    defer allocator.free(result.data);

    try std.testing.expectEqual(LoadSource.tre, result.source);
    try std.testing.expectEqualStrings("FORM", result.data[0..4]);
}

test "loadFile returns mod file when it exists in mod dir" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    // Create a temporary mod directory with an override file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // The TRE path for ATTITUDE.IFF is ..\..\DATA\AIDS\ATTITUDE.IFF
    // Normalized: AIDS/ATTITUDE.IFF
    try tmp_dir.dir.makePath("AIDS");
    const mod_data = "MODDED_ATTITUDE_DATA";
    {
        const file = try tmp_dir.dir.createFile("AIDS/ATTITUDE.IFF", .{});
        defer file.close();
        try file.writeAll(mod_data);
    }

    // Get the absolute path of the tmp directory
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const loader = ModLoader.init(allocator, tmp_path, tre_data);
    const result = try loader.loadFile("ATTITUDE.IFF");
    defer allocator.free(result.data);

    try std.testing.expectEqual(LoadSource.mod, result.source);
    try std.testing.expectEqualStrings(mod_data, result.data);
}

test "loadFile falls back to TRE when mod dir exists but file is not overridden" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    // Create an empty temp mod dir (no override files)
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const loader = ModLoader.init(allocator, tmp_path, tre_data);
    const result = try loader.loadFile("ATTITUDE.IFF");
    defer allocator.free(result.data);

    try std.testing.expectEqual(LoadSource.tre, result.source);
    try std.testing.expectEqualStrings("FORM", result.data[0..4]);
}

test "loadFile returns FileNotFound for unknown file" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    const loader = ModLoader.init(allocator, null, tre_data);
    const result = loader.loadFile("NONEXISTENT.IFF");
    try std.testing.expectError(ModLoaderError.FileNotFound, result);
}

test "loadFilePath loads by normalized TRE path" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    const loader = ModLoader.init(allocator, null, tre_data);
    const result = try loader.loadFilePath("..\\..\\DATA\\AIDS\\ATTITUDE.IFF");
    defer allocator.free(result.data);

    try std.testing.expectEqual(LoadSource.tre, result.source);
    try std.testing.expectEqualStrings("FORM", result.data[0..4]);
}

test "loadFilePath prefers mod override by path" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("AIDS");
    const mod_data = "PATH_OVERRIDE_DATA";
    {
        const file = try tmp_dir.dir.createFile("AIDS/ATTITUDE.IFF", .{});
        defer file.close();
        try file.writeAll(mod_data);
    }

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const loader = ModLoader.init(allocator, tmp_path, tre_data);
    const result = try loader.loadFilePath("..\\..\\DATA\\AIDS\\ATTITUDE.IFF");
    defer allocator.free(result.data);

    try std.testing.expectEqual(LoadSource.mod, result.source);
    try std.testing.expectEqualStrings(mod_data, result.data);
}

test "loadFile is case-insensitive on filename" {
    const allocator = std.testing.allocator;
    const tre_data = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_data);

    const loader = ModLoader.init(allocator, null, tre_data);

    // Test lowercase lookup
    const result = try loader.loadFile("attitude.iff");
    defer allocator.free(result.data);

    try std.testing.expectEqual(LoadSource.tre, result.source);
    try std.testing.expectEqualStrings("FORM", result.data[0..4]);
}
