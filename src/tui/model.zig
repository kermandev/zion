//! The dashboard's view of the run.
//!
//! `Model` is rebuilt from telemetry once per sample tick and read by the
//! panes. Panes never touch `telemetry.Shard` directly: everything they need is
//! already reduced, sorted and rated here, so a pane is pure layout.

const std = @import("std");
const testing = std.testing;
const features = @import("../features.zig");
const telemetry = @import("../telemetry.zig");
const theme = @import("theme.zig");

const Histogram = telemetry.Histogram;
pub const Severity = theme.Severity;

/// Charts advance on this cadence, independent of the 20 Hz repaint.
pub const sample_interval_ms: u64 = 500;
/// Fifteen minutes of fleet history at `sample_interval_ms`.
pub const sample_capacity: usize = 1800;
/// Two minutes per shard, which is all the drill-down chart shows.
pub const shard_sample_capacity: usize = 240;
/// Events kept for the log pane; older ones scroll out of history.
pub const log_capacity: usize = 4096;

pub const Pane = enum {
    fleet,
    shards,
    traffic,
    diagnostics,
    log,

    pub fn label(pane: Pane) []const u8 {
        return switch (pane) {
            .fleet => "fleet",
            .shards => "shards",
            .traffic => "traffic",
            .diagnostics => "diagnostics",
            .log => "log",
        };
    }

    /// Panes whose data does not exist in this build are not dimmed, they are
    /// absent: the strip only offers what the binary can answer.
    pub fn available(pane: Pane) bool {
        return switch (pane) {
            .fleet, .shards, .log => true,
            .traffic => features.stats,
            .diagnostics => features.diagnostics,
        };
    }
};

pub const Span = enum {
    s60,
    m5,
    m15,
    run,

    pub fn label(span: Span) []const u8 {
        return switch (span) {
            .s60 => "60s",
            .m5 => "5m",
            .m15 => "15m",
            .run => "run",
        };
    }

    /// How many stored samples the span covers.
    pub fn sampleCount(span: Span) usize {
        return switch (span) {
            .s60 => 120,
            .m5 => 600,
            .m15 => sample_capacity,
            .run => sample_capacity,
        };
    }

    pub fn next(span: Span) Span {
        return switch (span) {
            .s60 => .m5,
            .m5 => .m15,
            .m15 => .run,
            .run => .run,
        };
    }

    pub fn previous(span: Span) Span {
        return switch (span) {
            .s60 => .s60,
            .m5 => .s60,
            .m15 => .m5,
            .run => .m15,
        };
    }
};

pub const SortColumn = enum {
    id,
    joined,
    play,
    drops,
    reconnects,
    rx,
    tx,
    packets,
    keepalive,
    ring,

    pub fn label(column: SortColumn) []const u8 {
        return switch (column) {
            .id => "id",
            .joined => "joined",
            .play => "play",
            .drops => "drops",
            .reconnects => "churn",
            .rx => "rx/s",
            .tx => "tx/s",
            .packets => "pkt/s",
            .keepalive => "ka p99",
            .ring => "peak cq",
        };
    }

    pub fn next(column: SortColumn) SortColumn {
        const values = std.enums.values(SortColumn);
        const index = @backingInt(column);
        return values[(index + 1) % values.len];
    }
};

pub const LogFilter = enum {
    all,
    joins,
    drops,
    reconnects,
    server,
    protocol,

    pub fn label(filter: LogFilter) []const u8 {
        return switch (filter) {
            .all => "all",
            .joins => "joins",
            .drops => "drops",
            .reconnects => "reconnects",
            .server => "server",
            .protocol => "protocol",
        };
    }

    pub fn accepts(filter: LogFilter, event: telemetry.Event) bool {
        return switch (filter) {
            .all => true,
            .joins => event.kind == .entered_play or event.kind == .full_join or event.kind == .run_started,
            .drops => event.kind == .disconnect,
            .reconnects => event.kind == .reconnect,
            .server => event.kind == .disconnect and event.category == .server,
            .protocol => event.kind == .protocol_error or
                (event.kind == .disconnect and event.category == .protocol),
        };
    }

    pub fn next(filter: LogFilter) LogFilter {
        const values = std.enums.values(LogFilter);
        const index = @backingInt(filter);
        return values[(index + 1) % values.len];
    }

    pub fn previous(filter: LogFilter) LogFilter {
        const values = std.enums.values(LogFilter);
        const index = @backingInt(filter);
        return values[(index + values.len - 1) % values.len];
    }
};

/// A fixed-size ring of chart samples. Values are pushed newest-last; readers
/// ask for a window and get it resampled to whatever width they have.
pub fn Series(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        values: [capacity]f32 = @splat(0),
        len: usize = 0,
        head: usize = 0,
        peak: f32 = 0,
        peak_at_ms: u64 = 0,

        pub fn push(series: *Self, value: f32, at_ms: u64) void {
            series.values[series.head] = value;
            series.head = (series.head + 1) % capacity;
            if (series.len < capacity) series.len += 1;
            if (value > series.peak) {
                series.peak = value;
                series.peak_at_ms = at_ms;
            }
        }

        pub fn last(series: *const Self) f32 {
            if (series.len == 0) return 0;
            return series.values[(series.head + capacity - 1) % capacity];
        }

        /// Oldest-first sample `index` within the most recent `count` samples.
        fn sampleAt(series: *const Self, count: usize, index: usize) f32 {
            const available = @min(count, series.len);
            const offset = series.len - available + index;
            const start = (series.head + capacity - series.len) % capacity;
            return series.values[(start + offset) % capacity];
        }

        /// Resamples the most recent `span` worth of samples into `dest`,
        /// oldest first. Averages where several samples share a column and
        /// repeats where one sample covers several, so the shape of the series
        /// survives either way.
        fn resample(series: *const Self, count: usize, dest: []f32) void {
            for (0..dest.len) |column| {
                const from = column * count / dest.len;
                const to = @min(@max(from + 1, (column + 1) * count / dest.len), count);
                var total: f64 = 0;
                var used: usize = 0;
                for (from..to) |index| {
                    total += series.sampleAt(count, index);
                    used += 1;
                }
                dest[column] = if (used == 0) 0 else @floatCast(total / @as(f64, @floatFromInt(used)));
            }
        }

        /// Fills `out` with the span's samples, oldest first, and returns the
        /// populated prefix.
        ///
        /// A full span always spans the whole plot: the number of stored
        /// samples has nothing to do with how many columns the chart has, so a
        /// 60s window on a 130-column chart covers all 130 rather than leaving
        /// the plot part-empty. A span that has not filled yet occupies only
        /// the fraction of the plot it has actually covered, so a young run
        /// cannot be mistaken for a full period of history.
        pub fn window(series: *const Self, span: Span, out: []f32) []f32 {
            if (out.len == 0 or series.len == 0) return out[0..0];
            const count = @min(span.sampleCount(), series.len);
            // `run` is whatever has happened so far, so it is full by
            // definition and always spans the plot. A fixed span is only full
            // once it holds that much history.
            const span_samples = if (span == .run) count else span.sampleCount();
            const columns = if (count < span_samples)
                @max(1, out.len * count / span_samples)
            else
                out.len;
            series.resample(count, out[0..columns]);
            return out[0..columns];
        }

        /// Largest value in the span, used to scale a chart's vertical axis.
        pub fn maximum(series: *const Self, span: Span) f32 {
            const count = @min(span.sampleCount(), series.len);
            var highest: f32 = 0;
            for (0..count) |index| highest = @max(highest, series.sampleAt(count, index));
            return highest;
        }

        /// Median of the span, ignoring the most recent `exclude` samples.
        /// Used as the baseline a churn storm is measured against.
        pub fn medianExcludingRecent(series: *const Self, span: Span, exclude: usize) f32 {
            const count = @min(span.sampleCount(), series.len);
            if (count <= exclude) return 0;
            const considered = count - exclude;
            var scratch: [256]f32 = undefined;
            const take = @min(considered, scratch.len);
            for (0..take) |index| scratch[index] = series.sampleAt(count, considered - take + index);
            const slice = scratch[0..take];
            std.mem.sort(f32, slice, {}, std.sort.asc(f32));
            return slice[slice.len / 2];
        }
    };
}

pub const FleetSeries = Series(sample_capacity);
pub const ShardSeries = Series(shard_sample_capacity);

pub const RingPressure = struct {
    peak_cq_ready: u32 = 0,
    peak_cq_entries: u32 = 0,
    recv_nobufs: u64 = 0,
    cq_overflow: u64 = 0,
    close_failures: u64 = 0,
    max_bundle_bytes: u64 = 0,
    max_bundle_buffers: u32 = 0,
    /// Whether the receive ring got IOU_PBUF_RING_INC. Fixed for a run, so it
    /// is a property of the fleet rather than a per-shard measurement, but it
    /// rides along with the figures it explains.
    incremental_buffers: bool = false,

    pub fn occupancy(ring: RingPressure) f64 {
        if (ring.peak_cq_entries == 0) return 0;
        return @as(f64, @floatFromInt(ring.peak_cq_ready)) / @as(f64, @floatFromInt(ring.peak_cq_entries));
    }

    /// Reads the pressure on its own, so the fleet-wide totals can be rated
    /// without a shard to hang them on.
    pub fn severity(ring: RingPressure) Severity {
        if (ring.cq_overflow > 0) return .hot;
        if (ring.occupancy() >= 0.75 or ring.recv_nobufs > 0) return .watch;
        return .ok;
    }
};

pub const ShardRow = struct {
    id: u16 = 0,
    requested: u32 = 0,
    joined: u32 = 0,
    play: u32 = 0,
    connected: u32 = 0,
    connecting: u32 = 0,
    waiting: u32 = 0,
    stopped: u32 = 0,
    disconnects: u64 = 0,
    reconnects: u64 = 0,
    done: bool = false,

    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    packets_received: u64 = 0,
    rx_per_sec: f64 = 0,
    tx_per_sec: f64 = 0,
    packets_per_sec: f64 = 0,
    /// Fraction of the fleet's receive traffic this shard carries.
    rx_share: f64 = 0,

    ring: RingPressure = .{},
    keep_alive: Histogram = .{},
    keep_alive_p50_ms: u64 = 0,
    keep_alive_p99_ms: u64 = 0,

    /// Receive rate relative to the busiest shard, for the load column.
    load: f64 = 0,
    samples: ShardSeries = .{},

    /// Worst of this shard's individual signals, so one call answers "is this
    /// row worth looking at".
    pub fn severity(row: ShardRow, fleet: Fleet) Severity {
        var worst: Severity = .ok;
        for ([_]Severity{
            row.churnSeverity(fleet),
            row.keepAliveSeverity(),
            row.ringSeverity(),
            row.playSeverity(),
        }) |candidate| {
            if (@backingInt(candidate) > @backingInt(worst)) worst = candidate;
        }
        return worst;
    }

    /// A shard is hot on churn when it carries several times the fleet's
    /// per-shard average, not merely a little more than its neighbors.
    pub fn churnSeverity(row: ShardRow, fleet: Fleet) Severity {
        if (row.reconnects == 0) return .ok;
        const average = fleet.averageReconnectsPerShard();
        if (average <= 0) return if (row.reconnects > 0) .watch else .ok;
        const ratio = @as(f64, @floatFromInt(row.reconnects)) / average;
        if (ratio >= 3) return .hot;
        if (ratio >= 1.75) return .watch;
        return .ok;
    }

    pub fn keepAliveSeverity(row: ShardRow) Severity {
        return keepAliveSeverityFor(row.keep_alive_p99_ms);
    }

    pub fn ringSeverity(row: ShardRow) Severity {
        return row.ring.severity();
    }

    pub fn playSeverity(row: ShardRow) Severity {
        // A shard with nothing asked of it is not behind; the fraction below
        // would read as zero and call it hot.
        if (row.requested == 0) return .ok;
        return playSeverityFor(@as(f64, @floatFromInt(row.play)) / @as(f64, @floatFromInt(row.requested)));
    }
};

/// The keep-alive thresholds live here, once. Panes rate a latency by calling
/// this rather than restating the cutoffs, so the shard table, the diagnostics
/// column and the log agree by construction.
pub fn keepAliveSeverityFor(p99_ms: u64) Severity {
    if (p99_ms >= 100) return .hot;
    if (p99_ms >= 16) return .watch;
    return .ok;
}

/// Rates a play fraction. Callers guard an empty population themselves: a
/// fleet or shard with nothing requested has a fraction of zero, which is not
/// the same thing as being nowhere near play.
pub fn playSeverityFor(fraction: f64) Severity {
    if (fraction < 0.9) return .hot;
    if (fraction < 0.99) return .watch;
    return .ok;
}

pub const Fleet = struct {
    requested: u64 = 0,
    joined: u64 = 0,
    play: u64 = 0,
    connected: u64 = 0,
    connecting: u64 = 0,
    waiting: u64 = 0,
    stopped: u64 = 0,
    disconnects: u64 = 0,
    reconnects: u64 = 0,
    shard_count: usize = 0,

    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    packets_received: u64 = 0,
    keep_alives: u64 = 0,

    rx_per_sec: f64 = 0,
    tx_per_sec: f64 = 0,
    packets_per_sec: f64 = 0,
    reconnects_per_sec: f64 = 0,

    average_rx_per_sec: f64 = 0,
    average_tx_per_sec: f64 = 0,
    average_packets_per_sec: f64 = 0,

    peak_rx_per_sec: f64 = 0,
    peak_tx_per_sec: f64 = 0,
    peak_packets_per_sec: f64 = 0,
    peak_rx_at_ms: u64 = 0,
    peak_packets_at_ms: u64 = 0,

    ring: RingPressure = .{},
    keep_alive: Histogram = .{},
    rejoin: Histogram = .{},
    disconnect_counts: [telemetry.disconnect_category_count]u64 = @splat(0),

    /// What the server negotiated, once any shard has a client past login.
    /// Not the `compression` build feature: that says the binary can compress,
    /// this says the server asked it to.
    compression: telemetry.CompressionState = .unknown,
    compression_threshold: i32 = 0,

    pub fn playFraction(fleet: Fleet) f64 {
        if (fleet.requested == 0) return 0;
        return @as(f64, @floatFromInt(fleet.play)) / @as(f64, @floatFromInt(fleet.requested));
    }

    pub fn joinFraction(fleet: Fleet) f64 {
        if (fleet.requested == 0) return 0;
        return @as(f64, @floatFromInt(fleet.joined)) / @as(f64, @floatFromInt(fleet.requested));
    }

    pub fn averageReconnectsPerShard(fleet: Fleet) f64 {
        if (fleet.shard_count == 0) return 0;
        return @as(f64, @floatFromInt(fleet.reconnects)) / @as(f64, @floatFromInt(fleet.shard_count));
    }

    /// Receive-to-send ratio, the number the traffic pane prints as `13.4 : 1`.
    pub fn trafficRatio(fleet: Fleet) f64 {
        if (fleet.bytes_sent == 0) return 0;
        return @as(f64, @floatFromInt(fleet.bytes_received)) / @as(f64, @floatFromInt(fleet.bytes_sent));
    }
};

/// Why the dashboard has switched to its degraded presentation, and the
/// numbers that justify saying so.
pub const Degradation = struct {
    active: bool = false,
    began_at_ms: u64 = 0,

    reconnect_storm: bool = false,
    storm_rate: f64 = 0,
    storm_baseline: f64 = 0,
    storm_recent: u64 = 0,

    ring_overflow: bool = false,
    overflow_count: u64 = 0,

    keepalive_stalled: bool = false,
    keepalive_p99_ms: u64 = 0,

    /// Up to three shards named in the alert lines.
    hot_shards: [3]u16 = @splat(0),
    hot_shard_count: usize = 0,

    pub fn alertCount(degradation: Degradation) usize {
        var count: usize = 0;
        if (degradation.reconnect_storm) count += 1;
        if (degradation.ring_overflow) count += 1;
        if (degradation.keepalive_stalled) count += 1;
        return count;
    }
};

/// Newest-first ring of log events, with per-filter counts kept as events
/// arrive so the filter strip does not rescan history every frame.
pub const LogBuffer = struct {
    entries: []telemetry.Event = &.{},
    len: usize = 0,
    head: usize = 0,
    total: u64 = 0,
    dropped: u64 = 0,
    counts: [std.enums.values(LogFilter).len]u64 = @splat(0),

    pub fn init(allocator: std.mem.Allocator) !LogBuffer {
        return .{ .entries = try allocator.alloc(telemetry.Event, log_capacity) };
    }

    pub fn deinit(buffer: *LogBuffer, allocator: std.mem.Allocator) void {
        allocator.free(buffer.entries);
        buffer.* = undefined;
    }

    pub fn push(buffer: *LogBuffer, event: telemetry.Event) void {
        if (buffer.entries.len == 0) return;
        buffer.entries[buffer.head] = event;
        buffer.head = (buffer.head + 1) % buffer.entries.len;
        if (buffer.len < buffer.entries.len) buffer.len += 1;
        buffer.total += 1;
        for (std.enums.values(LogFilter), 0..) |filter, index| {
            if (filter.accepts(event)) buffer.counts[index] += 1;
        }
    }

    pub fn count(buffer: *const LogBuffer, filter: LogFilter) u64 {
        return buffer.counts[@backingInt(filter)];
    }

    /// `index` 0 is the newest retained event.
    pub fn at(buffer: *const LogBuffer, index: usize) ?telemetry.Event {
        if (index >= buffer.len) return null;
        const slot = (buffer.head + buffer.entries.len - 1 - index) % buffer.entries.len;
        return buffer.entries[slot];
    }

    /// Fills `out` with the newest matching events, newest first, skipping the
    /// first `skip` matches. Returns the populated prefix.
    pub fn collect(buffer: *const LogBuffer, filter: LogFilter, skip: usize, out: []telemetry.Event) []telemetry.Event {
        // The counts are lifetime totals, so a zero rules the ring out
        // entirely: the filter that has never matched cannot be hiding a
        // retained event, and this is the case that would scan hardest.
        if (buffer.count(filter) == 0) return out[0..0];
        var found: usize = 0;
        var written: usize = 0;
        var index: usize = 0;
        while (index < buffer.len and written < out.len) : (index += 1) {
            const event = buffer.at(index) orelse break;
            if (!filter.accepts(event)) continue;
            if (found < skip) {
                found += 1;
                continue;
            }
            out[written] = event;
            written += 1;
        }
        return out[0..written];
    }

    /// How many retained events match, so the pane can bound its scrolling.
    pub fn matching(buffer: *const LogBuffer, filter: LogFilter) usize {
        var total: usize = 0;
        var index: usize = 0;
        while (index < buffer.len) : (index += 1) {
            const event = buffer.at(index) orelse break;
            if (filter.accepts(event)) total += 1;
        }
        return total;
    }
};

/// Static facts about the run, rendered once into the header line.
pub const RunInfo = struct {
    target: []const u8 = "",
    minecraft_version: []const u8 = "",
    protocol_version: i32 = 0,
    client_count: usize = 0,
    connect_rate_per_sec: u32 = 0,
    username_prefix: []const u8 = "Zion",
    movement: []const u8 = "",
    broadcast: []const u8 = "",
    client_tick: []const u8 = "",
    reconnect: bool = true,
};

/// What the user is currently looking at. Owned by the app loop and handed to
/// panes read-only.
pub const View = struct {
    pane: Pane = .fleet,
    span: Span = .s60,
    sort: SortColumn = .reconnects,
    selected: usize = 0,
    drilled: bool = false,
    /// Which pane the drill-down was opened from, so leaving it returns there
    /// rather than stranding the user on the shard table they never chose.
    drilled_from: Pane = .fleet,
    overlay: bool = false,
    /// The fleet pane's alert layout. Never entered automatically: a fleet in
    /// trouble says so in the strip and waits to be asked.
    alerts: bool = false,
    paused: bool = false,
    log_filter: LogFilter = .all,
    log_scroll: usize = 0,
    log_follow: bool = true,

    /// Navigation lives here rather than in the key handler so it can be
    /// reasoned about, and tested, without a terminal attached.
    pub fn selectPane(view: *View, pane: Pane) void {
        if (!pane.available()) return;
        view.pane = pane;
        view.drilled = false;
        view.alerts = false;
    }

    pub fn drillDown(view: *View) void {
        switch (view.pane) {
            // Every pane that lists shards can open one; `back` returns to
            // whichever of them asked.
            .fleet, .shards, .diagnostics => {
                view.drilled_from = view.pane;
                view.pane = .shards;
                view.drilled = true;
            },
            else => {},
        }
    }

    /// Shows what is wrong. A fleet-pane view, so it is only reachable there;
    /// the other panes leave the key free for their own use.
    pub fn toggleAlerts(view: *View) void {
        if (view.pane != .fleet) return;
        view.alerts = !view.alerts;
        view.drilled = false;
    }

    /// Follow mode is the log pane's "stay on the newest event". The list is
    /// drawn from `log_scroll` alone, so re-entering it has to release the
    /// scroll anchor as well or the label would be the only thing that changed.
    pub fn toggleFollow(view: *View) void {
        view.log_follow = !view.log_follow;
        if (view.log_follow) view.log_scroll = 0;
    }

    /// Moves the window into history by `delta` matches, clamped to what the
    /// filter actually retains. Home and End are this same move to the ends,
    /// so they share the clamp rather than restating it.
    pub fn scrollLog(view: *View, delta: i32, matches: usize) void {
        const scroll: i64 = @as(i64, @intCast(view.log_scroll)) + delta;
        view.log_scroll = @intCast(std.math.clamp(scroll, 0, @as(i64, @intCast(matches -| 1))));
        // The list is drawn from `log_scroll` alone, so an offset of zero is
        // following whatever the flag says; keeping the two in step is what
        // stops the pane reporting "scrolled back 0".
        view.log_follow = view.log_scroll == 0;
    }

    /// Backs out one level. Returns false when there was nothing to leave.
    ///
    /// Innermost first: a shard opened from the alert layout is inside it, so
    /// the first `esc` closes the drill-down and lands back on the alerts the
    /// user came from, and the second leaves them.
    pub fn back(view: *View) bool {
        if (view.drilled) {
            view.drilled = false;
            // Return to the pane the drill-down was opened from; leaving the
            // user on a shard table they never asked for is disorienting.
            view.pane = view.drilled_from;
            return true;
        }
        if (view.alerts) {
            view.alerts = false;
            return true;
        }
        return false;
    }
};

pub const RowWindow = struct {
    start: usize,
    count: usize,
    /// Rows scrolled off the top and bottom of the window respectively. Both
    /// are relative to where the window currently sits, so they change as the
    /// selection moves rather than only reporting the fleet's size.
    above: usize,
    below: usize,
};

/// Which slice of `order` to draw. A fleet taller than the space available
/// scrolls to keep the selection in view and spends its last line saying what
/// it is not showing, so the table never runs off the bottom.
pub fn rowWindow(total: usize, selected: usize, capacity: u16) RowWindow {
    if (capacity == 0 or total == 0) return .{ .start = 0, .count = 0, .above = 0, .below = total };
    if (total <= capacity) return .{ .start = 0, .count = total, .above = 0, .below = 0 };
    const visible: usize = capacity - 1;
    const furthest = total - visible;
    const start = @min(if (selected < visible) 0 else selected - visible + 1, furthest);
    return .{
        .start = start,
        .count = visible,
        .above = start,
        .below = total - (start + visible),
    };
}

pub const RunState = enum { joining, running, degraded, stopped };

/// Consecutive samples an alert must hold before the run counts as degraded.
pub const alert_samples_to_raise: u8 = 3;
/// Consecutive calm samples before it stops counting as degraded. Longer than
/// the entry threshold on purpose: leaving should be the harder transition.
pub const calm_samples_to_clear: u8 = 12;

pub const Model = struct {
    allocator: std.mem.Allocator,
    info: RunInfo = .{},
    state: RunState = .joining,
    elapsed_ms: u64 = 0,

    fleet: Fleet = .{},
    shards: []ShardRow = &.{},
    /// Row indices in the order the shards pane lists them.
    order: []u16 = &.{},

    rx: FleetSeries = .{},
    tx: FleetSeries = .{},
    packets: FleetSeries = .{},
    churn: FleetSeries = .{},
    play_series: FleetSeries = .{},

    degradation: Degradation = .{},
    log: LogBuffer = .{},

    /// Fully joined at least once, which is what switches the fleet pane out of
    /// its ramp layout.
    reached_full_join: bool = false,
    full_join_at_ms: u64 = 0,

    /// When the previous sample was taken, used to turn counters into rates
    /// against `fleet`, which still holds that sample until `update` ends.
    previous_at_ms: u64 = 0,
    /// Reconnects seen in the last sample window, captured before `fleet` is
    /// replaced.
    recent_reconnects: u64 = 0,
    /// Consecutive samples the alert signals have been raised, and the
    /// consecutive calm samples since they last were.
    alert_streak: u8 = 0,
    calm_streak: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, info: RunInfo, shard_count: usize) !Model {
        const shards = try allocator.alloc(ShardRow, shard_count);
        errdefer allocator.free(shards);
        for (shards, 0..) |*row, index| row.* = .{ .id = @intCast(index) };

        const order = try allocator.alloc(u16, shard_count);
        errdefer allocator.free(order);
        for (order, 0..) |*slot, index| slot.* = @intCast(index);

        return .{
            .allocator = allocator,
            .info = info,
            .shards = shards,
            .order = order,
            .log = try LogBuffer.init(allocator),
            .fleet = .{ .requested = info.client_count, .shard_count = shard_count },
        };
    }

    pub fn deinit(model: *Model) void {
        model.allocator.free(model.shards);
        model.allocator.free(model.order);
        model.log.deinit(model.allocator);
        model.* = undefined;
    }

    /// The selected row's position in `order`, clamped: the selection outlives
    /// a fleet that shrank under it.
    pub fn selectedIndex(model: *const Model, view: View) usize {
        if (model.order.len == 0) return 0;
        return @min(view.selected, model.order.len - 1);
    }

    pub fn selectedRow(model: *const Model, view: View) ?ShardRow {
        if (model.order.len == 0) return null;
        return model.shards[model.order[model.selectedIndex(view)]];
    }

    /// Rebuilds every derived value from the shards' published snapshots.
    /// `at_ms` is milliseconds since the run started.
    pub fn update(model: *Model, shards: []telemetry.Shard, at_ms: u64) void {
        model.elapsed_ms = at_ms;

        var fleet: Fleet = .{
            .requested = model.info.client_count,
            .shard_count = shards.len,
        };

        for (shards, 0..) |*shard, index| {
            const snapshot = shard.read();
            const row = &model.shards[index];

            row.id = @intCast(index);
            row.joined = @intCast(shard.progress.joined.load(.acquire));
            row.done = shard.progress.done.load(.acquire);
            row.disconnects = shard.progress.disconnects.load(.acquire);
            // Churn comes from the progress counters rather than the published
            // snapshot: the shard keeps these in every build, while the stats
            // aggregate only counts with `-Denable-stats` on.
            row.reconnects = shard.progress.reconnects.load(.acquire);

            row.requested = snapshot.connected + snapshot.connecting + snapshot.waiting + snapshot.stopped;
            row.connected = snapshot.connected;
            row.connecting = snapshot.connecting;
            row.waiting = snapshot.waiting;
            row.stopped = snapshot.stopped;
            row.play = snapshot.play;

            const previous_bytes = row.bytes_received;
            const previous_sent = row.bytes_sent;
            const previous_packets = row.packets_received;
            row.bytes_received = snapshot.bytes_received;
            row.bytes_sent = snapshot.bytes_sent;
            row.packets_received = snapshot.packets_received;

            const window_seconds = intervalSeconds(at_ms, model.previous_at_ms);
            row.rx_per_sec = perSecond(row.bytes_received, previous_bytes, window_seconds);
            row.tx_per_sec = perSecond(row.bytes_sent, previous_sent, window_seconds);
            row.packets_per_sec = perSecond(row.packets_received, previous_packets, window_seconds);
            row.samples.push(@floatCast(row.rx_per_sec), at_ms);

            row.ring = .{
                .peak_cq_ready = snapshot.peak_cq_ready,
                .peak_cq_entries = snapshot.peak_cq_entries,
                .recv_nobufs = snapshot.recv_nobufs,
                .cq_overflow = snapshot.cq_overflow,
                .close_failures = snapshot.close_failures,
                .max_bundle_bytes = snapshot.max_bundle_bytes,
                .max_bundle_buffers = snapshot.max_bundle_buffers,
                .incremental_buffers = snapshot.incremental_buffers,
            };
            row.keep_alive = snapshot.keep_alive;
            row.keep_alive_p50_ms = snapshot.keep_alive.percentile(0.5);
            row.keep_alive_p99_ms = snapshot.keep_alive.percentile(0.99);

            fleet.joined += row.joined;
            fleet.disconnects += row.disconnects;
            fleet.reconnects += row.reconnects;
            fleet.play += row.play;
            fleet.connected += row.connected;
            fleet.connecting += row.connecting;
            fleet.waiting += row.waiting;
            fleet.stopped += row.stopped;

            fleet.bytes_received += snapshot.bytes_received;
            fleet.bytes_sent += snapshot.bytes_sent;
            fleet.packets_received += snapshot.packets_received;
            fleet.keep_alives += snapshot.keep_alives;

            fleet.keep_alive.add(snapshot.keep_alive);
            fleet.rejoin.add(snapshot.rejoin);
            for (&fleet.disconnect_counts, snapshot.disconnects) |*bucket, value| bucket.* += value;

            // Every shard talks to the same server, so the first shard with an
            // answer answers for the fleet. `.on` still wins over `.off` so a
            // shard whose clients are all still in login cannot mask it.
            if (fleet.compression != .on and snapshot.compression != .unknown) {
                fleet.compression = snapshot.compression;
                fleet.compression_threshold = snapshot.compression_threshold;
            }

            mergeRing(&fleet.ring, row.ring);
        }

        const window_seconds = intervalSeconds(at_ms, model.previous_at_ms);
        fleet.rx_per_sec = perSecond(fleet.bytes_received, model.fleet.bytes_received, window_seconds);
        fleet.tx_per_sec = perSecond(fleet.bytes_sent, model.fleet.bytes_sent, window_seconds);
        fleet.packets_per_sec = perSecond(fleet.packets_received, model.fleet.packets_received, window_seconds);
        fleet.reconnects_per_sec = perSecond(fleet.reconnects, model.fleet.reconnects, window_seconds);

        const elapsed_seconds = @max(0.001, @as(f64, @floatFromInt(at_ms)) / 1000.0);
        fleet.average_rx_per_sec = @as(f64, @floatFromInt(fleet.bytes_received)) / elapsed_seconds;
        fleet.average_tx_per_sec = @as(f64, @floatFromInt(fleet.bytes_sent)) / elapsed_seconds;
        fleet.average_packets_per_sec = @as(f64, @floatFromInt(fleet.packets_received)) / elapsed_seconds;

        // Peaks are carried forward, not recomputed, so they survive a series
        // that has already scrolled past them.
        fleet.peak_rx_per_sec = @max(model.fleet.peak_rx_per_sec, fleet.rx_per_sec);
        fleet.peak_tx_per_sec = @max(model.fleet.peak_tx_per_sec, fleet.tx_per_sec);
        fleet.peak_packets_per_sec = @max(model.fleet.peak_packets_per_sec, fleet.packets_per_sec);
        fleet.peak_rx_at_ms = if (fleet.rx_per_sec > model.fleet.peak_rx_per_sec) at_ms else model.fleet.peak_rx_at_ms;
        fleet.peak_packets_at_ms = if (fleet.packets_per_sec > model.fleet.peak_packets_per_sec) at_ms else model.fleet.peak_packets_at_ms;

        model.recent_reconnects = fleet.reconnects -| model.fleet.reconnects;
        model.previous_at_ms = at_ms;
        model.fleet = fleet;

        model.rx.push(@floatCast(fleet.rx_per_sec), at_ms);
        model.tx.push(@floatCast(fleet.tx_per_sec), at_ms);
        model.packets.push(@floatCast(fleet.packets_per_sec), at_ms);
        model.churn.push(@floatCast(fleet.reconnects_per_sec), at_ms);
        model.play_series.push(@floatFromInt(fleet.play), at_ms);

        model.updateShares();
        model.updateState(at_ms);
    }

    /// Re-sorts `order`. Kept separate from `update` so changing the sort
    /// column does not have to wait for the next sample tick.
    pub fn sortRows(model: *Model, column: SortColumn, descending: bool) void {
        const Context = struct {
            rows: []const ShardRow,
            column: SortColumn,
            descending: bool,

            fn key(context: @This(), row: ShardRow) f64 {
                return switch (context.column) {
                    .id => @floatFromInt(row.id),
                    .joined => @floatFromInt(row.joined),
                    .play => @floatFromInt(row.play),
                    .drops => @floatFromInt(row.disconnects),
                    .reconnects => @floatFromInt(row.reconnects),
                    .rx => row.rx_per_sec,
                    .tx => row.tx_per_sec,
                    .packets => row.packets_per_sec,
                    .keepalive => @floatFromInt(row.keep_alive_p99_ms),
                    .ring => row.ring.occupancy(),
                };
            }

            pub fn lessThan(context: @This(), a: u16, b: u16) bool {
                const left = context.key(context.rows[a]);
                const right = context.key(context.rows[b]);
                // Ties fall back to shard id so the table never reshuffles
                // rows that compare equal from one frame to the next.
                if (left == right) return a < b;
                return if (context.descending) left > right else left < right;
            }
        };
        std.mem.sort(u16, model.order, Context{
            .rows = model.shards,
            .column = column,
            .descending = descending,
        }, Context.lessThan);
    }

    /// Re-sorts `order` while keeping the selection on the shard it was on.
    ///
    /// `view.selected` is a rank into `order`, and the rate columns re-order
    /// the table on every sample tick, so sorting without this walks the
    /// selection onto whichever shard inherits the row — the drill-down would
    /// swap shards under someone in the middle of reading one.
    pub fn sortRowsKeepingSelection(model: *Model, view: *View, column: SortColumn, descending: bool) void {
        if (model.order.len == 0) return model.sortRows(column, descending);
        const shard = model.order[@min(view.selected, model.order.len - 1)];
        model.sortRows(column, descending);
        for (model.order, 0..) |id, rank| {
            if (id != shard) continue;
            view.selected = rank;
            break;
        }
    }

    fn updateShares(model: *Model) void {
        var busiest: f64 = 0;
        for (model.shards) |row| busiest = @max(busiest, row.rx_per_sec);
        const total = model.fleet.bytes_received;
        for (model.shards) |*row| {
            row.rx_share = if (total == 0)
                0
            else
                @as(f64, @floatFromInt(row.bytes_received)) / @as(f64, @floatFromInt(total));
            row.load = if (busiest > 0) row.rx_per_sec / busiest else 0;
        }
    }

    /// Spread of receive rate across the fleet, which the shards pane prints as
    /// its "no shard starved" line.
    pub fn receiveSpread(model: *const Model) struct { low: f64, high: f64, median: f64 } {
        if (model.shards.len == 0) return .{ .low = 0, .high = 0, .median = 0 };
        var scratch: [512]f32 = undefined;
        const take = @min(model.shards.len, scratch.len);
        var low: f64 = std.math.floatMax(f64);
        var high: f64 = 0;
        for (model.shards[0..take], 0..) |row, index| {
            scratch[index] = @floatCast(row.rx_per_sec);
            low = @min(low, row.rx_per_sec);
            high = @max(high, row.rx_per_sec);
        }
        const slice = scratch[0..take];
        std.mem.sort(f32, slice, {}, std.sort.asc(f32));
        return .{ .low = low, .high = high, .median = slice[slice.len / 2] };
    }

    /// Recomputes the run state and the degradation signals. Public so a
    /// caller can force a re-evaluation without waiting for a sample tick.
    pub fn updateState(model: *Model, at_ms: u64) void {
        if (!model.reached_full_join and model.fleet.requested > 0 and model.fleet.joined >= model.fleet.requested) {
            model.reached_full_join = true;
            model.full_join_at_ms = at_ms;
            model.log.push(.{
                .kind = .full_join,
                .fleet = true,
                .at_ms = at_ms,
                .value = model.fleet.joined,
            });
        }

        var degradation: Degradation = .{ .began_at_ms = model.degradation.began_at_ms };

        // The ring reporting overflow is unambiguous: completions were lost.
        if (model.fleet.ring.cq_overflow > 0) {
            degradation.ring_overflow = true;
            degradation.overflow_count = model.fleet.ring.cq_overflow;
        }

        // A churn storm is measured against this run's own trailing baseline,
        // not an absolute rate, so a busy-but-steady fleet is not called sick.
        const baseline = model.churn.medianExcludingRecent(.s60, 20);
        const rate = model.fleet.reconnects_per_sec;
        if (rate >= 1 and rate >= @max(0.2, @as(f64, baseline)) * 10) {
            degradation.reconnect_storm = true;
            degradation.storm_rate = rate;
            degradation.storm_baseline = baseline;
            degradation.storm_recent = model.recent_reconnects;
        }

        const keepalive_p99 = model.fleet.keep_alive.percentile(0.99);
        if (keepalive_p99 >= 200) {
            degradation.keepalive_stalled = true;
            degradation.keepalive_p99_ms = keepalive_p99;
        }

        // A signal sitting on its threshold would otherwise flip the run state
        // every sample, and with it the palette and the strip. Enter only after
        // the signals persist, and leave only after a longer stretch of calm,
        // so a fleet hovering at the boundary settles instead of chattering.
        const raised = degradation.alertCount() > 0;
        if (raised) {
            model.alert_streak +|= 1;
            model.calm_streak = 0;
        } else {
            model.calm_streak +|= 1;
            model.alert_streak = 0;
        }
        degradation.active = if (model.degradation.active)
            model.calm_streak < calm_samples_to_clear
        else
            model.alert_streak >= alert_samples_to_raise;
        if (degradation.active and !model.degradation.active) degradation.began_at_ms = at_ms;

        var named: usize = 0;
        for (model.order) |index| {
            if (named >= degradation.hot_shards.len) break;
            const row = model.shards[index];
            if (row.severity(model.fleet) != .hot) continue;
            degradation.hot_shards[named] = row.id;
            named += 1;
        }
        degradation.hot_shard_count = named;

        model.degradation = degradation;
        model.state = if (degradation.active)
            .degraded
        else if (model.reached_full_join)
            .running
        else
            .joining;
    }

    /// Drains every shard's event ring into the log buffer. Called every frame
    /// so a shard's 256-slot ring cannot back up between sample ticks.
    pub fn drainEvents(model: *Model, shards: []telemetry.Shard) void {
        var dropped: u64 = 0;
        for (shards) |*shard| {
            while (shard.events.pop()) |event| model.log.push(event);
            dropped += shard.events.dropped.load(.monotonic);
        }
        model.log.dropped = dropped;
    }

    /// Usernames are derived, never stored per client: prefix plus the 1-based
    /// client number, matching `client.username`.
    pub fn username(model: *const Model, index: u32, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}{d}", .{ model.info.username_prefix, index + 1 }) catch buffer[0..0];
    }

    /// One palette for the whole run. Trouble is signalled by markers, labels
    /// and the strip, never by recolouring the screen out from under someone
    /// who is reading it.
    pub fn palette(model: *const Model) theme.Palette {
        _ = model;
        return theme.running;
    }
};

fn mergeRing(into: *RingPressure, other: RingPressure) void {
    if (other.peak_cq_entries != 0) {
        if (into.peak_cq_entries == 0 or
            @as(u64, other.peak_cq_ready) * into.peak_cq_entries >
                @as(u64, into.peak_cq_ready) * other.peak_cq_entries)
        {
            into.peak_cq_ready = other.peak_cq_ready;
            into.peak_cq_entries = other.peak_cq_entries;
        }
    }
    into.recv_nobufs += other.recv_nobufs;
    into.cq_overflow += other.cq_overflow;
    into.close_failures += other.close_failures;
    into.max_bundle_bytes = @max(into.max_bundle_bytes, other.max_bundle_bytes);
    into.max_bundle_buffers = @max(into.max_bundle_buffers, other.max_bundle_buffers);
    // Every shard registers against the same kernel, so `or` carries the one
    // answer through a fleet total that starts out zeroed.
    into.incremental_buffers = into.incremental_buffers or other.incremental_buffers;
}

fn intervalSeconds(now_ms: u64, previous_ms: u64) f64 {
    const delta = now_ms -| previous_ms;
    if (delta == 0) return 0;
    return @as(f64, @floatFromInt(delta)) / 1000.0;
}

/// Rate over one sample window. A counter that went backwards (a shard that
/// republished mid-read) reports zero rather than a negative spike.
fn perSecond(current: u64, previous: u64, seconds: f64) f64 {
    if (seconds <= 0 or current < previous) return 0;
    return @as(f64, @floatFromInt(current - previous)) / seconds;
}

test "a full window fills a plot wider than the span's sample count" {
    if (comptime !features.tui) return error.SkipZigTest;
    var series: FleetSeries = .{};
    const span_samples = Span.s60.sampleCount();
    for (0..span_samples) |index| series.push(@floatFromInt(index), index * sample_interval_ms);

    // A 60s span is 120 samples; a 130-column chart still covers all 130,
    // because how many samples were stored has nothing to do with how wide the
    // plot is.
    var out: [130]f32 = undefined;
    const window = series.window(.s60, &out);
    try std.testing.expectEqual(@as(usize, 130), window.len);
    // Oldest first, ending on the newest sample, and monotonically increasing
    // like the series that produced it.
    try std.testing.expectEqual(@as(f32, 0), window[0]);
    try std.testing.expectEqual(@as(f32, @floatFromInt(span_samples - 1)), window[window.len - 1]);
    for (window[1..], 0..) |value, index| try std.testing.expect(value >= window[index]);
}

test "a full window averages over the period when the plot is narrower" {
    if (comptime !features.tui) return error.SkipZigTest;
    var series: FleetSeries = .{};
    const span_samples = Span.s60.sampleCount();
    for (0..span_samples) |index| series.push(@floatFromInt(index), index * sample_interval_ms);

    // Half as many columns as samples: every column is the mean of its pair,
    // so the average is taken over the period rather than samples being
    // skipped.
    var out: [60]f32 = undefined;
    const window = series.window(.s60, &out);
    try std.testing.expectEqual(@as(usize, 60), window.len);
    try std.testing.expectEqual(@as(f32, 0.5), window[0]);
    try std.testing.expectEqual(@as(f32, 2.5), window[1]);
    try std.testing.expectEqual(@as(f32, @floatFromInt(span_samples)) - 1.5, window[window.len - 1]);
}

test "the run span always spans the plot, however young the run is" {
    if (comptime !features.tui) return error.SkipZigTest;
    var series: FleetSeries = .{};
    // Four seconds in: a handful of samples against a capacity of 1800.
    for (0..8) |index| series.push(@floatFromInt(index), index * sample_interval_ms);

    var out: [138]f32 = undefined;
    const window = series.window(.run, &out);
    // "Everything so far" is complete by definition, so it fills the chart
    // rather than being scaled against a capacity the run has not reached.
    try testing.expectEqual(@as(usize, 138), window.len);
    try testing.expectEqual(@as(f32, 0), window[0]);
    try testing.expectEqual(@as(f32, 7), window[window.len - 1]);

    // A fixed span in the same state is still proportional.
    const fixed = series.window(.s60, &out);
    try testing.expect(fixed.len < 138);
}

test "a window that has not filled yet occupies only the fraction it covers" {
    if (comptime !features.tui) return error.SkipZigTest;
    var series: FleetSeries = .{};
    const span_samples = Span.s60.sampleCount();
    // A quarter of a 60s window.
    for (0..span_samples / 4) |index| series.push(@floatFromInt(index), index * sample_interval_ms);

    var out: [120]f32 = undefined;
    const window = series.window(.s60, &out);
    // A young run must not look like a full period of history: it takes a
    // quarter of the plot, and the chart right-aligns it.
    try std.testing.expectEqual(@as(usize, 30), window.len);
    try std.testing.expectEqual(@as(f32, @floatFromInt((span_samples / 4) - 1)), window[window.len - 1]);
}

test "series wraps without losing the newest samples" {
    if (comptime !features.tui) return error.SkipZigTest;
    var series: ShardSeries = .{};
    for (0..shard_sample_capacity + 5) |index| series.push(@floatFromInt(index), index);
    try std.testing.expectEqual(@as(usize, shard_sample_capacity), series.len);
    try std.testing.expectEqual(@as(f32, shard_sample_capacity + 4), series.last());

    // A 60s span is exactly 120 samples, so each column is one sample and the
    // window ends on the newest push despite the ring having wrapped.
    var out: [120]f32 = undefined;
    const window = series.window(.s60, &out);
    try std.testing.expectEqual(@as(usize, 120), window.len);
    try std.testing.expectEqual(@as(f32, shard_sample_capacity + 4), window[window.len - 1]);
    try std.testing.expectEqual(@as(f32, shard_sample_capacity + 4 - 119), window[0]);
}

test "log buffer filters and counts without rescanning history" {
    if (comptime !features.tui) return error.SkipZigTest;
    var buffer = try LogBuffer.init(std.testing.allocator);
    defer buffer.deinit(std.testing.allocator);

    buffer.push(.{ .kind = .entered_play, .at_ms = 1 });
    buffer.push(.{ .kind = .disconnect, .category = .server, .at_ms = 2 });
    buffer.push(.{ .kind = .reconnect, .at_ms = 3 });

    try std.testing.expectEqual(@as(u64, 3), buffer.count(.all));
    try std.testing.expectEqual(@as(u64, 1), buffer.count(.joins));
    try std.testing.expectEqual(@as(u64, 1), buffer.count(.drops));
    try std.testing.expectEqual(@as(u64, 1), buffer.count(.server));

    // Newest first.
    try std.testing.expectEqual(telemetry.Event.Kind.reconnect, buffer.at(0).?.kind);
    try std.testing.expectEqual(telemetry.Event.Kind.entered_play, buffer.at(2).?.kind);

    var out: [4]telemetry.Event = undefined;
    const drops = buffer.collect(.drops, 0, &out);
    try std.testing.expectEqual(@as(usize, 1), drops.len);
    try std.testing.expectEqual(@as(u64, 2), drops[0].at_ms);
}

test "log buffer keeps the newest events once it wraps" {
    if (comptime !features.tui) return error.SkipZigTest;
    var buffer = try LogBuffer.init(std.testing.allocator);
    defer buffer.deinit(std.testing.allocator);

    for (0..log_capacity + 10) |index| buffer.push(.{ .kind = .entered_play, .at_ms = index });
    try std.testing.expectEqual(@as(usize, log_capacity), buffer.len);
    try std.testing.expectEqual(@as(u64, log_capacity + 9), buffer.at(0).?.at_ms);
    // Total counts every event ever seen, not just the retained window.
    try std.testing.expectEqual(@as(u64, log_capacity + 10), buffer.total);
}

test "sortRows orders by the requested column and breaks ties by id" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 30 }, 3);
    defer model.deinit();

    model.shards[0].reconnects = 5;
    model.shards[1].reconnects = 21;
    model.shards[2].reconnects = 5;

    model.sortRows(.reconnects, true);
    try std.testing.expectEqualSlices(u16, &.{ 1, 0, 2 }, model.order);

    model.sortRows(.id, false);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, model.order);
}

test "a re-sort keeps the selection on the shard it was on, not on its rank" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 30 }, 3);
    defer model.deinit();
    var view: View = .{};

    model.shards[0].reconnects = 5;
    model.shards[1].reconnects = 21;
    model.shards[2].reconnects = 1;
    model.sortRows(.reconnects, true);
    try std.testing.expectEqualSlices(u16, &.{ 1, 0, 2 }, model.order);

    // Select the quietest shard, sitting last.
    view.selected = 2;
    try std.testing.expectEqual(@as(u16, 2), model.selectedRow(view).?.id);

    // It then churns past both others. The row moves to the top of the table;
    // the selection must move with it rather than staying on rank 2.
    model.shards[2].reconnects = 99;
    model.sortRowsKeepingSelection(&view, .reconnects, true);
    try std.testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, model.order);
    try std.testing.expectEqual(@as(usize, 0), view.selected);
    try std.testing.expectEqual(@as(u16, 2), model.selectedRow(view).?.id);
}

test "keepalive severity has one owner and escalates at 16 and 100 ms" {
    if (comptime !features.tui) return error.SkipZigTest;
    try std.testing.expectEqual(Severity.ok, keepAliveSeverityFor(15));
    try std.testing.expectEqual(Severity.watch, keepAliveSeverityFor(16));
    try std.testing.expectEqual(Severity.watch, keepAliveSeverityFor(99));
    try std.testing.expectEqual(Severity.hot, keepAliveSeverityFor(100));
    // The row method is the same rating, read off the row's own p99.
    const row: ShardRow = .{ .keep_alive_p99_ms = 100 };
    try std.testing.expectEqual(Severity.hot, row.keepAliveSeverity());

    // Play is rated the same way, and an empty population is guarded by the
    // caller rather than being reported as hot.
    try std.testing.expectEqual(Severity.hot, playSeverityFor(0));
    try std.testing.expectEqual(Severity.watch, playSeverityFor(0.95));
    try std.testing.expectEqual(Severity.ok, playSeverityFor(1));
    const empty: ShardRow = .{ .requested = 0 };
    try std.testing.expectEqual(Severity.ok, empty.playSeverity());
}

test "perSecond ignores a counter that appears to go backwards" {
    if (comptime !features.tui) return error.SkipZigTest;
    try std.testing.expectEqual(@as(f64, 200), perSecond(200, 100, 0.5));
    try std.testing.expectEqual(@as(f64, 0), perSecond(100, 200, 0.5));
    try std.testing.expectEqual(@as(f64, 0), perSecond(200, 100, 0));
}

test "shard severity escalates on churn far above the fleet average" {
    if (comptime !features.tui) return error.SkipZigTest;
    const fleet: Fleet = .{ .reconnects = 120, .shard_count = 12, .requested = 120 };
    // Average is 10 per shard.
    const calm: ShardRow = .{ .reconnects = 9, .requested = 10, .play = 10 };
    const hot: ShardRow = .{ .reconnects = 31, .requested = 10, .play = 10 };
    try std.testing.expectEqual(Severity.ok, calm.churnSeverity(fleet));
    try std.testing.expectEqual(Severity.hot, hot.churnSeverity(fleet));
}

test "degradation only fires when churn far exceeds its own baseline" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 100 }, 1);
    defer model.deinit();

    // A steady, busy fleet: high but stable churn is not a storm.
    for (0..60) |index| model.churn.push(4, index * sample_interval_ms);
    model.fleet.reconnects_per_sec = 4;
    model.updateState(30_000);
    try std.testing.expect(!model.degradation.reconnect_storm);

    // The same fleet suddenly reconnecting ten times as fast is, but the state
    // only follows once the signal has held for long enough to be believed.
    model.fleet.reconnects_per_sec = 40;
    model.updateState(31_000);
    try std.testing.expect(model.degradation.reconnect_storm);
    try std.testing.expect(model.state != .degraded);
    for (0..alert_samples_to_raise) |_| model.updateState(31_500);
    try std.testing.expectEqual(RunState.degraded, model.state);
}

test "a signal sitting on its threshold does not flip the run state each sample" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 100 }, 1);
    defer model.deinit();
    model.reached_full_join = true;
    for (0..60) |index| model.churn.push(1, index * sample_interval_ms);

    // Alternating either side of the threshold must not reach the degraded
    // state at all: that chattering is what the entry streak exists to absorb.
    for (0..20) |index| {
        model.fleet.reconnects_per_sec = if (index % 2 == 0) 40 else 0;
        model.updateState(@as(u64, index) * sample_interval_ms);
        try std.testing.expect(model.state != .degraded);
    }

    // Held long enough, it latches...
    model.fleet.reconnects_per_sec = 40;
    for (0..alert_samples_to_raise) |_| model.updateState(20_000);
    try std.testing.expectEqual(RunState.degraded, model.state);

    // ...and one calm sample does not immediately undo it.
    model.fleet.reconnects_per_sec = 0;
    model.updateState(20_500);
    try std.testing.expectEqual(RunState.degraded, model.state);

    // Only sustained calm clears it.
    for (0..calm_samples_to_clear) |_| model.updateState(21_000);
    try std.testing.expectEqual(RunState.running, model.state);
}

test "leaving a drill-down returns to the pane it was opened from" {
    if (comptime !features.tui) return error.SkipZigTest;
    var view: View = .{};

    // Drilled in from the fleet pane: escape goes back to the fleet, not to a
    // shard table the user never chose.
    view.drillDown();
    try std.testing.expectEqual(Pane.shards, view.pane);
    try std.testing.expect(view.drilled);
    try std.testing.expect(view.back());
    try std.testing.expectEqual(Pane.fleet, view.pane);
    try std.testing.expect(!view.drilled);

    // Drilled in from the shard table: escape goes back to the table.
    view.selectPane(.shards);
    view.drillDown();
    try std.testing.expect(view.back());
    try std.testing.expectEqual(Pane.shards, view.pane);
    try std.testing.expect(!view.drilled);

    // Nothing left to leave.
    try std.testing.expect(!view.back());
}

test "the alert view is a fleet-pane view, entered and left by hand" {
    if (comptime !features.tui) return error.SkipZigTest;
    var view: View = .{ .pane = .log };

    // Not reachable from another pane: those keep the key for themselves.
    view.toggleAlerts();
    try std.testing.expect(!view.alerts);
    try std.testing.expectEqual(Pane.log, view.pane);

    view.selectPane(.fleet);
    view.toggleAlerts();
    try std.testing.expect(view.alerts);

    try std.testing.expect(view.back());
    try std.testing.expect(!view.alerts);

    // Picking any pane leaves the alert view behind.
    view.toggleAlerts();
    view.selectPane(.shards);
    try std.testing.expect(!view.alerts);
    try std.testing.expectEqual(Pane.shards, view.pane);
}

test "a shard opened from the alert view backs out into it, not past it" {
    if (comptime !features.tui) return error.SkipZigTest;
    var view: View = .{};

    view.toggleAlerts();
    view.drillDown();
    try std.testing.expectEqual(Pane.shards, view.pane);
    try std.testing.expect(view.drilled);
    try std.testing.expect(view.alerts);

    // The drill-down is the inner level: leaving it lands back on the alert
    // layout the shard was opened from.
    try std.testing.expect(view.back());
    try std.testing.expectEqual(Pane.fleet, view.pane);
    try std.testing.expect(!view.drilled);
    try std.testing.expect(view.alerts);

    // Only the second escape leaves the alerts.
    try std.testing.expect(view.back());
    try std.testing.expect(!view.alerts);
    try std.testing.expect(!view.back());
}

test "re-entering follow mode releases the scroll anchor" {
    if (comptime !features.tui) return error.SkipZigTest;
    var view: View = .{ .pane = .log, .log_follow = true };

    // Scrolling into history leaves follow mode, as the key handler does.
    view.log_scroll = 5;
    view.log_follow = false;

    view.toggleFollow();
    try std.testing.expect(view.log_follow);
    // Following while anchored five events back would skip the newest events
    // while claiming to be showing them.
    try std.testing.expectEqual(@as(usize, 0), view.log_scroll);

    // Leaving follow mode on purpose keeps the position.
    view.log_scroll = 3;
    view.toggleFollow();
    try std.testing.expect(!view.log_follow);
    try std.testing.expectEqual(@as(usize, 3), view.log_scroll);
}

test "home and end reach the ends of the log rather than a hidden selection" {
    if (comptime !features.tui) return error.SkipZigTest;
    var view: View = .{ .pane = .log };

    // End walks to the oldest retained match, Home back to the newest. Both
    // clamp against the same bound the arrows do, so neither can run past it.
    view.scrollLog(std.math.maxInt(i32), 40);
    try std.testing.expectEqual(@as(usize, 39), view.log_scroll);
    try std.testing.expect(!view.log_follow);

    view.scrollLog(std.math.minInt(i32), 40);
    try std.testing.expectEqual(@as(usize, 0), view.log_scroll);
    // Arriving back at the newest event is following it, whichever key got
    // there; the pane reported "scrolled back 0" while these disagreed.
    try std.testing.expect(view.log_follow);

    // An empty filter has no history to walk into.
    view.scrollLog(std.math.maxInt(i32), 0);
    try std.testing.expectEqual(@as(usize, 0), view.log_scroll);
    try std.testing.expect(view.log_follow);
}

test "the diagnostics table opens a shard and returns to it" {
    if (comptime !features.tui) return error.SkipZigTest;
    if (comptime !features.diagnostics) return error.SkipZigTest;
    var view: View = .{};

    view.selectPane(.diagnostics);
    view.drillDown();
    try std.testing.expectEqual(Pane.shards, view.pane);
    try std.testing.expect(view.drilled);

    try std.testing.expect(view.back());
    try std.testing.expectEqual(Pane.diagnostics, view.pane);
}

test "log filters cycle both ways" {
    if (comptime !features.tui) return error.SkipZigTest;
    try std.testing.expectEqual(LogFilter.joins, LogFilter.all.next());
    try std.testing.expectEqual(LogFilter.all, LogFilter.joins.previous());
    // Both directions wrap.
    try std.testing.expectEqual(LogFilter.protocol, LogFilter.all.previous());
    try std.testing.expectEqual(LogFilter.all, LogFilter.protocol.next());
}

test "update reduces published shard snapshots into fleet totals and rates" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 20 }, 2);
    defer model.deinit();

    var shards: [2]telemetry.Shard = .{ .{}, .{} };
    for (&shards, 0..) |*shard, index| {
        shard.progress.joined.store(10, .release);
        shard.progress.reconnects.store(@intCast(index), .release);
        shard.publish(.{
            .bytes_received = 1000 * (index + 1),
            .bytes_sent = 100,
            .packets_received = 50,
            .connected = 10,
            .play = 10,
        });
    }

    // First sample: with no previous reading, rates are measured from the run
    // start, so one second of elapsed time yields the totals as a rate.
    model.update(&shards, 1000);
    try std.testing.expectEqual(@as(u64, 20), model.fleet.joined);
    try std.testing.expectEqual(@as(u64, 20), model.fleet.play);
    try std.testing.expectEqual(@as(u64, 3000), model.fleet.bytes_received);
    try std.testing.expectEqual(@as(u64, 1), model.fleet.reconnects);
    try std.testing.expectEqual(@as(f64, 3000), model.fleet.rx_per_sec);

    // Receive share is per shard, out of the fleet's bytes.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), model.shards[0].rx_share, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), model.shards[1].rx_share, 0.001);
    // The busiest shard defines full load.
    try std.testing.expectEqual(@as(f64, 1), model.shards[1].load);

    // Second sample half a second later: the rate reflects only the delta.
    for (&shards, 0..) |*shard, index| {
        shard.publish(.{
            .bytes_received = 1000 * (index + 1) + 500,
            .connected = 10,
            .play = 10,
        });
    }
    model.update(&shards, 1500);
    try std.testing.expectEqual(@as(u64, 4000), model.fleet.bytes_received);
    // 1000 new bytes over 0.5s.
    try std.testing.expectEqual(@as(f64, 2000), model.fleet.rx_per_sec);
    // The peak is carried forward rather than recomputed from the window.
    try std.testing.expectEqual(@as(f64, 3000), model.fleet.peak_rx_per_sec);
    // Full join was reached and logged as a milestone.
    try std.testing.expect(model.reached_full_join);
    try std.testing.expectEqual(@as(u64, 1), model.log.count(.joins));
}

test "the fleet takes compression from whichever shard has an answer" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 20 }, 2);
    defer model.deinit();

    var shards: [2]telemetry.Shard = .{ .{}, .{} };

    // Nothing past login anywhere yet: the fleet must not claim to know.
    model.update(&shards, 1000);
    try std.testing.expectEqual(telemetry.CompressionState.unknown, model.fleet.compression);

    // One shard still in login, the other with the server's answer. A shard
    // that has not been told cannot mask one that has.
    shards[1].publish(.{ .compression = .on, .compression_threshold = 256 });
    model.update(&shards, 1500);
    try std.testing.expectEqual(telemetry.CompressionState.on, model.fleet.compression);
    try std.testing.expectEqual(@as(i32, 256), model.fleet.compression_threshold);

    // And a server with it turned off is reported as off, not as unknown.
    var quiet: [1]telemetry.Shard = .{.{}};
    var off_model = try Model.init(std.testing.allocator, .{ .client_count = 10 }, 1);
    defer off_model.deinit();
    quiet[0].publish(.{ .compression = .off });
    off_model.update(&quiet, 1000);
    try std.testing.expectEqual(telemetry.CompressionState.off, off_model.fleet.compression);
}

test "the fleet's ring pressure is the busiest ratio, not the largest count" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 20 }, 2);
    defer model.deinit();

    var shards: [2]telemetry.Shard = .{ .{}, .{} };
    shards[0].publish(.{ .peak_cq_ready = 100, .peak_cq_entries = 4096, .recv_nobufs = 2 });
    shards[1].publish(.{ .peak_cq_ready = 90, .peak_cq_entries = 512, .recv_nobufs = 3 });

    model.update(&shards, 1000);
    // 90/512 is a heavier ring than 100/4096 despite the smaller count.
    try std.testing.expectEqual(@as(u32, 90), model.fleet.ring.peak_cq_ready);
    try std.testing.expectEqual(@as(u32, 512), model.fleet.ring.peak_cq_entries);
    // Counters that are not ratios still add up across the fleet.
    try std.testing.expectEqual(@as(u64, 5), model.fleet.ring.recv_nobufs);
}

test "the fleet reports the buffer mode its shards negotiated" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 20 }, 2);
    defer model.deinit();

    var whole: [2]telemetry.Shard = .{ .{}, .{} };
    whole[0].publish(.{ .peak_cq_entries = 512 });
    whole[1].publish(.{ .peak_cq_entries = 512 });
    model.update(&whole, 1000);
    try std.testing.expect(!model.fleet.ring.incremental_buffers);

    // The fleet total starts zeroed and every shard merges into it, so the
    // answer has to survive that rather than being cleared by it.
    var incremental: [2]telemetry.Shard = .{ .{}, .{} };
    incremental[0].publish(.{ .peak_cq_entries = 512, .incremental_buffers = true });
    incremental[1].publish(.{ .peak_cq_entries = 512, .incremental_buffers = true });
    model.update(&incremental, 2000);
    try std.testing.expect(model.fleet.ring.incremental_buffers);
}

test "drainEvents sums every shard's dropped count" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 4 }, 2);
    defer model.deinit();

    var shards: [2]telemetry.Shard = .{ .{}, .{} };
    shards[0].events.push(.{ .kind = .entered_play, .at_ms = 1 });
    shards[1].events.push(.{ .kind = .disconnect, .at_ms = 2 });
    // Overfill one ring so it reports drops.
    for (0..telemetry.EventRing.capacity + 3) |_| shards[1].events.push(.{ .kind = .reconnect });

    model.drainEvents(&shards);
    try std.testing.expectEqual(@as(u64, 4), shards[1].events.dropped.load(.monotonic));
    // Both shards' drops are reported, not just the last one scanned.
    try std.testing.expectEqual(@as(u64, 4), model.log.dropped);
    try std.testing.expect(model.log.len > 2);
}

test "ring overflow alone puts the dashboard in its degraded state" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 10 }, 1);
    defer model.deinit();
    model.fleet.ring.cq_overflow = 3918;
    model.updateState(1000);
    try std.testing.expect(model.degradation.ring_overflow);
    // Overflow is latched by the ring, so it holds across samples and the state
    // follows once the entry streak is met.
    for (0..alert_samples_to_raise) |_| model.updateState(1500);
    try std.testing.expectEqual(RunState.degraded, model.state);
}

test "churn is reported in a build with the stats counters compiled out" {
    if (comptime !features.tui) return error.SkipZigTest;
    var model = try Model.init(std.testing.allocator, .{ .client_count = 10 }, 1);
    defer model.deinit();

    // The shard's progress counters are maintained regardless of -Denable-stats,
    // which is why churn is read from them and not from the published snapshot.
    var shards: [1]telemetry.Shard = .{.{}};
    shards[0].progress.reconnects.store(37, .release);
    shards[0].publish(.{});

    model.update(&shards, 1000);
    try std.testing.expectEqual(@as(u64, 37), model.fleet.reconnects);
    try std.testing.expectEqual(@as(u64, 37), model.shards[0].reconnects);
}
