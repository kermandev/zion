const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

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
    final_rendered: bool = false,
    ended: bool = false,

    pub fn enterPlay(progress: *JoinProgress, first_join: bool) void {
        progress.active += 1;
        if (first_join) progress.joined += 1;
        if (progress.joined >= progress.total) {
            progress.render(.joined);
            return;
        }
        if (first_join or progress.detail) progress.render(.joining);
    }

    pub fn scheduleReconnect(progress: *JoinProgress, was_active: bool) void {
        if (was_active) {
            progress.active -|= 1;
            progress.disconnects += 1;
        }
        progress.reconnects += 1;
        if (progress.detail) progress.render(.joining);
    }

    pub fn end(progress: *JoinProgress) void {
        if (progress.ended) return;
        progress.ended = true;
        progress.render(.stopped);
    }

    pub fn update(progress: *JoinProgress, joined: usize, active: usize, disconnects: usize, reconnects: usize) void {
        const first_join = joined > progress.joined;
        progress.joined = joined;
        progress.active = active;
        progress.disconnects = disconnects;
        progress.reconnects = reconnects;
        if (joined >= progress.total) progress.render(.joined) else if (first_join or progress.detail) progress.render(.joining);
    }

    const Render = enum { joining, joined, stopped };

    fn render(progress: *JoinProgress, what: Render) void {
        if (what == .joining) {
            if (!progress.enabled or !progress.tty or progress.final_rendered) return;
        } else {
            if (progress.final_rendered) return;
            progress.final_rendered = true;
        }
        if (!progress.enabled) return;

        var buffer: [192]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        const percent_tenths = if (progress.total == 0) 1000 else @min(1000, (progress.joined * 1000) / progress.total);

        if (progress.tty) {
            writer.writeAll(if (what == .stopped) "\r\x1b[2K\n" else "\r\x1b[2K") catch return;
        }
        switch (what) {
            .joining => writer.print("joining {d}/{d} ({d}.{d}%)", .{ progress.joined, progress.total, percent_tenths / 10, percent_tenths % 10 }) catch return,
            .joined => writer.print("joined {d}/{d}; running.", .{ progress.joined, progress.total }) catch return,
            .stopped => writer.print("stopped with {d}/{d} clients joined", .{ progress.joined, progress.total }) catch return,
        }
        if (progress.detail) writer.print("{s}play={d} drops={d} reconnects={d}{s}", .{
            if (what == .stopped) "; " else " ", progress.active, progress.disconnects, progress.reconnects, if (what == .joined) "." else "",
        }) catch return;
        writer.writeAll(switch (what) {
            .joining => "",
            .joined => " Press Ctrl-C for stats.\n",
            .stopped => ".\n",
        }) catch return;

        Io.File.stdout().writeStreamingAll(progress.io, writer.buffered()) catch {};
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
        if (joined >= progress.total or done == shards.len) return;
        Io.sleep(progress.io, Io.Duration.fromMilliseconds(50), .awake) catch return;
    }
}

test "JoinProgress counts and finalizes once" {
    var progress: JoinProgress = .{
        .total = 2,
        .enabled = false,
    };
    progress.enterPlay(true);
    try std.testing.expectEqual(@as(usize, 1), progress.joined);
    try std.testing.expectEqual(@as(usize, 1), progress.active);
    try std.testing.expect(!progress.final_rendered);

    progress.scheduleReconnect(true);
    try std.testing.expectEqual(@as(usize, 0), progress.active);
    try std.testing.expectEqual(@as(usize, 1), progress.disconnects);
    try std.testing.expectEqual(@as(usize, 1), progress.reconnects);

    progress.enterPlay(false);
    try std.testing.expectEqual(@as(usize, 1), progress.joined);
    try std.testing.expectEqual(@as(usize, 1), progress.active);

    progress.enterPlay(true);
    try std.testing.expectEqual(@as(usize, 2), progress.joined);
    try std.testing.expectEqual(@as(usize, 2), progress.active);
    try std.testing.expect(progress.final_rendered);

    progress.end();
    progress.end();
    try std.testing.expect(progress.ended);
}
