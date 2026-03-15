//! Persistent game settings for Wing Commander: Privateer.
//! Manages user-configurable options (graphics, audio, input) with
//! JSON serialization for persistence across sessions.

const std = @import("std");
const viewport = @import("render/viewport.zig");
const upscale_mod = @import("render/upscale.zig");
const window_mod = @import("render/window.zig");
const joystick_mod = @import("input/joystick.zig");

/// All user-configurable game settings.
pub const Settings = struct {
    // Graphics
    /// Window scale factor (2x, 3x, 4x base resolution).
    scale_factor: upscale_mod.ScaleFactor,
    /// Start in fullscreen mode.
    fullscreen: bool,
    /// Viewport mode for landing screens.
    viewport_mode: viewport.Mode,

    // Audio (0.0 = mute, 1.0 = full volume)
    /// Sound effects volume.
    sfx_volume: f32,
    /// Music volume.
    music_volume: f32,

    // Input
    /// Joystick deadzone (0.0 to 1.0, fraction of axis range).
    joystick_deadzone: f32,

    /// Create settings with default values.
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

    /// Compute window width from scale factor.
    pub fn windowWidth(self: Settings) u32 {
        return window_mod.BASE_WIDTH * self.scale_factor.multiplier();
    }

    /// Compute window height from scale factor.
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

/// Serialize settings to a JSON string.
/// Caller owns the returned slice.
pub fn toJson(allocator: std.mem.Allocator, settings: Settings) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try std.fmt.format(buf.writer(allocator), "  \"scale_factor\": {d},\n", .{settings.scale_factor.multiplier()});
    try std.fmt.format(buf.writer(allocator), "  \"fullscreen\": {s},\n", .{if (settings.fullscreen) "true" else "false"});
    try std.fmt.format(buf.writer(allocator), "  \"viewport_mode\": \"{s}\",\n", .{switch (settings.viewport_mode) {
        .fill => "fill",
        .fit_4_3 => "fit_4_3",
    }});
    try std.fmt.format(buf.writer(allocator), "  \"sfx_volume\": {d:.2},\n", .{settings.sfx_volume});
    try std.fmt.format(buf.writer(allocator), "  \"music_volume\": {d:.2},\n", .{settings.music_volume});
    try std.fmt.format(buf.writer(allocator), "  \"joystick_deadzone\": {d:.2}\n", .{settings.joystick_deadzone});
    try buf.appendSlice(allocator, "}");

    return buf.toOwnedSlice(allocator);
}

/// Deserialize settings from a JSON string.
pub fn fromJson(json_str: []const u8) !Settings {
    var settings = Settings.defaults();

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_str, .{}) catch return settings;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return settings;

    if (root.object.get("scale_factor")) |v| {
        if (v == .integer) {
            const val: u8 = @intCast(std.math.clamp(v.integer, 2, 4));
            settings.scale_factor = switch (val) {
                2 => .x2,
                3 => .x3,
                else => .x4,
            };
        }
    }

    if (root.object.get("fullscreen")) |v| {
        if (v == .bool) settings.fullscreen = v.bool;
    }

    if (root.object.get("viewport_mode")) |v| {
        if (v == .string) {
            if (std.mem.eql(u8, v.string, "fill")) {
                settings.viewport_mode = .fill;
            } else if (std.mem.eql(u8, v.string, "fit_4_3")) {
                settings.viewport_mode = .fit_4_3;
            }
        }
    }

    if (root.object.get("sfx_volume")) |v| {
        if (v == .float) settings.sfx_volume = @floatCast(v.float);
        if (v == .integer) settings.sfx_volume = @floatFromInt(v.integer);
    }

    if (root.object.get("music_volume")) |v| {
        if (v == .float) settings.music_volume = @floatCast(v.float);
        if (v == .integer) settings.music_volume = @floatFromInt(v.integer);
    }

    if (root.object.get("joystick_deadzone")) |v| {
        if (v == .float) settings.joystick_deadzone = @floatCast(v.float);
        if (v == .integer) settings.joystick_deadzone = @floatFromInt(v.integer);
    }

    settings.sanitize();
    return settings;
}

/// Save settings to a file.
pub fn save(allocator: std.mem.Allocator, settings: Settings, path: []const u8) !void {
    const json = try toJson(allocator, settings);
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(json);
}

/// Load settings from a file. Returns defaults if file not found.
pub fn load(path: []const u8) Settings {
    const file = std.fs.cwd().openFile(path, .{}) catch return Settings.defaults();
    defer file.close();

    const stat = file.stat() catch return Settings.defaults();
    if (stat.size > 1024 * 1024) return Settings.defaults();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return Settings.defaults();

    return fromJson(buf[0..bytes_read]) catch Settings.defaults();
}

// --- Tests ---

test "defaults returns expected values" {
    const s = Settings.defaults();
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x4, s.scale_factor);
    try std.testing.expect(!s.fullscreen);
    try std.testing.expectEqual(viewport.Mode.fit_4_3, s.viewport_mode);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.sfx_volume, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), s.music_volume, 0.001);
    try std.testing.expectApproxEqAbs(joystick_mod.DEFAULT_DEADZONE, s.joystick_deadzone, 0.001);
}

test "windowWidth and windowHeight compute correctly" {
    var s = Settings.defaults();

    s.scale_factor = .x2;
    try std.testing.expectEqual(@as(u32, 640), s.windowWidth());
    try std.testing.expectEqual(@as(u32, 400), s.windowHeight());

    s.scale_factor = .x3;
    try std.testing.expectEqual(@as(u32, 960), s.windowWidth());
    try std.testing.expectEqual(@as(u32, 600), s.windowHeight());

    s.scale_factor = .x4;
    try std.testing.expectEqual(@as(u32, 1280), s.windowWidth());
    try std.testing.expectEqual(@as(u32, 800), s.windowHeight());
}

test "sanitize clamps volume to valid range" {
    var s = Settings.defaults();
    s.sfx_volume = 1.5;
    s.music_volume = -0.3;
    s.sanitize();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.sfx_volume, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.music_volume, 0.001);
}

test "toJson produces valid JSON" {
    const allocator = std.testing.allocator;
    const s = Settings.defaults();
    const json = try toJson(allocator, s);
    defer allocator.free(json);

    // Should contain all fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scale_factor\": 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fullscreen\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"viewport_mode\": \"fit_4_3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sfx_volume\": 1.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"music_volume\": 0.70") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"joystick_deadzone\": 0.15") != null);
}

test "fromJson round-trips with toJson" {
    const allocator = std.testing.allocator;
    const original = Settings{
        .scale_factor = .x3,
        .fullscreen = true,
        .viewport_mode = .fill,
        .sfx_volume = 0.5,
        .music_volume = 0.3,
        .joystick_deadzone = 0.25,
    };
    const json = try toJson(allocator, original);
    defer allocator.free(json);

    const restored = try fromJson(json);
    try std.testing.expectEqual(original.scale_factor, restored.scale_factor);
    try std.testing.expectEqual(original.fullscreen, restored.fullscreen);
    try std.testing.expectEqual(original.viewport_mode, restored.viewport_mode);
    try std.testing.expectApproxEqAbs(original.sfx_volume, restored.sfx_volume, 0.01);
    try std.testing.expectApproxEqAbs(original.music_volume, restored.music_volume, 0.01);
    try std.testing.expectApproxEqAbs(original.joystick_deadzone, restored.joystick_deadzone, 0.01);
}

test "fromJson returns defaults for empty JSON" {
    const s = try fromJson("{}");
    const d = Settings.defaults();
    try std.testing.expectEqual(d.scale_factor, s.scale_factor);
    try std.testing.expectEqual(d.fullscreen, s.fullscreen);
}

test "fromJson returns defaults for invalid JSON" {
    const s = try fromJson("not json at all");
    try std.testing.expectEqual(Settings.defaults().scale_factor, s.scale_factor);
}

test "fromJson clamps out-of-range volume" {
    const json =
        \\{"sfx_volume": 5.0, "music_volume": -2.0}
    ;
    const s = try fromJson(json);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.sfx_volume, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.music_volume, 0.001);
}

test "fromJson parses scale_factor values" {
    const json2 =
        \\{"scale_factor": 2}
    ;
    const s2 = try fromJson(json2);
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x2, s2.scale_factor);

    const json3 =
        \\{"scale_factor": 3}
    ;
    const s3 = try fromJson(json3);
    try std.testing.expectEqual(upscale_mod.ScaleFactor.x3, s3.scale_factor);
}

test "load returns defaults when file missing" {
    const s = load("nonexistent_settings_file_12345.json");
    try std.testing.expectEqual(Settings.defaults().scale_factor, s.scale_factor);
}
