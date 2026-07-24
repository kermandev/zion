const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

pub const current = @import("protocol/current.zig");
pub const packet_ids = current.packet_ids;
pub const version = current;
pub const compression_enabled = build_options.enable_compression;

pub const max_packet_len = 2 * 1024 * 1024;
pub const max_string_chars = 32767;

pub const State = enum(i32) {
    status = 1,
    login = 2,
    transfer = 3,
};

pub const PacketError = PacketReader.Error || error{StringTooLong} || Io.Writer.Error || error{
    PacketTooLarge,
    CompressionThresholdUnsupported,
} || std.mem.Allocator.Error;

pub const Packet = struct {
    id: i32,
    payload: []const u8,
};

pub fn PacketWriter(comptime Backend: type) type {
    const WriteError = if (Backend == Io.Writer.Allocating)
        std.mem.Allocator.Error
    else if (Backend == Io.Writer)
        Io.Writer.Error
    else
        @compileError("unsupported PacketWriter backend: " ++ @typeName(Backend));

    return struct {
        pub const Error = error{StringTooLong} || WriteError;

        backend: *Backend,

        const Self = @This();

        pub fn init(backend: *Backend) Self {
            return .{ .backend = backend };
        }

        fn writeAll(packet: Self, value: []const u8) WriteError!void {
            if (comptime Backend == Io.Writer.Allocating) {
                try packet.backend.ensureUnusedCapacity(value.len);
                const writer = &packet.backend.writer;
                @memcpy(writer.buffer[writer.end..][0..value.len], value);
                writer.end += value.len;
            } else {
                try packet.backend.writeAll(value);
            }
        }

        fn writeInt(packet: Self, comptime T: type, value: T) WriteError!void {
            var encoded: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &encoded, value, .big);
            try packet.writeAll(&encoded);
        }

        pub fn writeBool(packet: Self, value: bool) WriteError!void {
            try packet.writeByte(@intFromBool(value));
        }

        pub fn writeByte(packet: Self, value: u8) WriteError!void {
            try packet.writeAll(&.{value});
        }

        pub fn writeBytes(packet: Self, value: []const u8) WriteError!void {
            try packet.writeAll(value);
        }

        pub fn writeI32(packet: Self, value: i32) WriteError!void {
            try packet.writeInt(i32, value);
        }

        pub fn writeF32(packet: Self, value: f32) WriteError!void {
            try packet.writeI32(@bitCast(value));
        }

        pub fn writeF64(packet: Self, value: f64) WriteError!void {
            try packet.writeI64(@bitCast(value));
        }

        pub fn writeU16(packet: Self, value: u16) WriteError!void {
            try packet.writeInt(u16, value);
        }

        pub fn writeI64(packet: Self, value: i64) WriteError!void {
            try packet.writeInt(i64, value);
        }

        pub fn writeUuid(packet: Self, value: [16]u8) WriteError!void {
            try packet.writeAll(&value);
        }

        pub fn writeVarInt(packet: Self, value: i32) WriteError!void {
            var encoded: [5]u8 = undefined;
            var unsigned: u32 = @bitCast(value);
            var len: usize = 0;
            while ((unsigned & ~@as(u32, 0x7f)) != 0) {
                encoded[len] = @intCast((unsigned & 0x7f) | 0x80);
                len += 1;
                unsigned >>= 7;
            }
            encoded[len] = @intCast(unsigned);
            try packet.writeAll(encoded[0 .. len + 1]);
        }

        pub fn writeString(packet: Self, value: []const u8, comptime max_chars: usize) Error!void {
            const chars = std.unicode.utf8CountCodepoints(value) catch return error.StringTooLong;
            if (chars > max_chars) return error.StringTooLong;
            try packet.writeVarInt(@intCast(value.len));
            try packet.writeAll(value);
        }
    };
}

pub const PacketFrame = struct {
    writer: PacketWriter(Io.Writer.Allocating),

    pub fn init(buffer: *Io.Writer.Allocating, packet_id: i32) std.mem.Allocator.Error!PacketFrame {
        buffer.clearRetainingCapacity();
        var frame: PacketFrame = .{ .writer = .init(buffer) };
        try frame.writer.writeVarInt(packet_id);
        return frame;
    }

    pub fn packetData(frame: *const PacketFrame) []const u8 {
        return frame.writer.backend.written();
    }

    pub fn finish(frame: *PacketFrame, compression: Compression) PacketError![]u8 {
        const allocator = frame.writer.backend.allocator;
        var out: Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try appendPacketFrame(allocator, &out, frame.packetData(), compression, null, null);
        return try out.toOwnedSlice();
    }

    pub fn takePacketData(frame: *PacketFrame) std.mem.Allocator.Error![]u8 {
        return try frame.writer.backend.toOwnedSlice();
    }
};

pub fn appendPacketFrame(
    allocator: std.mem.Allocator,
    out: *Io.Writer.Allocating,
    packet_data: []const u8,
    compression: Compression,
    compress_buf: ?*std.ArrayList(u8),
    compress_window: ?[]u8,
) PacketError!void {
    if (packet_data.len > max_packet_len) return error.PacketTooLarge;
    var packet: PacketWriter(Io.Writer.Allocating) = .init(out);
    const threshold = compression.threshold() orelse {
        try packet.writeVarInt(@intCast(packet_data.len));
        try packet.writeBytes(packet_data);
        return;
    };

    if (comptime !compression_enabled) {
        unreachable;
    }

    if (threshold > 0 and packet_data.len < @as(usize, @intCast(threshold))) {
        try packet.writeVarInt(@intCast(1 + packet_data.len));
        try packet.writeByte(0);
        try packet.writeBytes(packet_data);
        return;
    }

    var local_buf: std.ArrayList(u8) = .empty;
    defer local_buf.deinit(allocator);
    const buf = compress_buf orelse &local_buf;

    const window = compress_window orelse try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer if (compress_window == null) allocator.free(window);

    try compressPacketInto(allocator, buf, packet_data, window);

    const data_len_len = varIntLen(@intCast(packet_data.len));
    try packet.writeVarInt(@intCast(data_len_len + buf.items.len));
    try packet.writeVarInt(@intCast(packet_data.len));
    try packet.writeBytes(buf.items);
}

pub const PacketReader = struct {
    pub const VarIntError = error{VarIntTooLong} || Io.Reader.Error;
    pub const Error = error{
        NegativeLength,
        StringTooLong,
        MalformedPacket,
    } || VarIntError;

    reader: *Io.Reader,

    pub fn init(reader: *Io.Reader) PacketReader {
        return .{ .reader = reader };
    }

    pub fn readI32(self: PacketReader) Io.Reader.Error!i32 {
        return self.reader.takeInt(i32, .big);
    }

    pub fn readI64(self: PacketReader) Io.Reader.Error!i64 {
        return self.reader.takeInt(i64, .big);
    }

    pub fn readF32(self: PacketReader) Io.Reader.Error!f32 {
        return @bitCast(try self.readI32());
    }

    pub fn readF64(self: PacketReader) Io.Reader.Error!f64 {
        return @bitCast(try self.readI64());
    }

    pub fn readUuid(self: PacketReader) Io.Reader.Error![16]u8 {
        return (try self.reader.takeArray(16)).*;
    }

    /// A decoded VarInt plus the number of bytes it occupied. Encodings may be
    /// non-canonical, so the length cannot be derived from the value.
    pub const VarInt = struct { value: i32, len: usize };

    pub fn readVarIntSized(self: PacketReader) VarIntError!VarInt {
        var value: u32 = 0;
        for (0..5) |i| {
            const byte = try self.reader.takeByte();
            value |= @as(u32, byte & 0x7f) << @intCast(i * 7);
            if ((byte & 0x80) == 0) return .{ .value = @bitCast(value), .len = i + 1 };
        }
        return error.VarIntTooLong;
    }

    pub fn readVarInt(self: PacketReader) VarIntError!i32 {
        return (try self.readVarIntSized()).value;
    }

    pub fn readString(self: PacketReader, comptime max_chars: usize) Error![]const u8 {
        const len = try self.readVarInt();
        if (len < 0) return error.NegativeLength;
        const usize_len: usize = @intCast(len);
        // Vanilla bounds serverbound strings at max_chars * 3 (UTF-16 code
        // units, 3 bytes each). We count codepoints instead, so use the UTF-8
        // worst case of 4 bytes per codepoint to avoid rejecting strings that
        // pass the codepoint check below.
        if (usize_len > max_chars * 4) return error.StringTooLong;
        const out = try self.reader.take(usize_len);
        const chars = std.unicode.utf8CountCodepoints(out) catch return error.MalformedPacket;
        if (chars > max_chars) {
            return error.StringTooLong;
        }
        return out;
    }
};

pub fn readPacketFrame(
    allocator: std.mem.Allocator,
    frame: []const u8,
    compression: Compression,
    decompress_buf: ?*std.ArrayList(u8),
    decompress_window: ?[]u8,
) PacketError!Packet {
    if (comptime !compression_enabled) {
        return packetFromPayload(frame);
    } else {
        var frame_reader: Io.Reader = .fixed(frame);
        var packet_reader = PacketReader.init(&frame_reader);
        switch (compression) {
            .disabled => return packetFromPayload(frame),
            .enabled => {
                const data_len = try packet_reader.readVarInt();
                if (data_len < 0) return error.NegativeLength;
                if (data_len > max_packet_len) return error.PacketTooLarge;

                const remaining = frame[frame_reader.seek..frame_reader.end];
                if (data_len == 0) return packetFromPayload(remaining);

                const decomp_buf = decompress_buf orelse return error.CompressionThresholdUnsupported;
                const window = decompress_window orelse return error.CompressionThresholdUnsupported;
                try decomp_buf.resize(allocator, @intCast(data_len));
                const payload = try decompressPacketInto(remaining, decomp_buf.items, window);
                return packetFromPayload(payload);
            },
        }
    }
}

pub fn packetFromPayload(payload: []const u8) PacketError!Packet {
    var payload_reader: Io.Reader = .fixed(payload);
    var packet_reader = PacketReader.init(&payload_reader);
    const id = try packet_reader.readVarInt();
    return .{
        .id = id,
        .payload = payload[payload_reader.seek..payload_reader.end],
    };
}

/// Decodes just the packet id from a (possibly partial) compressed frame body
/// without fully decompressing it. Returns null when more bytes are needed to
/// decide; malformed data is rejected even when the frame is still incomplete.
pub fn peekCompressedPacketId(compressed: []const u8, window: []u8) PacketError!?i32 {
    if (compressed.len < 2) return null;
    try validateZlibHeader(compressed);
    var input: Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, window);
    var packet_reader = PacketReader.init(&decompress.reader);
    return packet_reader.readVarInt() catch |err| switch (err) {
        // Decompress surfaces truncated input as ReadFailed with its err field
        // set to EndOfStream: more frame bytes are needed, not corruption.
        error.ReadFailed => {
            const cause = decompress.err orelse return error.MalformedPacket;
            return if (cause == error.EndOfStream) null else error.MalformedPacket;
        },
        error.EndOfStream => error.MalformedPacket,
        error.VarIntTooLong => error.VarIntTooLong,
    };
}

/// Reads a complete compressed frame body (the bytes after the data length
/// prefix), decompressing at most once. The packet id is decoded directly off
/// the stream; when `isHandled` rejects it, decompression stops early and null
/// is returned. Otherwise the payload is decompressed into decomp_buf.
pub fn readCompressedPacket(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    data_len: usize,
    decomp_buf: *std.ArrayList(u8),
    window: []u8,
    comptime isHandled: fn (i32) bool,
) PacketError!?Packet {
    if (comptime !compression_enabled) unreachable;
    std.debug.assert(data_len > 0 and data_len <= max_packet_len);
    try validateZlibHeader(compressed);

    var input: Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, window);

    var packet_reader: PacketReader = .init(&decompress.reader);
    const id = packet_reader.readVarIntSized() catch |err| switch (err) {
        error.VarIntTooLong => return error.VarIntTooLong,
        error.ReadFailed, error.EndOfStream => return error.MalformedPacket,
    };
    if (!isHandled(id.value)) return null;

    if (data_len < id.len) return error.MalformedPacket;
    const payload_len = data_len - id.len;
    try decomp_buf.resize(allocator, payload_len);
    var fixed: Io.Writer = .fixed(decomp_buf.items);
    decompress.reader.streamExact(&fixed, payload_len) catch return error.MalformedPacket;

    try expectStreamEnd(&decompress.reader, &input);
    return .{ .id = id.value, .payload = decomp_buf.items };
}

pub const Compression = if (compression_enabled) union(enum) {
    disabled,
    enabled: i32,

    pub fn threshold(compression: Compression) ?i32 {
        return switch (compression) {
            .disabled => null,
            .enabled => |value| value,
        };
    }
} else enum {
    disabled,

    pub fn threshold(_: @This()) ?i32 {
        return null;
    }
};

pub fn varIntLen(value: i32) usize {
    var unsigned: u32 = @bitCast(value);
    var len: usize = 1;
    while ((unsigned & ~@as(u32, 0x7f)) != 0) {
        len += 1;
        unsigned >>= 7;
    }
    return len;
}

pub fn offlineUuid(username: []const u8) [16]u8 {
    var hash: [16]u8 = undefined;
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("OfflinePlayer:");
    md5.update(username);
    md5.final(&hash);

    hash[6] = (hash[6] & 0x0f) | 0x30;
    hash[8] = (hash[8] & 0x3f) | 0x80;
    return hash;
}

fn decompressPacketInto(compressed: []const u8, out: []u8, window: []u8) PacketError![]u8 {
    if (comptime !compression_enabled) unreachable;

    try validateZlibHeader(compressed);

    var input: Io.Reader = .fixed(compressed);

    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, window);
    var fixed: Io.Writer = .fixed(out);
    decompress.reader.streamExact(&fixed, out.len) catch return error.MalformedPacket;

    try expectStreamEnd(&decompress.reader, &input);
    return out;
}

/// The frame must decode to exactly the expected bytes: no trailing
/// decompressed output and no unconsumed compressed input.
fn expectStreamEnd(decompressed: *Io.Reader, input: *const Io.Reader) PacketError!void {
    var discard_buffer: [1024]u8 = undefined;
    var discard: Io.Writer.Discarding = .init(&discard_buffer);
    const extra = decompressed.streamRemaining(&discard.writer) catch return error.MalformedPacket;
    if (extra != 0) return error.MalformedPacket;
    if (input.seek != input.end) return error.MalformedPacket;
}

fn validateZlibHeader(compressed: []const u8) PacketError!void {
    if (compressed.len < 2) return error.MalformedPacket;

    const cmf = compressed[0];
    const flg = compressed[1];

    const compression_method = cmf & 0x0f;
    const window_size = cmf >> 4;
    const header_check = (@as(u16, cmf) << 8) | flg;
    const has_preset_dictionary = (flg & 0x20) != 0;

    if (compression_method != 8) return error.MalformedPacket;
    if (window_size > 7) return error.MalformedPacket;
    if (header_check % 31 != 0) return error.MalformedPacket;
    if (has_preset_dictionary) return error.MalformedPacket;
}

fn compressPacketInto(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    plain: []const u8,
    window: []u8,
) PacketError!void {
    buf.clearRetainingCapacity();
    const out_bound = plain.len + plain.len / 16_383 * 5 + 64;
    try buf.ensureTotalCapacity(allocator, out_bound);
    var output: Io.Writer.Allocating = .fromArrayList(allocator, buf);
    defer buf.* = output.toArrayList();

    var compress = try std.compress.flate.Compress.init(&output.writer, window, .zlib, .fastest);
    try compress.writer.writeAll(plain);
    try compress.finish();
}

test "varint round trips protocol values" {
    const values = [_]i32{ 0, 1, 2, 127, 128, 255, 2147483647, -1 };
    for (values) |value| {
        var buffer: Io.Writer.Allocating = .init(std.testing.allocator);
        defer buffer.deinit();
        var packet_writer = PacketWriter(Io.Writer.Allocating).init(&buffer);
        try packet_writer.writeVarInt(value);
        var reader: Io.Reader = .fixed(buffer.written());
        var packet_reader = PacketReader.init(&reader);
        try std.testing.expectEqual(value, try packet_reader.readVarInt());
    }
}

test "varint rejects five continuation bytes without overflowing" {
    var reader: Io.Reader = .fixed(&.{ 0xff, 0xff, 0xff, 0xff, 0xff });
    var packet_reader = PacketReader.init(&reader);
    try std.testing.expectError(error.VarIntTooLong, packet_reader.readVarInt());
}

test "PacketWriter writes to an arbitrary Io.Writer" {
    var storage: [6]u8 = undefined;
    var io_writer: Io.Writer = .fixed(&storage);
    var packet_writer = PacketWriter(Io.Writer).init(&io_writer);

    try packet_writer.writeVarInt(300);
    try packet_writer.writeI32(0x0102_0304);

    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02, 0x01, 0x02, 0x03, 0x04 }, io_writer.buffered());
}

test "PacketWriter writes f32 values as big-endian IEEE bits" {
    var buffer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var frame = try PacketFrame.init(&buffer, 0);
    try frame.writer.writeF32(5.0);

    const payload = frame.packetData()[1..];
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0xa0, 0x00, 0x00 }, payload);
}

test "PacketWriter reports its own string validation error" {
    var buffer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var packet_writer = PacketWriter(Io.Writer.Allocating).init(&buffer);

    try std.testing.expectError(error.StringTooLong, packet_writer.writeString("too long", 3));
}

test "appendPacketFrame frames cached packet bodies like PacketFrame" {
    var buffer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var frame_builder = try PacketFrame.init(&buffer, 0x2b);
    try frame_builder.writer.writeI64(42);

    const frame = try frame_builder.finish(.disabled);
    defer std.testing.allocator.free(frame);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try appendPacketFrame(std.testing.allocator, &out, frame_builder.packetData(), .disabled, null, null);

    try std.testing.expectEqualSlices(u8, frame, out.written());
}

test "appendPacketFrame reuses caller-provided compression scratch" {
    if (comptime !compression_enabled) {
        return error.SkipZigTest;
    } else {
        const allocator = std.testing.allocator;
        var buffer: Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        var frame_builder = try PacketFrame.init(&buffer, 0x2b);
        var payload: [1024]u8 = undefined;
        var random: u32 = 0x1234_5678;
        for (&payload) |*byte| {
            random = random *% 1_664_525 +% 1_013_904_223;
            byte.* = @truncate(random >> 16);
        }
        try frame_builder.writer.writeBytes(&payload);

        var fresh: Io.Writer.Allocating = .init(allocator);
        defer fresh.deinit();
        try appendPacketFrame(allocator, &fresh, frame_builder.packetData(), .{ .enabled = 0 }, null, null);

        var scratch_buf: std.ArrayList(u8) = .empty;
        defer scratch_buf.deinit(allocator);
        const scratch_window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(scratch_window);

        var reused: Io.Writer.Allocating = .init(allocator);
        defer reused.deinit();
        for (0..2) |_| {
            reused.clearRetainingCapacity();
            try appendPacketFrame(allocator, &reused, frame_builder.packetData(), .{ .enabled = 0 }, &scratch_buf, scratch_window);
            try std.testing.expectEqualSlices(u8, fresh.written(), reused.written());
        }
    }
}

test "peekCompressedPacketId validates headers and tolerates truncation" {
    if (comptime !compression_enabled) {
        return error.SkipZigTest;
    } else {
        const allocator = std.testing.allocator;
        var buffer: Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        var frame_builder = try PacketFrame.init(&buffer, 0x2b);
        try frame_builder.writer.writeI64(42);

        const frame = try frame_builder.finish(.{ .enabled = 0 });
        defer allocator.free(frame);

        var frame_reader: Io.Reader = .fixed(frame);
        var packet_reader = PacketReader.init(&frame_reader);
        _ = try packet_reader.readVarInt();
        _ = try packet_reader.readVarInt();
        const compressed = frame[frame_reader.seek..];

        const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(window);

        try std.testing.expectEqual(@as(?i32, 0x2b), try peekCompressedPacketId(compressed, window));
        // A single byte cannot even hold the zlib header yet.
        try std.testing.expectEqual(@as(?i32, null), try peekCompressedPacketId(compressed[0..1], window));
        // A malformed zlib header is rejected even while incomplete.
        try std.testing.expectError(error.MalformedPacket, peekCompressedPacketId(&.{ 0x78, 0x00 }, window));
    }
}

test "readCompressedPacket decompresses handled packets exactly once and skips others" {
    if (comptime !compression_enabled) {
        return error.SkipZigTest;
    } else {
        const allocator = std.testing.allocator;
        var buffer: Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        var frame_builder = try PacketFrame.init(&buffer, 0x2b);
        try frame_builder.writer.writeI64(42);
        const data_len = frame_builder.packetData().len;

        const frame = try frame_builder.finish(.{ .enabled = 0 });
        defer allocator.free(frame);

        var frame_reader: Io.Reader = .fixed(frame);
        var packet_reader = PacketReader.init(&frame_reader);
        _ = try packet_reader.readVarInt();
        _ = try packet_reader.readVarInt();
        const compressed = frame[frame_reader.seek..];

        const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(window);
        var decomp_buf: std.ArrayList(u8) = .empty;
        defer decomp_buf.deinit(allocator);

        const handled = struct {
            fn accept(_: i32) bool {
                return true;
            }
            fn reject(_: i32) bool {
                return false;
            }
        };

        const packet = (try readCompressedPacket(allocator, compressed, data_len, &decomp_buf, window, handled.accept)).?;
        try std.testing.expectEqual(@as(i32, 0x2b), packet.id);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 42 }, packet.payload);

        try std.testing.expectEqual(@as(?Packet, null), try readCompressedPacket(allocator, compressed, data_len, &decomp_buf, window, handled.reject));

        // A declared length that disagrees with the stream is malformed.
        try std.testing.expectError(error.MalformedPacket, readCompressedPacket(allocator, compressed, data_len - 1, &decomp_buf, window, handled.accept));
    }
}

test "readPacketFrame borrows uncompressed payload bytes" {
    const allocator = std.testing.allocator;
    var buffer: Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    var frame_builder = try PacketFrame.init(&buffer, 0x2b);
    try frame_builder.writer.writeI64(42);

    const frame = try frame_builder.finish(.disabled);
    defer allocator.free(frame);

    var frame_reader: Io.Reader = .fixed(frame);
    var packet_reader = PacketReader.init(&frame_reader);
    _ = try packet_reader.readVarInt();
    const body = frame[frame_reader.seek..];

    const packet = try readPacketFrame(allocator, body, .disabled, null, null);

    try std.testing.expectEqual(@as(i32, 0x2b), packet.id);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 42 }, packet.payload);
    try std.testing.expect(@intFromPtr(packet.payload.ptr) >= @intFromPtr(body.ptr));
    try std.testing.expect(@intFromPtr(packet.payload.ptr) < @intFromPtr(body.ptr) + body.len);
}

test "readPacketFrame decodes compressed packets with valid zlib headers" {
    if (comptime !compression_enabled) {
        return error.SkipZigTest;
    } else {
        const allocator = std.testing.allocator;
        var buffer: Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        var frame_builder = try PacketFrame.init(&buffer, 0x2b);
        try frame_builder.writer.writeI64(42);

        const frame = try frame_builder.finish(.{ .enabled = 0 });
        defer allocator.free(frame);

        var frame_reader: Io.Reader = .fixed(frame);
        var packet_reader = PacketReader.init(&frame_reader);
        const frame_len = try packet_reader.readVarInt();
        try std.testing.expectEqual(@as(usize, @intCast(frame_len)), frame[frame_reader.seek..].len);

        const decomp_window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(decomp_window);
        var decomp_buf: std.ArrayList(u8) = .empty;
        defer decomp_buf.deinit(allocator);
        const packet = try readPacketFrame(allocator, frame[frame_reader.seek..], .{ .enabled = 0 }, &decomp_buf, decomp_window);

        try std.testing.expectEqual(@as(i32, 0x2b), packet.id);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 42 }, packet.payload);
    }
}

test "readPacketFrame rejects compressed packets with malformed zlib headers" {
    if (comptime !compression_enabled) {
        return error.SkipZigTest;
    } else {
        const allocator = std.testing.allocator;
        var frame: Io.Writer.Allocating = .init(allocator);
        defer frame.deinit();
        var packet_writer = PacketWriter(Io.Writer.Allocating).init(&frame);
        try packet_writer.writeVarInt(1);
        try packet_writer.writeBytes(&.{ 0x78, 0x00 });

        const decomp_window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(decomp_window);
        var decomp_buf: std.ArrayList(u8) = .empty;
        defer decomp_buf.deinit(allocator);
        try std.testing.expectError(error.MalformedPacket, readPacketFrame(allocator, frame.written(), .{ .enabled = 0 }, &decomp_buf, decomp_window));
    }
}

test "readPacketFrame rejects compressed packets with wrong declared data length" {
    if (comptime !compression_enabled) {
        return error.SkipZigTest;
    } else {
        const allocator = std.testing.allocator;
        var buffer: Io.Writer.Allocating = .init(allocator);
        defer buffer.deinit();
        var frame_builder = try PacketFrame.init(&buffer, 0x2b);
        try frame_builder.writer.writeI64(42);

        const original = try frame_builder.finish(.{ .enabled = 0 });
        defer allocator.free(original);

        var frame_reader: Io.Reader = .fixed(original);
        var packet_reader = PacketReader.init(&frame_reader);
        _ = try packet_reader.readVarInt();
        const frame = original[frame_reader.seek..];
        try std.testing.expect(frame[0] > 1);

        const corrupted = try allocator.dupe(u8, frame);
        defer allocator.free(corrupted);
        corrupted[0] -= 1;

        const decomp_window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(decomp_window);
        var decomp_buf: std.ArrayList(u8) = .empty;
        defer decomp_buf.deinit(allocator);
        try std.testing.expectError(error.MalformedPacket, readPacketFrame(allocator, corrupted, .{ .enabled = 0 }, &decomp_buf, decomp_window));
    }
}

test "offline UUID matches Notchian v3 shape" {
    const uuid = offlineUuid("Notch");
    try std.testing.expectEqual(@as(u8, 0x30), uuid[6] & 0xf0);
    try std.testing.expectEqual(@as(u8, 0x80), uuid[8] & 0xc0);
}

test "fuzz VarInt decoding" {
    try std.testing.fuzz({}, fuzzVarIntDecoding, .{ .corpus = &.{
        "\x01\x00\x00\x00\x00",
        "\x05\x00\x00\x00\xff\xff\xff\xff\xff",
        "\x05\x00\x00\x00\xff\xff\xff\xff\x07",
    } });
}

fn fuzzVarIntDecoding(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [16]u8 = undefined;
    const len: usize = smith.slice(&bytes);
    var reader: Io.Reader = .fixed(bytes[0..len]);
    var packet_reader = PacketReader.init(&reader);
    _ = packet_reader.readVarInt() catch |err| switch (err) {
        error.EndOfStream, error.VarIntTooLong => return,
        else => return err,
    };
    try std.testing.expect(reader.seek <= len);
    try std.testing.expect(reader.seek <= 5);
}

test "fuzz packet framing round trips" {
    try std.testing.fuzz({}, fuzzPacketFramingRoundTrip, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xff\x05\x00\x00\x00hello",
        "\x80\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x7f\x80\xff",
    } });
}

fn fuzzPacketFramingRoundTrip(_: void, smith: *std.testing.Smith) anyerror!void {
    const packet_id = smith.value(i32);
    var payload_buf: [512]u8 = undefined;
    const payload_len: usize = smith.slice(&payload_buf);
    const payload = payload_buf[0..payload_len];

    var buffer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var frame_builder = try PacketFrame.init(&buffer, packet_id);
    try frame_builder.writer.writeBytes(payload);

    const frame = try frame_builder.finish(.disabled);
    defer std.testing.allocator.free(frame);
    var frame_reader: Io.Reader = .fixed(frame);
    var packet_reader = PacketReader.init(&frame_reader);
    const frame_len = try packet_reader.readVarInt();
    try std.testing.expectEqual(frame[frame_reader.seek..].len, @as(usize, @intCast(frame_len)));

    const decoded = try readPacketFrame(std.testing.allocator, frame[frame_reader.seek..], .disabled, null, null);
    try std.testing.expectEqual(packet_id, decoded.id);
    try std.testing.expectEqualSlices(u8, payload, decoded.payload);
}
