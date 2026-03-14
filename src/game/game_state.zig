//! Game state machine for Wing Commander: Privateer.
//! Manages high-level game states (title, flight, landing, etc.) and
//! validates transitions between them. Connects click region actions
//! to state transitions for the scene system.

const std = @import("std");
const click_region = @import("click_region.zig");

/// High-level game states.
pub const State = enum {
    /// Title/main menu screen.
    title,
    /// Loading/transition screen (between major areas).
    loading,
    /// In-flight (normal space travel).
    space_flight,
    /// Landed at a base (walking around rooms).
    landed,
    /// In conversation with an NPC.
    conversation,
    /// In combat with hostiles.
    combat,
    /// Player destroyed (game over).
    dead,
    /// Playing a midgame animation sequence (landing/launch/jump/death).
    animation,
};

/// Error returned when an invalid state transition is attempted.
pub const TransitionError = error{InvalidTransition};

/// Returns true if the state is part of the base context (landed area).
/// Room/scene data is preserved across transitions within the base context.
fn isBaseState(state: State) bool {
    return state == .landed or state == .conversation or state == .animation;
}

/// Game state machine tracking the current high-level state and
/// base location (room/scene) when landed.
pub const GameStateMachine = struct {
    state: State,
    /// Current room ID when at a base (null otherwise).
    current_room: ?u8,
    /// Current scene ID when at a base (null otherwise).
    current_scene: ?u8,

    /// Create a new state machine in the title state.
    pub fn init() GameStateMachine {
        return .{
            .state = .title,
            .current_room = null,
            .current_scene = null,
        };
    }

    /// Check whether a transition to the target state is valid from
    /// the current state. Self-transitions are not allowed.
    pub fn canTransition(self: *const GameStateMachine, target: State) bool {
        return switch (self.state) {
            .title => target == .loading,
            .loading => target == .space_flight or target == .landed,
            .space_flight => target == .landed or target == .combat or target == .dead or target == .loading or target == .animation,
            .landed => target == .space_flight or target == .conversation or target == .loading or target == .animation,
            .conversation => target == .landed,
            .combat => target == .space_flight or target == .dead,
            .dead => target == .title,
            .animation => target == .space_flight or target == .landed,
        };
    }

    /// Transition to a new state. Returns error if the transition is invalid.
    /// Clears room/scene data when leaving the base context.
    pub fn transition(self: *GameStateMachine, target: State) TransitionError!void {
        if (!self.canTransition(target)) return error.InvalidTransition;
        // Clear room/scene when leaving base context
        if (!isBaseState(target)) {
            self.current_room = null;
            self.current_scene = null;
        }
        self.state = target;
    }

    /// Update current room and scene within a base.
    pub fn setScene(self: *GameStateMachine, room_id: u8, scene_id: u8) void {
        self.current_room = room_id;
        self.current_scene = scene_id;
    }

    /// Process a click region action and perform the appropriate state
    /// transition or scene change. Returns the action for the caller
    /// to handle UI-specific actions (dealer panels, etc.).
    pub fn handleAction(self: *GameStateMachine, action: click_region.Action) TransitionError!click_region.Action {
        switch (action) {
            .none => {},
            .scene_transition => |target_scene| {
                // Scene transitions stay within the landed state
                self.current_scene = target_scene;
            },
            .launch, .takeoff => {
                // Launch/takeoff only valid from landed state
                if (self.state != .landed) return error.InvalidTransition;
                try self.transition(.animation);
            },
            .bar_conversation, .bartender_conversation => {
                try self.transition(.conversation);
            },
            .ship_dealer, .commodity_exchange, .equipment_dealer, .scripted => {
                // UI-specific actions passed through for the caller
            },
        }
        return action;
    }

    /// Complete a midgame animation and transition to the target state.
    /// Called when a landing/launch animation sequence finishes.
    pub fn completeAnimation(self: *GameStateMachine, target: State) TransitionError!void {
        if (self.state != .animation) return error.InvalidTransition;
        if (target != .space_flight and target != .landed) return error.InvalidTransition;
        self.state = target;
        if (target == .space_flight) {
            self.current_room = null;
            self.current_scene = null;
        }
    }
};

// --- Tests ---

// Initialization

test "init creates state machine in title state" {
    const sm = GameStateMachine.init();
    try std.testing.expectEqual(State.title, sm.state);
    try std.testing.expect(sm.current_room == null);
    try std.testing.expect(sm.current_scene == null);
}

// Valid transitions

test "transition from title to loading succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try std.testing.expectEqual(State.loading, sm.state);
}

test "transition from loading to space_flight succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try std.testing.expectEqual(State.space_flight, sm.state);
}

test "transition from loading to landed succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "transition from space_flight to landed succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.landed);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "transition from space_flight to combat succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.combat);
    try std.testing.expectEqual(State.combat, sm.state);
}

test "transition from space_flight to dead succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.dead);
    try std.testing.expectEqual(State.dead, sm.state);
}

test "transition from space_flight to loading succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.loading);
    try std.testing.expectEqual(State.loading, sm.state);
}

test "transition from landed to space_flight succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.space_flight);
    try std.testing.expectEqual(State.space_flight, sm.state);
}

test "transition from landed to conversation succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.conversation);
    try std.testing.expectEqual(State.conversation, sm.state);
}

test "transition from landed to loading succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.loading);
    try std.testing.expectEqual(State.loading, sm.state);
}

test "transition from conversation to landed succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.conversation);
    try sm.transition(.landed);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "transition from combat to space_flight succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.combat);
    try sm.transition(.space_flight);
    try std.testing.expectEqual(State.space_flight, sm.state);
}

test "transition from combat to dead succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.combat);
    try sm.transition(.dead);
    try std.testing.expectEqual(State.dead, sm.state);
}

test "transition from dead to title succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.dead);
    try sm.transition(.title);
    try std.testing.expectEqual(State.title, sm.state);
}

// Invalid transitions

test "transition from title to space_flight is rejected" {
    var sm = GameStateMachine.init();
    try std.testing.expectError(error.InvalidTransition, sm.transition(.space_flight));
    try std.testing.expectEqual(State.title, sm.state);
}

test "transition from title to landed is rejected" {
    var sm = GameStateMachine.init();
    try std.testing.expectError(error.InvalidTransition, sm.transition(.landed));
}

test "transition from title to dead is rejected" {
    var sm = GameStateMachine.init();
    try std.testing.expectError(error.InvalidTransition, sm.transition(.dead));
}

test "transition from loading to combat is rejected" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try std.testing.expectError(error.InvalidTransition, sm.transition(.combat));
}

test "transition from loading to dead is rejected" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try std.testing.expectError(error.InvalidTransition, sm.transition(.dead));
}

test "transition from landed to combat is rejected" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try std.testing.expectError(error.InvalidTransition, sm.transition(.combat));
}

test "transition from landed to dead is rejected" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try std.testing.expectError(error.InvalidTransition, sm.transition(.dead));
}

test "transition from conversation to space_flight is rejected" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.conversation);
    try std.testing.expectError(error.InvalidTransition, sm.transition(.space_flight));
}

test "transition from dead to space_flight is rejected" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.dead);
    try std.testing.expectError(error.InvalidTransition, sm.transition(.space_flight));
}

test "self-transition from title is rejected" {
    var sm = GameStateMachine.init();
    try std.testing.expectError(error.InvalidTransition, sm.transition(.title));
}

test "invalid transition does not change state" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(3, 7);
    try std.testing.expectError(error.InvalidTransition, sm.transition(.dead));
    // State and scene preserved after rejected transition
    try std.testing.expectEqual(State.landed, sm.state);
    try std.testing.expectEqual(@as(u8, 3), sm.current_room.?);
    try std.testing.expectEqual(@as(u8, 7), sm.current_scene.?);
}

// Scene tracking

test "setScene updates room and scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(3, 7);
    try std.testing.expectEqual(@as(u8, 3), sm.current_room.?);
    try std.testing.expectEqual(@as(u8, 7), sm.current_scene.?);
}

test "leaving base clears room and scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(3, 7);
    try sm.transition(.space_flight);
    try std.testing.expect(sm.current_room == null);
    try std.testing.expect(sm.current_scene == null);
}

test "conversation preserves room and scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(3, 7);
    try sm.transition(.conversation);
    try std.testing.expectEqual(@as(u8, 3), sm.current_room.?);
    try std.testing.expectEqual(@as(u8, 7), sm.current_scene.?);
}

test "returning from conversation preserves room and scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(3, 7);
    try sm.transition(.conversation);
    try sm.transition(.landed);
    try std.testing.expectEqual(@as(u8, 3), sm.current_room.?);
    try std.testing.expectEqual(@as(u8, 7), sm.current_scene.?);
}

// Action handling

test "handleAction scene_transition updates current scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(1, 0);
    const action = try sm.handleAction(.{ .scene_transition = 0x0E });
    try std.testing.expect(action == .scene_transition);
    try std.testing.expectEqual(@as(u8, 0x0E), sm.current_scene.?);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "handleAction launch transitions to animation" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    _ = try sm.handleAction(.launch);
    try std.testing.expectEqual(State.animation, sm.state);
}

test "handleAction takeoff transitions to animation" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    _ = try sm.handleAction(.takeoff);
    try std.testing.expectEqual(State.animation, sm.state);
}

test "handleAction bar_conversation transitions to conversation" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    _ = try sm.handleAction(.{ .bar_conversation = 1 });
    try std.testing.expectEqual(State.conversation, sm.state);
}

test "handleAction bartender_conversation transitions to conversation" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    _ = try sm.handleAction(.{ .bartender_conversation = 0 });
    try std.testing.expectEqual(State.conversation, sm.state);
}

test "handleAction none does not change state" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    _ = try sm.handleAction(.none);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "handleAction ship_dealer does not change state" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    _ = try sm.handleAction(.ship_dealer);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "handleAction commodity_exchange does not change state" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    _ = try sm.handleAction(.commodity_exchange);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "handleAction launch from non-landed state returns error" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try std.testing.expectError(error.InvalidTransition, sm.handleAction(.launch));
    try std.testing.expectEqual(State.space_flight, sm.state);
}

// Animation state

test "transition from landed to animation succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.animation);
    try std.testing.expectEqual(State.animation, sm.state);
}

test "transition from space_flight to animation succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.animation);
    try std.testing.expectEqual(State.animation, sm.state);
}

test "transition from animation to space_flight succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.animation);
    try sm.transition(.space_flight);
    try std.testing.expectEqual(State.space_flight, sm.state);
}

test "transition from animation to landed succeeds" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.animation);
    try sm.transition(.landed);
    try std.testing.expectEqual(State.landed, sm.state);
}

test "animation preserves room and scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(3, 7);
    try sm.transition(.animation);
    try std.testing.expectEqual(@as(u8, 3), sm.current_room.?);
    try std.testing.expectEqual(@as(u8, 7), sm.current_scene.?);
}

test "completeAnimation to space_flight clears scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(3, 7);
    _ = try sm.handleAction(.launch);
    try std.testing.expectEqual(State.animation, sm.state);

    try sm.completeAnimation(.space_flight);
    try std.testing.expectEqual(State.space_flight, sm.state);
    try std.testing.expect(sm.current_room == null);
    try std.testing.expect(sm.current_scene == null);
}

test "completeAnimation to landed preserves scene" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.space_flight);
    try sm.transition(.animation);

    sm.setScene(2, 5);
    try sm.completeAnimation(.landed);
    try std.testing.expectEqual(State.landed, sm.state);
    try std.testing.expectEqual(@as(u8, 2), sm.current_room.?);
    try std.testing.expectEqual(@as(u8, 5), sm.current_scene.?);
}

test "completeAnimation from non-animation state returns error" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try std.testing.expectError(error.InvalidTransition, sm.completeAnimation(.space_flight));
}

test "completeAnimation to invalid target returns error" {
    var sm = GameStateMachine.init();
    try sm.transition(.loading);
    try sm.transition(.landed);
    try sm.transition(.animation);
    try std.testing.expectError(error.InvalidTransition, sm.completeAnimation(.dead));
}

// Full gameplay cycle

test "full cycle: title -> loading -> landed -> conversation -> landed -> animation -> space_flight -> combat -> dead -> title" {
    var sm = GameStateMachine.init();
    try std.testing.expectEqual(State.title, sm.state);

    try sm.transition(.loading);
    try sm.transition(.landed);
    sm.setScene(1, 0);

    // Walk to bar, talk to bartender
    _ = try sm.handleAction(.{ .scene_transition = 3 });
    try std.testing.expectEqual(@as(u8, 3), sm.current_scene.?);
    _ = try sm.handleAction(.{ .bartender_conversation = 0 });
    try std.testing.expectEqual(State.conversation, sm.state);

    // End conversation, launch (goes through animation)
    try sm.transition(.landed);
    _ = try sm.handleAction(.launch);
    try std.testing.expectEqual(State.animation, sm.state);

    // Animation completes -> space flight
    try sm.completeAnimation(.space_flight);
    try std.testing.expectEqual(State.space_flight, sm.state);
    try std.testing.expect(sm.current_room == null);

    // Get into combat, die
    try sm.transition(.combat);
    try sm.transition(.dead);
    try sm.transition(.title);
    try std.testing.expectEqual(State.title, sm.state);
}
