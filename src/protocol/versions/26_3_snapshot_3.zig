const v26_1 = @import("26_1.zig");
const std = @import("std");

pub const writeHandshake = v26_1.writeHandshake;
pub const writeLoginStart = v26_1.writeLoginStart;
pub const writeClientInformation = v26_1.writeClientInformation;
pub const writeKnownPacks = v26_1.writeKnownPacks;
pub const writeChatMessage = v26_1.writeChatMessage;
pub const writeChunkBatchReceived = v26_1.writeChunkBatchReceived;
pub const writeAcceptTeleportation = v26_1.writeAcceptTeleportation;
pub const writeMovementStatusOnly = v26_1.writeMovementStatusOnly;
pub const writeMovementRotation = v26_1.writeMovementRotation;
pub const writeMovementPositionRotation = v26_1.writeMovementPositionRotation;
pub const writeResourcePackResponse = v26_1.writeResourcePackResponse;
pub const writeKeepAlive = v26_1.writeKeepAlive;
pub const writePong = v26_1.writePong;

pub const packet_ids = struct {
    pub const handshake = v26_1.packet_ids.handshake;
    pub const status = v26_1.packet_ids.status;
    pub const login = v26_1.packet_ids.login;
    pub const configuration = struct {
        pub const clientbound = struct {
            pub const plugin_message = 0x01;
            pub const disconnect = 0x02;
            pub const finish = 0x03;
            pub const keep_alive = 0x04;
            pub const ping = 0x05;
            pub const add_resource_pack = 0x09;
            pub const known_packs = 0x0f;
        };
        pub const serverbound = v26_1.packet_ids.configuration.serverbound;
    };
    pub const play = struct {
        pub const clientbound = struct {
            pub const chunk_batch_finished = 0x0b;
            pub const disconnect = 0x20;
            pub const keep_alive = 0x2c;
            pub const login = 0x31;
            pub const ping = 0x3d;
            pub const player_position = 0x48;
            pub const start_configuration = 0x77;
        };
        pub const serverbound = v26_1.packet_ids.play.serverbound;
    };
};

test "26.3 snapshot 3 post-effects packet shifts" {
    try std.testing.expectEqual(@as(i32, 0x0f), packet_ids.configuration.clientbound.known_packs);
    try std.testing.expectEqual(@as(i32, 0x77), packet_ids.play.clientbound.start_configuration);
}
