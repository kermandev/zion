pub const Release = struct {
    minecraft_version: []const u8,
    protocol_version: i32,
    implementation_file: []const u8,
};

const v26_1_implementation = "26_1";
const v26_3_snapshot_3_implementation = "26_3_snapshot_3";
const v26_3_snapshot_10_implementation = "26_3_snapshot_10";
const v26_3_pre_3_implementation = "26_3_pre_3";

/// Snapshot/pre-release/RC builds set bit 30 of the protocol version and
/// count a separate snapshot ordinal in the low bits (e.g. `snapshot_bit | 304`
/// is 1073742128).
const snapshot_bit: i32 = 1 << 30;

/// The newest stable release; `all` below is in release order, with `latest`
/// spliced in at its chronological position.
pub const latest: Release = .{
    .minecraft_version = "26.2",
    .protocol_version = 776,
    .implementation_file = v26_1_implementation,
};

pub const all = [_]Release{
    .{ .minecraft_version = "26.1", .protocol_version = 775, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.1-rc-1", .protocol_version = snapshot_bit | 304, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.1", .protocol_version = 775, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26w14a", .protocol_version = snapshot_bit | 305, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-1", .protocol_version = snapshot_bit | 306, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.2-rc-1", .protocol_version = snapshot_bit | 307, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.1.2", .protocol_version = 775, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-2", .protocol_version = snapshot_bit | 308, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-3", .protocol_version = snapshot_bit | 309, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-4", .protocol_version = snapshot_bit | 310, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-5", .protocol_version = snapshot_bit | 311, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-6", .protocol_version = snapshot_bit | 312, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-7", .protocol_version = snapshot_bit | 313, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-snapshot-8", .protocol_version = snapshot_bit | 314, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-1", .protocol_version = snapshot_bit | 315, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-2", .protocol_version = snapshot_bit | 316, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-3", .protocol_version = snapshot_bit | 317, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-4", .protocol_version = snapshot_bit | 318, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-5", .protocol_version = snapshot_bit | 319, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-pre-6", .protocol_version = snapshot_bit | 320, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-rc-1", .protocol_version = snapshot_bit | 321, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.2-rc-2", .protocol_version = snapshot_bit | 322, .implementation_file = v26_1_implementation },
    latest,
    .{ .minecraft_version = "26.3-snapshot-1", .protocol_version = snapshot_bit | 323, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.3-snapshot-2", .protocol_version = snapshot_bit | 324, .implementation_file = v26_1_implementation },
    .{ .minecraft_version = "26.3-snapshot-3", .protocol_version = snapshot_bit | 325, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-4", .protocol_version = snapshot_bit | 326, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-5", .protocol_version = snapshot_bit | 327, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-6", .protocol_version = snapshot_bit | 328, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-7", .protocol_version = snapshot_bit | 329, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-8", .protocol_version = snapshot_bit | 330, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-9", .protocol_version = snapshot_bit | 331, .implementation_file = v26_3_snapshot_3_implementation },
    .{ .minecraft_version = "26.3-snapshot-10", .protocol_version = snapshot_bit | 332, .implementation_file = v26_3_snapshot_10_implementation },
    .{ .minecraft_version = "26.3-pre-1", .protocol_version = snapshot_bit | 333, .implementation_file = v26_3_snapshot_10_implementation },
    .{ .minecraft_version = "26.3-pre-2", .protocol_version = snapshot_bit | 334, .implementation_file = v26_3_snapshot_10_implementation },
    .{ .minecraft_version = "26.3-pre-3", .protocol_version = snapshot_bit | 335, .implementation_file = v26_3_pre_3_implementation },
    .{ .minecraft_version = "26.3-rc-1", .protocol_version = snapshot_bit | 336, .implementation_file = v26_3_pre_3_implementation },
    .{ .minecraft_version = "26.3-rc-2", .protocol_version = snapshot_bit | 337, .implementation_file = v26_3_pre_3_implementation },
    .{ .minecraft_version = "26.3-rc-3", .protocol_version = snapshot_bit | 338, .implementation_file = v26_3_pre_3_implementation },
};
