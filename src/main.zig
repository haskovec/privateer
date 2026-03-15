const std = @import("std");
const privateer = @import("privateer");

const GameState = struct {
    frame_count: u64 = 0,
};

fn update(state_ptr: *anyopaque) void {
    const state: *GameState = @ptrCast(@alignCast(state_ptr));
    state.frame_count += 1;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Privateer engine starting...\n", .{});

    // Load unified config (privateer.json → env var → defaults)
    var cfg = try privateer.config.load(allocator, privateer.config.CONFIG_FILE);
    defer cfg.deinit();

    // Apply macOS bundle override (Resources/data inside .app)
    privateer.config.applyBundleOverride(&cfg);

    // Apply PRIVATEER_DATA env var override for data_dir
    privateer.config.applyEnvOverride(&cfg) catch {};

    // Apply CLI arg overrides
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len > 1) {
        try privateer.config.applyArgs(&cfg, args[1..]);
    }

    privateer.sdl.init() catch |err| {
        std.debug.print("Failed to initialize SDL: {}\n", .{err});
        return err;
    };
    defer privateer.sdl.shutdown();

    const width: c_int = @intCast(cfg.settings.windowWidth());
    const height: c_int = @intCast(cfg.settings.windowHeight());
    var win = privateer.window.Window.create(width, height) catch |err| {
        std.debug.print("Failed to create window: {}\n", .{err});
        return err;
    };
    defer win.destroy();

    var state = GameState{};
    win.runLoop(@ptrCast(&state), &update);

    std.debug.print("Privateer engine shutting down after {} frames.\n", .{state.frame_count});
}

test "main module loads engine" {
    _ = privateer;
    try std.testing.expect(true);
}
