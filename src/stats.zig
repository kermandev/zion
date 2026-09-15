const std = @import("std");
const build_options = @import("build_options");

pub const stats_enabled = build_options.enable_stats;
pub const diagnostics_enabled = build_options.enable_diagnostics;
pub const tui_enabled = build_options.enable_tui;

// `T` in diagnostics builds, `void` otherwise: the SoA column stays declared but
// occupies no storage when diagnostics are compiled out.
pub fn Column(comptime T: type) type {
    return if (diagnostics_enabled) T else void;
}

// Columns only the dashboard reads. Gated on the dashboard as well as on
// diagnostics so a headless diagnostics build keeps its per-client footprint.
pub const dashboard_columns_enabled = diagnostics_enabled and tui_enabled;

pub fn DashboardColumn(comptime T: type) type {
    return if (dashboard_columns_enabled) T else void;
}

pub const StatsColumns = struct {
    last_packet_id: Column(i32) = if (diagnostics_enabled) -1 else {},
    keep_alives_answered: Column(u32) = if (diagnostics_enabled) 0 else {},
    keep_alive_started_ms: Column(u64) = if (diagnostics_enabled) 0 else {},
    keep_alive_pending_bytes: Column(u16) = if (diagnostics_enabled) 0 else {},
    // When this client last dropped, as milliseconds since the shard started,
    // so re-entering play can be reported as a rejoin time. Zero means it has
    // not dropped yet. 32 bits covers 49 days of run time and halves what this
    // cold column costs per client.
    disconnected_at_ms: DashboardColumn(u32) = if (dashboard_columns_enabled) 0 else {},
};

pub const Disconnects = struct {
    server: u64 = 0,
    transport: u64 = 0,
    connect: u64 = 0,
    buffer_limit: u64 = 0,
    protocol: u64 = 0,
    resource: u64 = 0,
    other: u64 = 0,

    pub fn add(self: *Disconnects, other: Disconnects) void {
        self.server += other.server;
        self.transport += other.transport;
        self.connect += other.connect;
        self.buffer_limit += other.buffer_limit;
        self.protocol += other.protocol;
        self.resource += other.resource;
        self.other += other.other;
    }

    pub fn record(self: *Disconnects, err: anyerror) void {
        const bucket = switch (err) {
            error.ServerDisconnected => &self.server,
            error.Disconnected => &self.transport,
            error.ConnectionRefused,
            error.HostUnreachable,
            error.NetworkUnreachable,
            error.Timeout,
            error.FileNotFound,
            => &self.connect,
            error.ReadBufferLimitExceeded,
            error.WriteBufferLimitExceeded,
            => &self.buffer_limit,
            error.SystemResources,
            error.OutOfMemory,
            => &self.resource,
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
            => &self.protocol,
            else => &self.other,
        };
        bucket.* += 1;
    }
};

pub const Diagnostics = struct {
    recv_nobufs: u64 = 0,
    cq_overflow: u64 = 0,
    close_failures: u64 = 0,
    max_cq_ready: u32 = 0,
    max_cq_entries: u32 = 0,
    max_recv_bundle_bytes: u64 = 0,
    max_recv_bundle_buffers: u32 = 0,
    keep_alive_send_samples: u64 = 0,
    keep_alive_send_total_ms: u64 = 0,
    keep_alive_send_max_ms: u64 = 0,
    // Whether the receive ring registered with IOU_PBUF_RING_INC, which decides
    // whether a completion retires a whole buffer or only the bytes it used.
    // Every shard registers against the same kernel and so gets the same
    // answer; merging with `or` keeps that answer through an aggregate that
    // starts out zeroed.
    incremental_buffers: bool = false,
    disconnects: Disconnects = .{},

    pub fn add(self: *Diagnostics, other: Diagnostics) void {
        self.recv_nobufs += other.recv_nobufs;
        self.cq_overflow += other.cq_overflow;
        self.close_failures += other.close_failures;
        self.observeCq(other.max_cq_ready, other.max_cq_entries);
        self.max_recv_bundle_bytes = @max(self.max_recv_bundle_bytes, other.max_recv_bundle_bytes);
        self.max_recv_bundle_buffers = @max(self.max_recv_bundle_buffers, other.max_recv_bundle_buffers);
        self.keep_alive_send_samples += other.keep_alive_send_samples;
        self.keep_alive_send_total_ms += other.keep_alive_send_total_ms;
        self.keep_alive_send_max_ms = @max(self.keep_alive_send_max_ms, other.keep_alive_send_max_ms);
        self.incremental_buffers = self.incremental_buffers or other.incremental_buffers;
        self.disconnects.add(other.disconnects);
    }

    pub fn observeCq(self: *Diagnostics, ready: u32, entries: u32) void {
        if (entries == 0) return;
        if (self.max_cq_entries != 0 and
            @as(u64, ready) * self.max_cq_entries <= @as(u64, self.max_cq_ready) * entries)
        {
            return;
        }
        self.max_cq_ready = ready;
        self.max_cq_entries = entries;
    }

    pub fn recordKeepAliveSend(self: *Diagnostics, latency_ms: u64) void {
        self.keep_alive_send_samples += 1;
        self.keep_alive_send_total_ms += latency_ms;
        self.keep_alive_send_max_ms = @max(self.keep_alive_send_max_ms, latency_ms);
    }
};

pub const RunDiagnostics = if (diagnostics_enabled) Diagnostics else void;

test "StatsColumns basic telemetry tracking" {
    var columns: StatsColumns = .{};

    if (diagnostics_enabled) {
        columns.last_packet_id = 42;
        try std.testing.expectEqual(@as(i32, 42), columns.last_packet_id);
        try std.testing.expectEqual(@as(u16, 0), columns.keep_alive_pending_bytes);
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

test "diagnostics aggregate pressure and retain peak CQ utilization" {
    var diagnostics: Diagnostics = .{
        .recv_nobufs = 2,
        .cq_overflow = 3,
        .close_failures = 1,
        .max_cq_ready = 100,
        .max_cq_entries = 512,
        .max_recv_bundle_bytes = 8192,
        .max_recv_bundle_buffers = 2,
        .keep_alive_send_samples = 1,
        .keep_alive_send_total_ms = 5,
        .keep_alive_send_max_ms = 5,
        .disconnects = .{ .transport = 1 },
    };
    diagnostics.add(.{
        .recv_nobufs = 7,
        .cq_overflow = 11,
        .close_failures = 2,
        .max_cq_ready = 80,
        .max_cq_entries = 256,
        .max_recv_bundle_bytes = 16_384,
        .max_recv_bundle_buffers = 4,
        .keep_alive_send_samples = 2,
        .keep_alive_send_total_ms = 13,
        .keep_alive_send_max_ms = 9,
        .incremental_buffers = true,
        .disconnects = .{ .server = 2 },
    });

    try std.testing.expectEqual(@as(u64, 9), diagnostics.recv_nobufs);
    try std.testing.expectEqual(@as(u64, 14), diagnostics.cq_overflow);
    try std.testing.expectEqual(@as(u64, 3), diagnostics.close_failures);
    try std.testing.expectEqual(@as(u32, 80), diagnostics.max_cq_ready);
    try std.testing.expectEqual(@as(u32, 256), diagnostics.max_cq_entries);
    try std.testing.expectEqual(@as(u64, 16_384), diagnostics.max_recv_bundle_bytes);
    try std.testing.expectEqual(@as(u32, 4), diagnostics.max_recv_bundle_buffers);
    // The run's buffer mode has to survive a merge whose left side is the
    // zeroed aggregate every shard is added into.
    try std.testing.expect(diagnostics.incremental_buffers);
    try std.testing.expectEqual(@as(u64, 3), diagnostics.keep_alive_send_samples);
    try std.testing.expectEqual(@as(u64, 18), diagnostics.keep_alive_send_total_ms);
    try std.testing.expectEqual(@as(u64, 9), diagnostics.keep_alive_send_max_ms);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.disconnects.server);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.disconnects.transport);
}

test "disconnect diagnostics classify actionable causes" {
    var disconnects: Disconnects = .{};
    disconnects.record(error.ServerDisconnected);
    disconnects.record(error.Disconnected);
    disconnects.record(error.ConnectionRefused);
    disconnects.record(error.WriteBufferLimitExceeded);
    disconnects.record(error.MalformedPacket);
    disconnects.record(error.SystemResources);
    disconnects.record(error.Unexpected);

    try std.testing.expectEqual(@as(u64, 1), disconnects.server);
    try std.testing.expectEqual(@as(u64, 1), disconnects.transport);
    try std.testing.expectEqual(@as(u64, 1), disconnects.connect);
    try std.testing.expectEqual(@as(u64, 1), disconnects.buffer_limit);
    try std.testing.expectEqual(@as(u64, 1), disconnects.protocol);
    try std.testing.expectEqual(@as(u64, 1), disconnects.resource);
    try std.testing.expectEqual(@as(u64, 1), disconnects.other);
}
