const v26_3_snapshot_3 = @import("26_3_snapshot_3.zig");
const std = @import("std");

pub const writeHandshake = v26_3_snapshot_3.writeHandshake;
pub const writeLoginStart = v26_3_snapshot_3.writeLoginStart;
pub const writeClientInformation = v26_3_snapshot_3.writeClientInformation;
pub const writeKnownPacks = v26_3_snapshot_3.writeKnownPacks;
pub const writeChatMessage = v26_3_snapshot_3.writeChatMessage;
pub const writeChunkBatchReceived = v26_3_snapshot_3.writeChunkBatchReceived;
pub const writeMovementStatusOnly = v26_3_snapshot_3.writeMovementStatusOnly;
pub const writeMovementRotation = v26_3_snapshot_3.writeMovementRotation;
pub const writeMovementPositionRotation = v26_3_snapshot_3.writeMovementPositionRotation;
pub const writeResourcePackResponse = v26_3_snapshot_3.writeResourcePackResponse;
pub const writeKeepAlive = v26_3_snapshot_3.writeKeepAlive;
pub const writePong = v26_3_snapshot_3.writePong;

/// The teleport acknowledgement carries the client's resolved absolute
/// position and rotation after the teleport id. The server rejects NaN
/// coordinates and non-finite angles with a disconnect.
pub const accept_teleportation_includes_pose = true;

pub fn writeAcceptTeleportation(packet: anytype, teleport_id: i32, x: f64, y: f64, z: f64, yaw: f32, pitch: f32) @TypeOf(packet.*).Error!void {
    try packet.writeVarInt(teleport_id);
    try packet.writeF64(x);
    try packet.writeF64(y);
    try packet.writeF64(z);
    try packet.writeF32(yaw);
    try packet.writeF32(pitch);
}

pub const packet_ids = v26_3_snapshot_3.packet_ids;

test "26.3 snapshot 10 keeps the snapshot 3 ids and echoes the pose" {
    try std.testing.expect(accept_teleportation_includes_pose);
    try std.testing.expect(!v26_3_snapshot_3.accept_teleportation_includes_pose);
    try std.testing.expectEqual(@as(i32, 0x00), packet_ids.play.serverbound.accept_teleportation);
    try std.testing.expectEqual(@as(i32, 0x0f), packet_ids.configuration.clientbound.known_packs);
    try std.testing.expectEqual(@as(i32, 0x77), packet_ids.play.clientbound.start_configuration);
}
