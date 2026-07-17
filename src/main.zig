const std = @import("std");
const Io = std.Io;
const features = @import("features.zig");
const cli = @import("cli.zig");
const client = @import("client.zig");
const endpoint = @import("endpoint.zig");
const pool = @import("pool.zig");
const report = @import("report.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = args.skip();

    const action = cli.parse(&args) catch |err| {
        try stderr.print("error: invalid arguments ({t})\n\n", .{err});
        try report.writeUsage(stderr);
        try stderr.flush();
        std.process.exit(2);
    };
    const options = switch (action) {
        .help => return report.writeUsage(stdout),
        .version => return report.writeVersion(stdout),
        .run => |run| run,
    };

    const recommended_fds = recommendedFdLimit(options.clients);
    const fd_limit = try std.posix.getrlimit(.NOFILE);
    if (fd_limit.cur < recommended_fds) {
        try stderr.print("warning: process file descriptor limit ({d}) is lower than recommended ({d}); client connections may fail. Run 'ulimit -n {d}' to increase.\n", .{ fd_limit.cur, recommended_fds, recommended_fds });
        try stderr.flush();
    }

    const resolved_target = endpoint.resolveAndProbe(io, options.target) catch |err| {
        try report.writeReachabilityError(stderr, options.target, err);
        try stderr.flush();
        std.process.exit(1);
    };

    const broadcast: if (features.broadcast) ?pool.Broadcast else void = if (comptime features.broadcast) if (options.broadcast) |broadcast_options| .{
        .interval_ms = broadcast_options.interval_ms,
        .packet = try client.buildChatBroadcastPacket(arena, broadcast_options.message, Io.Timestamp.now(io, .real).toMilliseconds()),
        .label = broadcast_options.message,
    } else null else {};
    const client_tick_packet = if (comptime features.client_tick) if (options.client_tick) try client.buildClientTickPacket(arena) else null else {};

    const shard_count = pool.shardCount(options.shards, options.clients);
    var join_progress: pool.JoinProgress = .{
        .io = io,
        .total = options.clients,
        .tty = Io.File.stdout().isTty(io) catch false,
        .detail = if (comptime features.diagnostics) options.progress_detail else false,
    };
    errdefer join_progress.end();

    try report.writeRunHeader(stdout, .{
        .target = options.target,
        .client_count = options.clients,
        .shard_count = shard_count,
        .known_core_pack = options.known_core_pack,
        .broadcast = if (comptime features.broadcast) if (broadcast) |value| .{ .interval_ms = value.interval_ms, .label = value.label } else null else {},
        .client_tick = if (comptime features.client_tick) options.client_tick else {},
        .progress_detail = if (comptime features.diagnostics) options.progress_detail else {},
        .movement = if (comptime features.movement) options.movement else {},
    });
    try stdout.flush();

    const stats = try pool.run(io, init.gpa, options.clients, resolved_target, .{
        .shards = options.shards,
        .broadcast = if (comptime features.broadcast) broadcast else {},
        .client_tick_packet = if (comptime features.client_tick) client_tick_packet else {},
        .movement = if (comptime features.movement) options.movement else {},
        .connect_rate_per_sec = options.connect_rate_per_sec,
        .username_prefix = options.username_prefix,
        .known_core_pack = options.known_core_pack,
        .join_progress = &join_progress,
    });
    join_progress.end();
    try stdout.flush();
    try report.writeStatsBlocking(io, stats);
}

fn recommendedFdLimit(client_count: usize) usize {
    return client_count;
}

test {
    _ = @import("cli.zig");
    _ = @import("endpoint.zig");
    _ = @import("report.zig");
    _ = @import("ring.zig");
    _ = @import("client_table.zig");
    _ = @import("client.zig");
    _ = @import("protocol.zig");
    _ = @import("progress.zig");
    _ = @import("stats.zig");
    _ = @import("outbound.zig");
    _ = @import("bench.zig");
}

test "direct socket file limit recommendation matches fixed slots" {
    try std.testing.expectEqual(@as(usize, 1000), recommendedFdLimit(1000));
}
