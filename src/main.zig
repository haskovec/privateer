const std = @import("std");
const privateer = @import("privateer");

const iso9660 = privateer.iso9660;
const tre = privateer.tre;
const pak = privateer.pak;
const pal = privateer.pal;
const scene_mod = privateer.scene;
const scene_renderer = privateer.scene_renderer;
const framebuffer_mod = privateer.framebuffer;
const viewport_mod = privateer.viewport;
const game_state_mod = privateer.game_state;
const click_region = privateer.click_region;
const sprite_mod = privateer.sprite;

/// Holds all live game data and rendering state for the main loop.
const GameState = struct {
    allocator: std.mem.Allocator,

    // Raw game data (owned)
    game_dat: []const u8,
    // Slice into game_dat for the TRE archive
    tre_data: []const u8,
    // Indexed TRE for fast lookups
    tre_index: tre.TreIndex,

    // Rendering
    fb: framebuffer_mod.Framebuffer,
    palette: pal.Palette,
    renderer: *privateer.sdl.raw.SDL_Renderer,
    window: *privateer.window.Window,
    viewport_mode: viewport_mod.Mode,

    // Scene system
    gameflow: scene_mod.GameFlow,
    state_machine: game_state_mod.GameStateMachine,

    // Currently decoded background sprite (owned pixels)
    current_bg: ?sprite_mod.Sprite,
    // Click regions for the current scene
    click_regions: []click_region.ClickRegion,

    // Title screen state
    title_bg: ?sprite_mod.Sprite,
    title_palette: ?pal.Palette,

    frame_count: u64,

    fn deinit(self: *GameState) void {
        if (self.current_bg) |*bg| {
            var s = bg.*;
            s.deinit();
        }
        if (self.title_bg) |*bg| {
            var s = bg.*;
            s.deinit();
        }
        self.allocator.free(self.click_regions);
        self.gameflow.deinit();
        self.tre_index.deinit();
        self.allocator.free(self.game_dat);
    }
};

/// Convert window pixel coordinates to framebuffer (320x200) coordinates.
fn windowToFb(win: *const privateer.window.Window, wx: f32, wy: f32, vp_mode: viewport_mod.Mode) struct { x: i16, y: i16 } {
    const vp = viewport_mod.compute(vp_mode, @intCast(win.width), @intCast(win.height));
    // Map window coords into viewport-relative coords, then scale to 320x200
    const rx = (wx - vp.x) / vp.w * @as(f32, framebuffer_mod.WIDTH);
    const ry = (wy - vp.y) / vp.h * @as(f32, framebuffer_mod.HEIGHT);
    return .{
        .x = @intFromFloat(std.math.clamp(rx, -1000, 1000)),
        .y = @intFromFloat(std.math.clamp(ry, -1000, 1000)),
    };
}

/// Load a scene background sprite from a PAK file in the TRE.
fn loadSceneBackground(allocator: std.mem.Allocator, tre_data: []const u8, index: *const tre.TreIndex, pak_name: []const u8, resource_idx: usize) !struct { sprite: sprite_mod.Sprite, palette: ?pal.Palette } {
    const entry = index.findEntry(pak_name) orelse return error.FileNotFound;
    const file_data = try tre.extractFileData(tre_data, entry.offset, entry.size);
    var pak_file = try pak.parse(allocator, file_data);
    defer pak_file.deinit();

    // Check if resource 0 is a palette (772 bytes)
    var scene_palette: ?pal.Palette = null;
    if (pak_file.resourceCount() > 0) {
        const r0 = try pak_file.getResource(0);
        if (r0.len == pal.PAL_FILE_SIZE) {
            scene_palette = try pal.parse(r0);
        }
    }

    const resource = try pak_file.getResource(resource_idx);
    var pack = try scene_renderer.parseScenePack(allocator, resource);
    defer pack.deinit();

    const spr = try pack.decodeSprite(allocator, 0);
    return .{ .sprite = spr, .palette = scene_palette };
}

/// Build click regions from a scene's sprite EFCT data.
fn buildClickRegions(allocator: std.mem.Allocator, scene: scene_mod.Scene) ![]click_region.ClickRegion {
    var regions: std.ArrayListUnmanaged(click_region.ClickRegion) = .empty;
    defer regions.deinit(allocator);

    for (scene.sprites) |spr| {
        if (spr.effect.len > 0) {
            const action = click_region.parseAction(spr.effect);
            if (action != .none) {
                // Create a click region from the sprite info byte
                // The info byte encodes a rough screen position/area
                // For now, create reasonable clickable areas based on sprite index
                try regions.append(allocator, .{
                    .x = 0,
                    .y = 0,
                    .width = 320,
                    .height = 200,
                    .sprite_id = spr.info,
                    .action = action,
                });
            }
        }
    }

    return regions.toOwnedSlice(allocator);
}

/// Try to load a landing scene for the given room/scene from GAMEFLOW.
fn loadLandingScene(state: *GameState, room_id: u8, scene_id: u8) void {
    // Find the room in gameflow
    const room = state.gameflow.findRoom(room_id) orelse return;

    // Find the scene within the room
    for (room.scenes) |scn| {
        if (scn.info == scene_id) {
            // Update state machine
            state.state_machine.setScene(room_id, scene_id);

            // Build click regions from this scene's sprites
            state.allocator.free(state.click_regions);
            state.click_regions = buildClickRegions(state.allocator, scn) catch &.{};

            break;
        }
    }
}

/// Main per-frame update callback.
fn update(state_ptr: *anyopaque) void {
    const state: *GameState = @ptrCast(@alignCast(state_ptr));
    state.frame_count += 1;

    switch (state.state_machine.state) {
        .title => updateTitle(state),
        .landed => updateLanded(state),
        else => updateDefault(state),
    }
}

fn updateTitle(state: *GameState) void {
    // Render title screen
    if (state.title_bg) |bg| {
        const view = scene_renderer.SceneView{ .background = bg };
        scene_renderer.renderScene(&state.fb, view);

        if (state.title_palette) |tp| {
            state.fb.applyPalette(&tp);
        } else {
            state.fb.applyPalette(&state.palette);
        }
    } else {
        // No title background loaded — render a basic screen
        state.fb.clear(0);
        state.fb.applyPalette(&state.palette);
    }

    state.fb.presentWithMode(
        state.renderer,
        @intCast(state.window.width),
        @intCast(state.window.height),
        state.viewport_mode,
    );

    // Any click or key press transitions to the game (title → loading → landed)
    if (state.window.mouse_clicked or state.window.key_pressed != 0) {
        state.state_machine.transition(.loading) catch return;
        state.state_machine.transition(.landed) catch return;

        // Load the first room/scene from gameflow as the initial landing
        if (state.gameflow.rooms.len > 0) {
            const room = state.gameflow.rooms[0];
            if (room.scenes.len > 0) {
                loadLandingScene(state, room.info, room.scenes[0].info);
            }
        }

        // Try to load a landing scene background
        loadLandedBackground(state);
    }
}

/// Try to load a background for the current landed scene.
fn loadLandedBackground(state: *GameState) void {
    // Free previous background
    if (state.current_bg) |*bg| {
        var s = bg.*;
        s.deinit();
        state.current_bg = null;
    }

    // Try several known PAK files that contain base/landing scenes
    const pak_names = [_][]const u8{
        "LTOBASES.PAK",
        "CU.PAK",
        "OPTSHPS.PAK",
    };

    for (pak_names) |pak_name| {
        const result = loadSceneBackground(
            state.allocator,
            state.tre_data,
            &state.tre_index,
            pak_name,
            1,
        ) catch continue;

        state.current_bg = result.sprite;
        if (result.palette) |p| {
            state.palette = p;
        }
        return;
    }
}

fn updateLanded(state: *GameState) void {
    // Render current scene
    if (state.current_bg) |bg| {
        const view = scene_renderer.SceneView{ .background = bg };
        scene_renderer.renderScene(&state.fb, view);
    } else {
        state.fb.clear(0);
    }

    state.fb.applyPalette(&state.palette);
    state.fb.presentWithMode(
        state.renderer,
        @intCast(state.window.width),
        @intCast(state.window.height),
        state.viewport_mode,
    );

    // Handle mouse clicks for scene transitions
    if (state.window.mouse_clicked) {
        const fb_pos = windowToFb(state.window, state.window.mouse_x, state.window.mouse_y, state.viewport_mode);
        const hit = click_region.hitTest(state.click_regions, fb_pos.x, fb_pos.y);
        if (hit) |result| {
            const action = state.state_machine.handleAction(result.region.action) catch return;
            switch (action) {
                .scene_transition => |target| {
                    // Scene changed — reload background
                    if (state.state_machine.current_room) |room_id| {
                        loadLandingScene(state, room_id, target);
                        loadLandedBackground(state);
                    }
                },
                .launch, .takeoff => {
                    // Transition to space (simplified — skip animation for now)
                    state.state_machine.completeAnimation(.space_flight) catch {};
                },
                else => {},
            }
        }
    }

    // Escape key returns to title
    if (state.window.key_pressed == privateer.sdl.raw.SDLK_ESCAPE) {
        // Reset to title
        state.state_machine = game_state_mod.GameStateMachine.init();
        if (state.current_bg) |*bg| {
            var s = bg.*;
            s.deinit();
            state.current_bg = null;
        }
    }
}

fn updateDefault(state: *GameState) void {
    state.fb.clear(0);
    state.fb.applyPalette(&state.palette);
    state.fb.presentWithMode(
        state.renderer,
        @intCast(state.window.width),
        @intCast(state.window.height),
        state.viewport_mode,
    );
}

/// Load all game data and initialize the game state.
fn initGameState(
    allocator: std.mem.Allocator,
    cfg: *const privateer.config.Config,
    win: *privateer.window.Window,
) !*GameState {
    // Build path to GAME.DAT
    const dat_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "GAME.DAT", .{cfg.data_dir});
    defer allocator.free(dat_path);

    std.debug.print("Loading {s}...\n", .{dat_path});

    // Load GAME.DAT
    const file = try std.fs.cwd().openFile(dat_path, .{});
    defer file.close();
    const stat = try file.stat();
    const game_dat = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(game_dat);
    const bytes_read = try file.readAll(game_dat);
    if (bytes_read != stat.size) return error.IncompleteRead;

    std.debug.print("GAME.DAT loaded ({d} bytes)\n", .{game_dat.len});

    // Extract PRIV.TRE from the ISO image
    const pvd = try iso9660.readPvd(game_dat);
    const tre_info = try iso9660.findFile(allocator, game_dat, pvd, "PRIV.TRE");
    const tre_data = try iso9660.readFileData(game_dat, tre_info.lba, tre_info.size);

    std.debug.print("PRIV.TRE found ({d} bytes)\n", .{tre_data.len});

    // Build TRE index for fast lookups
    var tre_index = try tre.TreIndex.build(allocator, tre_data);
    errdefer tre_index.deinit();

    std.debug.print("TRE index built ({d} entries)\n", .{tre_index.count()});

    // Load main palette
    var palette: pal.Palette = undefined;
    if (tre_index.findEntry("PCMAIN.PAL")) |pal_entry| {
        const pal_data = try tre.extractFileData(tre_data, pal_entry.offset, pal_entry.size);
        palette = try pal.parse(pal_data);
        std.debug.print("PCMAIN.PAL loaded\n", .{});
    } else {
        // Fallback: all-black palette
        @memset(&palette.colors, pal.Color{ .r = 0, .g = 0, .b = 0 });
        palette.header = .{ 0, 0, 0, 0 };
        std.debug.print("Warning: PCMAIN.PAL not found, using black palette\n", .{});
    }

    // Load GAMEFLOW.IFF
    var gameflow: scene_mod.GameFlow = undefined;
    if (tre_index.findEntry("GAMEFLOW.IFF")) |gf_entry| {
        const gf_data = try tre.extractFileData(tre_data, gf_entry.offset, gf_entry.size);
        gameflow = try scene_mod.parseGameFlow(allocator, gf_data);
        std.debug.print("GAMEFLOW.IFF loaded ({d} rooms, {d} scenes)\n", .{ gameflow.rooms.len, gameflow.totalScenes() });
    } else {
        // Empty gameflow
        gameflow = .{ .rooms = &.{}, .allocator = allocator };
        std.debug.print("Warning: GAMEFLOW.IFF not found\n", .{});
    }

    // Create framebuffer and SDL texture
    var fb = framebuffer_mod.Framebuffer.create();
    try fb.createTexture(win.renderer);

    // Try to load a title screen from OPTSHPS.PAK
    var title_bg: ?sprite_mod.Sprite = null;
    var title_palette: ?pal.Palette = null;
    const title_result = loadSceneBackground(allocator, tre_data, &tre_index, "OPTSHPS.PAK", 1) catch null;
    if (title_result) |result| {
        title_bg = result.sprite;
        title_palette = result.palette;
        std.debug.print("Title screen loaded from OPTSHPS.PAK\n", .{});
    } else {
        std.debug.print("Warning: Could not load title screen\n", .{});
    }

    // Allocate GameState on the heap (too large for stack)
    const state = try allocator.create(GameState);
    state.* = .{
        .allocator = allocator,
        .game_dat = game_dat,
        .tre_data = tre_data,
        .tre_index = tre_index,
        .fb = fb,
        .palette = palette,
        .renderer = win.renderer,
        .window = win,
        .viewport_mode = cfg.settings.viewport_mode,
        .gameflow = gameflow,
        .state_machine = game_state_mod.GameStateMachine.init(),
        .current_bg = null,
        .click_regions = &.{},
        .title_bg = title_bg,
        .title_palette = title_palette,
        .frame_count = 0,
    };

    return state;
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

    // Initialize game state (loads GAME.DAT, PRIV.TRE, palettes, scenes)
    var state = initGameState(allocator, &cfg, &win) catch |err| {
        std.debug.print("Failed to load game data: {}\n", .{err});
        std.debug.print("Make sure GAME.DAT is in your data directory: {s}\n", .{cfg.data_dir});
        std.debug.print("Set PRIVATEER_DATA environment variable or edit privateer.json\n", .{});
        return err;
    };
    defer {
        state.fb.destroy();
        state.deinit();
        allocator.destroy(state);
    }

    std.debug.print("Game initialized. Starting main loop...\n", .{});

    win.runLoop(@ptrCast(state), &update);

    std.debug.print("Privateer engine shutting down after {d} frames.\n", .{state.frame_count});
}

test "main module loads engine" {
    _ = privateer;
    try std.testing.expect(true);
}
