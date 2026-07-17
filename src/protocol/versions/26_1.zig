const std = @import("std");

pub fn writeHandshake(packet: anytype, host: []const u8, port: u16, next_state: anytype, protocol_version: i32) @TypeOf(packet.*).Error!void {
    try packet.writeVarInt(protocol_version);
    try packet.writeString(host, 255);
    try packet.writeU16(port);
    try packet.writeVarInt(@intFromEnum(next_state));
}

pub fn writeLoginStart(packet: anytype, username: []const u8, offline_uuid: [16]u8) @TypeOf(packet.*).Error!void {
    try packet.writeString(username, 16);
    try packet.writeUuid(offline_uuid);
}

pub fn writeClientInformation(packet: anytype) @TypeOf(packet.*).Error!void {
    try packet.writeString("en_us", 16);
    try packet.writeByte(2);
    try packet.writeVarInt(0);
    try packet.writeBool(true);
    try packet.writeByte(0x7f);
    try packet.writeVarInt(1);
    try packet.writeBool(false);
    try packet.writeBool(true);
    try packet.writeVarInt(0);
}

pub fn writeKnownPacks(packet: anytype, core_version: ?[]const u8) @TypeOf(packet.*).Error!void {
    const version = core_version orelse return packet.writeVarInt(0);
    try packet.writeVarInt(1);
    try packet.writeString("minecraft", std.math.maxInt(i32));
    try packet.writeString("core", std.math.maxInt(i32));
    try packet.writeString(version, std.math.maxInt(i32));
}

pub fn writeChatMessage(packet: anytype, message: []const u8, real_ms: i64) @TypeOf(packet.*).Error!void {
    try packet.writeString(message, 256);
    try packet.writeI64(real_ms);
    try packet.writeI64(0);
    try packet.writeBool(false);
    try packet.writeVarInt(0);
    try packet.writeBytes(&.{ 0, 0, 0 });
    try packet.writeByte(0);
}

pub fn writeChunkBatchReceived(packet: anytype) @TypeOf(packet.*).Error!void {
    try packet.writeF32(1.0);
}

pub fn writeAcceptTeleportation(packet: anytype, teleport_id: i32) @TypeOf(packet.*).Error!void {
    try packet.writeVarInt(teleport_id);
}

pub fn writeMovementStatusOnly(packet: anytype) @TypeOf(packet.*).Error!void {
    try packet.writeByte(0x01);
}

pub fn writeMovementRotation(packet: anytype, yaw: f32, pitch: f32) @TypeOf(packet.*).Error!void {
    try packet.writeF32(yaw);
    try packet.writeF32(pitch);
    try packet.writeByte(0x01);
}

pub fn writeMovementPositionRotation(packet: anytype, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) @TypeOf(packet.*).Error!void {
    try packet.writeF64(x);
    try packet.writeF64(y);
    try packet.writeF64(z);
    try packet.writeF32(yaw);
    try packet.writeF32(pitch);
    try packet.writeByte(0x01);
}

pub fn writeResourcePackResponse(packet: anytype, uuid: [16]u8) @TypeOf(packet.*).Error!void {
    try packet.writeUuid(uuid);
    try packet.writeVarInt(1);
}

pub fn writeKeepAlive(packet: anytype, keep_alive_id: i64) @TypeOf(packet.*).Error!void {
    try packet.writeI64(keep_alive_id);
}

pub fn writePong(packet: anytype, ping_id: i32) @TypeOf(packet.*).Error!void {
    try packet.writeI32(ping_id);
}

pub const packet_ids = struct {
    pub const handshake = struct {
        pub const serverbound = struct {
            pub const intention = 0x00;
        };
    };
    pub const status = struct {
        pub const clientbound = struct {
            pub const response = 0x00;
        };
        pub const serverbound = struct {
            pub const request = 0x00;
        };
    };
    pub const login = struct {
        pub const clientbound = struct {
            pub const disconnect = 0x00;
            pub const encryption_request = 0x01;
            pub const login_success = 0x02;
            pub const set_compression = 0x03;
        };
        pub const serverbound = struct {
            pub const login_start = 0x00;
            pub const acknowledged = 0x03;
        };
    };
    pub const configuration = struct {
        pub const clientbound = struct {
            pub const plugin_message = 0x01;
            pub const disconnect = 0x02;
            pub const finish = 0x03;
            pub const keep_alive = 0x04;
            pub const ping = 0x05;
            pub const add_resource_pack = 0x09;
            pub const known_packs = 0x0e;
        };
        pub const serverbound = struct {
            pub const client_information = 0x00;
            pub const finish = 0x03;
            pub const keep_alive = 0x04;
            pub const pong = 0x05;
            pub const resource_pack_response = 0x06;
            pub const known_packs = 0x07;
        };
    };
    pub const play = struct {
        pub const clientbound = struct {
            pub const chunk_batch_finished = 0x0b;
            pub const disconnect = 0x20;
            pub const keep_alive = 0x2c;
            pub const login = 0x31;
            pub const ping = 0x3d;
            pub const player_position = 0x48;
            pub const start_configuration = 0x76;
        };
        pub const serverbound = struct {
            pub const accept_teleportation = 0x00;
            pub const client_information = 0x0e;
            pub const chat = 0x09;
            pub const chunk_batch_received = 0x0b;
            pub const client_tick_end = 0x0d;
            pub const configuration_acknowledged = 0x10;
            pub const keep_alive = 0x1c;
            pub const move_player_position = 0x1e;
            pub const move_player_position_rotation = 0x1f;
            pub const move_player_rotation = 0x20;
            pub const move_player_status_only = 0x21;
            pub const player_loaded = 0x2c;
            pub const pong = 0x2d;
        };
    };
};

test "26.1 packet ids" {
    const ids = packet_ids;
    try std.testing.expectEqual(@as(i32, 0x00), ids.handshake.serverbound.intention);
    try std.testing.expectEqual(@as(i32, 0x00), ids.status.clientbound.response);
    try std.testing.expectEqual(@as(i32, 0x00), ids.status.serverbound.request);
    try std.testing.expectEqual(@as(i32, 0x02), ids.login.clientbound.login_success);
    try std.testing.expectEqual(@as(i32, 0x03), ids.configuration.clientbound.finish);
    try std.testing.expectEqual(@as(i32, 0x0b), ids.play.clientbound.chunk_batch_finished);
    try std.testing.expectEqual(@as(i32, 0x20), ids.play.clientbound.disconnect);
    try std.testing.expectEqual(@as(i32, 0x2c), ids.play.clientbound.keep_alive);
    try std.testing.expectEqual(@as(i32, 0x31), ids.play.clientbound.login);
    try std.testing.expectEqual(@as(i32, 0x3d), ids.play.clientbound.ping);
    try std.testing.expectEqual(@as(i32, 0x48), ids.play.clientbound.player_position);
    try std.testing.expectEqual(@as(i32, 0x76), ids.play.clientbound.start_configuration);
    try std.testing.expectEqual(@as(i32, 0x00), ids.play.serverbound.accept_teleportation);
    try std.testing.expectEqual(@as(i32, 0x09), ids.play.serverbound.chat);
    try std.testing.expectEqual(@as(i32, 0x0b), ids.play.serverbound.chunk_batch_received);
    try std.testing.expectEqual(@as(i32, 0x0d), ids.play.serverbound.client_tick_end);
    try std.testing.expectEqual(@as(i32, 0x10), ids.play.serverbound.configuration_acknowledged);
    try std.testing.expectEqual(@as(i32, 0x1c), ids.play.serverbound.keep_alive);
    try std.testing.expectEqual(@as(i32, 0x1e), ids.play.serverbound.move_player_position);
    try std.testing.expectEqual(@as(i32, 0x1f), ids.play.serverbound.move_player_position_rotation);
    try std.testing.expectEqual(@as(i32, 0x20), ids.play.serverbound.move_player_rotation);
    try std.testing.expectEqual(@as(i32, 0x21), ids.play.serverbound.move_player_status_only);
    try std.testing.expectEqual(@as(i32, 0x2c), ids.play.serverbound.player_loaded);
    try std.testing.expectEqual(@as(i32, 0x2d), ids.play.serverbound.pong);
}
