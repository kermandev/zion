const std = @import("std");
const build_options = @import("build_options");

pub const stats_enabled = build_options.enable_stats;
pub const diagnostics_enabled = build_options.enable_diagnostics;

pub const StatsColumns = struct {
    last_packet_id: if (diagnostics_enabled) i32 else void = if (diagnostics_enabled) -1 else {},
    keep_alives_answered: if (diagnostics_enabled) u32 else void = if (diagnostics_enabled) 0 else {},
};

test "StatsColumns basic telemetry tracking" {
    var columns: StatsColumns = .{};

    if (diagnostics_enabled) {
        columns.last_packet_id = 42;
        try std.testing.expectEqual(@as(i32, 42), columns.last_packet_id);
    }
}

test "StatsColumns slice telemetry mapping" {
    var list: std.MultiArrayList(StatsColumns) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacity(std.testing.allocator, 2);
    list.appendAssumeCapacity(.{});
    list.appendAssumeCapacity(.{});

    var slice = list.slice();

    if (diagnostics_enabled) {
        slice.items(.last_packet_id)[0] = 10;
        slice.items(.last_packet_id)[1] = 20;
        try std.testing.expectEqual(@as(i32, 10), slice.items(.last_packet_id)[0]);
        try std.testing.expectEqual(@as(i32, 20), slice.items(.last_packet_id)[1]);
    }
}
