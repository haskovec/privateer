//! Unified configuration system for Privateer.
//! Loads paths and user settings from a single `privateer.json` file.
//! Supports CLI arg overrides and the PRIVATEER_DATA environment variable.
//!
//! Precedence (highest to lowest):
//!   1. CLI arguments (--data-dir, --mod-dir, --output-dir)
//!   2. PRIVATEER_DATA environment variable (overrides data_dir only)
//!   3. privateer.json config file
//!   4. Built-in defaults

const std = @import("std");
const viewport = @import("render/viewport.zig");
const upscale_mod = @import("render/upscale.zig");
const window_mod = @import("render/window.zig");
const joystick_mod = @import("input/joystick.zig");

/// Config file name.
pub const CONFIG_FILE = "privateer.json";

/// User-configurable settings (graphics, audio, input).
/// Kept flat for simplicity — the JSON file uses nested sections but the
/// struct is flat so consumers don't need deep field paths.
pub const Settings = struct {
    // Graphics
    scale_factor: upscale_mod.ScaleFactor,
    fullscreen: bool,
    viewport_mode: viewport.Mode,

    // Audio (0.0 = mute, 1.0 = full volume)
    sfx_volume: f32,
    music_volume: f32,

    // Input
    joystick_deadzone: f32,

    pub fn defaults() Settings {
        return .{
            .scale_factor = .x4,
            .fullscreen = false,
            .viewport_mode = .fit_4_3,
            .sfx_volume = 1.0,
            .music_volume = 0.7,
            .joystick_deadzone = joystick_mod.DEFAULT_DEADZONE,
        };
    }

    pub fn windowWidth(self: Settings) u32 {
        return window_mod.BASE_WIDTH * self.scale_factor.multiplier();
    }

    pub fn windowHeight(self: Settings) u32 {
        return window_mod.BASE_HEIGHT * self.scale_factor.multiplier();
    }

    /// Clamp volume and deadzone values to valid range [0.0, 1.0].
    pub fn sanitize(self: *Settings) void {
        self.sfx_volume = std.math.clamp(self.sfx_volume, 0.0, 1.0);
        self.music_volume = std.math.clamp(self.music_volume, 0.0, 1.0);
        self.joystick_deadzone = std.math.clamp(self.joystick_deadzone, 0.0, 1.0);
    }
};

/// Default path values.
const path_defaults = .{
    .data_dir = "data",
    .mod_dir = "mods",
    .output_dir = "output",
};

/// On macOS, detect if running inside a .app bundle and resolve the
/// Resources directory path.  Returns null when not in a bundle.
pub fn detectBundleResourcesDir(allocator: std.mem.Allocator) ?[]const u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return null;

    // The executable lives at Privateer.app/Contents/MacOS/privateer.
    // We need Privateer.app/Contents/Resources.
    const self_exe = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(self_exe);

    // Walk up: strip "privateer" -> Contents/MacOS, strip "MacOS" -> Contents
    const macos_dir = std.fs.path.dirname(self_exe) orelse return null;
    const contents_dir = std.fs.path.dirname(macos_dir) orelse return null;

    // Verify we're actually inside a bundle by checking the parent is *.app
    const app_dir = std.fs.path.dirname(contents_dir) orelse return null;
    const app_basename = std.fs.path.basename(app_dir);
    if (!std.mem.endsWith(u8, app_basename, ".app")) return null;

    const resources = std.fs.path.join(allocator, &.{ contents_dir, "Resources" }) catch return null;
    return resources;
}

/// Resolve data_dir for macOS bundles: if the default "data" path doesn't
/// exist but the bundle's Resources/data does, use the bundle path instead.
pub fn applyBundleOverride(config: *Config) void {
    // Only override if data_dir is still the default
    if (!std.mem.eql(u8, config.data_dir, path_defaults.data_dir)) return;

    // Check if default data dir exists
    std.fs.cwd().access(config.data_dir, .{}) catch {
        // Default doesn't exist — try bundle Resources
        const resources_dir = detectBundleResourcesDir(config.allocator) orelse return;
        defer config.allocator.free(resources_dir);

        const bundle_data = std.fs.path.join(config.allocator, &.{ resources_dir, "data" }) catch return;

        std.fs.cwd().access(bundle_data, .{}) catch {
            config.allocator.free(bundle_data);
            return;
        };

        config.allocator.free(config.data_dir);
        config.data_dir = bundle_data;
    };
}

/// Full application configuration: paths + user settings.
pub const Config = struct {
    /// Path to the directory containing GAME.DAT.
    data_dir: []const u8,
    /// Path to the mod directory for file overrides.
    mod_dir: []const u8,
    /// Path to the output directory for saves and extracted assets.
    output_dir: []const u8,
    /// User-configurable settings.
    settings: Settings,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.data_dir);
        self.allocator.free(self.mod_dir);
        self.allocator.free(self.output_dir);
    }
};

/// Load configuration from a JSON file. Returns defaults if file doesn't exist.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return Config{
                .data_dir = try allocator.dupe(u8, path_defaults.data_dir),
                .mod_dir = try allocator.dupe(u8, path_defaults.mod_dir),
                .output_dir = try allocator.dupe(u8, path_defaults.output_dir),
                .settings = Settings.defaults(),
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

    // Parse path fields
    const data_dir = if (root.object.get("data_dir")) |v| blk: {
        if (v != .string) return error.InvalidConfig;
        break :blk try allocator.dupe(u8, v.string);
    } else try allocator.dupe(u8, path_defaults.data_dir);

    const mod_dir = if (root.object.get("mod_dir")) |v| blk: {
        if (v != .string) return error.InvalidConfig;
        break :blk try allocator.dupe(u8, v.string);
    } else try allocator.dupe(u8, path_defaults.mod_dir);

    const output_dir = if (root.object.get("output_dir")) |v| blk: {
        if (v != .string) return error.InvalidConfig;
        break :blk try allocator.dupe(u8, v.string);
    } else try allocator.dupe(u8, path_defaults.output_dir);

    // Parse settings from nested sections
    var settings = Settings.defaults();

    if (root.object.get("graphics")) |g| {
        if (g == .object) {
            if (g.object.get("scale_factor")) |v| {
                if (v == .integer) {
                    const val: u8 = @intCast(std.math.clamp(v.integer, 2, 4));
                    settings.scale_factor = switch (val) {
                        2 => .x2,
                        3 => .x3,
                        else => .x4,
                    };
                }
            }
            if (g.object.get("fullscreen")) |v| {
                if (v == .bool) settings.fullscreen = v.bool;
            }
            if (g.object.get("viewport_mode")) |v| {
                if (v == .string) {
                    if (std.mem.eql(u8, v.string, "fill")) {
                        settings.viewport_mode = .fill;
                    } else if (std.mem.eql(u8, v.string, "fit_4_3")) {
                        settings.viewport_mode = .fit_4_3;
                    }
                }
            }
        }
    }

    if (root.object.get("audio")) |a| {
        if (a == .object) {
            if (a.object.get("sfx_volume")) |v| {
                if (v == .float) settings.sfx_volume = @floatCast(v.float);
                if (v == .integer) settings.sfx_volume = @floatFromInt(v.integer);
            }
            if (a.object.get("music_volume")) |v| {
                if (v == .float) settings.music_volume = @floatCast(v.float);
                if (v == .integer) settings.music_volume = @floatFromInt(v.integer);
            }
        }
    }

    if (root.object.get("input")) |i| {
        if (i == .object) {
            if (i.object.get("joystick_deadzone")) |v| {
                if (v == .float) settings.joystick_deadzone = @floatCast(v.float);
                if (v == .integer) settings.joystick_deadzone = @floatFromInt(v.integer);
            }
        }
    }

    settings.sanitize();

    return Config{
        .data_dir = data_dir,
        .mod_dir = mod_dir,
        .output_dir = output_dir,
        .settings = settings,
        .allocator = allocator,
    };
}

/// Serialize a Config to a JSON string.
/// Caller owns the returned slice.
pub fn toJson(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try buf.appendSlice(allocator, "{\n");
    try std.fmt.format(w, "  \"data_dir\": \"{s}\",\n", .{cfg.data_dir});
    try std.fmt.format(w, "  \"mod_dir\": \"{s}\",\n", .{cfg.mod_dir});
    try std.fmt.format(w, "  \"output_dir\": \"{s}\",\n", .{cfg.output_dir});

    // Graphics section
    try buf.appendSlice(allocator, "  \"graphics\": {\n");
    try std.fmt.format(w, "    \"scale_factor\": {d},\n", .{cfg.settings.scale_factor.multiplier()});
    try std.fmt.format(w, "    \"fullscreen\": {s},\n", .{if (cfg.settings.fullscreen) "true" else "false"});
    try std.fmt.format(w, "    \"viewport_mode\": \"{s}\"\n", .{switch (cfg.settings.viewport_mode) {
        .fill => "fill",
        .fit_4_3 => "fit_4_3",
    }});
    try buf.appendSlice(allocator, "  },\n");

    // Audio section
    try buf.appendSlice(allocator, "  \"audio\": {\n");
    try std.fmt.format(w, "    \"sfx_volume\": {d:.2},\n", .{cfg.settings.sfx_volume});
    try std.fmt.format(w, "    \"music_volume\": {d:.2}\n", .{cfg.settings.music_volume});
    try buf.appendSlice(allocator, "  },\n");

    // Input section
    try buf.appendSlice(allocator, "  \"input\": {\n");
    try std.fmt.format(w, "    \"joystick_deadzone\": {d:.2}\n", .{cfg.settings.joystick_deadzone});
    try buf.appendSlice(allocator, "  }\n");

    try buf.appendSlice(allocator, "}");

    return buf.toOwnedSlice(allocator);
}

/// Save configuration to a file.
pub fn save(allocator: std.mem.Allocator, cfg: Config, path: []const u8) !void {
    const json = try toJson(allocator, cfg);
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(json);
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

/// Apply PRIVATEER_DATA environment variable override to data_dir.
/// Env var takes precedence over the config file value but not CLI args.
pub fn applyEnvOverride(config: *Config) !void {
    const env_val = std.process.getEnvVarOwned(config.allocator, "PRIVATEER_DATA") catch |err| {
        if (err == error.EnvironmentVariableNotFound) return;
        return err;
    };
    config.allocator.free(config.data_dir);
    config.data_dir = env_val;
}

// --- Tests ---

const testing = std.testing;

test "parseJson loads all path fields" {
    const allocator = testing.allocator;
    const json =
        \\{
        \\  "data_dir": "/games/privateer",
        \\  "mod_dir": "/games/privateer/mods",
        \\  "output_dir": "/tmp/privateer-out"
        \\}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try testing.expectEqualStrings("/games/privateer", cfg.data_dir);
    try testing.expectEqualStrings("/games/privateer/mods", cfg.mod_dir);
    try testing.expectEqualStrings("/tmp/privateer-out", cfg.output_dir);
}

test "parseJson uses defaults for missing fields" {
    const allocator = testing.allocator;
    var cfg = try parseJson(allocator, "{}");
    defer cfg.deinit();

    try testing.expectEqualStrings("data", cfg.data_dir);
    try testing.expectEqualStrings("mods", cfg.mod_dir);
    try testing.expectEqualStrings("output", cfg.output_dir);
}

test "parseJson with partial path fields uses defaults for rest" {
    const allocator = testing.allocator;
    const json =
        \\{"data_dir": "C:\\WC\\PRIV"}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try testing.expectEqualStrings("C:\\WC\\PRIV", cfg.data_dir);
    try testing.expectEqualStrings("mods", cfg.mod_dir);
    try testing.expectEqualStrings("output", cfg.output_dir);
}

test "parseJson loads nested graphics settings" {
    const allocator = testing.allocator;
    const json =
        \\{
        \\  "graphics": {
        \\    "scale_factor": 3,
        \\    "fullscreen": true,
        \\    "viewport_mode": "fill"
        \\  }
        \\}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try testing.expectEqual(upscale_mod.ScaleFactor.x3, cfg.settings.scale_factor);
    try testing.expect(cfg.settings.fullscreen);
    try testing.expectEqual(viewport.Mode.fill, cfg.settings.viewport_mode);
}

test "parseJson loads nested audio settings" {
    const allocator = testing.allocator;
    const json =
        \\{
        \\  "audio": {
        \\    "sfx_volume": 0.5,
        \\    "music_volume": 0.3
        \\  }
        \\}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try testing.expectApproxEqAbs(@as(f32, 0.5), cfg.settings.sfx_volume, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.3), cfg.settings.music_volume, 0.01);
}

test "parseJson loads nested input settings" {
    const allocator = testing.allocator;
    const json =
        \\{
        \\  "input": {
        \\    "joystick_deadzone": 0.25
        \\  }
        \\}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try testing.expectApproxEqAbs(@as(f32, 0.25), cfg.settings.joystick_deadzone, 0.01);
}

test "parseJson uses default settings when sections missing" {
    const allocator = testing.allocator;
    var cfg = try parseJson(allocator, "{}");
    defer cfg.deinit();

    const d = Settings.defaults();
    try testing.expectEqual(d.scale_factor, cfg.settings.scale_factor);
    try testing.expect(!cfg.settings.fullscreen);
    try testing.expectApproxEqAbs(d.sfx_volume, cfg.settings.sfx_volume, 0.01);
    try testing.expectApproxEqAbs(d.music_volume, cfg.settings.music_volume, 0.01);
    try testing.expectApproxEqAbs(d.joystick_deadzone, cfg.settings.joystick_deadzone, 0.01);
}

test "parseJson clamps out-of-range volume" {
    const allocator = testing.allocator;
    const json =
        \\{"audio": {"sfx_volume": 5.0, "music_volume": -2.0}}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try testing.expectApproxEqAbs(@as(f32, 1.0), cfg.settings.sfx_volume, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), cfg.settings.music_volume, 0.001);
}

test "parseJson loads full config with all sections" {
    const allocator = testing.allocator;
    const json =
        \\{
        \\  "data_dir": "/opt/privateer",
        \\  "mod_dir": "my_mods",
        \\  "output_dir": "/tmp/out",
        \\  "graphics": {"scale_factor": 2, "fullscreen": true, "viewport_mode": "fill"},
        \\  "audio": {"sfx_volume": 0.8, "music_volume": 0.4},
        \\  "input": {"joystick_deadzone": 0.2}
        \\}
    ;
    var cfg = try parseJson(allocator, json);
    defer cfg.deinit();

    try testing.expectEqualStrings("/opt/privateer", cfg.data_dir);
    try testing.expectEqualStrings("my_mods", cfg.mod_dir);
    try testing.expectEqualStrings("/tmp/out", cfg.output_dir);
    try testing.expectEqual(upscale_mod.ScaleFactor.x2, cfg.settings.scale_factor);
    try testing.expect(cfg.settings.fullscreen);
    try testing.expectEqual(viewport.Mode.fill, cfg.settings.viewport_mode);
    try testing.expectApproxEqAbs(@as(f32, 0.8), cfg.settings.sfx_volume, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.4), cfg.settings.music_volume, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.2), cfg.settings.joystick_deadzone, 0.01);
}

test "parseJson rejects non-object root" {
    const allocator = testing.allocator;
    const result = parseJson(allocator, "\"just a string\"");
    try testing.expectError(error.InvalidConfig, result);
}

test "parseJson rejects non-string path field" {
    const allocator = testing.allocator;
    const json =
        \\{"data_dir": 42}
    ;
    const result = parseJson(allocator, json);
    try testing.expectError(error.InvalidConfig, result);
}

test "toJson produces valid nested JSON" {
    const allocator = testing.allocator;
    var cfg = try parseJson(allocator, "{}");
    defer cfg.deinit();

    const json = try toJson(allocator, cfg);
    defer allocator.free(json);

    // Top-level paths
    try testing.expect(std.mem.indexOf(u8, json, "\"data_dir\": \"data\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"mod_dir\": \"mods\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"output_dir\": \"output\"") != null);
    // Nested sections
    try testing.expect(std.mem.indexOf(u8, json, "\"graphics\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"scale_factor\": 4") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"audio\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"sfx_volume\": 1.00") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"input\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"joystick_deadzone\": 0.15") != null);
}

test "toJson round-trips through parseJson" {
    const allocator = testing.allocator;
    const json_in =
        \\{
        \\  "data_dir": "/my/data",
        \\  "mod_dir": "my_mods",
        \\  "output_dir": "/tmp/out",
        \\  "graphics": {"scale_factor": 3, "fullscreen": true, "viewport_mode": "fill"},
        \\  "audio": {"sfx_volume": 0.5, "music_volume": 0.3},
        \\  "input": {"joystick_deadzone": 0.25}
        \\}
    ;
    var original = try parseJson(allocator, json_in);
    defer original.deinit();

    const json_out = try toJson(allocator, original);
    defer allocator.free(json_out);

    var restored = try parseJson(allocator, json_out);
    defer restored.deinit();

    try testing.expectEqualStrings(original.data_dir, restored.data_dir);
    try testing.expectEqualStrings(original.mod_dir, restored.mod_dir);
    try testing.expectEqualStrings(original.output_dir, restored.output_dir);
    try testing.expectEqual(original.settings.scale_factor, restored.settings.scale_factor);
    try testing.expectEqual(original.settings.fullscreen, restored.settings.fullscreen);
    try testing.expectEqual(original.settings.viewport_mode, restored.settings.viewport_mode);
    try testing.expectApproxEqAbs(original.settings.sfx_volume, restored.settings.sfx_volume, 0.01);
    try testing.expectApproxEqAbs(original.settings.music_volume, restored.settings.music_volume, 0.01);
    try testing.expectApproxEqAbs(original.settings.joystick_deadzone, restored.settings.joystick_deadzone, 0.01);
}

test "load returns defaults when config file missing" {
    const allocator = testing.allocator;
    var cfg = try load(allocator, "nonexistent_privateer_config.json");
    defer cfg.deinit();

    try testing.expectEqualStrings("data", cfg.data_dir);
    try testing.expectEqualStrings("mods", cfg.mod_dir);
    try testing.expectEqualStrings("output", cfg.output_dir);
    try testing.expectEqual(Settings.defaults().scale_factor, cfg.settings.scale_factor);
}

test "applyArgs overrides path values" {
    const allocator = testing.allocator;
    var cfg = try parseJson(allocator, "{}");
    defer cfg.deinit();

    const args = [_][]const u8{
        "--data-dir",   "D:\\GAMES\\PRIV",
        "--output-dir", "D:\\SAVES",
    };
    try applyArgs(&cfg, &args);

    try testing.expectEqualStrings("D:\\GAMES\\PRIV", cfg.data_dir);
    try testing.expectEqualStrings("mods", cfg.mod_dir); // unchanged
    try testing.expectEqualStrings("D:\\SAVES", cfg.output_dir);
}

test "Settings defaults returns expected values" {
    const s = Settings.defaults();
    try testing.expectEqual(upscale_mod.ScaleFactor.x4, s.scale_factor);
    try testing.expect(!s.fullscreen);
    try testing.expectEqual(viewport.Mode.fit_4_3, s.viewport_mode);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.sfx_volume, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), s.music_volume, 0.001);
    try testing.expectApproxEqAbs(joystick_mod.DEFAULT_DEADZONE, s.joystick_deadzone, 0.001);
}

test "Settings windowWidth and windowHeight compute correctly" {
    var s = Settings.defaults();

    s.scale_factor = .x2;
    try testing.expectEqual(@as(u32, 640), s.windowWidth());
    try testing.expectEqual(@as(u32, 400), s.windowHeight());

    s.scale_factor = .x3;
    try testing.expectEqual(@as(u32, 960), s.windowWidth());
    try testing.expectEqual(@as(u32, 600), s.windowHeight());

    s.scale_factor = .x4;
    try testing.expectEqual(@as(u32, 1280), s.windowWidth());
    try testing.expectEqual(@as(u32, 800), s.windowHeight());
}

test "detectBundleResourcesDir returns null on non-bundle path" {
    // When not running from a .app bundle, should return null (or on non-macOS).
    const allocator = testing.allocator;
    const result = detectBundleResourcesDir(allocator);
    // In test context we're not inside a .app bundle, so expect null
    // (unless actually running tests from within a bundle, which is unlikely)
    if (result) |r| {
        // If we somehow got a result, it should at least end in "Resources"
        try testing.expect(std.mem.endsWith(u8, r, "Resources"));
        allocator.free(r);
    }
}

test "applyBundleOverride does not change non-default data_dir" {
    const allocator = testing.allocator;
    var cfg = Config{
        .data_dir = try allocator.dupe(u8, "/custom/path"),
        .mod_dir = try allocator.dupe(u8, "mods"),
        .output_dir = try allocator.dupe(u8, "output"),
        .settings = Settings.defaults(),
        .allocator = allocator,
    };
    defer cfg.deinit();

    applyBundleOverride(&cfg);
    // Should remain unchanged since it's not the default
    try testing.expectEqualStrings("/custom/path", cfg.data_dir);
}

test "Settings sanitize clamps values" {
    var s = Settings.defaults();
    s.sfx_volume = 1.5;
    s.music_volume = -0.3;
    s.joystick_deadzone = 2.0;
    s.sanitize();
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.sfx_volume, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.music_volume, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.joystick_deadzone, 0.001);
}
