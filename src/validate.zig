//! Data validation pipeline for Wing Commander: Privateer.
//! Runs all parsers against game data and reports results.
//! This is the Phase 3 gate: must report 0 errors on known-good data.

const std = @import("std");
const tre = @import("tre.zig");
const iff = @import("iff.zig");
const pal_mod = @import("pal.zig");
const shp = @import("shp.zig");
const pak = @import("pak.zig");
const voc = @import("voc.zig");
const vpk = @import("vpk.zig");
const music = @import("music.zig");

/// Result of a full validation run across all game data files.
pub const ValidationResult = struct {
    /// Total number of files in the TRE archive.
    total_files: u32 = 0,
    /// Files successfully parsed by their respective format parser.
    iff_parsed: u32 = 0,
    pal_parsed: u32 = 0,
    shp_parsed: u32 = 0,
    pak_parsed: u32 = 0,
    voc_parsed: u32 = 0,
    vpk_parsed: u32 = 0,
    music_parsed: u32 = 0,
    /// Files that failed to parse.
    iff_errors: u32 = 0,
    pal_errors: u32 = 0,
    shp_errors: u32 = 0,
    pak_errors: u32 = 0,
    voc_errors: u32 = 0,
    vpk_errors: u32 = 0,
    music_errors: u32 = 0,
    /// Files with unrecognized extensions (DAT, etc.) — not errors.
    other_files: u32 = 0,
    /// Warnings (non-fatal issues).
    warnings: u32 = 0,

    pub fn totalParsed(self: ValidationResult) u32 {
        return self.iff_parsed + self.pal_parsed + self.shp_parsed +
            self.pak_parsed + self.voc_parsed + self.vpk_parsed +
            self.music_parsed;
    }

    pub fn totalErrors(self: ValidationResult) u32 {
        return self.iff_errors + self.pal_errors + self.shp_errors +
            self.pak_errors + self.voc_errors + self.vpk_errors +
            self.music_errors;
    }
};

/// Classify a file by its extension to determine which parser to use.
pub const FileType = enum {
    iff,
    pal,
    shp,
    pak,
    voc,
    vpk,
    music,
    other,
};

pub fn classifyFile(path: []const u8) FileType {
    if (std.mem.endsWith(u8, path, ".IFF")) return .iff;
    if (std.mem.endsWith(u8, path, ".PAL")) return .pal;
    if (std.mem.endsWith(u8, path, ".SHP")) return .shp;
    if (std.mem.endsWith(u8, path, ".PAK")) return .pak;
    if (std.mem.endsWith(u8, path, ".VOC")) return .voc;
    if (std.mem.endsWith(u8, path, ".VPK")) return .vpk;
    if (std.mem.endsWith(u8, path, ".VPF")) return .vpk;
    if (std.mem.endsWith(u8, path, ".ADL")) return .music;
    if (std.mem.endsWith(u8, path, ".GEN")) return .music;
    return .other;
}

/// Validate a single IFF file by parsing its chunk tree.
fn validateIff(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < 8) return false;
    const tag = data[0..4];
    if (!std.mem.eql(u8, tag, "FORM") and
        !std.mem.eql(u8, tag, "CAT ") and
        !std.mem.eql(u8, tag, "LIST"))
    {
        return false;
    }
    var chunk = iff.parseFile(allocator, data) catch return false;
    defer chunk.deinit();
    return chunk.isContainer();
}

/// Validate a single PAL file.
fn validatePal(data: []const u8) bool {
    _ = pal_mod.parse(data) catch return false;
    return true;
}

/// Validate a single SHP file.
fn validateShp(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < shp.MIN_FILE_SIZE) return false;
    var shape_file = shp.parse(allocator, data) catch return false;
    defer shape_file.deinit();
    return shape_file.spriteCount() > 0;
}

/// Validate a single PAK file.
fn validatePak(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < pak.MIN_FILE_SIZE) return false;
    var pak_file = pak.parse(allocator, data) catch return false;
    defer pak_file.deinit();
    return pak_file.resourceCount() > 0;
}

/// Validate a single VOC file.
fn validateVoc(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < voc.MIN_FILE_SIZE) return false;
    var voc_file = voc.parse(allocator, data) catch return false;
    defer voc_file.deinit();
    return voc_file.samples.len > 0;
}

/// Validate a single VPK/VPF file.
fn validateVpk(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < vpk.MIN_FILE_SIZE) return false;
    var vpk_file = vpk.parse(allocator, data) catch return false;
    defer vpk_file.deinit();
    return vpk_file.entryCount() > 0;
}

/// Validate a single music file (ADL/GEN).
fn validateMusic(allocator: std.mem.Allocator, data: []const u8) bool {
    if (data.len < music.MIN_FILE_SIZE) return false;
    var music_file = music.parse(allocator, data) catch return false;
    defer music_file.deinit();
    return true;
}

/// Run the full validation pipeline against all files in a TRE archive.
/// `tre_data` is the raw PRIV.TRE contents.
pub fn validateAll(allocator: std.mem.Allocator, tre_data: []const u8) !ValidationResult {
    const entries = try tre.readAllEntries(allocator, tre_data);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit();
        }
        allocator.free(entries);
    }

    var result = ValidationResult{};
    result.total_files = @intCast(entries.len);

    for (entries) |entry| {
        const file_data = tre.extractFileData(tre_data, entry.offset, entry.size) catch {
            result.warnings += 1;
            continue;
        };

        const file_type = classifyFile(entry.path);
        switch (file_type) {
            .iff => {
                if (validateIff(allocator, file_data)) {
                    result.iff_parsed += 1;
                } else {
                    result.iff_errors += 1;
                }
            },
            .pal => {
                if (validatePal(file_data)) {
                    result.pal_parsed += 1;
                } else {
                    result.pal_errors += 1;
                }
            },
            .shp => {
                if (validateShp(allocator, file_data)) {
                    result.shp_parsed += 1;
                } else {
                    result.shp_errors += 1;
                }
            },
            .pak => {
                if (validatePak(allocator, file_data)) {
                    result.pak_parsed += 1;
                } else {
                    result.pak_errors += 1;
                }
            },
            .voc => {
                if (validateVoc(allocator, file_data)) {
                    result.voc_parsed += 1;
                } else {
                    result.voc_errors += 1;
                }
            },
            .vpk => {
                if (validateVpk(allocator, file_data)) {
                    result.vpk_parsed += 1;
                } else {
                    result.vpk_errors += 1;
                }
            },
            .music => {
                if (validateMusic(allocator, file_data)) {
                    result.music_parsed += 1;
                } else {
                    result.music_errors += 1;
                }
            },
            .other => {
                result.other_files += 1;
            },
        }
    }

    return result;
}

// --- Tests ---

test "classifyFile identifies IFF files" {
    try std.testing.expectEqual(FileType.iff, classifyFile("..\\..\\DATA\\AIDS\\ATTITUDE.IFF"));
    try std.testing.expectEqual(FileType.iff, classifyFile("WEAPONS.IFF"));
}

test "classifyFile identifies PAL files" {
    try std.testing.expectEqual(FileType.pal, classifyFile("..\\..\\DATA\\PALETTE\\PCMAIN.PAL"));
    try std.testing.expectEqual(FileType.pal, classifyFile("SPACE.PAL"));
}

test "classifyFile identifies SHP files" {
    try std.testing.expectEqual(FileType.shp, classifyFile("CONVFONT.SHP"));
}

test "classifyFile identifies PAK files" {
    try std.testing.expectEqual(FileType.pak, classifyFile("..\\..\\DATA\\APPEARNC\\GALAXY.PAK"));
}

test "classifyFile identifies VOC files" {
    try std.testing.expectEqual(FileType.voc, classifyFile("..\\..\\DATA\\SPEECH\\MID01\\ROMAN.VOC"));
}

test "classifyFile identifies VPK and VPF files" {
    try std.testing.expectEqual(FileType.vpk, classifyFile("SPEECH.VPK"));
    try std.testing.expectEqual(FileType.vpk, classifyFile("SPEECH.VPF"));
}

test "classifyFile identifies music files" {
    try std.testing.expectEqual(FileType.music, classifyFile("BASETUNE.ADL"));
    try std.testing.expectEqual(FileType.music, classifyFile("BASETUNE.GEN"));
}

test "classifyFile returns other for unknown extensions" {
    try std.testing.expectEqual(FileType.other, classifyFile("TABLE.DAT"));
    try std.testing.expectEqual(FileType.other, classifyFile("UNKNOWN.BIN"));
}

test "ValidationResult totalParsed sums all parsed counts" {
    var r = ValidationResult{};
    r.iff_parsed = 10;
    r.pal_parsed = 4;
    r.shp_parsed = 11;
    r.pak_parsed = 32;
    r.voc_parsed = 17;
    r.vpk_parsed = 5;
    r.music_parsed = 10;
    try std.testing.expectEqual(@as(u32, 89), r.totalParsed());
}

test "ValidationResult totalErrors sums all error counts" {
    var r = ValidationResult{};
    r.iff_errors = 1;
    r.pal_errors = 2;
    try std.testing.expectEqual(@as(u32, 3), r.totalErrors());
}

test "ValidationResult defaults to all zeros" {
    const r = ValidationResult{};
    try std.testing.expectEqual(@as(u32, 0), r.totalParsed());
    try std.testing.expectEqual(@as(u32, 0), r.totalErrors());
    try std.testing.expectEqual(@as(u32, 0), r.total_files);
}

test "validateAll with fixture TRE data processes entries" {
    const allocator = std.testing.allocator;
    const testing_helpers = @import("testing.zig");

    const tre_fixture = try testing_helpers.loadFixture(allocator, "test_tre.bin");
    defer allocator.free(tre_fixture);

    const result = try validateAll(allocator, tre_fixture);

    // The fixture has 3 entries (2 IFF, 1 PAK) but the file data in the
    // fixture is minimal/synthetic, so parsers may not fully validate.
    // What matters is: the pipeline processes all entries without crashing.
    try std.testing.expectEqual(@as(u32, 3), result.total_files);
    // Total parsed + errors + other should equal total files
    try std.testing.expectEqual(
        result.total_files,
        result.totalParsed() + result.totalErrors() + result.other_files + result.warnings,
    );
}
