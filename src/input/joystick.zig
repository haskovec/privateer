//! Joystick/gamepad input for Wing Commander: Privateer.
//! Manages SDL3 game controller connection, axis normalization with deadzone,
//! and mapping of gamepad inputs to flight controls.

const std = @import("std");
const sdl = @import("../sdl.zig");
const c = sdl.raw;

/// Normalized flight input commands produced from gamepad state.
pub const FlightInput = struct {
    /// Yaw: -1.0 (left) to 1.0 (right).
    yaw: f32 = 0,
    /// Pitch: -1.0 (down) to 1.0 (up).
    pitch: f32 = 0,
    /// Throttle: 0.0 (idle) to 1.0 (full).
    throttle: f32 = 0,
    /// Afterburner held.
    afterburner: bool = false,
    /// Primary fire (guns) held.
    fire_guns: bool = false,
    /// Secondary fire (missile) just pressed this frame.
    fire_missile: bool = false,
    /// Cycle target just pressed this frame.
    cycle_target: bool = false,
    /// Toggle autopilot just pressed this frame.
    autopilot: bool = false,
    /// Toggle nav map just pressed this frame.
    nav_map: bool = false,
};

/// Button indices used for edge detection (pressed-this-frame).
pub const Button = enum(u4) {
    fire_missile = 0,
    cycle_target = 1,
    autopilot = 2,
    nav_map = 3,
};

/// Tracks button state for edge detection.
pub const ButtonState = packed struct {
    fire_missile: bool = false,
    cycle_target: bool = false,
    autopilot: bool = false,
    nav_map: bool = false,

    /// Returns true if the button is pressed this frame but was not last frame.
    pub fn justPressed(curr: ButtonState, prev: ButtonState) ButtonState {
        return .{
            .fire_missile = curr.fire_missile and !prev.fire_missile,
            .cycle_target = curr.cycle_target and !prev.cycle_target,
            .autopilot = curr.autopilot and !prev.autopilot,
            .nav_map = curr.nav_map and !prev.nav_map,
        };
    }
};

/// SDL3 gamepad wrapper with deadzone handling and input mapping.
pub const Joystick = struct {
    gamepad: ?*c.SDL_Gamepad,
    deadzone: f32,
    prev_buttons: ButtonState,
    curr_buttons: ButtonState,
    connected: bool,

    /// Create an unconnected joystick handler with the given deadzone.
    pub fn init(deadzone: f32) Joystick {
        return .{
            .gamepad = null,
            .deadzone = std.math.clamp(deadzone, 0.0, 1.0),
            .prev_buttons = .{},
            .curr_buttons = .{},
            .connected = false,
        };
    }

    /// Open a specific gamepad by instance ID.
    pub fn open(self: *Joystick, instance_id: c.SDL_JoystickID) bool {
        self.close();
        const gp = c.SDL_OpenGamepad(instance_id);
        if (gp) |pad| {
            self.gamepad = pad;
            self.connected = true;
            return true;
        }
        return false;
    }

    /// Close the current gamepad if open.
    pub fn close(self: *Joystick) void {
        if (self.gamepad) |pad| {
            c.SDL_CloseGamepad(pad);
        }
        self.gamepad = null;
        self.connected = false;
    }

    /// Apply deadzone and normalize a raw SDL axis value (-32768..32767) to -1.0..1.0.
    /// Values within the deadzone return 0. Values outside are rescaled to fill
    /// the full -1.0..1.0 range smoothly.
    pub fn normalizeAxis(self: *const Joystick, raw_value: i16) f32 {
        // Normalize raw to -1.0..1.0
        const normalized: f32 = @as(f32, @floatFromInt(raw_value)) / 32767.0;
        const abs_val = @abs(normalized);
        if (abs_val < self.deadzone) return 0.0;
        // Rescale so the edge of the deadzone maps to 0 and the max maps to 1
        const sign: f32 = if (normalized < 0) -1.0 else 1.0;
        const rescaled = (abs_val - self.deadzone) / (1.0 - self.deadzone);
        return sign * std.math.clamp(rescaled, 0.0, 1.0);
    }

    /// Normalize a trigger axis value (0..32767) to 0.0..1.0 with deadzone.
    pub fn normalizeTrigger(self: *const Joystick, raw_value: i16) f32 {
        const normalized: f32 = @as(f32, @floatFromInt(raw_value)) / 32767.0;
        const clamped = std.math.clamp(normalized, 0.0, 1.0);
        if (clamped < self.deadzone) return 0.0;
        return (clamped - self.deadzone) / (1.0 - self.deadzone);
    }

    /// Begin a new input frame — shifts current buttons to previous.
    pub fn beginFrame(self: *Joystick) void {
        self.prev_buttons = self.curr_buttons;
    }

    /// Read the current gamepad state and produce flight input commands.
    /// Call beginFrame() before processing events, then readFlightInput() after.
    pub fn readFlightInput(self: *const Joystick) FlightInput {
        const pad = self.gamepad orelse return .{};

        // Read analog sticks
        const left_x = c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFTX);
        const left_y = c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFTY);
        const right_trigger = c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);

        // Read buttons (held state)
        const fire_guns = c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER);
        const afterburner = c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER);

        // Edge-detected buttons
        const edges = ButtonState.justPressed(self.curr_buttons, self.prev_buttons);

        return .{
            .yaw = self.normalizeAxis(left_x),
            .pitch = -self.normalizeAxis(left_y), // Invert: SDL Y-down → pitch-up
            .throttle = self.normalizeTrigger(right_trigger),
            .afterburner = afterburner,
            .fire_guns = fire_guns,
            .fire_missile = edges.fire_missile,
            .cycle_target = edges.cycle_target,
            .autopilot = edges.autopilot,
            .nav_map = edges.nav_map,
        };
    }

    /// Process an SDL event and update internal button state.
    /// Call between beginFrame() and readFlightInput().
    pub fn handleEvent(self: *Joystick, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_GAMEPAD_ADDED => {
                if (!self.connected) {
                    _ = self.open(event.gdevice.which);
                }
            },
            c.SDL_EVENT_GAMEPAD_REMOVED => {
                if (self.gamepad != null) {
                    self.close();
                }
            },
            c.SDL_EVENT_GAMEPAD_BUTTON_DOWN => {
                self.updateButton(event.gbutton.button, true);
            },
            c.SDL_EVENT_GAMEPAD_BUTTON_UP => {
                self.updateButton(event.gbutton.button, false);
            },
            else => {},
        }
    }

    /// Map SDL button to our tracked button state.
    fn updateButton(self: *Joystick, sdl_button: u8, pressed: bool) void {
        switch (sdl_button) {
            c.SDL_GAMEPAD_BUTTON_SOUTH => self.curr_buttons.fire_missile = pressed,    // A
            c.SDL_GAMEPAD_BUTTON_NORTH => self.curr_buttons.cycle_target = pressed,    // Y
            c.SDL_GAMEPAD_BUTTON_WEST => self.curr_buttons.autopilot = pressed,        // X
            c.SDL_GAMEPAD_BUTTON_EAST => self.curr_buttons.nav_map = pressed,          // B
            else => {},
        }
    }
};

/// Merge two FlightInput sources (e.g. keyboard + gamepad).
/// Analog axes use "larger absolute value wins"; booleans OR-merge;
/// throttle uses @max so a resting gamepad trigger doesn't drag keyboard throttle down.
pub fn mergeFlightInput(a: FlightInput, b: FlightInput) FlightInput {
    return .{
        .yaw = if (@abs(a.yaw) >= @abs(b.yaw)) a.yaw else b.yaw,
        .pitch = if (@abs(a.pitch) >= @abs(b.pitch)) a.pitch else b.pitch,
        .throttle = @max(a.throttle, b.throttle),
        .afterburner = a.afterburner or b.afterburner,
        .fire_guns = a.fire_guns or b.fire_guns,
        .fire_missile = a.fire_missile or b.fire_missile,
        .cycle_target = a.cycle_target or b.cycle_target,
        .autopilot = a.autopilot or b.autopilot,
        .nav_map = a.nav_map or b.nav_map,
    };
}

/// Default deadzone value (15% of axis range).
pub const DEFAULT_DEADZONE: f32 = 0.15;

// --- Tests ---

const testing = std.testing;

// FlightInput defaults

test "FlightInput defaults to zero/false" {
    const input = FlightInput{};
    try testing.expectEqual(@as(f32, 0), input.yaw);
    try testing.expectEqual(@as(f32, 0), input.pitch);
    try testing.expectEqual(@as(f32, 0), input.throttle);
    try testing.expect(!input.afterburner);
    try testing.expect(!input.fire_guns);
    try testing.expect(!input.fire_missile);
    try testing.expect(!input.cycle_target);
    try testing.expect(!input.autopilot);
    try testing.expect(!input.nav_map);
}

// Joystick initialization

test "init creates unconnected joystick with deadzone" {
    const js = Joystick.init(0.15);
    try testing.expect(js.gamepad == null);
    try testing.expect(!js.connected);
    try testing.expectApproxEqAbs(@as(f32, 0.15), js.deadzone, 0.001);
}

test "init clamps deadzone to 0-1 range" {
    const js_low = Joystick.init(-0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), js_low.deadzone, 0.001);

    const js_high = Joystick.init(1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), js_high.deadzone, 0.001);
}

// Axis normalization with deadzone

test "normalizeAxis returns 0 for values within deadzone" {
    const js = Joystick.init(0.2);
    // 20% of 32767 = ~6553
    try testing.expectEqual(@as(f32, 0), js.normalizeAxis(0));
    try testing.expectEqual(@as(f32, 0), js.normalizeAxis(100));
    try testing.expectEqual(@as(f32, 0), js.normalizeAxis(-100));
    try testing.expectEqual(@as(f32, 0), js.normalizeAxis(6000));
    try testing.expectEqual(@as(f32, 0), js.normalizeAxis(-6000));
}

test "normalizeAxis returns 1.0 at full deflection" {
    const js = Joystick.init(0.15);
    try testing.expectApproxEqAbs(@as(f32, 1.0), js.normalizeAxis(32767), 0.01);
    try testing.expectApproxEqAbs(@as(f32, -1.0), js.normalizeAxis(-32767), 0.01);
}

test "normalizeAxis rescales values outside deadzone smoothly" {
    const js = Joystick.init(0.2);
    // Halfway between deadzone edge and max:
    // normalized = 0.6, rescaled = (0.6 - 0.2) / (1.0 - 0.2) = 0.5
    const raw: i16 = @intFromFloat(0.6 * 32767.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), js.normalizeAxis(raw), 0.02);
}

test "normalizeAxis with zero deadzone passes through linearly" {
    const js = Joystick.init(0.0);
    const raw: i16 = @intFromFloat(0.5 * 32767.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), js.normalizeAxis(raw), 0.01);
}

test "normalizeAxis negative values mirror positive" {
    const js = Joystick.init(0.15);
    const pos_raw: i16 = 20000;
    const neg_raw: i16 = -20000;
    const pos_result = js.normalizeAxis(pos_raw);
    const neg_result = js.normalizeAxis(neg_raw);
    try testing.expectApproxEqAbs(-pos_result, neg_result, 0.001);
}

// Trigger normalization

test "normalizeTrigger returns 0 within deadzone" {
    const js = Joystick.init(0.15);
    try testing.expectEqual(@as(f32, 0), js.normalizeTrigger(0));
    try testing.expectEqual(@as(f32, 0), js.normalizeTrigger(3000));
}

test "normalizeTrigger returns 1.0 at full pull" {
    const js = Joystick.init(0.15);
    try testing.expectApproxEqAbs(@as(f32, 1.0), js.normalizeTrigger(32767), 0.01);
}

test "normalizeTrigger rescales outside deadzone" {
    const js = Joystick.init(0.2);
    // normalized = 0.6, rescaled = (0.6 - 0.2) / (1.0 - 0.2) = 0.5
    const raw: i16 = @intFromFloat(0.6 * 32767.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), js.normalizeTrigger(raw), 0.02);
}

test "normalizeTrigger clamps negative to zero" {
    const js = Joystick.init(0.15);
    try testing.expectEqual(@as(f32, 0), js.normalizeTrigger(-1000));
}

// Button edge detection

test "ButtonState.justPressed detects rising edge" {
    const prev = ButtonState{};
    const curr = ButtonState{ .fire_missile = true, .cycle_target = false, .autopilot = false, .nav_map = false };
    const edges = ButtonState.justPressed(curr, prev);
    try testing.expect(edges.fire_missile);
    try testing.expect(!edges.cycle_target);
}

test "ButtonState.justPressed ignores held buttons" {
    const prev = ButtonState{ .fire_missile = true, .cycle_target = false, .autopilot = false, .nav_map = false };
    const curr = ButtonState{ .fire_missile = true, .cycle_target = false, .autopilot = false, .nav_map = false };
    const edges = ButtonState.justPressed(curr, prev);
    try testing.expect(!edges.fire_missile);
}

test "ButtonState.justPressed ignores released buttons" {
    const prev = ButtonState{ .fire_missile = true, .cycle_target = false, .autopilot = false, .nav_map = false };
    const curr = ButtonState{};
    const edges = ButtonState.justPressed(curr, prev);
    try testing.expect(!edges.fire_missile);
}

test "ButtonState.justPressed detects multiple simultaneous presses" {
    const prev = ButtonState{};
    const curr = ButtonState{ .fire_missile = true, .cycle_target = true, .autopilot = false, .nav_map = true };
    const edges = ButtonState.justPressed(curr, prev);
    try testing.expect(edges.fire_missile);
    try testing.expect(edges.cycle_target);
    try testing.expect(!edges.autopilot);
    try testing.expect(edges.nav_map);
}

// beginFrame shifts button state

test "beginFrame shifts current to previous" {
    var js = Joystick.init(0.15);
    js.curr_buttons.fire_missile = true;
    js.beginFrame();
    try testing.expect(js.prev_buttons.fire_missile);
    // curr_buttons is unchanged (same value carried forward)
    try testing.expect(js.curr_buttons.fire_missile);
}

// updateButton mapping

test "updateButton maps SDL_GAMEPAD_BUTTON_SOUTH to fire_missile" {
    var js = Joystick.init(0.15);
    js.updateButton(c.SDL_GAMEPAD_BUTTON_SOUTH, true);
    try testing.expect(js.curr_buttons.fire_missile);
    js.updateButton(c.SDL_GAMEPAD_BUTTON_SOUTH, false);
    try testing.expect(!js.curr_buttons.fire_missile);
}

test "updateButton maps SDL_GAMEPAD_BUTTON_NORTH to cycle_target" {
    var js = Joystick.init(0.15);
    js.updateButton(c.SDL_GAMEPAD_BUTTON_NORTH, true);
    try testing.expect(js.curr_buttons.cycle_target);
}

test "updateButton maps SDL_GAMEPAD_BUTTON_WEST to autopilot" {
    var js = Joystick.init(0.15);
    js.updateButton(c.SDL_GAMEPAD_BUTTON_WEST, true);
    try testing.expect(js.curr_buttons.autopilot);
}

test "updateButton maps SDL_GAMEPAD_BUTTON_EAST to nav_map" {
    var js = Joystick.init(0.15);
    js.updateButton(c.SDL_GAMEPAD_BUTTON_EAST, true);
    try testing.expect(js.curr_buttons.nav_map);
}

test "updateButton ignores unmapped buttons" {
    var js = Joystick.init(0.15);
    js.updateButton(c.SDL_GAMEPAD_BUTTON_START, true);
    try testing.expect(!js.curr_buttons.fire_missile);
    try testing.expect(!js.curr_buttons.cycle_target);
    try testing.expect(!js.curr_buttons.autopilot);
    try testing.expect(!js.curr_buttons.nav_map);
}

// readFlightInput without gamepad

test "readFlightInput returns zero input when no gamepad connected" {
    const js = Joystick.init(0.15);
    const input = js.readFlightInput();
    try testing.expectEqual(@as(f32, 0), input.yaw);
    try testing.expectEqual(@as(f32, 0), input.pitch);
    try testing.expectEqual(@as(f32, 0), input.throttle);
    try testing.expect(!input.afterburner);
    try testing.expect(!input.fire_guns);
}

// DEFAULT_DEADZONE

test "DEFAULT_DEADZONE is reasonable value" {
    try testing.expect(DEFAULT_DEADZONE > 0.05);
    try testing.expect(DEFAULT_DEADZONE < 0.5);
}

// mergeFlightInput tests

test "mergeFlightInput: keyboard-only passthrough" {
    const kb = FlightInput{ .yaw = -1.0, .pitch = 1.0, .throttle = 0.5, .afterburner = true };
    const gp = FlightInput{};
    const merged = mergeFlightInput(kb, gp);
    try testing.expectEqual(@as(f32, -1.0), merged.yaw);
    try testing.expectEqual(@as(f32, 1.0), merged.pitch);
    try testing.expectApproxEqAbs(@as(f32, 0.5), merged.throttle, 0.01);
    try testing.expect(merged.afterburner);
}

test "mergeFlightInput: gamepad-only passthrough" {
    const kb = FlightInput{};
    const gp = FlightInput{ .yaw = 0.5, .pitch = -0.3, .throttle = 0.8, .fire_guns = true };
    const merged = mergeFlightInput(kb, gp);
    try testing.expectApproxEqAbs(@as(f32, 0.5), merged.yaw, 0.01);
    try testing.expectApproxEqAbs(@as(f32, -0.3), merged.pitch, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.8), merged.throttle, 0.01);
    try testing.expect(merged.fire_guns);
}

test "mergeFlightInput: larger absolute value wins for axes" {
    const kb = FlightInput{ .yaw = -1.0, .pitch = 0.2 };
    const gp = FlightInput{ .yaw = 0.5, .pitch = -0.8 };
    const merged = mergeFlightInput(kb, gp);
    try testing.expectEqual(@as(f32, -1.0), merged.yaw); // |-1| > |0.5|
    try testing.expectEqual(@as(f32, -0.8), merged.pitch); // |-0.8| > |0.2|
}

test "mergeFlightInput: throttle uses max" {
    const kb = FlightInput{ .throttle = 0.6 };
    const gp = FlightInput{ .throttle = 0.0 }; // resting trigger
    const merged = mergeFlightInput(kb, gp);
    try testing.expectApproxEqAbs(@as(f32, 0.6), merged.throttle, 0.01);
}

test "mergeFlightInput: booleans OR-merge" {
    const kb = FlightInput{ .afterburner = true, .fire_guns = false, .fire_missile = true };
    const gp = FlightInput{ .afterburner = false, .fire_guns = true, .fire_missile = false };
    const merged = mergeFlightInput(kb, gp);
    try testing.expect(merged.afterburner);
    try testing.expect(merged.fire_guns);
    try testing.expect(merged.fire_missile);
}

test "mergeFlightInput: both zero produces zero" {
    const a = FlightInput{};
    const b = FlightInput{};
    const merged = mergeFlightInput(a, b);
    try testing.expectEqual(@as(f32, 0), merged.yaw);
    try testing.expectEqual(@as(f32, 0), merged.pitch);
    try testing.expectEqual(@as(f32, 0), merged.throttle);
    try testing.expect(!merged.afterburner);
    try testing.expect(!merged.fire_guns);
}

test "mergeFlightInput: equal absolute values picks first" {
    const a = FlightInput{ .yaw = 0.5 };
    const b = FlightInput{ .yaw = -0.5 };
    const merged = mergeFlightInput(a, b);
    try testing.expectEqual(@as(f32, 0.5), merged.yaw); // a wins on tie
}
