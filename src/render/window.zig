//! Window creation and main game loop.
//! Manages an SDL3 window at 4x the original 320x200 resolution,
//! runs a fixed-timestep game loop at 60fps, and supports fullscreen toggle.

const std = @import("std");
const sdl = @import("../sdl.zig");
const c = sdl.raw;
const joystick_mod = @import("../input/joystick.zig");
const keyboard_mod = @import("../input/keyboard.zig");

/// Original game resolution.
pub const BASE_WIDTH = 320;
pub const BASE_HEIGHT = 200;
pub const DEFAULT_SCALE = 4;
pub const DEFAULT_WIDTH = BASE_WIDTH * DEFAULT_SCALE; // 1280
pub const DEFAULT_HEIGHT = BASE_HEIGHT * DEFAULT_SCALE; // 800

/// Target frame rate and timestep.
pub const TARGET_FPS = 60;
pub const FRAME_TIME_NS: u64 = std.time.ns_per_s / TARGET_FPS; // ~16.67ms

/// Callback signature for game update/render.
pub const FrameCallback = *const fn (state: *anyopaque) void;

pub const Window = struct {
    sdl_window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    width: c_int,
    height: c_int,
    fullscreen: bool,
    quit_requested: bool,
    joystick: joystick_mod.Joystick,
    keyboard: keyboard_mod.Keyboard,
    /// Mouse state updated each frame by pollEvents.
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_clicked: bool = false,
    key_pressed: u32 = 0,
    /// Key modifier state (SDL_KMOD_* flags) for the most recent key press.
    key_mod: u16 = 0,

    pub const CreateError = error{
        WindowCreateFailed,
        RendererCreateFailed,
    };

    /// Create a new game window with the given dimensions.
    /// SDL must be initialized before calling this.
    pub fn create(width: c_int, height: c_int) CreateError!Window {
        const sdl_window = c.SDL_CreateWindow(
            "Wing Commander: Privateer",
            width,
            height,
            c.SDL_WINDOW_RESIZABLE,
        ) orelse {
            std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
            return CreateError.WindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(sdl_window);

        const renderer = c.SDL_CreateRenderer(sdl_window, null) orelse {
            std.log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
            return CreateError.RendererCreateFailed;
        };

        return Window{
            .sdl_window = sdl_window,
            .renderer = renderer,
            .width = width,
            .height = height,
            .fullscreen = false,
            .quit_requested = false,
            .joystick = joystick_mod.Joystick.init(joystick_mod.DEFAULT_DEADZONE),
            .keyboard = keyboard_mod.Keyboard.init(),
        };
    }

    /// Create a window with the default 4x resolution (1280x800).
    pub fn createDefault() CreateError!Window {
        return create(DEFAULT_WIDTH, DEFAULT_HEIGHT);
    }

    /// Destroy the window and release all resources.
    pub fn destroy(self: *Window) void {
        self.joystick.close();
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.sdl_window);
    }

    /// Toggle between windowed and fullscreen mode.
    pub fn toggleFullscreen(self: *Window) void {
        self.fullscreen = !self.fullscreen;
        _ = c.SDL_SetWindowFullscreen(self.sdl_window, self.fullscreen);
    }

    /// Process all pending SDL events. Returns false if quit was requested.
    pub fn pollEvents(self: *Window) bool {
        self.joystick.beginFrame();
        self.keyboard.beginFrame();
        self.mouse_clicked = false;
        self.key_pressed = 0;
        self.key_mod = 0;
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    self.quit_requested = true;
                    return false;
                },
                c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                    const key = event.key;
                    // Alt+Enter toggles fullscreen
                    if (event.type == c.SDL_EVENT_KEY_DOWN and
                        key.key == c.SDLK_RETURN and (key.mod & c.SDL_KMOD_ALT) != 0)
                    {
                        self.toggleFullscreen();
                    }
                    // Track key press for game state
                    if (event.type == c.SDL_EVENT_KEY_DOWN and !key.repeat) {
                        self.key_pressed = key.key;
                        self.key_mod = key.mod;
                    }
                    // Route all key events to keyboard handler
                    self.keyboard.handleEvent(&event);
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        self.mouse_clicked = true;
                        self.mouse_x = event.button.x;
                        self.mouse_y = event.button.y;
                    }
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    self.mouse_x = event.motion.x;
                    self.mouse_y = event.motion.y;
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    self.width = event.window.data1;
                    self.height = event.window.data2;
                },
                c.SDL_EVENT_GAMEPAD_ADDED,
                c.SDL_EVENT_GAMEPAD_REMOVED,
                c.SDL_EVENT_GAMEPAD_BUTTON_DOWN,
                c.SDL_EVENT_GAMEPAD_BUTTON_UP,
                => {
                    self.joystick.handleEvent(&event);
                },
                else => {},
            }
        }
        return true;
    }

    /// Get the merged flight input (keyboard + gamepad) for this frame.
    /// Uses a fixed dt of 1/60s for keyboard throttle ramping.
    pub fn getFlightInput(self: *Window) joystick_mod.FlightInput {
        const dt: f32 = 1.0 / @as(f32, @floatFromInt(TARGET_FPS));
        const kb_input = self.keyboard.readFlightInput(dt);
        const gp_input = self.joystick.readFlightInput();
        return joystick_mod.mergeFlightInput(kb_input, gp_input);
    }

    /// Run the main game loop with a fixed timestep.
    /// Calls `update_fn` each frame with `state`, then presents the frame.
    /// The loop exits when the window is closed or quit is requested.
    pub fn runLoop(self: *Window, state: *anyopaque, update_fn: FrameCallback) void {
        while (!self.quit_requested) {
            const frame_start = std.time.Instant.now() catch unreachable;

            if (!self.pollEvents()) break;

            // Clear the screen
            _ = c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255);
            _ = c.SDL_RenderClear(self.renderer);

            // Call the game's update/render callback
            update_fn(state);

            // Present the frame
            _ = c.SDL_RenderPresent(self.renderer);

            // Frame pacing: sleep to maintain target FPS
            const frame_end = std.time.Instant.now() catch unreachable;
            const elapsed = frame_end.since(frame_start);
            if (elapsed < FRAME_TIME_NS) {
                std.Thread.sleep(FRAME_TIME_NS - elapsed);
            }
        }
    }

    /// Get the current window size.
    pub fn getSize(self: *const Window) struct { width: c_int, height: c_int } {
        return .{ .width = self.width, .height = self.height };
    }
};

// --- Tests ---

test "default window dimensions are 4x base resolution" {
    try std.testing.expectEqual(@as(c_int, 1280), DEFAULT_WIDTH);
    try std.testing.expectEqual(@as(c_int, 800), DEFAULT_HEIGHT);
}

test "base resolution is 320x200" {
    try std.testing.expectEqual(@as(c_int, 320), BASE_WIDTH);
    try std.testing.expectEqual(@as(c_int, 200), BASE_HEIGHT);
}

test "frame time targets 60fps" {
    // 1 second / 60 = ~16,666,666 ns
    try std.testing.expectEqual(@as(u64, 16_666_666), FRAME_TIME_NS);
}

test "window creates at correct size" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try Window.create(1280, 800);
    defer win.destroy();

    const size = win.getSize();
    try std.testing.expectEqual(@as(c_int, 1280), size.width);
    try std.testing.expectEqual(@as(c_int, 800), size.height);
    try std.testing.expect(!win.fullscreen);
    try std.testing.expect(!win.quit_requested);
}

test "window creates at default 4x resolution" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try Window.createDefault();
    defer win.destroy();

    const size = win.getSize();
    try std.testing.expectEqual(@as(c_int, DEFAULT_WIDTH), size.width);
    try std.testing.expectEqual(@as(c_int, DEFAULT_HEIGHT), size.height);
}

test "fullscreen toggle flips state" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try Window.createDefault();
    defer win.destroy();

    try std.testing.expect(!win.fullscreen);
    win.toggleFullscreen();
    try std.testing.expect(win.fullscreen);
    win.toggleFullscreen();
    try std.testing.expect(!win.fullscreen);
}

test "pollEvents returns true when no quit" {
    try sdl.init();
    defer sdl.shutdown();

    var win = try Window.createDefault();
    defer win.destroy();

    // With no events queued, pollEvents should return true (no quit)
    const result = win.pollEvents();
    try std.testing.expect(result);
    try std.testing.expect(!win.quit_requested);
}
