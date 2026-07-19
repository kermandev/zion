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
            const base = v26_1.packet_ids.configuration.clientbound;
            pub const plugin_message = base.plugin_message;
            pub const disconnect = base.disconnect;
            pub const finish = base.finish;
            pub const keep_alive = base.keep_alive;
            pub const ping = base.ping;
            pub const add_resource_pack = base.add_resource_pack;
            /// Shifted from 0x0e in 26.1.
            pub const known_packs = 0x0f;
        };
        pub const serverbound = v26_1.packet_ids.configuration.serverbound;
    };
    pub const play = struct {
        pub const clientbound = struct {
            const base = v26_1.packet_ids.play.clientbound;
            pub const chunk_batch_finished = base.chunk_batch_finished;
            pub const disconnect = base.disconnect;
            pub const keep_alive = base.keep_alive;
            pub const login = base.login;
            pub const ping = base.ping;
            pub const player_position = base.player_position;
            /// Shifted from 0x76 in 26.1.
            pub const start_configuration = 0x77;
        };
        pub const serverbound = v26_1.packet_ids.play.serverbound;
    };
};

test "26.3 snapshot 3 post-effects packet shifts" {
    try std.testing.expectEqual(@as(i32, 0x0f), packet_ids.configuration.clientbound.known_packs);
    try std.testing.expectEqual(@as(i32, 0x77), packet_ids.play.clientbound.start_configuration);
}
