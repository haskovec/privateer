//! Keyboard input for Wing Commander: Privateer.
//! Maps keyboard keys to the same FlightInput struct used by the gamepad,
//! allowing both input methods to coexist seamlessly.

const std = @import("std");
const sdl = @import("../sdl.zig");
const c = sdl.raw;
const joystick_mod = @import("joystick.zig");
const FlightInput = joystick_mod.FlightInput;
const ButtonState = joystick_mod.ButtonState;

/// Throttle change rate per second when +/- keys are held.
pub const THROTTLE_RATE: f32 = 1.0;

/// Tracks which keys are currently held down (analog-style held state).
pub const KeyHeldState = packed struct {
    arrow_left: bool = false,
    arrow_right: bool = false,
    arrow_up: bool = false,
    arrow_down: bool = false,
    tab: bool = false,
    space: bool = false,
    enter: bool = false,
    throttle_up: bool = false,
    throttle_down: bool = false,
};

pub const Keyboard = struct {
    held: KeyHeldState,
    prev_buttons: ButtonState,
    curr_buttons: ButtonState,
    persistent_throttle: f32,

    pub fn init() Keyboard {
        return .{
            .held = .{},
            .prev_buttons = .{},
            .curr_buttons = .{},
            .persistent_throttle = 0.0,
        };
    }

    /// Begin a new input frame — shifts current buttons to previous for edge detection.
    pub fn beginFrame(self: *Keyboard) void {
        self.prev_buttons = self.curr_buttons;
    }

    /// Process an SDL key event and update internal state.
    /// Ignores key repeats. Skips Enter when Alt is held (preserve fullscreen toggle).
    pub fn handleEvent(self: *Keyboard, event: *const c.SDL_Event) void {
        const is_down = event.type == c.SDL_EVENT_KEY_DOWN;
        const key = event.key;

        // Ignore key repeats
        if (key.repeat) return;

        const keycode = key.key;
        const mod = key.mod;

        switch (keycode) {
            // Held axes
            c.SDLK_LEFT => self.held.arrow_left = is_down,
            c.SDLK_RIGHT => self.held.arrow_right = is_down,
            c.SDLK_UP => self.held.arrow_up = is_down,
            c.SDLK_DOWN => self.held.arrow_down = is_down,

            // Held buttons
            c.SDLK_TAB => self.held.tab = is_down,
            c.SDLK_SPACE => self.held.space = is_down,
            c.SDLK_RETURN => {
                // Skip Enter when Alt is held (fullscreen toggle)
                if ((mod & c.SDL_KMOD_ALT) != 0) return;
                self.held.enter = is_down;
            },

            // Throttle
            c.SDLK_EQUALS => self.held.throttle_up = is_down, // + / = key
            c.SDLK_MINUS => self.held.throttle_down = is_down,

            // Edge-detected buttons
            c.SDLK_F => self.curr_buttons.fire_missile = is_down,
            c.SDLK_T => self.curr_buttons.cycle_target = is_down,
            c.SDLK_A => self.curr_buttons.autopilot = is_down,
            c.SDLK_N => self.curr_buttons.nav_map = is_down,

            else => {},
        }
    }

    /// Read the current keyboard state and produce flight input commands.
    /// Call beginFrame() before processing events, then readFlightInput() after.
    /// `dt` is the frame delta time in seconds (used for throttle ramping).
    pub fn readFlightInput(self: *Keyboard, dt: f32) FlightInput {
        // Digital axes: -1, 0, or 1
        var yaw: f32 = 0;
        if (self.held.arrow_left) yaw -= 1.0;
        if (self.held.arrow_right) yaw += 1.0;

        var pitch: f32 = 0;
        if (self.held.arrow_down) pitch -= 1.0;
        if (self.held.arrow_up) pitch += 1.0;

        // Update persistent throttle
        if (self.held.throttle_up) {
            self.persistent_throttle += THROTTLE_RATE * dt;
        }
        if (self.held.throttle_down) {
            self.persistent_throttle -= THROTTLE_RATE * dt;
        }
        self.persistent_throttle = std.math.clamp(self.persistent_throttle, 0.0, 1.0);

        // Edge-detected buttons
        const edges = ButtonState.justPressed(self.curr_buttons, self.prev_buttons);

        return .{
            .yaw = yaw,
            .pitch = pitch,
            .throttle = self.persistent_throttle,
            .afterburner = self.held.tab,
            .fire_guns = self.held.space or self.held.enter,
            .fire_missile = edges.fire_missile,
            .cycle_target = edges.cycle_target,
            .autopilot = edges.autopilot,
            .nav_map = edges.nav_map,
        };
    }
};

// --- Tests ---

const testing = std.testing;

// KeyHeldState defaults

test "KeyHeldState defaults all false" {
    const state = KeyHeldState{};
    try testing.expect(!state.arrow_left);
    try testing.expect(!state.arrow_right);
    try testing.expect(!state.arrow_up);
    try testing.expect(!state.arrow_down);
    try testing.expect(!state.tab);
    try testing.expect(!state.space);
    try testing.expect(!state.enter);
    try testing.expect(!state.throttle_up);
    try testing.expect(!state.throttle_down);
}

// Keyboard initialization

test "Keyboard.init has zero throttle and default states" {
    const kb = Keyboard.init();
    try testing.expectEqual(@as(f32, 0.0), kb.persistent_throttle);
    try testing.expect(!kb.held.arrow_left);
    try testing.expect(!kb.curr_buttons.fire_missile);
    try testing.expect(!kb.prev_buttons.fire_missile);
}

// Helper to create a fake SDL key event for testing
fn makeKeyEvent(event_type: u32, keycode: c.SDL_Keycode, mod_state: u16, repeat: bool) c.SDL_Event {
    var event: c.SDL_Event = undefined;
    // Zero out the event to avoid undefined memory
    @memset(std.mem.asBytes(&event), 0);
    event.type = event_type;
    event.key.key = keycode;
    event.key.mod = mod_state;
    event.key.repeat = repeat;
    return event;
}

// handleEvent tests — arrow keys

test "handleEvent: arrow left key down sets held state" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_LEFT, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.arrow_left);
}

test "handleEvent: arrow left key up clears held state" {
    var kb = Keyboard.init();
    var down = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_LEFT, 0, false);
    kb.handleEvent(&down);
    var up = makeKeyEvent(c.SDL_EVENT_KEY_UP, c.SDLK_LEFT, 0, false);
    kb.handleEvent(&up);
    try testing.expect(!kb.held.arrow_left);
}

test "handleEvent: arrow right key" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_RIGHT, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.arrow_right);
}

test "handleEvent: arrow up key" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_UP, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.arrow_up);
}

test "handleEvent: arrow down key" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_DOWN, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.arrow_down);
}

// handleEvent — held buttons

test "handleEvent: tab key sets afterburner" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_TAB, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.tab);
}

test "handleEvent: space key sets fire" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_SPACE, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.space);
}

test "handleEvent: enter key sets fire (no alt)" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_RETURN, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.enter);
}

test "handleEvent: alt+enter is ignored (fullscreen toggle)" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_RETURN, c.SDL_KMOD_ALT, false);
    kb.handleEvent(&event);
    try testing.expect(!kb.held.enter);
}

// handleEvent — throttle keys

test "handleEvent: equals/plus key sets throttle_up" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_EQUALS, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.throttle_up);
}

test "handleEvent: minus key sets throttle_down" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_MINUS, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.held.throttle_down);
}

// handleEvent — edge-detected buttons

test "handleEvent: F key sets fire_missile button" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_F, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.curr_buttons.fire_missile);
}

test "handleEvent: T key sets cycle_target button" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_T, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.curr_buttons.cycle_target);
}

test "handleEvent: A key sets autopilot button" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_A, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.curr_buttons.autopilot);
}

test "handleEvent: N key sets nav_map button" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_N, 0, false);
    kb.handleEvent(&event);
    try testing.expect(kb.curr_buttons.nav_map);
}

// handleEvent — repeat rejection

test "handleEvent: ignores key repeats" {
    var kb = Keyboard.init();
    var event = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_LEFT, 0, true);
    kb.handleEvent(&event);
    try testing.expect(!kb.held.arrow_left);
}

// beginFrame + edge detection

test "beginFrame shifts current to previous buttons" {
    var kb = Keyboard.init();
    kb.curr_buttons.fire_missile = true;
    kb.beginFrame();
    try testing.expect(kb.prev_buttons.fire_missile);
}

test "edge detection: button press detected on first frame only" {
    var kb = Keyboard.init();

    // Frame 1: press F
    kb.beginFrame();
    var down = makeKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_F, 0, false);
    kb.handleEvent(&down);
    var input = kb.readFlightInput(1.0 / 60.0);
    try testing.expect(input.fire_missile);

    // Frame 2: still held — no edge
    kb.beginFrame();
    input = kb.readFlightInput(1.0 / 60.0);
    try testing.expect(!input.fire_missile);
}

// readFlightInput — digital axes

test "readFlightInput: arrow left produces yaw -1" {
    var kb = Keyboard.init();
    kb.held.arrow_left = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expectEqual(@as(f32, -1.0), input.yaw);
}

test "readFlightInput: arrow right produces yaw +1" {
    var kb = Keyboard.init();
    kb.held.arrow_right = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expectEqual(@as(f32, 1.0), input.yaw);
}

test "readFlightInput: both left+right cancel to 0" {
    var kb = Keyboard.init();
    kb.held.arrow_left = true;
    kb.held.arrow_right = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expectEqual(@as(f32, 0.0), input.yaw);
}

test "readFlightInput: arrow up produces pitch +1" {
    var kb = Keyboard.init();
    kb.held.arrow_up = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expectEqual(@as(f32, 1.0), input.pitch);
}

test "readFlightInput: arrow down produces pitch -1" {
    var kb = Keyboard.init();
    kb.held.arrow_down = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expectEqual(@as(f32, -1.0), input.pitch);
}

// readFlightInput — throttle

test "readFlightInput: throttle increments when + held" {
    var kb = Keyboard.init();
    kb.held.throttle_up = true;
    _ = kb.readFlightInput(0.5); // 0.5s at rate 1.0/s = 0.5
    try testing.expectApproxEqAbs(@as(f32, 0.5), kb.persistent_throttle, 0.01);
}

test "readFlightInput: throttle decrements when - held" {
    var kb = Keyboard.init();
    kb.persistent_throttle = 0.8;
    kb.held.throttle_down = true;
    _ = kb.readFlightInput(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.3), kb.persistent_throttle, 0.01);
}

test "readFlightInput: throttle clamps to 0..1" {
    var kb = Keyboard.init();
    kb.held.throttle_up = true;
    _ = kb.readFlightInput(2.0); // Would be 2.0, clamped to 1.0
    try testing.expectEqual(@as(f32, 1.0), kb.persistent_throttle);

    kb.held.throttle_up = false;
    kb.held.throttle_down = true;
    _ = kb.readFlightInput(3.0); // Would be -2.0, clamped to 0.0
    try testing.expectEqual(@as(f32, 0.0), kb.persistent_throttle);
}

// readFlightInput — held buttons

test "readFlightInput: tab produces afterburner" {
    var kb = Keyboard.init();
    kb.held.tab = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expect(input.afterburner);
}

test "readFlightInput: space produces fire_guns" {
    var kb = Keyboard.init();
    kb.held.space = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expect(input.fire_guns);
}

test "readFlightInput: enter produces fire_guns" {
    var kb = Keyboard.init();
    kb.held.enter = true;
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expect(input.fire_guns);
}

test "readFlightInput: no keys produces zero input" {
    var kb = Keyboard.init();
    const input = kb.readFlightInput(1.0 / 60.0);
    try testing.expectEqual(@as(f32, 0.0), input.yaw);
    try testing.expectEqual(@as(f32, 0.0), input.pitch);
    try testing.expectEqual(@as(f32, 0.0), input.throttle);
    try testing.expect(!input.afterburner);
    try testing.expect(!input.fire_guns);
    try testing.expect(!input.fire_missile);
}
