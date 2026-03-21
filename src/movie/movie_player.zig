//! Movie player integration for Wing Commander: Privateer intro cinematic.
//!
//! Orchestrates the full opening cinematic sequence by coordinating:
//!   - Scene sequencing from OPENING.PAK playlist (mid1a → mid1f)
//!   - Frame-by-frame FORM:MOVI script execution via MovieRenderer
//!   - SPED-based timing for ACTS block advancement
//!   - Fade-to-black transition at completion
//!
//! Called once per game frame from the main loop. Returns status to
//! indicate whether playback is ongoing, fading, or complete.

const std = @import("std");
const movie_mod = @import("movie.zig");
const movie_renderer_mod = @import("movie_renderer.zig");
const opening_mod = @import("opening.zig");
const tre_mod = @import("../formats/tre.zig");
const pal_mod = @import("../formats/pal.zig");
const framebuffer_mod = @import("../render/framebuffer.zig");

/// Playback status returned by the movie player.
pub const Status = enum {
    /// Movie is actively playing scenes.
    playing,
    /// Fading to black before transitioning to title.
    fade_out,
    /// Movie playback complete (or skipped). Transition to title.
    done,
};

/// DOS timer tick rate (≈70 Hz) used for SPED timing conversion.
const DOS_TICK_HZ: u32 = 70;

/// Game loop frame rate.
const GAME_FPS: u32 = 60;

/// Number of frames for fade-to-black at movie end (~0.5s at 60fps).
pub const FADE_FRAMES: u32 = 30;

pub const MoviePlayer = struct {
    allocator: std.mem.Allocator,

    // Scene playlist (owned)
    sequence: opening_mod.OpeningSequence,
    current_scene_idx: usize,

    // Current scene state
    script: ?movie_mod.MovieScript,
    renderer: ?movie_renderer_mod.MovieRenderer,
    current_acts_idx: usize,

    // Timing: integer ratio accumulator for DOS tick → game frame conversion.
    // Each game frame adds DOS_TICK_HZ to tick_accum.
    // When tick_accum >= tick_threshold (= sped * GAME_FPS), advance ACTS block.
    tick_accum: u32,
    tick_threshold: u32,

    // TRE data (borrowed — lifetime must exceed MoviePlayer)
    tre_data: []const u8,
    tre_index: *const tre_mod.TreIndex,

    // Framebuffer (borrowed)
    fb: *framebuffer_mod.Framebuffer,

    // Current palette extracted from movie PAK files
    current_palette: ?pal_mod.Palette,

    // Playback status
    status: Status,

    // Fade-out progress counter
    fade_frame: u32,

    /// Initialize the movie player with a parsed opening sequence.
    /// Takes ownership of `sequence` (will be freed on deinit).
    pub fn init(
        allocator: std.mem.Allocator,
        sequence: opening_mod.OpeningSequence,
        tre_data: []const u8,
        tre_index: *const tre_mod.TreIndex,
        fb: *framebuffer_mod.Framebuffer,
    ) MoviePlayer {
        var player = MoviePlayer{
            .allocator = allocator,
            .sequence = sequence,
            .current_scene_idx = 0,
            .script = null,
            .renderer = null,
            .current_acts_idx = 0,
            .tick_accum = 0,
            .tick_threshold = 0,
            .tre_data = tre_data,
            .tre_index = tre_index,
            .fb = fb,
            .current_palette = null,
            .status = .playing,
            .fade_frame = 0,
        };

        // No scenes → immediately done
        if (sequence.sceneCount() == 0) {
            player.status = .done;
            return player;
        }

        // Load the first scene
        player.loadCurrentScene();

        return player;
    }

    /// Release all owned resources.
    pub fn deinit(self: *MoviePlayer) void {
        if (self.script) |*s| s.deinit();
        if (self.renderer) |*r| r.deinit();
        self.sequence.deinit();
    }

    /// Get the current palette for framebuffer presentation.
    pub fn getPalette(self: *const MoviePlayer) ?pal_mod.Palette {
        return self.current_palette;
    }

    /// Get the fade multiplier for the current frame.
    /// Returns 1.0 during normal playback, decreasing to 0.0 during fade-out.
    pub fn getFade(self: *const MoviePlayer) f32 {
        if (self.status == .fade_out) {
            if (self.fade_frame >= FADE_FRAMES) return 0.0;
            const progress: f32 = @as(f32, @floatFromInt(self.fade_frame)) /
                @as(f32, @floatFromInt(FADE_FRAMES));
            return 1.0 - progress;
        }
        return 1.0;
    }

    /// Skip the intro movie (e.g., Escape key). Sets status to done immediately.
    pub fn skip(self: *MoviePlayer) void {
        self.status = .done;
    }

    /// Advance the movie by one game frame.
    /// Call once per frame from the game loop.
    pub fn update(self: *MoviePlayer) void {
        switch (self.status) {
            .playing => self.updatePlaying(),
            .fade_out => self.updateFadeOut(),
            .done => {},
        }
    }

    fn updatePlaying(self: *MoviePlayer) void {
        const script = self.script orelse {
            self.status = .done;
            return;
        };
        var renderer = &(self.renderer orelse {
            self.status = .done;
            return;
        });

        // Execute current ACTS block (render sprites to framebuffer)
        if (self.current_acts_idx < script.acts_blocks.len) {
            renderer.executeActsBlock(script.acts_blocks[self.current_acts_idx]) catch |err| {
                std.debug.print("  ACTS[{d}] render error: {}\n", .{ self.current_acts_idx, err });
            };
        }

        // Advance timing
        self.tick_accum += DOS_TICK_HZ;
        if (self.tick_threshold > 0 and self.tick_accum >= self.tick_threshold) {
            self.tick_accum -= self.tick_threshold;
            self.current_acts_idx += 1;

            // Check if current scene is complete
            if (self.current_acts_idx >= script.acts_blocks.len) {
                self.advanceScene();
            }
        }
    }

    fn updateFadeOut(self: *MoviePlayer) void {
        self.fade_frame += 1;
        if (self.fade_frame >= FADE_FRAMES) {
            self.status = .done;
        }
    }

    fn advanceScene(self: *MoviePlayer) void {
        // Clean up current scene
        if (self.script) |*s| {
            s.deinit();
            self.script = null;
        }
        if (self.renderer) |*r| {
            r.deinit();
            self.renderer = null;
        }

        self.current_scene_idx += 1;
        self.current_acts_idx = 0;
        self.tick_accum = 0;

        if (self.current_scene_idx >= self.sequence.sceneCount()) {
            // All scenes played — start fade-out
            self.status = .fade_out;
            self.fade_frame = 0;
            return;
        }

        self.loadCurrentScene();
    }

    fn loadCurrentScene(self: *MoviePlayer) void {
        // Get TRE path for current scene name
        const path = (self.sequence.getSceneTrePath(self.allocator, self.current_scene_idx) catch {
            self.advanceScene();
            return;
        }) orelse {
            self.advanceScene();
            return;
        };
        defer self.allocator.free(path);

        // Find in TRE archive (findEntry matches by basename, so extract it)
        const basename = std.fs.path.basename(path);
        const entry = self.tre_index.findEntry(basename) orelse {
            self.advanceScene();
            return;
        };
        const movi_data = tre_mod.extractFileData(self.tre_data, entry.offset, entry.size) catch {
            self.advanceScene();
            return;
        };

        // Parse FORM:MOVI script
        var script = movie_mod.parse(self.allocator, movi_data) catch {
            self.advanceScene();
            return;
        };

        // Set up timing from SPED
        self.tick_threshold = @as(u32, script.frame_speed_ticks) * GAME_FPS;
        self.tick_accum = 0;
        self.current_acts_idx = 0;

        // Create renderer for this scene's file references
        var renderer = movie_renderer_mod.MovieRenderer.init(
            self.allocator,
            self.fb,
            script.file_references.len,
        ) catch {
            script.deinit();
            self.advanceScene();
            return;
        };

        // Clear screen if the script requests it
        if (script.clear_screen) {
            renderer.clearScreen();
        }

        // Load PAK files referenced by the script (use basename for TRE lookup)
        var paks_loaded: usize = 0;
        for (script.file_references, 0..) |ref_path, i| {
            const ref_basename = std.fs.path.basename(ref_path);
            if (self.tre_index.findEntry(ref_basename)) |ref_entry| {
                const pak_data = tre_mod.extractFileData(
                    self.tre_data,
                    ref_entry.offset,
                    ref_entry.size,
                ) catch {
                    std.debug.print("  PAK[{d}] {s}: extract failed\n", .{ i, ref_basename });
                    continue;
                };
                renderer.loadPak(i, pak_data) catch {
                    std.debug.print("  PAK[{d}] {s}: parse failed ({d} bytes)\n", .{ i, ref_basename, pak_data.len });
                    continue;
                };
                paks_loaded += 1;
            } else {
                std.debug.print("  PAK[{d}] {s}: not found in TRE\n", .{ i, ref_basename });
            }
        }

        // Extract palette from renderer (first loaded PAK with a palette)
        if (renderer.getPalette()) |pal_val| {
            self.current_palette = pal_val;
            std.debug.print("  Palette loaded, {d}/{d} PAKs loaded\n", .{ paks_loaded, script.file_references.len });
        } else {
            std.debug.print("  WARNING: No palette found, {d}/{d} PAKs loaded\n", .{ paks_loaded, script.file_references.len });
        }

        self.script = script;
        self.renderer = renderer;

        std.debug.print("Movie scene: {s} ({d} ACTS, SPED={d})\n", .{
            self.sequence.getSceneName(self.current_scene_idx) orelse "?",
            script.acts_blocks.len,
            script.frame_speed_ticks,
        });
    }
};

// --- Tests ---

test "MoviePlayer with empty sequence is immediately done" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    // Empty sequence — tre_index is never accessed, use undefined
    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    try std.testing.expectEqual(Status.done, player.status);
}

test "MoviePlayer skip sets status to done" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    player.skip();
    try std.testing.expectEqual(Status.done, player.status);
}

test "MoviePlayer getFade returns 1.0 when not fading" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    try std.testing.expectEqual(@as(f32, 1.0), player.getFade());
}

test "MoviePlayer fade_out decreases fade over time" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    // Manually set fade_out state
    player.status = .fade_out;
    player.fade_frame = 0;

    // At start: full brightness
    try std.testing.expectEqual(@as(f32, 1.0), player.getFade());

    // Halfway through
    player.fade_frame = FADE_FRAMES / 2;
    const half_fade = player.getFade();
    try std.testing.expect(half_fade < 1.0);
    try std.testing.expect(half_fade > 0.0);

    // At end: fully black
    player.fade_frame = FADE_FRAMES;
    try std.testing.expectEqual(@as(f32, 0.0), player.getFade());
}

test "MoviePlayer update in done state is a no-op" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    // Already done — update should not change state
    player.update();
    try std.testing.expectEqual(Status.done, player.status);
}

test "MoviePlayer fade_out completes after FADE_FRAMES updates" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    // Manually set fade_out state
    player.status = .fade_out;
    player.fade_frame = 0;

    // Run FADE_FRAMES updates
    for (0..FADE_FRAMES) |_| {
        try std.testing.expectEqual(Status.fade_out, player.status);
        player.update();
    }

    // Should now be done
    try std.testing.expectEqual(Status.done, player.status);
}
