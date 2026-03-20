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
const room_assets = privateer.room_assets;
const text_mod = privateer.text;

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
    // Overlay sprites for interactive hotspots (owned pixels)
    current_overlays: []scene_renderer.PositionedSprite,
    // Click regions for the current scene
    click_regions: []click_region.ClickRegion,

    // Title screen state
    title_bg: ?sprite_mod.Sprite,
    title_palette: ?pal.Palette,
    title_font: ?text_mod.Font,

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
        if (self.title_font) |*f| {
            f.deinit();
        }
        freeOverlays(self.allocator, self.current_overlays);
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
/// Each GAMEFLOW sprite INFO byte is a global OPTSHPS.PAK resource index pointing
/// to that hotspot's own scene pack. Sprite 0's header gives the click region bounds.
fn buildClickRegions(allocator: std.mem.Allocator, scene: scene_mod.Scene, optshps_pak: *const pak.PakFile) ![]click_region.ClickRegion {
    var regions: std.ArrayListUnmanaged(click_region.ClickRegion) = .empty;
    defer regions.deinit(allocator);

    for (scene.sprites) |spr| {
        if (spr.effect.len > 0) {
            const action = click_region.parseAction(spr.effect);
            if (action != .none) {
                var x: i16 = 0;
                var y: i16 = 0;
                var w: u16 = 320;
                var h: u16 = 200;

                // Sprite INFO byte = global OPTSHPS.PAK resource index
                // Each hotspot has its own scene pack; sprite 0's header gives bounds
                const resource = optshps_pak.getResource(spr.info) catch null;
                if (resource) |res| {
                    var spr_pack = scene_renderer.parseScenePack(allocator, res) catch null;
                    if (spr_pack) |*sp| {
                        defer sp.deinit();
                        if (sp.getSpriteHeader(0)) |header| {
                            const sw = header.width() catch 0;
                            const sh = header.height() catch 0;
                            if (sw > 0 and sh > 0) {
                                // Sprite screen position when rendered at center (0,0):
                                // top-left = (-x1, -y1)
                                const left: i32 = -@as(i32, header.x1);
                                const top: i32 = -@as(i32, header.y1);
                                x = @intCast(@max(@as(i32, 0), left));
                                y = @intCast(@max(@as(i32, 0), top));
                                w = sw;
                                h = sh;
                            }
                        } else |_| {}
                    }
                }

                try regions.append(allocator, .{
                    .x = x,
                    .y = y,
                    .width = w,
                    .height = h,
                    .sprite_id = spr.info,
                    .action = action,
                });
            }
        }
    }

    return regions.toOwnedSlice(allocator);
}

/// Find which room contains a given scene ID, preferring the current room.
fn findRoomForScene(gameflow: *const scene_mod.GameFlow, scene_id: u8, preferred_room: ?u8) ?u8 {
    // Check preferred room first
    if (preferred_room) |pref| {
        if (gameflow.findRoom(pref)) |room| {
            for (room.scenes) |s| {
                if (s.info == scene_id) return pref;
            }
        }
    }
    // Search all rooms
    for (gameflow.rooms) |room| {
        for (room.scenes) |s| {
            if (s.info == scene_id) return room.info;
        }
    }
    return null;
}

/// Free overlay sprite pixel data and the overlay array itself.
fn freeOverlays(allocator: std.mem.Allocator, overlays: []scene_renderer.PositionedSprite) void {
    for (overlays) |*overlay| {
        var spr = overlay.sprite;
        spr.deinit();
    }
    allocator.free(overlays);
}

/// Load overlay sprites for a scene's interactive hotspots from OPTSHPS.PAK.
/// Each GAMEFLOW sprite INFO byte is a global OPTSHPS.PAK resource index.
/// Sprite 0 of each hotspot's scene pack provides the visual overlay.
fn loadOverlaySprites(allocator: std.mem.Allocator, scene: scene_mod.Scene, optshps_pak: *const pak.PakFile) []scene_renderer.PositionedSprite {
    var overlays: std.ArrayListUnmanaged(scene_renderer.PositionedSprite) = .empty;

    for (scene.sprites) |spr| {
        const resource = optshps_pak.getResource(spr.info) catch continue;
        var spr_pack = scene_renderer.parseScenePack(allocator, resource) catch continue;
        defer spr_pack.deinit();

        // Decode sprite 0 (the visual overlay)
        var decoded = spr_pack.decodeSprite(allocator, 0) catch continue;

        // Overlay sprites are rendered at center (0,0); the header encodes screen position
        overlays.append(allocator, .{
            .sprite = decoded,
            .x = 0,
            .y = 0,
        }) catch {
            decoded.deinit();
            continue;
        };
    }

    return overlays.toOwnedSlice(allocator) catch &.{};
}

/// Load a scene palette from OPTPALS.PAK based on scene ID.
fn loadScenePalette(state: *GameState, scene_id: u8) void {
    // Determine which palette to use
    const room_first_scene: ?u8 = if (state.state_machine.current_room) |rid| blk: {
        const room = state.gameflow.findRoom(rid) orelse break :blk null;
        if (room.scenes.len > 0) break :blk room.scenes[0].info;
        break :blk null;
    } else null;

    const pal_idx = room_assets.paletteIndex(scene_id, room_first_scene) orelse return;

    const optpals_entry = state.tre_index.findEntry(room_assets.OPTPALS_PAK) orelse return;
    const optpals_data = tre.extractFileData(state.tre_data, optpals_entry.offset, optpals_entry.size) catch return;
    var optpals_pak = pak.parse(state.allocator, optpals_data) catch return;
    defer optpals_pak.deinit();

    const pal_resource = optpals_pak.getResource(pal_idx) catch return;
    if (pal_resource.len == pal.PAL_FILE_SIZE) {
        state.palette = pal.parse(pal_resource) catch return;
    }
}

/// Load a landing scene: background from OPTSHPS.PAK, click regions from sprite headers,
/// and palette from OPTPALS.PAK. Scene ID is used directly as the OPTSHPS.PAK resource index.
fn loadLandingScene(state: *GameState, room_id: u8, scene_id: u8) void {
    // Find the room in gameflow
    const room = state.gameflow.findRoom(room_id) orelse return;

    // Find the scene within the room
    var target_scene: ?scene_mod.Scene = null;
    for (room.scenes) |scn| {
        if (scn.info == scene_id) {
            target_scene = scn;
            break;
        }
    }
    const scn = target_scene orelse return;

    // Update state machine
    state.state_machine.setScene(room_id, scene_id);

    // Free previous background
    if (state.current_bg) |*bg| {
        var s = bg.*;
        s.deinit();
        state.current_bg = null;
    }

    // Free previous overlays
    freeOverlays(state.allocator, state.current_overlays);
    state.current_overlays = &.{};

    // Free previous click regions
    state.allocator.free(state.click_regions);
    state.click_regions = &.{};

    // Load scene pack from OPTSHPS.PAK (scene_id = resource index)
    const optshps_entry = state.tre_index.findEntry(room_assets.OPTSHPS_PAK) orelse return;
    const optshps_data = tre.extractFileData(state.tre_data, optshps_entry.offset, optshps_entry.size) catch return;
    var optshps_pak = pak.parse(state.allocator, optshps_data) catch return;
    defer optshps_pak.deinit();

    // Load background from scene pack (scene_id = PAK resource index for background)
    const bg_resource = optshps_pak.getResource(scene_id) catch return;
    var bg_pack = scene_renderer.parseScenePack(state.allocator, bg_resource) catch return;
    defer bg_pack.deinit();

    // Decode background sprite (index 0 in the scene pack)
    state.current_bg = bg_pack.decodeSprite(state.allocator, 0) catch null;

    // Build click regions (each sprite INFO = separate OPTSHPS.PAK resource)
    state.click_regions = buildClickRegions(state.allocator, scn, &optshps_pak) catch &.{};

    // Load overlay sprites for interactive hotspots
    state.current_overlays = loadOverlaySprites(state.allocator, scn, &optshps_pak);

    // Load the appropriate palette from OPTPALS.PAK
    loadScenePalette(state, scene_id);

    std.debug.print("Scene loaded: room={d} scene={d} regions={d} overlays={d}\n", .{ room_id, scene_id, state.click_regions.len, state.current_overlays.len });
}

/// Main per-frame update callback.
fn update(state_ptr: *anyopaque) void {
    const state: *GameState = @ptrCast(@alignCast(state_ptr));
    state.frame_count += 1;

    switch (state.state_machine.state) {
        .title => updateTitle(state),
        .landed => updateLanded(state),
        .conversation => updateConversation(state),
        else => updateDefault(state),
    }
}

fn updateTitle(state: *GameState) void {
    // Render title screen
    if (state.title_bg) |bg| {
        const view = scene_renderer.SceneView{ .background = bg };
        scene_renderer.renderScene(&state.fb, view);

        // Render scaled title menu text over the background
        if (state.title_font) |font| {
            const active_pal = if (state.title_palette) |*tp| tp else &state.palette;
            const text_color = findBrightestColor(active_pal);
            const scale: u16 = 2;

            const menu_items = [_][]const u8{
                "Play Privateer",
                "Load a Saved Game",
            };
            const center_x: u16 = framebuffer_mod.WIDTH / 2;
            const scaled_line_h = font.line_height * scale;
            const line_spacing: u16 = scaled_line_h + 4;
            const total_h: u16 = @intCast(menu_items.len * line_spacing);
            const start_y: u16 = (framebuffer_mod.HEIGHT -| total_h) / 2 + 30;

            var y: u16 = start_y;
            for (menu_items) |item| {
                const text_w = font.measureTextScaled(item, scale);
                const x = center_x -| (text_w / 2);
                _ = font.drawTextScaled(&state.fb, x, y, item, text_color, scale);
                y += line_spacing;
            }
        }

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

    // Mouse click or Enter/Space/Escape transitions to the game (title → loading → landed)
    // Ignore modifier keys (Cmd/Shift/etc.) so screenshot shortcuts don't advance the title
    const key = state.window.key_pressed;
    const is_action_key = (key == privateer.sdl.raw.SDLK_RETURN or
        key == privateer.sdl.raw.SDLK_SPACE or
        key == privateer.sdl.raw.SDLK_ESCAPE or
        key == privateer.sdl.raw.SDLK_KP_ENTER);
    if (state.window.mouse_clicked or is_action_key) {
        state.state_machine.transition(.loading) catch return;
        state.state_machine.transition(.landed) catch return;

        // Load the first room/scene from gameflow as the initial landing
        if (state.gameflow.rooms.len > 0) {
            const room = state.gameflow.rooms[0];
            if (room.scenes.len > 0) {
                loadLandingScene(state, room.info, room.scenes[0].info);
            }
        }
    }
}

fn updateLanded(state: *GameState) void {
    // Render current scene with overlay sprites
    if (state.current_bg) |bg| {
        const view = scene_renderer.SceneView{
            .background = bg,
            .sprites = state.current_overlays,
        };
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
                    // Find the room containing the target scene (prefer current room)
                    const room_id = findRoomForScene(&state.gameflow, target, state.state_machine.current_room);
                    if (room_id) |rid| {
                        loadLandingScene(state, rid, target);
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
        freeOverlays(state.allocator, state.current_overlays);
        state.current_overlays = &.{};
    }
}

fn updateConversation(state: *GameState) void {
    // Render the current scene as background during conversation
    if (state.current_bg) |bg| {
        const view = scene_renderer.SceneView{
            .background = bg,
            .sprites = state.current_overlays,
        };
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

    // Click or key press returns to the landed state
    if (state.window.mouse_clicked or state.window.key_pressed != 0) {
        state.state_machine.transition(.landed) catch return;
        // Reload the scene (room/scene preserved by state machine)
        if (state.state_machine.current_room) |room_id| {
            if (state.state_machine.current_scene) |scene_id| {
                loadLandingScene(state, room_id, scene_id);
            }
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

/// Find the brightest color in a palette (by luminance), skipping index 0 (transparent/black).
/// Returns the palette index that will be most visible for text rendering.
fn findBrightestColor(palette: *const pal.Palette) u8 {
    var best_idx: u8 = 15; // fallback
    var best_lum: u32 = 0;
    for (1..pal.COLOR_COUNT) |i| {
        const c = palette.colors[i];
        // Approximate luminance: 2*R + 5*G + B (weighted for human perception, avoids floats)
        const lum: u32 = @as(u32, c.r) * 2 + @as(u32, c.g) * 5 + @as(u32, c.b);
        if (lum > best_lum) {
            best_lum = lum;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
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

    // Try to load DEMOFONT.SHP for title screen text
    var title_font: ?text_mod.Font = null;
    if (tre_index.findEntry("DEMOFONT.SHP")) |font_entry| {
        const font_data = tre.extractFileData(tre_data, font_entry.offset, font_entry.size) catch null;
        if (font_data) |fd| {
            title_font = text_mod.Font.load(allocator, fd, 0) catch null;
            if (title_font != null) {
                std.debug.print("DEMOFONT.SHP loaded ({d} glyphs)\n", .{title_font.?.glyphCount()});
            }
        }
    }
    if (title_font == null) {
        std.debug.print("Warning: Could not load DEMOFONT.SHP\n", .{});
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
        .current_overlays = &.{},
        .click_regions = &.{},
        .title_bg = title_bg,
        .title_palette = title_palette,
        .title_font = title_font,
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
