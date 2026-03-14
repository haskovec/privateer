//! Privateer - Wing Commander: Privateer reimplementation
//! Core engine library root module.

const std = @import("std");

// Foundation
pub const testing_helpers = @import("testing.zig");
pub const sdl = @import("sdl.zig");
pub const config = @import("config.zig");

// File format parsers
pub const iso9660 = @import("formats/iso9660.zig");
pub const tre = @import("formats/tre.zig");
pub const iff = @import("formats/iff.zig");
pub const pal = @import("formats/pal.zig");
pub const sprite = @import("formats/sprite.zig");
pub const shp = @import("formats/shp.zig");
pub const pak = @import("formats/pak.zig");
pub const voc = @import("formats/voc.zig");
pub const vpk = @import("formats/vpk.zig");
pub const music = @import("formats/music.zig");

// Rendering pipeline
pub const png = @import("render/png.zig");
pub const render = @import("render/render.zig");
pub const window = @import("render/window.zig");
pub const framebuffer = @import("render/framebuffer.zig");
pub const upscale = @import("render/upscale.zig");
pub const viewport = @import("render/viewport.zig");
pub const text = @import("render/text.zig");
pub const scene_renderer = @import("render/scene_renderer.zig");

// Game systems
pub const scene = @import("game/scene.zig");
pub const click_region = @import("game/click_region.zig");
pub const game_state = @import("game/game_state.zig");
pub const midgame = @import("game/midgame.zig");
pub const universe = @import("game/universe.zig");
pub const bases = @import("game/bases.zig");
pub const nav_graph = @import("game/nav_graph.zig");
pub const nav_map = @import("game/nav_map.zig");

// Economy & Trading
pub const commodities = @import("economy/commodities.zig");
pub const exchange = @import("economy/exchange.zig");
pub const ship_dealer = @import("economy/ship_dealer.zig");
pub const landing_fees = @import("economy/landing_fees.zig");

// Flight systems
pub const flight_physics = @import("flight/flight_physics.zig");
pub const autopilot = @import("flight/autopilot.zig");
pub const jump_drive = @import("flight/jump_drive.zig");

// Combat
pub const weapons = @import("combat/weapons.zig");
pub const projectiles = @import("combat/projectiles.zig");
pub const damage = @import("combat/damage.zig");
pub const ai = @import("combat/ai.zig");
pub const spawning = @import("combat/spawning.zig");
pub const explosions = @import("combat/explosions.zig");
pub const tractor_cargo = @import("combat/tractor_cargo.zig");

// Cockpit & HUD
pub const cockpit = @import("cockpit/cockpit.zig");
pub const mfd = @import("cockpit/mfd.zig");
pub const radar = @import("cockpit/radar.zig");
pub const damage_display = @import("cockpit/damage_display.zig");
pub const targeting = @import("cockpit/targeting.zig");
pub const messages = @import("cockpit/messages.zig");

// CLI tools
pub const extract = @import("cli/extract.zig");
pub const validate = @import("cli/validate.zig");
pub const palette_viewer = @import("cli/palette_viewer.zig");

// Tests
pub const integration_tests = @import("integration_tests.zig");

test "engine module loads" {
    try std.testing.expect(true);
}

test {
    // Pull in tests from all submodules
    std.testing.refAllDecls(@This());
}
