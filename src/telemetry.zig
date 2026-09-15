//! Live shard-to-dashboard telemetry.
//!
//! Shard threads own their counters and publish a coherent snapshot into their
//! own cache line every `publish_interval_ms`; the render thread reads those
//! snapshots without ever touching shard-owned memory. Log events cross the
//! same way, through a bounded single-producer ring per shard.
//!
//! Compiled only when the `tui` feature is on; `pool.zig` keeps its existing
//! `ShardProgress`-only path otherwise.

const std = @import("std");
const features = @import("features.zig");
const stats_module = @import("stats.zig");
const progress_module = @import("progress.zig");

pub const enabled = features.tui;

const cache_line = std.atomic.cache_line;

/// Shards republish at most this often. The renderer samples at 500 ms and
/// repaints at 20 Hz, so anything faster is invisible work on the hot loop.
pub const publish_interval_ms: u64 = 100;

pub const disconnect_category_count = 7;

/// Ordered to match the columns `report.writeDisconnects` prints, so the pane
/// and the final stats block name causes in the same order.
pub const DisconnectCategory = enum(u8) {
    transport,
    server,
    protocol,
    connect,
    buffer_limit,
    resource,
    other,

    pub fn label(category: DisconnectCategory) []const u8 {
        return switch (category) {
            .transport => "transport",
            .server => "server",
            .protocol => "protocol",
            .connect => "connect",
            .buffer_limit => "buffer",
            .resource => "resource",
            .other => "other",
        };
    }

    /// The error names that feed this bucket, shown as the pane's right column.
    pub fn detail(category: DisconnectCategory) []const u8 {
        return switch (category) {
            .transport => "Disconnected",
            .server => "ServerDisconnected",
            .protocol => "malformed / unexpected packet",
            .connect => "refused · unreachable · timeout",
            .buffer_limit => "read/write limit exceeded",
            .resource => "SystemResources · OutOfMemory",
            .other => "",
        };
    }

    pub fn fromError(err: anyerror) DisconnectCategory {
        return switch (err) {
            error.ServerDisconnected => .server,
            error.Disconnected => .transport,
            error.ConnectionRefused,
            error.HostUnreachable,
            error.NetworkUnreachable,
            error.Timeout,
            error.FileNotFound,
            => .connect,
            error.ReadBufferLimitExceeded,
            error.WriteBufferLimitExceeded,
            => .buffer_limit,
            error.SystemResources,
            error.OutOfMemory,
            => .resource,
            error.OnlineModeUnsupported,
            error.UnexpectedPacket,
            error.MalformedPacket,
            error.NegativeLength,
            error.VarIntTooLong,
            error.PacketTooLarge,
            error.CompressionThresholdUnsupported,
            error.StringTooLong,
            error.EndOfStream,
            error.UsernameTooLong,
            => .protocol,
            else => .other,
        };
    }
};

/// Reads a `Disconnects` counter block by category so the pane and the model
/// never re-derive the field order.
pub fn disconnectCount(disconnects: stats_module.Disconnects, category: DisconnectCategory) u64 {
    return switch (category) {
        .transport => disconnects.transport,
        .server => disconnects.server,
        .protocol => disconnects.protocol,
        .connect => disconnects.connect,
        .buffer_limit => disconnects.buffer_limit,
        .resource => disconnects.resource,
        .other => disconnects.other,
    };
}

/// Power-of-two latency histogram: bucket `n` holds `[2^(n-1), 2^n)` ms, with
/// bucket 0 reserved for sub-millisecond samples. Percentiles interpolate
/// inside a bucket, so a p50 is accurate to roughly the bucket width rather
/// than being pinned to its edge.
pub const bucket_count = 14;

pub const Histogram = struct {
    buckets: [bucket_count]u64 = @splat(0),
    samples: u64 = 0,
    total: u64 = 0,
    max: u64 = 0,

    pub fn record(histogram: *Histogram, value: u64) void {
        histogram.buckets[bucketFor(value)] += 1;
        histogram.samples += 1;
        histogram.total +|= value;
        histogram.max = @max(histogram.max, value);
    }

    pub fn add(histogram: *Histogram, other: Histogram) void {
        for (&histogram.buckets, other.buckets) |*bucket, value| bucket.* += value;
        histogram.samples += other.samples;
        histogram.total +|= other.total;
        histogram.max = @max(histogram.max, other.max);
    }

    pub fn mean(histogram: Histogram) f64 {
        if (histogram.samples == 0) return 0;
        return @as(f64, @floatFromInt(histogram.total)) / @as(f64, @floatFromInt(histogram.samples));
    }

    /// Linear interpolation within the containing bucket. `quantile` is in
    /// [0,1]; the result is clamped to the largest sample actually seen so a
    /// coarse top bucket cannot report a latency that never happened.
    pub fn percentile(histogram: Histogram, quantile: f64) u64 {
        if (histogram.samples == 0) return 0;
        const target = quantile * @as(f64, @floatFromInt(histogram.samples));
        var seen: u64 = 0;
        for (histogram.buckets, 0..) |count, index| {
            if (count == 0) continue;
            const next = seen + count;
            if (@as(f64, @floatFromInt(next)) < target) {
                seen = next;
                continue;
            }
            const low = bucketLow(index);
            const high = bucketHigh(index);
            const within = (target - @as(f64, @floatFromInt(seen))) / @as(f64, @floatFromInt(count));
            const span = @as(f64, @floatFromInt(high - low));
            const value: u64 = low + @as(u64, @intFromFloat(@max(0, @min(span, within * span))));
            return @min(value, histogram.max);
        }
        return histogram.max;
    }

    pub fn bucketFor(value: u64) usize {
        if (value == 0) return 0;
        const width: usize = @intCast(64 - @clz(value));
        return @min(bucket_count - 1, width);
    }

    /// Inclusive lower bound of a bucket, in the histogram's unit.
    pub fn bucketLow(index: usize) u64 {
        if (index == 0) return 0;
        return @as(u64, 1) << @intCast(index - 1);
    }

    /// Exclusive upper bound of a bucket, in the histogram's unit.
    pub fn bucketHigh(index: usize) u64 {
        if (index == 0) return 1;
        return @as(u64, 1) << @intCast(index);
    }

    /// Folds the power-of-two buckets into the five ranges the diagnostics pane
    /// shows: <1, 1-4, 4-16, 16-64, >64.
    pub fn displayRows(histogram: Histogram) [5]u64 {
        var rows: [5]u64 = @splat(0);
        for (histogram.buckets, 0..) |count, index| {
            const row: usize = switch (index) {
                0 => 0,
                1, 2 => 1,
                3, 4 => 2,
                5, 6 => 3,
                else => 4,
            };
            rows[row] += count;
        }
        return rows;
    }

    pub const display_labels = [5][]const u8{ "<1ms", "1-4ms", "4-16ms", "16-64ms", ">64ms" };
};

/// What the server negotiated for a shard's clients.
///
/// Compression is settled per connection during login, but every client on a
/// shard is talking to the same server with the same configuration, so one
/// observation answers it for all of them. Distinct from the `compression`
/// build feature: that says the binary *can* compress, this says the server
/// asked it to.
pub const CompressionState = enum(u8) {
    /// No client has been told either way yet.
    unknown,
    /// The server did not enable compression, or disabled it with a negative
    /// threshold.
    off,
    /// Packets at or above `compression_threshold` bytes are compressed.
    on,
};

/// One event as the log pane shows it. Fixed size and self-contained: nothing
/// here points at shard-owned memory, so the renderer can hold it for as long
/// as its scrollback keeps it.
pub const Event = struct {
    /// Milliseconds since the run started.
    at_ms: u64 = 0,
    shard: u16 = 0,
    kind: Kind = .entered_play,
    category: DisconnectCategory = .other,
    /// Global client index; the renderer derives the username from it.
    client: u32 = 0,
    /// Backoff for `reconnect`, reply latency for `keepalive`, rejoin time for
    /// `entered_play`, joined count for `full_join`.
    value: u64 = 0,
    /// Fleet-wide events carry no single client.
    fleet: bool = false,

    pub const Kind = enum(u8) {
        run_started,
        compression_on,
        entered_play,
        full_join,
        disconnect,
        reconnect,
        keepalive,
        protocol_error,
    };
};

/// Single-producer single-consumer ring. The shard thread pushes, the renderer
/// pops. A full ring drops the newest event and counts it rather than stalling
/// the shard or overwriting history the renderer has not read yet.
pub const EventRing = struct {
    pub const capacity = 256;

    entries: [capacity]Event = @splat(.{}),
    /// Written by the producer only.
    head: std.atomic.Value(u32) align(cache_line) = .init(0),
    /// Written by the consumer only.
    tail: std.atomic.Value(u32) align(cache_line) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),

    pub fn push(ring: *EventRing, event: Event) void {
        const head = ring.head.load(.monotonic);
        const tail = ring.tail.load(.acquire);
        if (head -% tail >= capacity) {
            _ = ring.dropped.fetchAdd(1, .monotonic);
            return;
        }
        ring.entries[head % capacity] = event;
        // Release pairs with the consumer's acquire load: the entry write is
        // visible before the slot is published.
        ring.head.store(head +% 1, .release);
    }

    pub fn pop(ring: *EventRing) ?Event {
        const tail = ring.tail.load(.monotonic);
        if (ring.head.load(.acquire) == tail) return null;
        const event = ring.entries[tail % capacity];
        ring.tail.store(tail +% 1, .release);
        return event;
    }
};

/// The counters a shard republishes as a set. Assembled on the shard's stack,
/// then copied into `Shard` under the seqlock.
pub const Snapshot = struct {
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    packets_received: u64 = 0,
    keep_alives: u64 = 0,
    // Deliberately no `reconnects`: churn is read straight from
    // `Shard.progress.reconnects`, which the shard maintains in every build.
    // A copy here would come from `Stats.reconnects`, which only counts when
    // `-Denable-stats` is on, so it would sit next to the other counters
    // reading zero for a fleet that was reconnecting hard.

    connected: u32 = 0,
    connecting: u32 = 0,
    waiting: u32 = 0,
    stopped: u32 = 0,
    play: u32 = 0,

    peak_cq_ready: u32 = 0,
    peak_cq_entries: u32 = 0,
    recv_nobufs: u64 = 0,
    cq_overflow: u64 = 0,
    close_failures: u64 = 0,
    max_bundle_bytes: u64 = 0,
    max_bundle_buffers: u32 = 0,
    /// Whether the receive ring got IOU_PBUF_RING_INC. Fixed for a run, but it
    /// travels with the ring figures it explains.
    incremental_buffers: bool = false,

    compression: CompressionState = .unknown,
    /// Bytes at or above which the server compresses, meaningful only when
    /// `compression` is `.on`.
    compression_threshold: i32 = 0,

    keep_alive: Histogram = .{},
    rejoin: Histogram = .{},
    disconnects: [disconnect_category_count]u64 = @splat(0),
};

/// Guards one shard's snapshot handover.
///
/// The critical section is a fixed-size struct copy with no syscall in it, and
/// it is entered ten times a second by the shard and twenty by the renderer, so
/// a waiter is never more than a few hundred nanoseconds from the handoff.
/// Spinning is the right trade there; parking would cost a futex round trip to
/// avoid a wait that barely exists.
const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn acquire(lock: *Lock) void {
        while (lock.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(lock: *Lock) void {
        lock.held.store(false, .release);
    }
};

/// Per-shard slot. Aligned so no two shards share a cache line, matching the
/// reasoning behind `ShardProgress`.
pub const Shard = struct {
    /// The counters the plain progress line already maintains; the shard's
    /// `ProgressSink` points here so nothing is counted twice.
    progress: progress_module.ShardProgress align(cache_line) = .{},

    lock: Lock align(cache_line) = .{},
    published: Snapshot = .{},

    events: EventRing = .{},

    pub fn publish(shard: *Shard, snapshot: Snapshot) void {
        shard.lock.acquire();
        defer shard.lock.release();
        shard.published = snapshot;
    }

    pub fn read(shard: *Shard) Snapshot {
        shard.lock.acquire();
        defer shard.lock.release();
        return shard.published;
    }
};

test "histogram percentiles interpolate inside the containing bucket" {
    if (comptime !enabled) return error.SkipZigTest;
    var histogram: Histogram = .{};
    for (0..100) |_| histogram.record(2);
    try std.testing.expectEqual(@as(u64, 100), histogram.samples);
    // Every sample is 2ms, so every percentile lands in the [2,4) bucket and
    // can never exceed the largest observed sample.
    try std.testing.expectEqual(@as(u64, 2), histogram.percentile(0.5));
    try std.testing.expectEqual(@as(u64, 2), histogram.percentile(0.99));
    try std.testing.expectEqual(@as(f64, 2), histogram.mean());
}

test "histogram folds power-of-two buckets into the pane's five rows" {
    if (comptime !enabled) return error.SkipZigTest;
    var histogram: Histogram = .{};
    histogram.record(0); // <1ms
    histogram.record(1); // 1-4ms
    histogram.record(3); // 1-4ms
    histogram.record(8); // 4-16ms
    histogram.record(20); // 16-64ms
    histogram.record(200); // >64ms
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 1, 1, 1 }, &histogram.displayRows());
}

test "histogram add merges buckets and keeps the larger maximum" {
    if (comptime !enabled) return error.SkipZigTest;
    var a: Histogram = .{};
    a.record(4);
    var b: Histogram = .{};
    b.record(41);
    a.add(b);
    try std.testing.expectEqual(@as(u64, 2), a.samples);
    try std.testing.expectEqual(@as(u64, 41), a.max);
    try std.testing.expectEqual(@as(u64, 45), a.total);
}

test "event ring hands every pushed event to the consumer in order" {
    if (comptime !enabled) return error.SkipZigTest;
    var ring: EventRing = .{};
    for (0..EventRing.capacity) |i| {
        ring.push(.{ .at_ms = i, .kind = .entered_play });
    }
    // One past capacity is dropped rather than overwriting unread history.
    ring.push(.{ .at_ms = 9999 });
    try std.testing.expectEqual(@as(u64, 1), ring.dropped.load(.monotonic));

    for (0..EventRing.capacity) |i| {
        const event = ring.pop() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u64, i), event.at_ms);
    }
    try std.testing.expectEqual(@as(?Event, null), ring.pop());

    // Draining frees the slots again.
    ring.push(.{ .at_ms = 7 });
    try std.testing.expectEqual(@as(u64, 7), (ring.pop() orelse return error.TestUnexpectedResult).at_ms);
}

test "shard publication is seen whole by the reader" {
    if (comptime !enabled) return error.SkipZigTest;
    var shard: Shard = .{};
    shard.publish(.{ .bytes_received = 1024, .play = 7 });
    const snapshot = shard.read();
    try std.testing.expectEqual(@as(u64, 1024), snapshot.bytes_received);
    try std.testing.expectEqual(@as(u32, 7), snapshot.play);
}
