pub const Release = struct {
    minecraft_version: []const u8,
    protocol_version: i32,
    implementation_file: []const u8,
};

const v26_1_implementation = "26_1";
const v26_3_snapshot_3_implementation = "26_3_snapshot_3";

pub const latest: Release = .{
    .minecraft_version = "26.2",
    .protocol_version = 776,
    .implementation_file = v26_1_implementation,
};

pub const all = [_]Release{
    .{ .minecraft_version = "26.1", .protocol_version = 775, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.1-rc-1", .protocol_version = 1073742128, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.1", .protocol_version = 775, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26w14a", .protocol_version = 1073742129, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-1", .protocol_version = 1073742130, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.2-rc-1", .protocol_version = 1073742131, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.2", .protocol_version = 775, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-2", .protocol_version = 1073742132, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-3", .protocol_version = 1073742133, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-4", .protocol_version = 1073742134, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-5", .protocol_version = 1073742135, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-6", .protocol_version = 1073742136, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-7", .protocol_version = 1073742137, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-8", .protocol_version = 1073742138, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-1", .protocol_version = 1073742139, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-2", .protocol_version = 1073742140, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-3", .protocol_version = 1073742141, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-4", .protocol_version = 1073742142, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-5", .protocol_version = 1073742143, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-6", .protocol_version = 1073742144, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-rc-1", .protocol_version = 1073742145, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-rc-2", .protocol_version = 1073742146, .implementation_file = v26_1_implementation },
    latest,
    .{ .minecraft_version = "26.3-snapshot-1", .protocol_version = 1073742147, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.3-snapshot-2", .protocol_version = 1073742148, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.3-snapshot-3", .protocol_version = 1073742149, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-4", .protocol_version = 1073742150, .implementation_file = v26_3_snapshot_3_implementation },
};
