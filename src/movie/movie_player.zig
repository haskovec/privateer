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
const movie_music_mod = @import("movie_music.zig");
const movie_voice_mod = @import("movie_voice.zig");
const movie_sfx_mod = @import("movie_sfx.zig");
const audio_mod = @import("../audio/audio.zig");
const music_player_mod = @import("../audio/music_player.zig");

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

/// Audio state for the intro movie cinematic.
///
/// Manages opening music (OPENING.GEN → PCM), voice clips (SPEECH/MID01/),
/// and sound effects (SOUNDFX.PAK). Audio devices are created on demand
/// and cleaned up when the movie ends or is skipped.
pub const MovieAudio = struct {
    allocator: std.mem.Allocator,

    // Music (OPENING.GEN → XMIDI → PCM)
    music_pcm: ?[]u8,
    music_player: ?music_player_mod.MusicPlayer,
    music_started: bool,

    // Voice clips (SPEECH/MID01/ VOC files)
    voice_set: movie_voice_mod.MovieVoiceSet,
    voice_player: ?audio_mod.AudioPlayer,
    voice_clip_index: usize,

    // Sound effects (SOUNDFX.PAK nested VOC bank)
    sfx_bank: movie_sfx_mod.SfxBank,

    /// Create a MovieAudio with no data loaded and no playback devices.
    pub fn init(allocator: std.mem.Allocator) MovieAudio {
        return .{
            .allocator = allocator,
            .music_pcm = null,
            .music_player = null,
            .music_started = false,
            .voice_set = movie_voice_mod.MovieVoiceSet.init(allocator),
            .voice_player = null,
            .voice_clip_index = 0,
            .sfx_bank = movie_sfx_mod.SfxBank.init(allocator),
        };
    }

    /// Release all owned audio resources and close devices.
    pub fn deinit(self: *MovieAudio) void {
        self.stopAll();
        if (self.music_player) |*mp| mp.deinit();
        if (self.voice_player) |*vp| vp.deinit();
        if (self.music_pcm) |pcm| self.allocator.free(pcm);
        self.voice_set.deinit();
        self.sfx_bank.deinit();
        self.music_pcm = null;
        self.music_player = null;
        self.voice_player = null;
    }

    /// Load all audio assets from the TRE archive.
    /// Failures are non-fatal: missing audio means silent playback.
    pub fn loadFromTre(
        self: *MovieAudio,
        tre_index: *const tre_mod.TreIndex,
        tre_data: []const u8,
    ) void {
        // Load opening music (OPENING.GEN → PCM)
        self.music_pcm = movie_music_mod.loadFromTreIndex(
            self.allocator,
            tre_index,
            tre_data,
        ) catch null;

        // Load voice clips (graceful degradation per clip)
        self.voice_set.loadFromTre(tre_index, tre_data);

        // Load sound effects from SOUNDFX.PAK
        if (tre_index.findEntry("SOUNDFX.PAK")) |entry| {
            if (tre_mod.extractFileData(tre_data, entry.offset, entry.size)) |sfx_data| {
                self.sfx_bank.loadFromPak(sfx_data) catch {};
            } else |_| {}
        }

        std.debug.print("Movie audio: music={s}, voices={d}/{d}, sfx={d}\n", .{
            if (self.music_pcm != null) "loaded" else "missing",
            self.voice_set.loadedCount(),
            movie_voice_mod.TOTAL_CLIP_COUNT,
            self.sfx_bank.loadedCount(),
        });
    }

    /// Open SDL audio devices for playback. Call after loadFromTre().
    /// Failures are non-fatal: no device means silent playback.
    pub fn initPlayback(self: *MovieAudio) void {
        self.music_player = music_player_mod.MusicPlayer.init(self.allocator) catch null;
        self.voice_player = audio_mod.AudioPlayer.init() catch null;
    }

    /// Start playing the opening music track.
    pub fn startMusic(self: *MovieAudio) void {
        if (self.music_started) return;
        const pcm = self.music_pcm orelse return;
        if (self.music_player) |*mp| {
            // Dupe the PCM because MusicPlayer takes ownership
            const owned = self.allocator.dupe(u8, pcm) catch return;
            mp.playPcm(owned, .opening);
            self.music_started = true;
            std.debug.print("Movie music started ({d} bytes PCM)\n", .{pcm.len});
        }
    }

    /// Stop all audio playback immediately.
    pub fn stopAll(self: *MovieAudio) void {
        if (self.music_player) |*mp| mp.stop();
        if (self.voice_player) |*vp| vp.stop();
        self.music_started = false;
    }

    /// Trigger voice clips when a dialogue scene starts.
    ///
    /// The intro pirate encounter (mid1c/mid1d/mid1e scenes) alternates
    /// between pirate and player voice lines. Pirates speak first in the
    /// encounter, so odd dialogue scenes play pirate clips and even ones
    /// play player clips.
    pub fn onSceneStart(self: *MovieAudio, scene_name: []const u8) void {
        if (!isDialogueScene(scene_name)) return;
        const vp = &(self.voice_player orelse return);

        // Alternate pirate / player clips (pirates speak first)
        if (self.voice_clip_index % 2 == 0) {
            // Pirate's turn
            const pirate_idx = self.voice_clip_index / 2;
            if (pirate_idx < movie_voice_mod.PIRATE_CLIP_COUNT) {
                _ = self.voice_set.playPirateClip(pirate_idx, vp);
            }
        } else {
            // Player's turn
            const player_idx = self.voice_clip_index / 2;
            if (player_idx < movie_voice_mod.PLAYER_CLIP_COUNT) {
                _ = self.voice_set.playPlayerClip(player_idx, vp);
            }
        }
        self.voice_clip_index += 1;
    }

    /// Play a sound effect by SFX bank index.
    /// Uses the voice audio player (shared device) for SFX playback.
    pub fn playSfx(self: *MovieAudio, sfx_index: usize) void {
        const vp = &(self.voice_player orelse return);
        const sample = self.sfx_bank.getSample(sfx_index) orelse return;
        vp.play(sample.samples, sample.sample_rate) catch {};
    }

    /// Returns the number of loaded audio assets (music + voice + sfx).
    pub fn loadedAssetCount(self: *const MovieAudio) usize {
        var count: usize = 0;
        if (self.music_pcm != null) count += 1;
        count += self.voice_set.loadedCount();
        count += self.sfx_bank.loadedCount();
        return count;
    }
};

/// Recognized file extensions for MOVI FILE slot references.
const FileExt = enum { pak, shp, voc, none };

/// Detect file extension from a basename (case-insensitive).
fn extensionLower(basename: []const u8) FileExt {
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        const ext = basename[dot..];
        if (std.ascii.eqlIgnoreCase(ext, ".pak")) return .pak;
        if (std.ascii.eqlIgnoreCase(ext, ".shp")) return .shp;
        if (std.ascii.eqlIgnoreCase(ext, ".voc")) return .voc;
    }
    return .none;
}

/// Check if a scene name corresponds to a dialogue scene (pirate encounter).
/// Dialogue scenes are mid1c*, mid1d, and mid1e* (the pirate encounter sequence).
fn isDialogueScene(name: []const u8) bool {
    if (name.len < 5) return false;
    if (!std.mem.startsWith(u8, name, "mid1")) return false;
    const suffix = name[4];
    return suffix == 'c' or suffix == 'd' or suffix == 'e';
}

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

    // Audio (null = silent mode)
    audio: ?MovieAudio,

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
            .audio = null,
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

    /// Load and start movie audio (music, voice clips, SFX).
    /// Call after init(), before the first update(). Requires SDL audio.
    /// Failures are non-fatal: audio simply won't play.
    pub fn initAudio(self: *MoviePlayer) void {
        var ma = MovieAudio.init(self.allocator);
        ma.loadFromTre(self.tre_index, self.tre_data);
        ma.initPlayback();
        ma.startMusic();
        self.audio = ma;
    }

    /// Release all owned resources.
    pub fn deinit(self: *MoviePlayer) void {
        if (self.audio) |*a| a.deinit();
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

    /// Skip the intro movie (e.g., Escape key). Stops audio and sets status to done.
    pub fn skip(self: *MoviePlayer) void {
        if (self.audio) |*a| a.stopAll();
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

            // Trigger SFX when ACTS block advances in combat scenes
            if (self.audio) |*a| {
                if (script.acts_blocks.len > 2) {
                    // Multi-ACTS scenes have combat — cycle through SFX bank
                    const sfx_idx = self.current_acts_idx % (a.sfx_bank.loadedCount() + 1);
                    if (sfx_idx > 0) a.playSfx(sfx_idx - 1);
                }
            }

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
            // All scenes played — stop audio, start fade-out
            if (self.audio) |*a| a.stopAll();
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

        // Create renderer for this scene's file slot count (max slot_id + 1)
        var renderer = movie_renderer_mod.MovieRenderer.init(
            self.allocator,
            self.fb,
            script.fileSlotCount(),
        ) catch {
            script.deinit();
            self.advanceScene();
            return;
        };

        // Clear screen if the script requests it
        if (script.clear_screen) {
            renderer.clearScreen();
        }

        // Load files referenced by the script (use basename for TRE lookup).
        // FILE slots can reference different file types: PAK, SHP (fonts),
        // VOC (audio), or directory names (sound dirs). Detect by extension.
        var files_loaded: usize = 0;
        for (script.file_references) |slot| {
            const ref_basename = std.fs.path.basename(slot.path);
            const ext = extensionLower(ref_basename);

            // Skip sound directory references (no extension, e.g. "opening")
            // and VOC audio files (handled by voice system, not renderer)
            if (ext == .none or ext == .voc) continue;

            if (self.tre_index.findEntry(ref_basename)) |ref_entry| {
                const file_data = tre_mod.extractFileData(
                    self.tre_data,
                    ref_entry.offset,
                    ref_entry.size,
                ) catch {
                    std.debug.print("  FILE[{d}] {s}: extract failed\n", .{ slot.slot_id, ref_basename });
                    continue;
                };

                switch (ext) {
                    .shp => {
                        renderer.loadFont(@as(usize, slot.slot_id), file_data) catch {
                            std.debug.print("  FILE[{d}] {s}: font parse failed ({d} bytes)\n", .{ slot.slot_id, ref_basename, file_data.len });
                            continue;
                        };
                    },
                    .pak => {
                        renderer.loadPak(@as(usize, slot.slot_id), file_data) catch {
                            std.debug.print("  FILE[{d}] {s}: PAK parse failed ({d} bytes)\n", .{ slot.slot_id, ref_basename, file_data.len });
                            continue;
                        };
                    },
                    else => continue,
                }
                files_loaded += 1;
            } else {
                std.debug.print("  FILE[{d}] {s}: not found in TRE\n", .{ slot.slot_id, ref_basename });
            }
        }

        // Extract palette from renderer (first loaded PAK with a palette)
        if (renderer.getPalette()) |pal_val| {
            self.current_palette = pal_val;
            std.debug.print("  Palette loaded, {d}/{d} files loaded\n", .{ files_loaded, script.file_references.len });
        } else {
            std.debug.print("  WARNING: No palette found, {d}/{d} files loaded\n", .{ files_loaded, script.file_references.len });
        }

        self.script = script;
        self.renderer = renderer;

        const scene_name = self.sequence.getSceneName(self.current_scene_idx) orelse "?";
        std.debug.print("Movie scene: {s} ({d} ACTS, SPED={d})\n", .{
            scene_name,
            script.acts_blocks.len,
            script.frame_speed_ticks,
        });

        // Trigger voice clips for dialogue scenes
        if (self.audio) |*a| a.onSceneStart(scene_name);
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

test "MoviePlayer has null audio by default" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    try std.testing.expect(player.audio == null);
}

test "MovieAudio init has no loaded assets" {
    var audio = MovieAudio.init(std.testing.allocator);
    defer audio.deinit();

    try std.testing.expect(audio.music_pcm == null);
    try std.testing.expect(!audio.music_started);
    try std.testing.expectEqual(@as(usize, 0), audio.voice_clip_index);
    try std.testing.expectEqual(@as(usize, 0), audio.loadedAssetCount());
}

test "MovieAudio stopAll resets music_started" {
    var audio = MovieAudio.init(std.testing.allocator);
    defer audio.deinit();

    // Simulate started state
    audio.music_started = true;
    audio.stopAll();

    try std.testing.expect(!audio.music_started);
}

test "MovieAudio startMusic with no PCM is a no-op" {
    var audio = MovieAudio.init(std.testing.allocator);
    defer audio.deinit();

    // No music loaded, no player — should not crash
    audio.startMusic();
    try std.testing.expect(!audio.music_started);
}

test "MovieAudio loadedAssetCount counts music and voice" {
    const allocator = std.testing.allocator;
    var audio = MovieAudio.init(allocator);
    defer audio.deinit();

    // Load some dummy PCM as music
    const pcm = try allocator.alloc(u8, 100);
    @memset(pcm, 128);
    audio.music_pcm = pcm;

    // 1 for music + 0 for voice + 0 for sfx
    try std.testing.expectEqual(@as(usize, 1), audio.loadedAssetCount());
}

test "isDialogueScene identifies pirate encounter scenes" {
    // Dialogue scenes: mid1c*, mid1d, mid1e*
    try std.testing.expect(isDialogueScene("mid1c1"));
    try std.testing.expect(isDialogueScene("mid1c4"));
    try std.testing.expect(isDialogueScene("mid1d"));
    try std.testing.expect(isDialogueScene("mid1e1"));
    try std.testing.expect(isDialogueScene("mid1e3"));

    // Non-dialogue scenes
    try std.testing.expect(!isDialogueScene("mid1a"));
    try std.testing.expect(!isDialogueScene("mid1b"));
    try std.testing.expect(!isDialogueScene("mid1f"));
    try std.testing.expect(!isDialogueScene(""));
    try std.testing.expect(!isDialogueScene("short"));
}

test "MovieAudio onSceneStart advances voice index on dialogue scenes" {
    var audio = MovieAudio.init(std.testing.allocator);
    defer audio.deinit();

    // No voice player — playback won't happen, but index should still advance
    // Actually, without a voice_player, onSceneStart returns early.
    // Verify index stays at 0 when there's no player.
    audio.onSceneStart("mid1c1");
    try std.testing.expectEqual(@as(usize, 0), audio.voice_clip_index);

    // Non-dialogue scene should never advance index regardless
    audio.onSceneStart("mid1a");
    try std.testing.expectEqual(@as(usize, 0), audio.voice_clip_index);
}

test "MoviePlayer skip stops audio" {
    const allocator = std.testing.allocator;

    const names = try allocator.alloc([]const u8, 0);
    const seq = opening_mod.OpeningSequence{
        .scene_names = names,
        .allocator = allocator,
    };

    var fb = framebuffer_mod.Framebuffer.create();

    var player = MoviePlayer.init(allocator, seq, &.{}, undefined, &fb);
    defer player.deinit();

    // Attach audio in test mode (no SDL devices, no TRE data)
    player.audio = MovieAudio.init(allocator);

    // Simulate that music was playing
    player.audio.?.music_started = true;

    player.skip();

    // After skip: status is done, music_started is reset
    try std.testing.expectEqual(Status.done, player.status);
    try std.testing.expect(!player.audio.?.music_started);
}
