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
    std.debug.print("Privateer engine starting...\n", .{});

    privateer.sdl.init() catch |err| {
        std.debug.print("Failed to initialize SDL: {}\n", .{err});
        return err;
    };
    defer privateer.sdl.shutdown();

    var win = privateer.window.Window.createDefault() catch |err| {
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
