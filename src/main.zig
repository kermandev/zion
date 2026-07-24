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

    const action = cli.parse(&args) catch |err| try exitInvalidArgs(stderr, err);
    switch (action) {
        .help => try report.writeUsage(stdout),
        .version => try report.writeVersion(stdout),
        .run => |options| try runLoad(io, init.gpa, arena, stdout, stderr, options),
    }
}

fn runLoad(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    options: cli.RunOptions,
) !void {
    const resolved_target = endpoint.resolveAndProbe(io, options.target) catch |err|
        try exitUnreachable(stderr, options.target, err);

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
        .client_tick = options.client_tick,
        .progress_detail = options.progress_detail,
        .movement = options.movement,
    });
    try stdout.flush();

    const stats = try pool.run(io, gpa, options.clients, resolved_target, .{
        .shards = options.shards,
        .broadcast = broadcast,
        .client_tick_packet = client_tick_packet,
        .movement = options.movement,
        .connect_rate_per_sec = options.connect_rate_per_sec,
        .reconnect = options.reconnect,
        .username_prefix = options.username_prefix,
        .known_core_pack = options.known_core_pack,
        .join_progress = &join_progress,
    });
    join_progress.end();
    try stdout.flush();
    try report.writeStatsBlocking(io, stats);
}

// Both exits flush stderr themselves: std.process.exit runs before main's
// deferred flushes.
fn exitInvalidArgs(stderr: *Io.Writer, err: anyerror) !noreturn {
    try stderr.print("error: invalid arguments ({t})\n\n", .{err});
    try report.writeUsage(stderr);
    try stderr.flush();
    std.process.exit(2);
}

fn exitUnreachable(stderr: *Io.Writer, target: endpoint.Target, err: anyerror) !noreturn {
    try report.writeReachabilityError(stderr, target, err);
    try stderr.flush();
    std.process.exit(1);
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
    _ = @import("scheduler.zig");
    _ = @import("pool.zig");
    _ = @import("bench.zig");
}
