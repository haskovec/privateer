//! Room asset mapping for Wing Commander: Privateer.
//!
//! Maps GAMEFLOW scene IDs to their visual resources in the TRE archive.
//!
//! ## Key Discovery (from PRCD.EXE reverse engineering)
//!
//! The mapping is direct: **Scene ID = OPTSHPS.PAK L1 index**.
//!
//! All scene backgrounds live in a single PAK file (OPTSHPS.PAK). The scene INFO
//! byte from each FORM:SCEN in GAMEFLOW.IFF is used directly as the L1 resource
//! index into OPTSHPS.PAK. Each resource is a "scene pack" containing one or more
//! RLE-encoded sprites (background + overlays).
//!
//! Palettes are in OPTPALS.PAK with 42 entries. Scenes 0-41 use palette[scene_id]
//! directly. Scenes 42+ share a palette with the room's primary scene group.
//!
//! ## PAK Files
//!
//! | PAK File | TRE Path | Contents |
//! |----------|----------|----------|
//! | OPTSHPS.PAK | `..\..\DATA\OPTIONS\OPTSHPS.PAK` | 226 scene/UI sprite packs |
//! | OPTPALS.PAK | `..\..\DATA\OPTIONS\OPTPALS.PAK` | 42 VGA palettes (772B each) |
//! | CU.PAK | `..\..\DATA\OPTIONS\CU.PAK` | 30 NPC close-up sprites |
//! | LTOBASES.PAK | `..\..\DATA\MIDGAMES\LTOBASES.PAK` | 10 landing transition sprites |

/// TRE path for the main scene sprite PAK file.
/// Contains 226 L1 entries; entries 0-61 are scene backgrounds indexed by scene ID.
pub const OPTSHPS_PAK = "OPTSHPS.PAK";

/// TRE path for the scene palette PAK file.
/// Contains 42 L1 entries; entries 0-41 are palettes indexed by scene ID.
pub const OPTPALS_PAK = "OPTPALS.PAK";

/// TRE path for the NPC close-up sprite PAK file.
/// Contains 30 L1 entries; used for conversation/character views.
pub const CU_PAK = "CU.PAK";

/// TRE path for the landing transition animation PAK file.
/// Contains 10 L1 entries; small sprites for the "landing at base" animation.
pub const LTOBASES_PAK = "LTOBASES.PAK";

/// Maximum scene ID used in GAMEFLOW.IFF.
pub const MAX_SCENE_ID = 61;

/// Number of palettes available in OPTPALS.PAK.
pub const PALETTE_COUNT = 42;

/// Get the OPTSHPS.PAK L1 resource index for a given scene ID.
/// The mapping is direct: scene_id IS the resource index.
pub fn sceneResourceIndex(scene_id: u8) u8 {
    return scene_id;
}

/// Get the OPTPALS.PAK palette index for a given scene ID.
///
/// For scenes 0-41, the palette index equals the scene ID.
/// For scenes 42+, returns the palette from a related scene in the same
/// base type group. If `room_first_scene_id` is provided and is < 42,
/// it is used as the palette index (since rooms share a palette across
/// all their scenes).
///
/// Returns null if no suitable palette can be determined.
pub fn paletteIndex(scene_id: u8, room_first_scene_id: ?u8) ?u8 {
    // Direct mapping for scenes with their own palette
    if (scene_id < PALETTE_COUNT) {
        return scene_id;
    }

    // For scenes >= 42, use the room's first scene as the palette source
    if (room_first_scene_id) |first| {
        if (first < PALETTE_COUNT) {
            return first;
        }
    }

    // Fallback: map by base type group (tune-based grouping)
    return switch (scene_id) {
        // Guild scenes (tune=8) -> use palette from scene 39
        42...45 => 39,
        // Merchant guild scenes (tune=9) -> use scene 0 palette as fallback
        46...55 => if (room_first_scene_id) |f| (if (f < PALETTE_COUNT) f else 0) else 0,
        // Finale scenes (tune=2) -> no known palette, use scene 0
        56, 57 => 0,
        // Bar/bartender (scene 59) and bar conversation (scene 61)
        // These are shared across all room types; palette comes from the room
        59, 61 => if (room_first_scene_id) |f| (if (f < PALETTE_COUNT) f else 0) else 0,
        else => null,
    };
}

/// Scene type classification based on EFCT action analysis.
pub const SceneType = enum {
    /// Main base view with COMMODITY/TAKEOFF actions
    base_main,
    /// Hallway / navigation screen with scene transition actions
    hallway,
    /// Launch pad screen with LAUNCH action
    launch_pad,
    /// Ship dealer / equipment dealer screen
    dealer,
    /// Bar / bartender screen (scene 59, shared across rooms)
    bar,
    /// Bar conversation screen (scene 61, shared across rooms)
    bar_conversation,
    /// Ship dealer detailed view (sub-screens with many sprites)
    dealer_detail,
    /// Mission computer view
    mission_computer,
    /// Finale / ending scene
    finale,
    /// Unknown or other
    other,
};

/// Classify a scene by its ID based on known GAMEFLOW patterns.
pub fn classifyScene(scene_id: u8) SceneType {
    return switch (scene_id) {
        // Bar screens (shared across all rooms)
        59 => .bar,
        61 => .bar_conversation,

        // Base main views (various concourse/exterior scenes)
        0...4, 8...11, 13, 17, 21, 25, 36, 39...42, 46, 48...52 => .base_main,

        // Hallway / navigation screens
        5, 14, 18, 22, 29, 33, 37, 43, 47, 53 => .hallway,

        // Launch pad screens
        6, 15, 20, 24, 30, 35, 38, 44, 54, 56 => .launch_pad,

        // Ship/equipment dealer screens
        7, 16, 19, 23, 28, 34, 45, 55 => .dealer,

        // Ship dealer detailed views
        26, 27 => .dealer_detail,

        // Mission computer
        31...32 => .mission_computer,

        // Finale
        57 => .finale,

        else => .other,
    };
}

// --- Tests ---

const std = @import("std");

test "sceneResourceIndex is identity mapping" {
    try std.testing.expectEqual(@as(u8, 0), sceneResourceIndex(0));
    try std.testing.expectEqual(@as(u8, 13), sceneResourceIndex(13));
    try std.testing.expectEqual(@as(u8, 59), sceneResourceIndex(59));
    try std.testing.expectEqual(@as(u8, 61), sceneResourceIndex(61));
}

test "paletteIndex direct mapping for scenes 0-41" {
    try std.testing.expectEqual(@as(?u8, 0), paletteIndex(0, null));
    try std.testing.expectEqual(@as(?u8, 13), paletteIndex(13, null));
    try std.testing.expectEqual(@as(?u8, 41), paletteIndex(41, null));
}

test "paletteIndex uses room first scene for scenes 42+" {
    // Guild scene 42, room first scene is 39
    try std.testing.expectEqual(@as(?u8, 39), paletteIndex(42, 39));
    // Bar scene 59, room first scene is 13
    try std.testing.expectEqual(@as(?u8, 13), paletteIndex(59, 13));
    // Bar conversation scene 61, room first scene is 3
    try std.testing.expectEqual(@as(?u8, 3), paletteIndex(61, 3));
}

test "paletteIndex fallback for guild scenes without room context" {
    // Guild scenes 42-45 fall back to palette 39
    try std.testing.expectEqual(@as(?u8, 39), paletteIndex(42, null));
    try std.testing.expectEqual(@as(?u8, 39), paletteIndex(45, null));
}

test "classifyScene identifies bar screens" {
    try std.testing.expectEqual(SceneType.bar, classifyScene(59));
    try std.testing.expectEqual(SceneType.bar_conversation, classifyScene(61));
}

test "classifyScene identifies base main views" {
    try std.testing.expectEqual(SceneType.base_main, classifyScene(0));
    try std.testing.expectEqual(SceneType.base_main, classifyScene(13));
    try std.testing.expectEqual(SceneType.base_main, classifyScene(36));
}

test "classifyScene identifies launch pads" {
    try std.testing.expectEqual(SceneType.launch_pad, classifyScene(6));
    try std.testing.expectEqual(SceneType.launch_pad, classifyScene(15));
    try std.testing.expectEqual(SceneType.launch_pad, classifyScene(38));
}
