const v26_3_snapshot_10 = @import("26_3_snapshot_10.zig");
const std = @import("std");

pub const writeHandshake = v26_3_snapshot_10.writeHandshake;
pub const writeLoginStart = v26_3_snapshot_10.writeLoginStart;
pub const writeClientInformation = v26_3_snapshot_10.writeClientInformation;
pub const writeKnownPacks = v26_3_snapshot_10.writeKnownPacks;
pub const writeChatMessage = v26_3_snapshot_10.writeChatMessage;
pub const writeChunkBatchReceived = v26_3_snapshot_10.writeChunkBatchReceived;
pub const writeAcceptTeleportation = v26_3_snapshot_10.writeAcceptTeleportation;
pub const writeMovementStatusOnly = v26_3_snapshot_10.writeMovementStatusOnly;
pub const writeMovementRotation = v26_3_snapshot_10.writeMovementRotation;
pub const writeMovementPositionRotation = v26_3_snapshot_10.writeMovementPositionRotation;
pub const writeResourcePackResponse = v26_3_snapshot_10.writeResourcePackResponse;
pub const writeKeepAlive = v26_3_snapshot_10.writeKeepAlive;
pub const writePong = v26_3_snapshot_10.writePong;

pub const accept_teleportation_includes_pose = v26_3_snapshot_10.accept_teleportation_includes_pose;

pub const packet_ids = struct {
    pub const handshake = v26_3_snapshot_10.packet_ids.handshake;
    pub const status = v26_3_snapshot_10.packet_ids.status;
    pub const login = v26_3_snapshot_10.packet_ids.login;
    pub const configuration = v26_3_snapshot_10.packet_ids.configuration;
    pub const play = struct {
        pub const clientbound = struct {
            const base = v26_3_snapshot_10.packet_ids.play.clientbound;
            pub const chunk_batch_finished = base.chunk_batch_finished;
            pub const disconnect = base.disconnect;
            /// Shifted from 0x2c by the add_transient_block packet inserted
            /// after disconnect.
            pub const keep_alive = 0x2d;
            /// Shifted from 0x31.
            pub const login = 0x32;
            /// Shifted from 0x3d.
            pub const ping = 0x3e;
            /// Shifted from 0x48.
            pub const player_position = 0x49;
            /// Shifted from 0x77.
            pub const start_configuration = 0x78;
        };
        pub const serverbound = v26_3_snapshot_10.packet_ids.play.serverbound;
    };
};

test "26.3 pre 3 transient block packet shifts" {
    try std.testing.expectEqual(@as(i32, 0x0b), packet_ids.play.clientbound.chunk_batch_finished);
    try std.testing.expectEqual(@as(i32, 0x20), packet_ids.play.clientbound.disconnect);
    try std.testing.expectEqual(@as(i32, 0x2d), packet_ids.play.clientbound.keep_alive);
    try std.testing.expectEqual(@as(i32, 0x32), packet_ids.play.clientbound.login);
    try std.testing.expectEqual(@as(i32, 0x3e), packet_ids.play.clientbound.ping);
    try std.testing.expectEqual(@as(i32, 0x49), packet_ids.play.clientbound.player_position);
    try std.testing.expectEqual(@as(i32, 0x78), packet_ids.play.clientbound.start_configuration);
}
