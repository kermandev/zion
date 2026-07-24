const std = @import("std");
const builtin = @import("builtin");
const features = @import("features.zig");
const Io = std.Io;

// Minimum spacing between live progress repaints on a TTY (~20 Hz), matching the
// shared-progress poll cadence so both sinks refresh at the same smooth rate.
const live_repaint_interval_ms: u64 = 50;

fn nowMs(io: Io) u64 {
    const ns: u64 = @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
    return ns / std.time.ns_per_ms;
}

pub const JoinProgress = struct {
    io: Io = undefined,
    total: usize = 0,
    tty: bool = false,
    detail: bool = false,
    enabled: bool = !builtin.is_test,
    joined: usize = 0,
    active: usize = 0,
    disconnects: usize = 0,
    reconnects: usize = 0,
    // Set once the fleet first reaches full join, so a non-TTY sink announces
    // that milestone exactly once instead of on every later update.
    announced: bool = false,
    final_rendered: bool = false,
    ended: bool = false,
    // Wall-clock of the last live repaint. The single-shard sink drives render
    // per event, so a reconnect storm would otherwise repaint thousands of
    // times a second; coalesce to ~live_repaint_interval_ms like the poller.
    last_render_ms: u64 = 0,

    pub fn enterPlay(progress: *JoinProgress, first_join: bool) void {
        progress.active += 1;
        if (first_join) progress.joined += 1;
        progress.render();
    }

    pub fn scheduleReconnect(progress: *JoinProgress, was_active: bool) void {
        if (comptime !features.reconnect) unreachable;
        if (was_active) {
            progress.active -|= 1;
            progress.disconnects += 1;
        }
        progress.reconnects += 1;
        progress.render();
    }

    pub fn noteDrop(progress: *JoinProgress, was_active: bool) void {
        if (was_active) {
            progress.active -|= 1;
            progress.disconnects += 1;
            progress.render();
        }
    }

    pub fn end(progress: *JoinProgress) void {
        if (progress.ended) return;
        progress.ended = true;
        if (!progress.enabled) return;
        progress.final_rendered = true;
        progress.paint(.stopped);
    }

    pub fn update(progress: *JoinProgress, joined: usize, active: usize, disconnects: usize, reconnects: usize) void {
        progress.joined = joined;
        progress.active = active;
        progress.disconnects = disconnects;
        progress.reconnects = reconnects;
        progress.render();
    }

    const Paint = enum { ramp, milestone, running, stopped };

    // Live progress only; the stopped summary is painted straight from end().
    fn render(progress: *JoinProgress) void {
        if (!progress.enabled or progress.final_rendered) return;

        const fully_joined = progress.total == 0 or progress.joined >= progress.total;

        // Without a TTY we cannot repaint a line in place, so emit only the
        // one-time full-join milestone; the stopped summary comes later. This
        // keeps piped logs free of partial-progress and reconnect churn lines.
        if (!progress.tty) {
            if (fully_joined and !progress.announced) {
                progress.announced = true;
                progress.paint(.milestone);
            }
            return;
        }

        // The full-join milestone commits its own permanent line and always
        // paints immediately. The ramp spinner and the live running line are
        // coalesced to one repaint per interval so a reconnect storm cannot
        // flicker or flood stdout.
        if (fully_joined and !progress.announced) {
            progress.announced = true;
            progress.last_render_ms = nowMs(progress.io);
            progress.paint(.milestone);
            return;
        }
        const now_ms = nowMs(progress.io);
        if (now_ms -| progress.last_render_ms < live_repaint_interval_ms) return;
        progress.last_render_ms = now_ms;
        progress.paint(if (fully_joined) .running else .ramp);
    }

    // render owns the state transitions; paint and writeLine only read.
    fn paint(progress: *const JoinProgress, kind: Paint) void {
        var buffer: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        progress.writeLine(&writer, kind) catch return;
        Io.File.stdout().writeStreamingAll(progress.io, writer.buffered()) catch {};
    }

    fn writeLine(progress: *const JoinProgress, writer: *Io.Writer, kind: Paint) !void {
        // Live lines rewrite themselves in place; committed lines (milestone,
        // stopped) end in a newline so the next output starts fresh below them.
        if (progress.tty) try writer.writeAll("\r\x1b[2K");
        switch (kind) {
            .ramp => {
                const percent_tenths = if (progress.total == 0) 1000 else @min(1000, (progress.joined * 1000) / progress.total);
                try writer.print("joining {d}/{d} ({d}.{d}%)", .{ progress.joined, progress.total, percent_tenths / 10, percent_tenths % 10 });
                if (progress.detail) try writer.print(" play={d} drops={d} reconnects={d}", .{ progress.active, progress.disconnects, progress.reconnects });
            },
            // Commit "joined N/N." as a permanent line. On a TTY, open the live
            // running line right below it in the same write.
            .milestone => {
                try writer.print("joined {d}/{d}.\n", .{ progress.joined, progress.total });
                if (progress.tty) try progress.writeRunning(writer);
            },
            .running => try progress.writeRunning(writer),
            .stopped => try writer.print("stopped | {d}/{d} joined, {d} reconnects.\n", .{ progress.joined, progress.total, progress.reconnects }),
        }
    }

    // The live status line shown below the committed "joined" milestone. play
    // reflects the currently-connected fleet; drops/reconnects appear once any
    // client has cycled (or always in detail mode) so a healthy run stays terse.
    fn writeRunning(progress: *const JoinProgress, writer: *Io.Writer) !void {
        try writer.print("running | play={d}", .{progress.active});
        if (progress.detail or progress.disconnects > 0 or progress.reconnects > 0) {
            try writer.print(" drops={d} reconnects={d}", .{ progress.disconnects, progress.reconnects });
        }
        try writer.writeAll(" | Ctrl-C for stats");
    }
};

// Aligning the first field to a cache line raises the whole struct's alignment,
// so each element of a `[]ShardProgress` is padded to its own line and adjacent
// shards never share one and false-share.
pub const ShardProgress = struct {
    joined: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),
    active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    disconnects: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    reconnects: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    comptime {
        std.debug.assert(@alignOf(ShardProgress) == std.atomic.cache_line);
        std.debug.assert(@sizeOf(ShardProgress) % std.atomic.cache_line == 0);
    }
};

pub const ProgressSink = union(enum) {
    none,
    direct: *JoinProgress,
    shared: *ShardProgress,

    pub fn init(progress: ?*JoinProgress) ProgressSink {
        if (progress) |value| {
            if (value.enabled) return .{ .direct = value };
        }
        return .none;
    }

    pub fn enterPlay(sink: ProgressSink, first_join: bool) void {
        switch (sink) {
            .none => {},
            .direct => |progress| progress.enterPlay(first_join),
            .shared => |progress| {
                _ = progress.active.fetchAdd(1, .monotonic);
                if (first_join) _ = progress.joined.fetchAdd(1, .monotonic);
            },
        }
    }

    pub fn scheduleReconnect(sink: ProgressSink, was_active: bool) void {
        if (comptime !features.reconnect) unreachable;
        switch (sink) {
            .none => {},
            .direct => |progress| progress.scheduleReconnect(was_active),
            .shared => |progress| {
                if (was_active) {
                    _ = progress.active.fetchSub(1, .monotonic);
                    _ = progress.disconnects.fetchAdd(1, .monotonic);
                }
                _ = progress.reconnects.fetchAdd(1, .monotonic);
            },
        }
    }

    pub fn noteDrop(sink: ProgressSink, was_active: bool) void {
        switch (sink) {
            .none => {},
            .direct => |progress| progress.noteDrop(was_active),
            .shared => |progress| {
                if (was_active) {
                    _ = progress.active.fetchSub(1, .monotonic);
                    _ = progress.disconnects.fetchAdd(1, .monotonic);
                }
            },
        }
    }

    pub fn shardDone(sink: ProgressSink) void {
        switch (sink) {
            .none, .direct => {},
            .shared => |progress| progress.done.store(true, .release),
        }
    }

    pub fn suppressesLogs(sink: ProgressSink) bool {
        return switch (sink) {
            .none => false,
            .direct => |progress| progress.enabled and progress.tty and !progress.final_rendered,
            .shared => true,
        };
    }
};

pub fn waitForSharedProgress(progress: *JoinProgress, shards: []const ShardProgress) void {
    while (true) {
        var joined: usize = 0;
        var active: usize = 0;
        var disconnects: usize = 0;
        var reconnects: usize = 0;
        var done: usize = 0;
        for (shards) |*shard| {
            joined += shard.joined.load(.acquire);
            active += shard.active.load(.acquire);
            disconnects += shard.disconnects.load(.acquire);
            reconnects += shard.reconnects.load(.acquire);
            if (shard.done.load(.acquire)) done += 1;
        }
        progress.update(joined, active, disconnects, reconnects);
        // Keep polling for the whole run (not just until full join) so the live
        // line reflects disconnect/reconnect churn. Exit only when every shard
        // has finished; the main thread then joins them without further waiting.
        if (done == shards.len) return;
        Io.sleep(progress.io, Io.Duration.fromMilliseconds(50), .awake) catch return;
    }
}

test "JoinProgress counts drops and finalizes once" {
    var progress: JoinProgress = .{
        .total = 2,
        .enabled = false,
    };
    progress.enterPlay(true);
    try std.testing.expectEqual(@as(usize, 1), progress.joined);
    try std.testing.expectEqual(@as(usize, 1), progress.active);
    try std.testing.expect(!progress.final_rendered);

    progress.noteDrop(true);
    try std.testing.expectEqual(@as(usize, 0), progress.active);
    try std.testing.expectEqual(@as(usize, 1), progress.disconnects);
    try std.testing.expectEqual(@as(usize, 0), progress.reconnects);

    progress.enterPlay(false);
    try std.testing.expectEqual(@as(usize, 1), progress.active);

    // Reaching full join no longer finalizes the line: the fleet stays live so
    // later drops keep updating. Only end() finalizes.
    progress.enterPlay(true);
    try std.testing.expectEqual(@as(usize, 2), progress.joined);
    try std.testing.expectEqual(@as(usize, 2), progress.active);
    try std.testing.expect(!progress.final_rendered);

    progress.end();
    progress.end();
    try std.testing.expect(progress.ended);
}

test "JoinProgress counts reconnects" {
    if (comptime !features.reconnect) return error.SkipZigTest;
    var progress: JoinProgress = .{ .total = 2, .enabled = false };
    progress.enterPlay(true);

    progress.scheduleReconnect(true);
    try std.testing.expectEqual(@as(usize, 0), progress.active);
    try std.testing.expectEqual(@as(usize, 1), progress.disconnects);
    try std.testing.expectEqual(@as(usize, 1), progress.reconnects);
}
