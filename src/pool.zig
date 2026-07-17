const std = @import("std");
const builtin = @import("builtin");
const features = @import("features.zig");
const endpoint = @import("endpoint.zig");
const Io = std.Io;
const client = @import("client.zig");
const stats_module = @import("stats.zig");
const scheduler_module = @import("scheduler.zig");
const TimerWheel = scheduler_module.TimerWheel;

const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

const progress_module = @import("progress.zig");
pub const JoinProgress = progress_module.JoinProgress;
const ProgressSink = progress_module.ProgressSink;
const ShardProgress = progress_module.ShardProgress;
const waitForSharedProgress = progress_module.waitForSharedProgress;

const client_table = @import("client_table.zig");
const IndexedBot = client_table.IndexedBot;
const ConnectionState = client.ConnectionState;
const PoolState = client.PoolState;
const ClientTable = client.ClientTable;
pub const Stats = client_table.Stats;
const collectStats = client_table.collectStats;
const initial_backoff_ms = client.initial_backoff_ms;
pub const shardCount = client_table.shardCount;

const PosixAddress = endpoint.PosixAddress;
const addressFamily = endpoint.addressFamily;
const addressToPosix = endpoint.addressToPosix;

// io_uring wrappers from ring.zig
const ring_module = @import("ring.zig");
const CompletionKind = ring_module.CompletionKind;
const CompletionKey = ring_module.CompletionKey;
const packCompletionKey = ring_module.packCompletionKey;
const unpackCompletionKey = ring_module.unpackCompletionKey;
const openUring = ring_module.openUring;
const ioUringEntries = ring_module.ioUringEntries;
const RecvBufferGroup = ring_module.RecvBufferGroup;
const recvLayout = ring_module.recvLayout;
const waitForUringEvents = ring_module.waitForUringEvents;
const copyReadyCqes = ring_module.copyReadyCqes;
const registerFixedFiles = ring_module.registerFixedFiles;
const queueSocketDirect = ring_module.queueSocketDirect;
const queueConfigureAndConnectFixed = ring_module.queueConfigureAndConnectFixed;
const queueSendFixed = ring_module.queueSendFixed;
const queueRecvMultishotFixed = ring_module.queueRecvMultishotFixed;
const queueShutdownAndCloseFixed = ring_module.queueShutdownAndCloseFixed;

var stop_requested = std.atomic.Value(bool).init(false);

pub const stats_enabled = stats_module.stats_enabled;
const diagnostics_enabled = stats_module.diagnostics_enabled;

pub const Broadcast = if (features.broadcast) struct {
    interval_ms: u64,
    packet: client.CachedPacket,
    label: []const u8,
} else void;

pub const Options = struct {
    shards: ?usize = null,
    broadcast: if (features.broadcast) ?Broadcast else void = if (features.broadcast) null else {},
    client_tick_packet: if (features.client_tick) ?client.CachedPacket else void = if (features.client_tick) null else {},
    movement: if (features.movement) client.MovementConfig else void = if (features.movement) .{} else {},
    connect_rate_per_sec: u32 = 100,
    username_prefix: []const u8 = "Zion",
    known_core_pack: bool = false,
    join_progress: ?*JoinProgress = null,
};

const max_backoff_ms: u64 = 30_000;
const stop_check_interval_ms: i32 = 250;
const recv_buffer_group_id: u16 = 1;
const min_fragment_buffer_budget: usize = 4 * 1024 * 1024;
const max_fragment_buffer_budget: usize = 64 * 1024 * 1024;
const fragment_buffer_budget_per_client: usize = 1024;
const max_retained_decompression_bytes: usize = 256 * 1024;
const max_retained_packet_scratch_bytes: usize = 64 * 1024;

const ShardContext = struct {
    io: Io,
    bots: []const IndexedBot,
    resolved_target: endpoint.ResolvedTarget,
    options: Options,
    progress: ProgressSink = .none,
    total_client_count: usize,
    shard_id: usize,
    stats: Stats = .{},
};

const LoopContext = struct {
    ring: *IoUring,
    recv_buffers: *RecvBufferGroup,
    clients: *ClientTable,
    decompress_buf: if (client.protocol.compression_enabled) *std.ArrayList(u8) else void,
    decompress_window: if (client.protocol.compression_enabled) []u8 else void,
    packet_builder_buf: *Io.Writer.Allocating,
    write_temp_buf: *Io.Writer.Allocating,
    scheduler: *TimerWheel,
    target: endpoint.Target,
    address: endpoint.Address,
    connect_address: PosixAddress,
    connect_address_length: posix.socklen_t,
    socket_receive_buffer_bytes: i32 = endpoint.socket_receive_buffer_bytes,
    socket_send_buffer_bytes: i32 = endpoint.socket_send_buffer_bytes,
    tcp_nodelay: i32 = 1,
    aggregate: Stats = .{},
};

pub fn run(
    io: Io,
    allocator: std.mem.Allocator,
    client_count: usize,
    resolved_target: endpoint.ResolvedTarget,
    options: Options,
) !Stats {
    stop_requested.store(false, .monotonic);
    if (!builtin.is_test) installSignalHandlers();
    const started_ms = monotonicMs(io);

    const count = client_count;
    const shards = client_table.shardCount(options.shards, count);
    const partitions = try client_table.partitionBots(allocator, count, shards);
    defer client_table.freeBotPartitions(allocator, partitions);
    if (shards == 1) {
        var stats = try runShardLoop(io, allocator, partitions[0], resolved_target, options, ProgressSink.init(options.join_progress), count);
        stats.duration_ms = monotonicMs(io) -| started_ms;
        return stats;
    }

    const threads = try allocator.alloc(std.Thread, shards);
    errdefer allocator.free(threads);
    defer allocator.free(threads);

    const contexts = try allocator.alloc(ShardContext, shards);
    errdefer allocator.free(contexts);
    defer allocator.free(contexts);

    const shard_progress: ProgressSink = .none;
    var progress_counters: ?[]ShardProgress = null;
    if (options.join_progress) |progress| {
        if (progress.enabled) {
            const counters = try allocator.alloc(ShardProgress, shards);
            for (counters) |*counter| counter.* = .{};
            progress_counters = counters;
        }
    }
    defer if (progress_counters) |counters| allocator.free(counters);

    for (partitions, 0..) |partition, shard_id| {
        contexts[shard_id] = .{
            .io = io,
            .bots = partition,
            .resolved_target = resolved_target,
            .options = options,
            .progress = if (progress_counters) |counters| .{ .shared = &counters[shard_id] } else shard_progress,
            .total_client_count = count,
            .shard_id = shard_id,
        };
        threads[shard_id] = std.Thread.spawn(.{}, shardThreadMain, .{
            &contexts[shard_id],
        }) catch |err| {
            printStderr(io, "error: failed to spawn shard {d}: {t}\n", .{ shard_id, err });
            std.process.exit(1);
        };
    }

    if (progress_counters) |counters| waitForSharedProgress(options.join_progress.?, counters);

    for (threads) |thread| thread.join();

    var stats: Stats = .{};
    for (contexts) |context| stats.add(context.stats);
    stats.duration_ms = monotonicMs(io) -| started_ms;
    return stats;
}

fn shardThreadMain(context: *ShardContext) void {
    defer context.progress.shardDone();
    context.stats = runShardLoop(
        context.io,
        std.heap.c_allocator,
        context.bots,
        context.resolved_target,
        context.options,
        context.progress,
        context.total_client_count,
    ) catch |err| {
        printStderr(context.io, "error: shard {d} loop failed: {t}\n", .{ context.shard_id, err });
        std.process.exit(1);
    };
}

fn runShardLoop(
    io: Io,
    allocator: std.mem.Allocator,
    bots: []const IndexedBot,
    resolved_target: endpoint.ResolvedTarget,
    options: Options,
    progress: ProgressSink,
    total_client_count: usize,
) !Stats {
    var clients: ClientTable = .{
        .allocator = allocator,
        .io = io,
        .read_buffer_limit = @min(max_fragment_buffer_budget, @max(min_fragment_buffer_budget, bots.len *| fragment_buffer_budget_per_client)),
        .handshake_host = resolved_target.target.handshakeHost(),
        .handshake_port = resolved_target.target.handshakePort(),
        .username_prefix = options.username_prefix,
        .known_core_pack = options.known_core_pack,
        .total_client_count = total_client_count,
        .broadcast_packet = if (comptime features.broadcast) if (options.broadcast) |broadcast| broadcast.packet else null else {},
        .broadcast_interval_ms = if (comptime features.broadcast) if (options.broadcast) |broadcast| broadcast.interval_ms else 0 else {},
        .client_tick_packet = if (comptime features.client_tick) options.client_tick_packet else {},
        .movement = if (comptime features.movement) options.movement else {},
    };
    defer clients.deinit(allocator);
    try clients.ensureTotalCapacity(allocator, bots.len);

    const now = monotonicMs(io);
    for (bots) |bot| {
        const i: usize = bot.global_index;
        const next_attempt_ms = now +| client_table.initialConnectOffsetMs(i, options.connect_rate_per_sec);
        clients.appendAssumeCapacity(bot.global_index, next_attempt_ms);
    }

    var ring = try openUring(bots.len);
    defer ring.deinit();
    try registerFixedFiles(&ring, bots.len);

    // Single shared decompress_buf for packet parsing
    var decompress_buf = if (comptime client.protocol.compression_enabled)
        std.ArrayList(u8).empty
    else {};
    defer {
        if (comptime client.protocol.compression_enabled) {
            decompress_buf.deinit(allocator);
        }
    }

    const decompress_window = if (comptime client.protocol.compression_enabled)
        try allocator.alloc(u8, std.compress.flate.max_window_len)
    else {};
    defer {
        if (comptime client.protocol.compression_enabled) {
            allocator.free(decompress_window);
        }
    }

    var write_temp_buf: Io.Writer.Allocating = .init(allocator);
    defer write_temp_buf.deinit();

    var packet_builder_buf: Io.Writer.Allocating = .init(allocator);
    defer packet_builder_buf.deinit();

    // BufferGroup registers a provided-buffer ring with io_uring. Complete
    // frames are parsed directly from these buffers without an intermediate
    // userspace copy; only a fragmented tail is copied into client state.
    // IORING_OP_RECV_ZC is deliberately not used here: it requires NIC queue
    // steering and header/data split, so it is not a general TCP/loopback path.
    var recv_buffers = try RecvBufferGroup.init(&ring, allocator, recv_buffer_group_id, recvLayout(&ring, bots.len));
    defer recv_buffers.deinit(allocator);

    const event_capacity: usize = @intCast(ioUringEntries(bots.len));
    const events = try allocator.alloc(linux.io_uring_cqe, event_capacity);
    defer allocator.free(events);

    var scheduler = try TimerWheel.init(allocator, bots.len, now);
    defer scheduler.deinit();
    const due_clients = try allocator.alloc(u32, bots.len);
    defer allocator.free(due_clients);
    for (0..bots.len) |i| scheduler.schedule(i, clients.pool.slice().items(.next_attempt_ms)[i]);

    var connect_address: PosixAddress = undefined;
    const connect_address_length = addressToPosix(&resolved_target.address, &connect_address);

    var ctx = LoopContext{
        .ring = &ring,
        .recv_buffers = &recv_buffers,
        .clients = &clients,
        .decompress_buf = if (comptime client.protocol.compression_enabled) &decompress_buf else {},
        .decompress_window = if (comptime client.protocol.compression_enabled) decompress_window else {},
        .packet_builder_buf = &packet_builder_buf,
        .write_temp_buf = &write_temp_buf,
        .scheduler = &scheduler,
        .target = resolved_target.target,
        .address = resolved_target.address,
        .connect_address = connect_address,
        .connect_address_length = connect_address_length,
    };
    if (comptime diagnostics_enabled) ctx.aggregate.diagnostics.observeCq(0, @intCast(ring.cq.cqes.len));

    var loop_now = now;
    while (!shouldStop()) {
        try driveDueClientsConfigured(&ctx, loop_now, progress, due_clients);
        const timeout = timeoutFromDue(scheduler.nextDeadline(), loop_now);
        try waitForUringEvents(&ring, capTimeoutForStopCheck(timeout), &stop_requested);
        if (comptime diagnostics_enabled) {
            ctx.aggregate.diagnostics.observeCq(ring.cq_ready(), @intCast(ring.cq.cqes.len));
        }
        const ready = try copyReadyCqes(&ring, events, &stop_requested);

        loop_now = monotonicMs(io);
        // A receive heavy server can keep thousands of multishot CQEs ready.
        // Retire sends and connects first so their buffers and protocol replies
        // cannot starve behind unrelated inbound play traffic.
        for (events[0..ready]) |event| {
            const key = unpackCompletionKey(event.user_data) orelse continue;
            if (key.kind == .recv) continue;
            try processUringEvent(&ctx, event, loop_now, progress);
            trimScratchBuffers(&ctx);
        }
        for (events[0..ready]) |event| {
            const key = unpackCompletionKey(event.user_data) orelse continue;
            if (key.kind != .recv) continue;
            try processUringEvent(&ctx, event, loop_now, progress);
            trimScratchBuffers(&ctx);
        }
    }

    if (comptime diagnostics_enabled) {
        ctx.aggregate.diagnostics.cq_overflow = @atomicLoad(u32, ring.cq.overflow, .monotonic);
    }
    var stats = collectStats(&clients);
    if (stats_enabled) {
        stats.reconnects = ctx.aggregate.reconnects;
        stats.packets_received = ctx.aggregate.packets_received;
        stats.keep_alives_answered = ctx.aggregate.keep_alives_answered;
        stats.bytes_received = ctx.aggregate.bytes_received;
        stats.bytes_sent = ctx.aggregate.bytes_sent;
    }
    if (comptime diagnostics_enabled) stats.diagnostics = ctx.aggregate.diagnostics;
    return stats;
}

fn trimScratchBuffers(ctx: *LoopContext) void {
    if (comptime client.protocol.compression_enabled) {
        if (ctx.decompress_buf.capacity > max_retained_decompression_bytes) {
            ctx.decompress_buf.clearAndFree(ctx.clients.allocator);
        }
    }
    for ([_]*Io.Writer.Allocating{ ctx.packet_builder_buf, ctx.write_temp_buf }) |buffer| {
        if (buffer.writer.buffer.len <= max_retained_packet_scratch_bytes) continue;
        buffer.deinit();
        buffer.* = .init(ctx.clients.allocator);
    }
}

fn driveConnectedClient(
    comptime movement_profile: client.MovementProfile,
    ctx: *LoopContext,
    i: usize,
    now_ms: u64,
    progress: ProgressSink,
) !void {
    if (!ctx.clients.pool.slice().items(.flags)[i].socket_live) return;
    const phase = ctx.clients.phases.items[i];
    if (phase != .play) return;

    const t = client.nextTimerMs(ctx.clients, i, phase) orelse return;
    if (now_ms < t) {
        return;
    }

    const phase_ref = ctx.clients.getPhase(i);
    const wrote = client.onTimerFor(movement_profile, ctx.clients, i, phase_ref, now_ms, ctx.packet_builder_buf, ctx.write_temp_buf) catch |err| {
        try failRuntime(ctx, i, err, now_ms, progress);
        return;
    };

    if (wrote) {
        try armSend(ctx, i);
    }

    scheduleClient(ctx, i);
}

fn driveDueClients(
    comptime movement_profile: client.MovementProfile,
    ctx: *LoopContext,
    now_ms: u64,
    progress: ProgressSink,
    due_clients: []u32,
) !void {
    const count = ctx.scheduler.takeDue(now_ms, due_clients);
    for (due_clients[0..count]) |raw_index| {
        const i: usize = raw_index;
        switch (ctx.clients.pool.slice().items(.state)[i]) {
            .waiting => {
                startConnect(ctx, i, now_ms) catch |err| try failRuntime(ctx, i, err, now_ms, progress);
                scheduleClient(ctx, i);
            },
            .connecting, .draining => {},
            .connected => try driveConnectedClient(movement_profile, ctx, i, now_ms, progress),
        }
    }
}

fn driveDueClientsConfigured(
    ctx: *LoopContext,
    now_ms: u64,
    progress: ProgressSink,
    due_clients: []u32,
) !void {
    if (comptime features.movement) {
        return switch (ctx.clients.movement.profile) {
            inline else => |profile| driveDueClients(profile, ctx, now_ms, progress, due_clients),
        };
    } else {
        return driveDueClients({}, ctx, now_ms, progress, due_clients);
    }
}

fn processUringEvent(
    ctx: *LoopContext,
    event: linux.io_uring_cqe,
    now_ms: u64,
    progress: ProgressSink,
) !void {
    const key = unpackCompletionKey(event.user_data) orelse return;
    switch (key.kind) {
        .timeout => return,
        .recv => {
            try handleRecvReady(ctx, event, key, now_ms, progress);
            return;
        },
        .send => {
            try handleSendReady(ctx, event, key, now_ms, progress);
            return;
        },
        .connect => try handleConnectReady(ctx, event, key, now_ms, progress),
        .socket => try handleSocketReady(ctx, event, key, now_ms, progress),
        .socket_option => return,
        .close => try handleCloseReady(ctx, event, key),
    }
}

fn handleSocketReady(ctx: *LoopContext, event: linux.io_uring_cqe, key: CompletionKey, now_ms: u64, progress: ProgressSink) !void {
    if (key.index >= ctx.clients.global_indices.items.len) return;
    const pool = ctx.clients.pool.slice();
    const index = key.index;
    if (key.generation != pool.items(.connect_generation)[index] or pool.items(.state)[index] != .connecting) return;

    if (event.err() != .SUCCESS) {
        try failRuntime(ctx, index, error.SystemResources, now_ms, progress);
        return;
    }

    pool.items(.flags)[index].socket_live = true;
    const tcp = switch (ctx.address) {
        .ip => true,
        .unix => false,
    };
    queueConfigureAndConnectFixed(
        ctx.ring,
        packCompletionKey(.{ .kind = .socket_option, .generation = pool.items(.connect_generation)[index], .index = index }),
        packCompletionKey(.{ .kind = .connect, .generation = pool.items(.connect_generation)[index], .index = index }),
        @intCast(index),
        tcp,
        &ctx.socket_receive_buffer_bytes,
        &ctx.socket_send_buffer_bytes,
        &ctx.tcp_nodelay,
        &ctx.connect_address.any,
        ctx.connect_address_length,
    ) catch |err| {
        try failRuntime(ctx, index, err, now_ms, progress);
    };
}

fn handleCloseReady(ctx: *LoopContext, event: linux.io_uring_cqe, key: CompletionKey) !void {
    if (key.index >= ctx.clients.global_indices.items.len) return;
    const pool = ctx.clients.pool.slice();
    const index = key.index;
    if (key.generation != pool.items(.close_generation)[index] or !pool.items(.flags)[index].close_armed) return;
    if (event.err() != .SUCCESS) return error.Unexpected;
    pool.items(.flags)[index].close_armed = false;
    pool.items(.flags)[index].socket_live = false;
    finishDraining(ctx, index);
}

fn handleConnectReady(ctx: *LoopContext, event: linux.io_uring_cqe, key: CompletionKey, now_ms: u64, progress: ProgressSink) !void {
    if (key.index >= ctx.clients.global_indices.items.len) return;
    const pool = ctx.clients.pool.slice();
    const index = key.index;
    if (key.generation != pool.items(.connect_generation)[index] or pool.items(.state)[index] != .connecting) return;
    const errno = event.err();
    if (errno != .SUCCESS) {
        const err = switch (errno) {
            .CANCELED => error.Disconnected,
            .NOENT => switch (ctx.address) {
                .unix => error.FileNotFound,
                .ip => error.Disconnected,
            },
            .CONNREFUSED => error.ConnectionRefused,
            .HOSTUNREACH => error.HostUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .TIMEDOUT => error.Timeout,
            else => error.Disconnected,
        };
        try failRuntime(ctx, index, err, now_ms, progress);
        return;
    }
    finishConnect(ctx, index, now_ms) catch |err| {
        try failRuntime(ctx, index, err, now_ms, progress);
        return;
    };
    scheduleClient(ctx, index);
}

fn handleRecvReady(
    ctx: *LoopContext,
    event: linux.io_uring_cqe,
    key: CompletionKey,
    now_ms: u64,
    progress: ProgressSink,
) !void {
    if (key.index >= ctx.clients.global_indices.items.len) {
        releaseRecvBufferIfPresent(ctx.recv_buffers, event);
        return;
    }

    const pool = ctx.clients.pool.slice();
    const index = key.index;
    if (key.generation != pool.items(.recv_generation)[index]) {
        releaseRecvBufferIfPresent(ctx.recv_buffers, event);
        return;
    }

    if ((event.flags & linux.IORING_CQE_F_MORE) == 0) {
        pool.items(.flags)[index].recv_armed = false;
    }

    const errno = event.err();
    if (errno != .SUCCESS) {
        releaseRecvBufferIfPresent(ctx.recv_buffers, event);
        switch (errno) {
            .CANCELED, .NOENT => return,
            .NOBUFS => {
                if (comptime diagnostics_enabled) ctx.aggregate.diagnostics.recv_nobufs += 1;
                try armRecv(ctx, index);
                return;
            },
            else => {
                try failRuntime(ctx, index, error.Disconnected, now_ms, progress);
                return;
            },
        }
    }

    if (event.res <= 0) {
        releaseRecvBufferIfPresent(ctx.recv_buffers, event);
        try failRuntime(ctx, index, error.Disconnected, now_ms, progress);
        return;
    }

    var batch = ctx.recv_buffers.batch(event) catch {
        releaseRecvBufferIfPresent(ctx.recv_buffers, event);
        try failRuntime(ctx, index, error.Disconnected, now_ms, progress);
        return;
    };
    const release_batch = batch;
    defer ctx.recv_buffers.releaseBatch(release_batch);
    if (comptime diagnostics_enabled) {
        const batch_bytes: u64 = @intCast(event.res);
        const batch_buffers: u32 = @intCast(std.math.divCeil(
            usize,
            @intCast(event.res),
            ctx.recv_buffers.buffer_size,
        ) catch 1);
        ctx.aggregate.diagnostics.max_recv_bundle_bytes = @max(ctx.aggregate.diagnostics.max_recv_bundle_bytes, batch_bytes);
        ctx.aggregate.diagnostics.max_recv_bundle_buffers = @max(ctx.aggregate.diagnostics.max_recv_bundle_buffers, batch_buffers);
    }

    const phase = ctx.clients.getPhase(index);
    var read_result: client.ReadResult = .{};
    while (batch.next()) |recv_slice| {
        const part = client.onReadBytes(ctx.clients, index, phase, ctx.recv_buffers.bytes(recv_slice), ctx.decompress_buf, ctx.decompress_window, ctx.packet_builder_buf, ctx.write_temp_buf) catch |err| {
            try failRuntime(ctx, index, err, now_ms, progress);
            return;
        };
        read_result.bytes += part.bytes;
        read_result.packets += part.packets;
        read_result.keep_alives += part.keep_alives;
        if (part.last_packet_id) |id| read_result.last_packet_id = id;
        read_result.effects.write_ready = read_result.effects.write_ready or part.effects.write_ready;
        read_result.effects.deadline_changed = read_result.effects.deadline_changed or part.effects.deadline_changed;
        read_result.effects.progress_changed = read_result.effects.progress_changed or part.effects.progress_changed;
        if (comptime diagnostics_enabled) {
            if (part.keep_alive_reply_bytes) |pending_bytes| read_result.keep_alive_reply_bytes = pending_bytes;
        }
    }
    if (stats_enabled) {
        ctx.aggregate.bytes_received += read_result.bytes;
        ctx.aggregate.packets_received += read_result.packets;
        ctx.aggregate.keep_alives_answered += read_result.keep_alives;
    }
    if (diagnostics_enabled) {
        if (read_result.last_packet_id) |id| ctx.clients.stats.slice().items(.last_packet_id)[index] = id;
        ctx.clients.stats.slice().items(.keep_alives_answered)[index] += @intCast(read_result.keep_alives);
        if (read_result.keep_alive_reply_bytes) |pending_bytes| {
            noteKeepAliveQueued(ctx, index, pending_bytes, now_ms);
        }
    }
    if (read_result.effects.progress_changed) recordJoinProgress(ctx.clients, index, progress);
    if (read_result.effects.deadline_changed) scheduleClient(ctx, index);
    if (read_result.effects.write_ready) try armSend(ctx, index);

    if (!pool.items(.flags)[index].recv_armed and pool.items(.state)[index] == .connected) {
        try armRecv(ctx, index);
    }
}

fn handleSendReady(
    ctx: *LoopContext,
    event: linux.io_uring_cqe,
    key: CompletionKey,
    now_ms: u64,
    progress: ProgressSink,
) !void {
    if (key.index >= ctx.clients.global_indices.items.len) return;

    const pool = ctx.clients.pool.slice();
    const index = key.index;
    if (key.generation != pool.items(.send_generation)[index]) return;

    if (pool.items(.state)[index] == .draining) {
        pool.items(.flags)[index].send_armed = false;
        pool.items(.send_generation)[index] +%= 1;
        finishDraining(ctx, index);
        return;
    }
    if (pool.items(.state)[index] != .connected) return;
    pool.items(.flags)[index].send_armed = false;

    const errno = event.err();
    if (errno != .SUCCESS) {
        switch (errno) {
            .AGAIN => {
                client.cancelBeginWrite(ctx.clients, index);
                try armSend(ctx, index);
                return;
            },
            else => try failRuntime(ctx, index, error.Disconnected, now_ms, progress),
        }
        return;
    }

    if (event.res <= 0) {
        try failRuntime(ctx, index, error.Disconnected, now_ms, progress);
        return;
    }

    const phase = ctx.clients.getPhase(index);
    client.onWriteComplete(ctx.clients, index, phase, @intCast(event.res)) catch |err| {
        try failRuntime(ctx, index, err, now_ms, progress);
        return;
    };
    if (comptime diagnostics_enabled) {
        noteKeepAliveSendProgress(ctx, index, @intCast(event.res), now_ms);
    }
    if (stats_enabled) {
        ctx.aggregate.bytes_sent += @intCast(event.res);
    }

    try armSend(ctx, index);
}

fn releaseRecvBufferIfPresent(recv_buffers: *RecvBufferGroup, event: linux.io_uring_cqe) void {
    if ((event.flags & linux.IORING_CQE_F_BUFFER) == 0) return;
    if (event.res <= 0) return;
    const batch = recv_buffers.batch(event) catch return;
    recv_buffers.releaseBatch(batch);
}

fn startConnect(ctx: *LoopContext, index: usize, now_ms: u64) !void {
    _ = now_ms;
    const pool = ctx.clients.pool.slice();

    std.debug.assert(!pool.items(.flags)[index].socket_live);
    std.debug.assert(!pool.items(.flags)[index].close_armed);
    pool.items(.state)[index] = .connecting;
    pool.items(.connect_generation)[index] +%= 1;
    errdefer pool.items(.state)[index] = .waiting;
    const socket_protocol: u32 = switch (ctx.address) {
        .ip => @intFromEnum(Io.net.Protocol.tcp),
        .unix => 0,
    };
    try queueSocketDirect(ctx.ring, packCompletionKey(.{
        .kind = .socket,
        .generation = pool.items(.connect_generation)[index],
        .index = index,
    }), @intCast(index), @intCast(addressFamily(&ctx.address)), socket_protocol);
}

fn finishConnect(ctx: *LoopContext, index: usize, now_ms: u64) !void {
    const pool = ctx.clients.pool.slice();
    if (!pool.items(.flags)[index].socket_live) return error.Disconnected;
    pool.items(.state)[index] = .connected;
    pool.items(.backoff_ms)[index] = initial_backoff_ms;
    const phase = ctx.clients.getPhase(index);
    try client.onConnected(ctx.clients, index, phase, now_ms, ctx.packet_builder_buf, ctx.write_temp_buf);
    try armSend(ctx, index);
    try armRecv(ctx, index);
}

fn resetConnectionState(clients: *ClientTable, index: usize) bool {
    const pool = clients.pool.slice();
    pool.items(.flags)[index].progress_active = false;
    const preserve_inflight_send = pool.items(.flags)[index].send_armed and pool.items(.flags)[index].socket_live;
    pool.items(.connect_generation)[index] +%= 1;
    pool.items(.flags)[index].recv_armed = false;
    pool.items(.recv_generation)[index] +%= 1;
    if (!preserve_inflight_send) {
        pool.items(.flags)[index].send_armed = false;
        pool.items(.send_generation)[index] +%= 1;
    }
    return preserve_inflight_send;
}

fn failClient(clients: *ClientTable, index: usize, err: anyerror, now_ms: u64, progress: ProgressSink, target: endpoint.Target) void {
    const pool = clients.pool.slice();
    const was_active = pool.items(.flags)[index].progress_active;
    const preserve_inflight_send = resetConnectionState(clients, index);

    const phase = clients.getPhase(index);
    const phase_before = phase.*;
    const delay: u64 = pool.items(.backoff_ms)[index];
    if (!builtin.is_test and !progress.suppressesLogs()) {
        if (clients.io) |io| {
            var username_buffer: [16]u8 = undefined;
            const client_username = client.username(clients, index, &username_buffer) catch "<invalid>";
            switch (target) {
                .tcp => printStderr(io, "warning: client {s}@{s}:{d} disconnected: {t}; reconnecting in {d}ms\n", .{
                    client_username,
                    clients.handshake_host,
                    clients.handshake_port,
                    err,
                    delay,
                }),
                .unix => |unix| printStderr(io, "warning: client {s}@unix:{s} (handshake {s}:{d}) disconnected: {t}; reconnecting in {d}ms\n", .{
                    client_username,
                    unix.path,
                    clients.handshake_host,
                    clients.handshake_port,
                    err,
                    delay,
                }),
            }
            if (diagnostics_enabled) {
                const stats = clients.stats.slice();
                const last_packet_before = stats.items(.last_packet_id)[index];
                printStderr(io, "warning: client state before reconnect: phase={s} last_packet=0x{x}\n", .{
                    @tagName(phase_before),
                    last_packet_before,
                });
                printStderr(io, "warning: keep-alives answered={d}\n", .{
                    stats.items(.keep_alives_answered)[index],
                });
            } else {
                printStderr(io, "warning: client state before reconnect: phase={s}\n", .{@tagName(phase_before)});
            }
        }
    }

    client.close(clients, index, phase, preserve_inflight_send);
    pool.items(.next_attempt_ms)[index] = now_ms +| delay;
    pool.items(.backoff_ms)[index] = @intCast(@min(delay *| 2, max_backoff_ms));
    pool.items(.state)[index] = if (preserve_inflight_send or pool.items(.flags)[index].close_armed or pool.items(.flags)[index].socket_live) .draining else .waiting;
    progress.scheduleReconnect(was_active);
}

fn recordJoinProgress(clients: *ClientTable, index: usize, progress: ProgressSink) void {
    const pool = clients.pool.slice();
    if (!client.joinedLogged(clients, index).*) return;
    const was_active = pool.items(.flags)[index].progress_active;
    const was_counted = pool.items(.flags)[index].progress_counted;
    if (was_active and was_counted) return;
    pool.items(.flags)[index].progress_active = true;
    pool.items(.flags)[index].progress_counted = true;
    progress.enterPlay(!was_counted);
}

fn scheduleClient(ctx: *LoopContext, index: usize) void {
    const pool = ctx.clients.pool.slice();
    switch (pool.items(.state)[index]) {
        .waiting => ctx.scheduler.update(index, pool.items(.next_attempt_ms)[index]),
        .connecting, .draining => ctx.scheduler.update(index, null),
        .connected => {
            const phase = ctx.clients.phases.items[index];
            ctx.scheduler.update(index, client.nextTimerMs(ctx.clients, index, phase));
        },
    }
}

fn canFinishDraining(state: PoolState) bool {
    return state.state == .draining and !state.flags.close_armed and !state.flags.send_armed and !state.flags.socket_live;
}

fn finishDraining(ctx: *LoopContext, index: usize) void {
    const pool = ctx.clients.pool.slice();
    const state: PoolState = ctx.clients.pool.get(index);
    if (!canFinishDraining(state)) return;
    client.close(ctx.clients, index, ctx.clients.getPhase(index), false);
    pool.items(.state)[index] = .waiting;
    scheduleClient(ctx, index);
}

fn failRuntime(ctx: *LoopContext, index: usize, err: anyerror, now_ms: u64, progress: ProgressSink) !void {
    if (comptime diagnostics_enabled) {
        ctx.aggregate.diagnostics.disconnects.record(err);
        clearKeepAlivePending(ctx.clients, index);
    }
    const pool = ctx.clients.pool.slice();
    if (pool.items(.flags)[index].socket_live and !pool.items(.flags)[index].close_armed) {
        pool.items(.close_generation)[index] +%= 1;
        pool.items(.flags)[index].close_armed = true;
        errdefer pool.items(.flags)[index].close_armed = false;
        try queueShutdownAndCloseFixed(
            ctx.ring,
            packCompletionKey(.{ .kind = .socket_option, .generation = 0, .index = index }),
            packCompletionKey(.{ .kind = .close, .generation = pool.items(.close_generation)[index], .index = index }),
            @intCast(index),
        );
    }
    failClient(ctx.clients, index, err, now_ms, progress, ctx.target);
    if (stats_enabled) ctx.aggregate.reconnects += 1;
    scheduleClient(ctx, index);
}

fn noteKeepAliveQueued(ctx: *LoopContext, index: usize, pending_bytes: u16, now_ms: u64) void {
    if (comptime !diagnostics_enabled) return;
    const stats = ctx.clients.stats.slice();
    stats.items(.keep_alive_started_ms)[index] = now_ms;
    stats.items(.keep_alive_pending_bytes)[index] = pending_bytes;
}

fn noteKeepAliveSendProgress(ctx: *LoopContext, index: usize, sent_bytes: usize, now_ms: u64) void {
    if (comptime !diagnostics_enabled) return;
    const stats = ctx.clients.stats.slice();
    const pending = stats.items(.keep_alive_pending_bytes)[index];
    if (pending == 0) return;
    if (sent_bytes < pending) {
        stats.items(.keep_alive_pending_bytes)[index] = pending - @as(u16, @intCast(sent_bytes));
        return;
    }

    const started_ms = stats.items(.keep_alive_started_ms)[index];
    ctx.aggregate.diagnostics.recordKeepAliveSend(now_ms -| started_ms);
    stats.items(.keep_alive_started_ms)[index] = 0;
    stats.items(.keep_alive_pending_bytes)[index] = 0;
}

fn clearKeepAlivePending(clients: *ClientTable, index: usize) void {
    if (comptime !diagnostics_enabled) return;
    const stats = clients.stats.slice();
    stats.items(.keep_alive_started_ms)[index] = 0;
    stats.items(.keep_alive_pending_bytes)[index] = 0;
}

fn timeoutFromDue(due_optional: ?u64, now_ms: u64) i32 {
    const due = due_optional orelse return -1;
    if (due <= now_ms) return 0;
    return @intCast(@min(due - now_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
}

fn capTimeoutForStopCheck(timeout: i32) i32 {
    if (timeout < 0) return stop_check_interval_ms;
    return @min(timeout, stop_check_interval_ms);
}

fn armSend(ctx: *LoopContext, index: usize) !void {
    const pool = ctx.clients.pool.slice();
    if (pool.items(.flags)[index].send_armed) return;
    if (pool.items(.state)[index] != .connected) return;
    if (!pool.items(.flags)[index].socket_live) return;

    const bytes = client.beginWrite(ctx.clients, index);
    if (bytes.len == 0) return;

    pool.items(.send_generation)[index] +%= 1;
    pool.items(.flags)[index].send_armed = true;
    errdefer {
        pool.items(.flags)[index].send_armed = false;
        client.cancelBeginWrite(ctx.clients, index);
    }
    try queueSendFixed(ctx.ring, packCompletionKey(.{
        .kind = .send,
        .generation = pool.items(.send_generation)[index],
        .index = index,
    }), @intCast(index), bytes);
}

fn armRecv(ctx: *LoopContext, index: usize) !void {
    const pool = ctx.clients.pool.slice();
    if (pool.items(.flags)[index].recv_armed) return;
    if (pool.items(.state)[index] != .connected) return;
    if (!pool.items(.flags)[index].socket_live) return;

    pool.items(.recv_generation)[index] +%= 1;
    pool.items(.flags)[index].recv_armed = true;
    try queueRecvMultishotFixed(ctx.ring, ctx.recv_buffers, packCompletionKey(.{
        .kind = .recv,
        .generation = pool.items(.recv_generation)[index],
        .index = index,
    }), @intCast(index));
}

fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    writer.print(fmt, args) catch return;
    Io.File.stderr().writeStreamingAll(io, writer.buffered()) catch {};
}

fn monotonicMs(io: Io) u64 {
    return @intCast(Io.Timestamp.now(io, .awake).toMilliseconds());
}

fn shouldStop() bool {
    return stop_requested.load(.monotonic);
}

fn handleSignal(_: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

fn installSignalHandlers() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
}

test "capTimeoutForStopCheck bounds indefinite and long io_uring waits" {
    try std.testing.expectEqual(@as(i32, stop_check_interval_ms), capTimeoutForStopCheck(-1));
    try std.testing.expectEqual(@as(i32, stop_check_interval_ms), capTimeoutForStopCheck(stop_check_interval_ms + 1));
    try std.testing.expectEqual(@as(i32, 10), capTimeoutForStopCheck(10));
    try std.testing.expectEqual(@as(i32, 0), capTimeoutForStopCheck(0));
}

test "failClient isolates one client and schedules reconnect backoff" {
    const allocator = std.testing.allocator;
    var clients: ClientTable = .{};
    defer clients.deinit(allocator);

    try clients.ensureTotalCapacity(allocator, 2);
    clients.appendAssumeCapacity(0, 0);
    clients.appendAssumeCapacity(1, 0);

    const pool = clients.pool.slice();
    pool.items(.state)[0] = .connected;
    pool.items(.state)[1] = .connected;
    pool.items(.connect_generation)[0] = 7;
    pool.items(.recv_generation)[0] = 9;
    pool.items(.flags)[0].recv_armed = true;
    pool.items(.send_generation)[0] = 11;
    pool.items(.flags)[0].send_armed = true;
    clients.getPhase(0).* = .play;
    clients.getPhase(1).* = .play;

    failClient(&clients, 0, error.Disconnected, 1_000, .none, .{ .tcp = .{ .host = "127.0.0.1" } });

    try std.testing.expectEqual(ConnectionState.waiting, pool.items(.state)[0]);
    try std.testing.expectEqual(ConnectionState.connected, pool.items(.state)[1]);
    try std.testing.expectEqual(@as(u64, 1_250), pool.items(.next_attempt_ms)[0]);
    try std.testing.expectEqual(@as(u16, 500), pool.items(.backoff_ms)[0]);
    try std.testing.expectEqual(@as(u16, 8), pool.items(.connect_generation)[0]);
    try std.testing.expectEqual(@as(u16, 10), pool.items(.recv_generation)[0]);
    try std.testing.expect(!pool.items(.flags)[0].recv_armed);
    try std.testing.expectEqual(@as(u16, 12), pool.items(.send_generation)[0]);
    try std.testing.expect(!pool.items(.flags)[0].send_armed);
    try std.testing.expectEqual(client.Phase.disconnected, clients.phases.items[0]);
    try std.testing.expectEqual(client.Phase.play, clients.phases.items[1]);
}

test "failClient preserves an armed send until its completion" {
    const allocator = std.testing.allocator;
    var clients: ClientTable = .{};
    defer clients.deinit(allocator);
    try clients.ensureTotalCapacity(allocator, 1);
    clients.appendAssumeCapacity(0, 0);

    const states = clients.pool.slice();
    states.items(.flags)[0].socket_live = true;
    states.items(.flags)[0].close_armed = true;
    states.items(.state)[0] = .connected;
    states.items(.flags)[0].send_armed = true;
    states.items(.send_generation)[0] = 41;

    failClient(&clients, 0, error.Disconnected, 1000, .none, .{ .tcp = .{ .host = "127.0.0.1" } });

    try std.testing.expectEqual(ConnectionState.draining, states.items(.state)[0]);
    try std.testing.expect(states.items(.flags)[0].socket_live);
    try std.testing.expect(states.items(.flags)[0].close_armed);
    try std.testing.expect(states.items(.flags)[0].send_armed);
    try std.testing.expectEqual(@as(u16, 41), states.items(.send_generation)[0]);
}

test "direct socket draining waits for close and send retirement" {
    var state: PoolState = .{ .next_attempt_ms = 0 };
    state.state = .draining;
    state.flags.close_armed = true;
    state.flags.send_armed = true;

    try std.testing.expect(!canFinishDraining(state));
    state.flags.close_armed = false;
    try std.testing.expect(!canFinishDraining(state));
    state.flags.send_armed = false;
    try std.testing.expect(canFinishDraining(state));
}
