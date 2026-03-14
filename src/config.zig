//! Configuration system for Privateer.
//! Loads paths and settings from a JSON config file with command-line overrides.

const std = @import("std");

pub const Config = struct {
    /// Path to the original game data directory (containing GAME.DAT or PRIV.TRE).
    data_dir: []const u8,
    /// Path to the mod directory for file overrides.
    mod_dir: []const u8,
    /// Path to the output directory for saves and extracted assets.
    output_dir: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.data_dir);
        self.allocator.free(self.mod_dir);
        self.allocator.free(self.output_dir);
    }
};

/// Default config values.
const defaults = .{
    .data_dir = "data",
    .mod_dir = "mods",
    .output_dir = "output",
};

/// Load configuration from a JSON file. Returns error if file exists but is malformed.
/// If file doesn't exist, returns defaults.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return Config{
                .data_dir = try allocator.dupe(u8, defaults.data_dir),
                .mod_dir = try allocator.dupe(u8, defaults.mod_dir),
                .output_dir = try allocator.dupe(u8, defaults.output_dir),
                .allocator = allocator,
            };
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 1024 * 1024) return error.ConfigTooLarge;
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    const bytes_read = try file.readAll(content);
    if (bytes_read != stat.size) return error.IncompleteRead;

    return parseJson(allocator, content[0..bytes_read]);
}

/// Parse a JSON string into a Config.
pub fn parseJson(allocator: std.mem.Allocator, json_str: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidConfig;

    const data_dir = if (root.object.get("data_dir")) |v| blk: {
        if (v != .string) return error.InvalidConfig;
        break :blk try allocator.dupe(u8, v.string);
    } else try allocator.dupe(u8, defaults.data_dir);

    const mod_dir = if (root.object.get("mod_dir")) |v| blk: {
        if (v != .string) return error.InvalidConfig;
        break :blk try allocator.dupe(u8, v.string);
    } else try allocator.dupe(u8, defaults.mod_dir);

    const output_dir = if (root.object.get("output_dir")) |v| blk: {
        if (v != .string) return error.InvalidConfig;
        break :blk try allocator.dupe(u8, v.string);
    } else try allocator.dupe(u8, defaults.output_dir);

    return Config{
        .data_dir = data_dir,
        .mod_dir = mod_dir,
        .output_dir = output_dir,
        .allocator = allocator,
    };
}

/// Apply command-line overrides to an existing config.
/// Recognized flags: --data-dir, --mod-dir, --output-dir
pub fn applyArgs(config: *Config, args: []const []const u8) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (i + 1 >= args.len) break;
        const flag = args[i];
        const value = args[i + 1];

        if (std.mem.eql(u8, flag, "--data-dir")) {
            config.allocator.free(config.data_dir);
            config.data_dir = try config.allocator.dupe(u8, value);
            i += 1;
        } else if (std.mem.eql(u8, flag, "--mod-dir")) {
            config.allocator.free(config.mod_dir);
            config.mod_dir = try config.allocator.dupe(u8, value);
            i += 1;
        } else if (std.mem.eql(u8, flag, "--output-dir")) {
            config.allocator.free(config.output_dir);
            config.output_dir = try config.allocator.dupe(u8, value);
            i += 1;
        }
    }
}

// --- Tests ---

test "parseJson loads all fields from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "data_dir": "/games/privateer",
        \\  "mod_dir": "/games/privateer/mods",
        \\  "output_dir": "/tmp/privateer-out"
        \\}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("/games/privateer", cfg.data_dir);
    try std.testing.expectEqualStrings("/games/privateer/mods", cfg.mod_dir);
    try std.testing.expectEqualStrings("/tmp/privateer-out", cfg.output_dir);
}

test "parseJson uses defaults for missing fields" {
    const allocator = std.testing.allocator;
    const json = "{}";
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("data", cfg.data_dir);
    try std.testing.expectEqualStrings("mods", cfg.mod_dir);
    try std.testing.expectEqualStrings("output", cfg.output_dir);
}

test "parseJson with partial fields uses defaults for rest" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data_dir": "C:\\WC\\PRIV"}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("C:\\WC\\PRIV", cfg.data_dir);
    try std.testing.expectEqualStrings("mods", cfg.mod_dir);
    try std.testing.expectEqualStrings("output", cfg.output_dir);
}

test "load returns defaults when config file missing" {
    const allocator = std.testing.allocator;
    var cfg = try load(allocator, "nonexistent_privateer_config.json");
    defer cfg.deinit();

    try std.testing.expectEqualStrings("data", cfg.data_dir);
    try std.testing.expectEqualStrings("mods", cfg.mod_dir);
    try std.testing.expectEqualStrings("output", cfg.output_dir);
}

test "applyArgs overrides config values" {
    const allocator = std.testing.allocator;
    var cfg = try parseJson(allocator, "{}");
    defer cfg.deinit();

    const args = [_][]const u8{
        "--data-dir",  "D:\\GAMES\\PRIV",
        "--output-dir", "D:\\SAVES",
    };
    try applyArgs(&cfg, &args);

    try std.testing.expectEqualStrings("D:\\GAMES\\PRIV", cfg.data_dir);
    try std.testing.expectEqualStrings("mods", cfg.mod_dir); // unchanged
    try std.testing.expectEqualStrings("D:\\SAVES", cfg.output_dir);
}

test "parseJson rejects non-object root" {
    const allocator = std.testing.allocator;
    const result = parseJson(allocator, "\"just a string\"");
    try std.testing.expectError(error.InvalidConfig, result);
}

test "parseJson rejects non-string field value" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data_dir": 42}
    ;
    const result = parseJson(allocator, json);
    try std.testing.expectError(error.InvalidConfig, result);
}
