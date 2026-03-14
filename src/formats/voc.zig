//! VOC (Creative Voice File) parser for Wing Commander: Privateer.
//! Parses Creative Labs' VOC format used for speech and sound effects.
//! Structure: 26-byte header with signature/version, followed by typed data blocks
//! containing 8-bit unsigned PCM audio at 11,025 Hz mono.

const std = @import("std");

/// VOC file signature: "Creative Voice File" + 0x1A.
pub const SIGNATURE = "Creative Voice File\x1a";
pub const SIGNATURE_LEN: usize = 20;

/// Standard header size (data offset for version 1.10).
pub const HEADER_SIZE: usize = 26;

/// Minimum valid VOC file: header + terminator block.
pub const MIN_FILE_SIZE: usize = HEADER_SIZE + 1;

/// Block type identifiers.
pub const BLOCK_TERMINATOR: u8 = 0x00;
pub const BLOCK_SOUND_DATA: u8 = 0x01;
pub const BLOCK_SOUND_CONTINUATION: u8 = 0x02;

/// Codec type for 8-bit unsigned PCM.
pub const CODEC_PCM_8BIT: u8 = 0x00;

pub const VocError = error{
    /// File too small to contain a valid VOC header.
    InvalidSize,
    /// Header signature does not match "Creative Voice File".
    InvalidSignature,
    /// Version validity check failed.
    InvalidVersion,
    /// Data offset points outside the file.
    InvalidDataOffset,
    /// Sound data block specifies an unsupported codec.
    UnsupportedCodec,
    /// A data block extends past end of file.
    BlockOverflow,
    /// Sound continuation block without a preceding sound data block.
    OrphanContinuation,
    /// No audio data found in the file.
    NoAudioData,
    OutOfMemory,
};

/// Parsed VOC file header.
pub const VocHeader = struct {
    /// Offset from file start to first data block.
    data_offset: u16,
    /// Format version (e.g. 0x010A = 1.10).
    version: u16,
    /// Validity check value.
    validity: u16,
};

/// A parsed VOC file with extracted audio data.
pub const VocFile = struct {
    header: VocHeader,
    /// Sample rate in Hz (derived from frequency divisor in first sound block).
    sample_rate: u32,
    /// Codec identifier (0 = 8-bit unsigned PCM).
    codec: u8,
    /// Concatenated PCM audio samples from all sound data blocks.
    /// Owned by allocator -- freed on deinit().
    samples: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VocFile) void {
        self.allocator.free(self.samples);
    }

    /// Duration in milliseconds.
    pub fn durationMs(self: VocFile) u64 {
        if (self.sample_rate == 0) return 0;
        return (@as(u64, self.samples.len) * 1000) / @as(u64, self.sample_rate);
    }
};

/// Parse a VOC file header from raw bytes.
pub fn parseHeader(data: []const u8) VocError!VocHeader {
    if (data.len < HEADER_SIZE) return VocError.InvalidSize;

    // Verify signature
    if (!std.mem.eql(u8, data[0..SIGNATURE_LEN], SIGNATURE)) return VocError.InvalidSignature;

    const data_offset = std.mem.readInt(u16, data[20..22], .little);
    const version = std.mem.readInt(u16, data[22..24], .little);
    const validity = std.mem.readInt(u16, data[24..26], .little);

    // Validity check: ~version + 0x1234 should equal validity
    const expected: u16 = (~version) +% 0x1234;
    if (validity != expected) return VocError.InvalidVersion;

    if (data_offset > data.len) return VocError.InvalidDataOffset;

    return .{
        .data_offset = data_offset,
        .version = version,
        .validity = validity,
    };
}

/// Read a 3-byte little-endian block size from data at position.
fn readBlockSize(data: []const u8, pos: usize) u32 {
    return @as(u32, data[pos]) |
        (@as(u32, data[pos + 1]) << 8) |
        (@as(u32, data[pos + 2]) << 16);
}

/// Parse a complete VOC file, extracting all audio data.
/// Caller must call deinit() on the returned VocFile.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) VocError!VocFile {
    const header = try parseHeader(data);

    // First pass: count total audio bytes
    var total_samples: usize = 0;
    var sample_rate: u32 = 0;
    var codec: u8 = CODEC_PCM_8BIT;
    var has_sound = false;

    var pos: usize = header.data_offset;
    while (pos < data.len) {
        const block_type = data[pos];
        pos += 1;

        if (block_type == BLOCK_TERMINATOR) break;

        // All non-terminator blocks have a 3-byte size field
        if (pos + 3 > data.len) return VocError.BlockOverflow;
        const block_size = readBlockSize(data, pos);
        pos += 3;

        const block_end = pos + @as(usize, block_size);
        if (block_end > data.len) return VocError.BlockOverflow;

        switch (block_type) {
            BLOCK_SOUND_DATA => {
                if (block_size < 2) return VocError.BlockOverflow;
                const freq_divisor = data[pos];
                codec = data[pos + 1];
                if (codec != CODEC_PCM_8BIT) return VocError.UnsupportedCodec;
                sample_rate = 1_000_000 / (256 - @as(u32, freq_divisor));
                total_samples += block_size - 2; // subtract freq_divisor + codec bytes
                has_sound = true;
            },
            BLOCK_SOUND_CONTINUATION => {
                if (!has_sound) return VocError.OrphanContinuation;
                total_samples += block_size;
            },
            else => {
                // Skip unknown block types (forward compatible)
            },
        }
        pos = block_end;
    }

    if (!has_sound) return VocError.NoAudioData;

    // Second pass: collect audio samples
    const samples = try allocator.alloc(u8, total_samples);
    errdefer allocator.free(samples);

    var write_pos: usize = 0;
    pos = header.data_offset;
    while (pos < data.len) {
        const block_type = data[pos];
        pos += 1;

        if (block_type == BLOCK_TERMINATOR) break;

        const block_size = readBlockSize(data, pos);
        pos += 3;

        switch (block_type) {
            BLOCK_SOUND_DATA => {
                const audio_start = pos + 2; // skip freq_divisor + codec
                const audio_len = block_size - 2;
                @memcpy(samples[write_pos .. write_pos + audio_len], data[audio_start .. audio_start + audio_len]);
                write_pos += audio_len;
            },
            BLOCK_SOUND_CONTINUATION => {
                @memcpy(samples[write_pos .. write_pos + block_size], data[pos .. pos + block_size]);
                write_pos += block_size;
            },
            else => {},
        }
        pos += @as(usize, block_size);
    }

    return .{
        .header = header,
        .sample_rate = sample_rate,
        .codec = codec,
        .samples = samples,
        .allocator = allocator,
    };
}

// --- Tests ---

const testing_helpers = @import("../testing.zig");

test "parse VOC header from fixture" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_voc.bin");
    defer allocator.free(data);

    const header = try parseHeader(data);
    try std.testing.expectEqual(@as(u16, 26), header.data_offset);
    try std.testing.expectEqual(@as(u16, 0x010A), header.version);
}

test "parse VOC extracts PCM samples" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_voc.bin");
    defer allocator.free(data);

    var voc = try parse(allocator, data);
    defer voc.deinit();

    try std.testing.expectEqual(@as(u32, 11111), voc.sample_rate); // 1000000/(256-165) = 10989, but let's check
    try std.testing.expectEqual(CODEC_PCM_8BIT, voc.codec);
    try std.testing.expectEqual(@as(usize, 16), voc.samples.len);

    // Verify first and last sample values
    try std.testing.expectEqual(@as(u8, 128), voc.samples[0]);
    try std.testing.expectEqual(@as(u8, 96), voc.samples[15]);
}

test "parse VOC multi-block concatenates audio" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_voc_multi.bin");
    defer allocator.free(data);

    var voc = try parse(allocator, data);
    defer voc.deinit();

    // 8 samples from block 1 + 8 samples from block 2 = 16 total
    try std.testing.expectEqual(@as(usize, 16), voc.samples.len);

    // Block 1 starts with 128
    try std.testing.expectEqual(@as(u8, 128), voc.samples[0]);
    // Block 2 starts with 128 (at index 8)
    try std.testing.expectEqual(@as(u8, 128), voc.samples[8]);
    // Block 2 ends with 96
    try std.testing.expectEqual(@as(u8, 96), voc.samples[15]);
}

test "parseHeader rejects too-small data" {
    const data = [_]u8{0} ** 20;
    try std.testing.expectError(VocError.InvalidSize, parseHeader(&data));
}

test "parseHeader rejects invalid signature" {
    var data = [_]u8{0} ** 26;
    @memcpy(data[0..20], "Not A Voice File\x1a\x00\x00\x00");
    try std.testing.expectError(VocError.InvalidSignature, parseHeader(&data));
}

test "parseHeader rejects invalid version check" {
    var data = [_]u8{0} ** 27;
    @memcpy(data[0..SIGNATURE_LEN], SIGNATURE);
    // data_offset = 26, version = 0x010A, but wrong validity
    std.mem.writeInt(u16, data[20..22], 26, .little);
    std.mem.writeInt(u16, data[22..24], 0x010A, .little);
    std.mem.writeInt(u16, data[24..26], 0x0000, .little); // wrong!
    try std.testing.expectError(VocError.InvalidVersion, parseHeader(&data));
}

test "parse rejects file with no audio blocks" {
    const allocator = std.testing.allocator;
    // Valid header + immediate terminator
    var data: [27]u8 = undefined;
    @memcpy(data[0..SIGNATURE_LEN], SIGNATURE);
    std.mem.writeInt(u16, data[20..22], 26, .little);
    std.mem.writeInt(u16, data[22..24], 0x010A, .little);
    const expected_validity: u16 = (~@as(u16, 0x010A)) +% 0x1234;
    std.mem.writeInt(u16, data[24..26], expected_validity, .little);
    data[26] = BLOCK_TERMINATOR;

    try std.testing.expectError(VocError.NoAudioData, parse(allocator, &data));
}

test "VOC durationMs calculation" {
    const allocator = std.testing.allocator;
    const data = try testing_helpers.loadFixture(allocator, "test_voc.bin");
    defer allocator.free(data);

    var voc = try parse(allocator, data);
    defer voc.deinit();

    // 16 samples at ~11111 Hz ≈ 1ms
    const duration = voc.durationMs();
    try std.testing.expect(duration >= 1);
    try std.testing.expect(duration < 10);
}
