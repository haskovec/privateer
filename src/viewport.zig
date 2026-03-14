//! Widescreen viewport calculations.
//! Computes the destination rectangle for presenting the 320x200 framebuffer
//! onto windows of arbitrary size. Supports two modes:
//!   - fit_4_3: Maintain 4:3 aspect ratio with pillarbox/letterbox borders (landing screens)
//!   - fill: Fill the entire window (space flight)

const std = @import("std");

/// Viewport presentation mode.
pub const Mode = enum {
    /// Fill the entire window (space flight).
    /// The 320x200 framebuffer stretches to cover the full window area.
    fill,
    /// Maintain 4:3 display aspect ratio (landing screens).
    /// The original 320x200 VGA mode displayed at 4:3 on CRT monitors
    /// (non-square pixels with ~1.2:1 pixel aspect ratio).
    /// Content is centered with black pillarbox or letterbox borders.
    fit_4_3,
};

/// A computed viewport rectangle in window pixel coordinates.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// The correct display aspect ratio for the original game.
/// VGA 320x200 was displayed at 4:3 on CRT monitors.
const DISPLAY_ASPECT: f32 = 4.0 / 3.0;

/// Compute the destination rectangle for presenting the framebuffer.
///
/// For `fill` mode, the rect covers the entire window.
/// For `fit_4_3` mode, the rect is the largest 4:3 rectangle that fits
/// within the window, centered with equal margins on both sides.
pub fn compute(mode: Mode, window_w: u32, window_h: u32) Rect {
    const wf: f32 = @floatFromInt(window_w);
    const hf: f32 = @floatFromInt(window_h);

    return switch (mode) {
        .fill => .{ .x = 0, .y = 0, .w = wf, .h = hf },
        .fit_4_3 => blk: {
            if (window_w == 0 or window_h == 0) {
                break :blk Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
            }
            const window_ratio = wf / hf;

            if (window_ratio > DISPLAY_ASPECT) {
                // Window is wider than 4:3 → pillarbox (black bars on sides)
                const scaled_w = hf * DISPLAY_ASPECT;
                break :blk Rect{
                    .x = (wf - scaled_w) / 2.0,
                    .y = 0,
                    .w = scaled_w,
                    .h = hf,
                };
            } else {
                // Window is taller than 4:3 → letterbox (black bars top/bottom)
                const scaled_h = wf / DISPLAY_ASPECT;
                break :blk Rect{
                    .x = 0,
                    .y = (hf - scaled_h) / 2.0,
                    .w = wf,
                    .h = scaled_h,
                };
            }
        },
    };
}

/// Compute the horizontal margin (pillarbox width) for a given window size in fit_4_3 mode.
/// Returns 0 if the window is narrower than or equal to 4:3.
pub fn pillarboxWidth(window_w: u32, window_h: u32) f32 {
    const rect = compute(.fit_4_3, window_w, window_h);
    return rect.x;
}

/// Compute the vertical margin (letterbox height) for a given window size in fit_4_3 mode.
/// Returns 0 if the window is wider than or equal to 4:3.
pub fn letterboxHeight(window_w: u32, window_h: u32) f32 {
    const rect = compute(.fit_4_3, window_w, window_h);
    return rect.y;
}

// --- Tests ---

test "fill mode covers entire window" {
    const rect = compute(.fill, 1920, 1080);
    try std.testing.expectEqual(@as(f32, 0), rect.x);
    try std.testing.expectEqual(@as(f32, 0), rect.y);
    try std.testing.expectEqual(@as(f32, 1920), rect.w);
    try std.testing.expectEqual(@as(f32, 1080), rect.h);
}

test "fill mode covers non-standard window" {
    const rect = compute(.fill, 800, 600);
    try std.testing.expectEqual(@as(f32, 0), rect.x);
    try std.testing.expectEqual(@as(f32, 0), rect.y);
    try std.testing.expectEqual(@as(f32, 800), rect.w);
    try std.testing.expectEqual(@as(f32, 600), rect.h);
}

test "16:9 viewport calculates correct pillarbox margins" {
    // 1920x1080 is 16:9, wider than 4:3
    // 4:3 rect within 1080 height: width = 1080 * 4/3 = 1440
    // Margin each side: (1920 - 1440) / 2 = 240
    const rect = compute(.fit_4_3, 1920, 1080);
    try std.testing.expectApproxEqAbs(@as(f32, 240), rect.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rect.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1440), rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1080), rect.h, 0.5);
}

test "4:3 window fills entirely with no margins" {
    // 1280x960 is exactly 4:3
    const rect = compute(.fit_4_3, 1280, 960);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rect.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rect.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1280), rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 960), rect.h, 0.5);
}

test "tall window calculates letterbox margins" {
    // 800x800 is 1:1, taller than 4:3
    // 4:3 rect within 800 width: height = 800 / (4/3) = 600
    // Margin each side: (800 - 600) / 2 = 100
    const rect = compute(.fit_4_3, 800, 800);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rect.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), rect.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 800), rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 600), rect.h, 0.5);
}

test "16:10 window pillarboxes" {
    // 1280x800 is 16:10 (the default window), wider than 4:3
    // 4:3 within 800 height: width = 800 * 4/3 ≈ 1066.67
    // Margin: (1280 - 1066.67) / 2 ≈ 106.67
    const rect = compute(.fit_4_3, 1280, 800);
    try std.testing.expectApproxEqAbs(@as(f32, 106.67), rect.x, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rect.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1066.67), rect.w, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 800), rect.h, 0.5);
}

test "pillarboxWidth returns margin for widescreen" {
    const margin = pillarboxWidth(1920, 1080);
    try std.testing.expectApproxEqAbs(@as(f32, 240), margin, 0.5);
}

test "pillarboxWidth returns zero for 4:3 window" {
    const margin = pillarboxWidth(1280, 960);
    try std.testing.expectApproxEqAbs(@as(f32, 0), margin, 0.5);
}

test "letterboxHeight returns margin for tall window" {
    const margin = letterboxHeight(800, 800);
    try std.testing.expectApproxEqAbs(@as(f32, 100), margin, 0.5);
}

test "letterboxHeight returns zero for widescreen" {
    const margin = letterboxHeight(1920, 1080);
    try std.testing.expectApproxEqAbs(@as(f32, 0), margin, 0.5);
}

test "zero-size window produces zero rect" {
    const rect = compute(.fit_4_3, 0, 0);
    try std.testing.expectEqual(@as(f32, 0), rect.x);
    try std.testing.expectEqual(@as(f32, 0), rect.y);
    try std.testing.expectEqual(@as(f32, 0), rect.w);
    try std.testing.expectEqual(@as(f32, 0), rect.h);
}

test "ultrawide 21:9 has large pillarbox" {
    // 2560x1080 is ~21.3:9 ≈ 2.37:1, much wider than 4:3
    // 4:3 within 1080 height: width = 1080 * 4/3 = 1440
    // Margin: (2560 - 1440) / 2 = 560
    const rect = compute(.fit_4_3, 2560, 1080);
    try std.testing.expectApproxEqAbs(@as(f32, 560), rect.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rect.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1440), rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1080), rect.h, 0.5);
}

test "viewport area equals window area in fill mode" {
    const rect = compute(.fill, 1920, 1080);
    try std.testing.expectApproxEqAbs(@as(f32, 1920 * 1080), rect.w * rect.h, 1.0);
}

test "viewport preserves 4:3 ratio in fit mode" {
    const rect = compute(.fit_4_3, 1920, 1080);
    const ratio = rect.w / rect.h;
    try std.testing.expectApproxEqAbs(DISPLAY_ASPECT, ratio, 0.01);
}
