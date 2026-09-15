const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const features = @import("features.zig");
const cli = @import("cli.zig");
const client = @import("client.zig");
const endpoint = @import("endpoint.zig");
const pool = @import("pool.zig");
const report = @import("report.zig");
const tui = @import("tui.zig");

pub const panic = std.debug.FullPanic(zionPanic);

/// A panic does not unwind, so `Term.deinit` and the `errdefer` that back the
/// dashboard's restore never run: without this a bug in the render path leaves
/// raw mode and the alternate screen behind. Restoring first also moves the
/// trace onto the real screen, which the alternate one would otherwise discard
/// along with the message that explains the crash.
fn zionPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    tui.emergencyRestore();
    std.debug.defaultPanic(message, first_trace_address);
}

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
    const dashboard_wanted = if (comptime features.tui) tui.shouldRun(io, options.tui) else false;

    var join_progress: pool.JoinProgress = .{
        .io = io,
        .total = options.clients,
        .tty = Io.File.stdout().isTty(io) catch false,
        .detail = if (comptime features.diagnostics) options.progress_detail else false,
        // The dashboard owns the screen; the single-line progress output would
        // fight it for stdout.
        .enabled = !dashboard_wanted,
    };
    errdefer join_progress.end();

    var dashboard: if (features.tui) tui.Dashboard else void = if (comptime features.tui) .{
        .info = .{
            .target = try renderTarget(arena, options.target),
            .minecraft_version = client.protocol.current.minecraft_version,
            .protocol_version = client.protocol.current.protocol_version,
            .client_count = options.clients,
            .connect_rate_per_sec = options.connect_rate_per_sec,
            .username_prefix = options.username_prefix,
            .movement = if (comptime features.movement) @tagName(options.movement.profile) else "",
            // The run header scrolls away behind the alternate screen, so the
            // context line is the only place these show while the dashboard is
            // up. The broadcast's own message is deliberately left out: it is
            // user-supplied and arbitrarily long, and the header still has it.
            .broadcast = if (comptime features.broadcast)
                (if (broadcast) |value| try std.fmt.allocPrint(arena, "broadcast {d}ms", .{value.interval_ms}) else "")
            else
                "",
            .client_tick = if (comptime features.client_tick)
                (if (options.client_tick) "tick 50ms" else "")
            else
                "",
            .reconnect = options.reconnect,
        },
    } else {};

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
        .dashboard = if (comptime features.tui) (if (dashboard_wanted) &dashboard else null) else {},
    });
    join_progress.end();
    try stdout.flush();
    try report.writeStatsBlocking(io, stats);
    // The dashboard's own history dies with the alternate screen, so its peaks
    // follow the stats block into scrollback.
    if (comptime features.tui) try writeSummaryBlocking(io, dashboard.summary);
}

fn renderTarget(arena: std.mem.Allocator, target: endpoint.Target) ![]const u8 {
    var rendered: Io.Writer.Allocating = .init(arena);
    try report.writeTarget(&rendered.writer, target);
    return rendered.written();
}

fn writeSummaryBlocking(io: Io, summary: tui.Summary) !void {
    if (comptime !features.tui) return;
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try tui.writeSummary(&writer, summary);
    if (writer.buffered().len == 0) return;
    try Io.File.stdout().writeStreamingAll(io, writer.buffered());
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
    _ = @import("telemetry.zig");
    _ = @import("tui.zig");
}
