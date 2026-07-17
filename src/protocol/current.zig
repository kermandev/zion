const std = @import("std");
const build_options = @import("build_options");
const protocol = @import("../protocol.zig");
const features = @import("../features.zig");

const version = @import("minecraft_version");

pub const minecraft_version = build_options.minecraft_version;
pub const protocol_version = build_options.minecraft_protocol_version;
pub const packet_ids = version.packet_ids;

pub fn writeHandshake(packet: anytype, host: []const u8, port: u16, next_state: protocol.State) @TypeOf(packet.*).Error!void {
    return version.writeHandshake(packet, host, port, next_state, protocol_version);
}

pub fn writeLoginStart(packet: anytype, username: []const u8) @TypeOf(packet.*).Error!void {
    return version.writeLoginStart(packet, username, protocol.offlineUuid(username));
}
pub const writeClientInformation = version.writeClientInformation;
pub fn writeKnownPacks(packet: anytype, include_core: bool) @TypeOf(packet.*).Error!void {
    return version.writeKnownPacks(packet, if (include_core) minecraft_version else null);
}
pub const writeChatMessage = version.writeChatMessage;
pub const writeChunkBatchReceived = version.writeChunkBatchReceived;
pub const writeAcceptTeleportation = version.writeAcceptTeleportation;
pub const writeMovementStatusOnly = version.writeMovementStatusOnly;
pub const writeMovementRotation = if (features.movement) version.writeMovementRotation else {};
pub const writeMovementPositionRotation = if (features.movement) version.writeMovementPositionRotation else {};
pub const writeResourcePackResponse = version.writeResourcePackResponse;
pub const writeKeepAlive = version.writeKeepAlive;
pub const writePong = version.writePong;

test "selected version writes its protocol number" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var frame = try protocol.PacketFrame.init(&buffer, packet_ids.handshake.serverbound.intention);
    try writeHandshake(&frame.writer, "localhost", 25565, .login);

    var reader: std.Io.Reader = .fixed(frame.packetData());
    var packet_reader = protocol.PacketReader.init(&reader);
    try std.testing.expectEqual(packet_ids.handshake.serverbound.intention, try packet_reader.readVarInt());
    try std.testing.expectEqual(protocol_version, try packet_reader.readVarInt());
    try std.testing.expectEqualStrings(build_options.minecraft_version, minecraft_version);
}

test "selected version writes its current core known pack" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var frame = try protocol.PacketFrame.init(&buffer, packet_ids.configuration.serverbound.known_packs);
    try writeKnownPacks(&frame.writer, true);

    var reader: std.Io.Reader = .fixed(frame.packetData());
    var packet_reader = protocol.PacketReader.init(&reader);
    try std.testing.expectEqual(packet_ids.configuration.serverbound.known_packs, try packet_reader.readVarInt());
    try std.testing.expectEqual(@as(i32, 1), try packet_reader.readVarInt());
    try std.testing.expectEqualStrings("minecraft", try packet_reader.readString(protocol.max_string_chars));
    try std.testing.expectEqualStrings("core", try packet_reader.readString(protocol.max_string_chars));
    try std.testing.expectEqualStrings(minecraft_version, try packet_reader.readString(protocol.max_string_chars));

    frame = try protocol.PacketFrame.init(&buffer, packet_ids.configuration.serverbound.known_packs);
    try writeKnownPacks(&frame.writer, false);
    reader = .fixed(frame.packetData());
    packet_reader = protocol.PacketReader.init(&reader);
    _ = try packet_reader.readVarInt();
    try std.testing.expectEqual(@as(i32, 0), try packet_reader.readVarInt());
}

test "selected version writes login start username and offline uuid" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var frame = try protocol.PacketFrame.init(&buffer, packet_ids.login.serverbound.login_start);
    try writeLoginStart(&frame.writer, "Zion0");

    var reader: std.Io.Reader = .fixed(frame.packetData());
    var packet_reader = protocol.PacketReader.init(&reader);
    try std.testing.expectEqual(packet_ids.login.serverbound.login_start, try packet_reader.readVarInt());
    const username = try packet_reader.readString(16);
    try std.testing.expectEqualStrings("Zion0", username);
    try std.testing.expectEqualSlices(u8, &protocol.offlineUuid("Zion0"), &(try packet_reader.readUuid()));
}

test "selected version writes chat body shape" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var frame = try protocol.PacketFrame.init(&buffer, packet_ids.play.serverbound.chat);
    try writeChatMessage(&frame.writer, "hello", 1234);

    var reader: std.Io.Reader = .fixed(frame.packetData());
    var packet_reader = protocol.PacketReader.init(&reader);
    try std.testing.expectEqual(packet_ids.play.serverbound.chat, try packet_reader.readVarInt());
    const message = try packet_reader.readString(256);
    try std.testing.expectEqualStrings("hello", message);
    try std.testing.expectEqual(@as(i64, 1234), try packet_reader.readI64());
}
