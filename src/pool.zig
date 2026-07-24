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
const RecvBufferGroup = ring_module.RecvBufferGroup;
const recvLayout = ring_module.recvLayout;
const waitForUringEvents = ring_module.waitForUringEvents;
const copyReadyCqes = ring_module.copyReadyCqes;
const registerFixedFiles = ring_module.registerFixedFiles;
const queueSocketDirect = ring_module.queueSocketDirect;
const queueConfigureAndConnectFixed = ring_module.queueConfigureAndConnectFixed;
const queueSendFixed = ring_module.queueSendFixed;
const queueSendMsgFixed = ring_module.queueSendMsgFixed;
const queueRecvMultishotFixed = ring_module.queueRecvMultishotFixed;
const queueShutdownAndCloseFixed = ring_module.queueShutdownAndCloseFixed;
const queuePollOut = ring_module.queuePollOut;

var stop_requested = std.atomic.Value(bool).init(false);
var stop_signal_count = std.atomic.Value(u32).init(0);

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
    reconnect: bool = features.reconnect,
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
    // Per-client gathered-send state; the kernel reads the msghdr and iovecs
    // referenced by an in-flight IORING_OP_SENDMSG, so both live for the run.
    send_iovecs: [][client.write_segment_capacity]posix.iovec_const,
    send_msghdrs: []linux.msghdr_const,
    socket_receive_buffer_bytes: i32 = endpoint.socket_receive_buffer_bytes,
    socket_send_buffer_bytes: i32 = endpoint.socket_send_buffer_bytes,
    tcp_nodelay: i32 = 1,
    reconnect: bool = features.reconnect,
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
    stop_signal_count.store(0, .monotonic);
    ring_module.setStopSignal(&stop_requested);
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
    defer allocator.free(threads);

    const contexts = try allocator.alloc(ShardContext, shards);
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
    if (comptime features.reconnect) {
        // Distinct seed per shard (clock plus the shard's first global index and
        // size) so shards do not jitter their reconnects in phase with each other.
        const seed_index: u64 = if (bots.len > 0) bots[0].global_index else 0;
        clients.reconnect_prng = std.Random.DefaultPrng.init(now ^ (seed_index << 32) ^ bots.len);
    }
    for (bots) |bot| {
        // Keyed to the global index, not the shard-local slot, so the whole
        // fleet ramps at connect_rate_per_sec instead of once per shard.
        const next_attempt_ms = now +| client_table.initialConnectOffsetMs(bot.global_index, options.connect_rate_per_sec);
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

    // Sized to the CQ so one iteration drains everything the kernel can hold.
    const event_capacity: usize = ring.cq.cqes.len;
    const events = try allocator.alloc(linux.io_uring_cqe, event_capacity);
    defer allocator.free(events);

    var scheduler = try TimerWheel.init(allocator, bots.len, now);
    defer scheduler.deinit();
    const due_clients = try allocator.alloc(u32, bots.len);
    defer allocator.free(due_clients);

    const send_iovecs = try allocator.alloc([client.write_segment_capacity]posix.iovec_const, bots.len);
    defer allocator.free(send_iovecs);
    const send_msghdrs = try allocator.alloc(linux.msghdr_const, bots.len);
    defer allocator.free(send_msghdrs);
    for (clients.pool.items(.next_attempt_ms), 0..) |deadline_ms, i| scheduler.schedule(i, deadline_ms);

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
        .send_iovecs = send_iovecs,
        .send_msghdrs = send_msghdrs,
        .reconnect = features.reconnect and options.reconnect,
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
        // Bail before retiring a large completion batch so a shutdown request
        // observed mid-iteration cannot be delayed behind thousands of events.
        if (shouldStop()) break;

        loop_now = monotonicMs(io);
        // A receive heavy server can keep thousands of multishot CQEs ready.
        // Retire sends and connects first so their buffers and protocol replies
        // cannot starve behind unrelated inbound play traffic.
        for (events[0..ready]) |event| {
            const key = unpackCompletionKey(event.user_data) orelse continue;
            if (key.kind == .recv) continue;
            try processUringEvent(&ctx, event, key, loop_now, progress);
        }
        for (events[0..ready]) |event| {
            const key = unpackCompletionKey(event.user_data) orelse continue;
            if (key.kind != .recv) continue;
            try processUringEvent(&ctx, event, key, loop_now, progress);
        }
        trimScratchBuffers(&ctx);
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

fn trimScratchBuffers(ctx: *const LoopContext) void {
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
    const phase = ctx.clients.getPhase(i);
    if (phase.* != .play) return;

    const deadline_ms = client.nextTimerMs(ctx.clients, i, phase.*) orelse return;
    if (now_ms < deadline_ms) return;

    const wrote = client.onTimerFor(movement_profile, ctx.clients, i, phase, now_ms, ctx.packet_builder_buf, ctx.write_temp_buf) catch |err| {
        try failRuntime(ctx, i, err, now_ms, progress);
        return;
    };
    if (wrote) try armSend(ctx, i);
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
                startConnect(ctx, i) catch |err| try failRuntime(ctx, i, err, now_ms, progress);
                scheduleClient(ctx, i);
            },
            .connecting, .draining, .stopped => {},
            .connected => try driveConnectedClient(movement_profile, ctx, i, now_ms, progress),
        }
    }
}

// `noinline`: the inline-else below fans out into one copy of the whole timer
// path per movement profile, and inlining that into runShardLoop doubled it.
noinline fn driveDueClientsConfigured(
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
    key: CompletionKey,
    now_ms: u64,
    progress: ProgressSink,
) !void {
    switch (key.kind) {
        .timeout, .socket_option => {},
        .recv => try handleRecvReady(ctx, event, key, now_ms, progress),
        .send => try handleSendReady(ctx, event, key, now_ms, progress),
        .connect => try handleConnectReady(ctx, event, key, now_ms, progress),
        .socket => try handleSocketReady(ctx, event, key, now_ms, progress),
        .close => handleCloseReady(ctx, event, key),
        .poll => try handlePollReady(ctx, event, key, now_ms, progress),
    }
}

fn handleSocketReady(ctx: *LoopContext, event: linux.io_uring_cqe, key: CompletionKey, now_ms: u64, progress: ProgressSink) !void {
    const index = key.index;
    if (index >= ctx.clients.global_indices.items.len) return;
    const pool = ctx.clients.pool.slice();
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
    // The guard above proved key.generation is the live connect generation.
    queueConfigureAndConnectFixed(
        ctx.ring,
        packCompletionKey(.{ .kind = .socket_option, .generation = key.generation, .index = index }),
        packCompletionKey(.{ .kind = .connect, .generation = key.generation, .index = index }),
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

fn handleCloseReady(ctx: *LoopContext, event: linux.io_uring_cqe, key: CompletionKey) void {
    if (key.index >= ctx.clients.global_indices.items.len) return;
    const pool = ctx.clients.pool.slice();
    const index = key.index;
    if (key.generation != pool.items(.close_generation)[index] or !pool.items(.flags)[index].close_armed) return;
    // A failed close (e.g. EBADF on a recycled direct slot) must not tear down
    // the shard; the slot is unusable either way, so retire it and move on.
    if (comptime diagnostics_enabled) {
        if (event.err() != .SUCCESS) ctx.aggregate.diagnostics.close_failures += 1;
    }
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
        // buffer_size is a power of two; shift instead of a hardware divide.
        const size: u64 = ctx.recv_buffers.buffer_size;
        const batch_buffers: u32 = @intCast((batch_bytes + size - 1) >> @intCast(@ctz(size)));
        ctx.aggregate.diagnostics.max_recv_bundle_bytes = @max(ctx.aggregate.diagnostics.max_recv_bundle_bytes, batch_bytes);
        ctx.aggregate.diagnostics.max_recv_bundle_buffers = @max(ctx.aggregate.diagnostics.max_recv_bundle_buffers, batch_buffers);
    }

    const phase = ctx.clients.getPhase(index);
    // Snapshot once per completion rather than per receive slice; a bundled
    // recv can span many slices and the effect comparisons are per-batch state.
    const before = client.readSnapshot(ctx.clients, index, phase.*);
    var read_result: client.ReadResult = .{};
    while (batch.next()) |recv_slice| {
        const part = client.onReadBytesRaw(ctx.clients, index, phase, ctx.recv_buffers.bytes(recv_slice), ctx.decompress_buf, ctx.decompress_window, ctx.packet_builder_buf, ctx.write_temp_buf) catch |err| {
            try failRuntime(ctx, index, err, now_ms, progress);
            return;
        };
        read_result.bytes += part.bytes;
        read_result.packets += part.packets;
        read_result.keep_alives += part.keep_alives;
        if (part.last_packet_id) |id| read_result.last_packet_id = id;
        if (comptime diagnostics_enabled) {
            if (part.keep_alive_reply_bytes) |pending_bytes| read_result.keep_alive_reply_bytes = pending_bytes;
        }
    }
    read_result.effects = client.readEffects(ctx.clients, index, phase.*, before);
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
                // The socket buffer is genuinely full: wait for POLLOUT and
                // re-issue the send from its completion instead of
                // hot-resubmitting.
                client.cancelBeginWrite(ctx.clients, index);
                armSendPoll(ctx, index) catch |err| try failRuntime(ctx, index, err, now_ms, progress);
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

// Arms a POLLOUT keyed to the current send generation. The completion is only
// acted on if the generation still matches: any intervening send re-arm or
// reconnect bumps send_generation and makes the poll a stale no-op.
fn armSendPoll(ctx: *const LoopContext, index: usize) !void {
    const pool = ctx.clients.pool.slice();
    try queuePollOut(ctx.ring, packCompletionKey(.{
        .kind = .poll,
        .generation = pool.items(.send_generation)[index],
        .index = index,
    }), @intCast(index));
}

fn handlePollReady(
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
    if (pool.items(.state)[index] != .connected) return;

    if (event.err() != .SUCCESS) {
        try failRuntime(ctx, index, error.Disconnected, now_ms, progress);
        return;
    }

    try armSend(ctx, index);
}

fn releaseRecvBufferIfPresent(recv_buffers: *RecvBufferGroup, event: linux.io_uring_cqe) void {
    if ((event.flags & linux.IORING_CQE_F_BUFFER) == 0) return;
    if (event.res <= 0) return;
    const batch = recv_buffers.batch(event) catch return;
    recv_buffers.releaseBatch(batch);
}

fn startConnect(ctx: *const LoopContext, index: usize) !void {
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

fn finishConnect(ctx: *const LoopContext, index: usize, now_ms: u64) !void {
    const pool = ctx.clients.pool.slice();
    if (!pool.items(.flags)[index].socket_live) return error.Disconnected;
    pool.items(.state)[index] = .connected;
    // Backoff is intentionally NOT reset here: a bare TCP connect that is
    // immediately dropped (server restarting, proxy closing the socket) would
    // otherwise pin backoff at the floor and reconnect forever at ~250ms,
    // pegging a core. It is reset in recordJoinProgress once the client has
    // actually reached play.
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

fn failClient(clients: *ClientTable, index: usize, err: anyerror, now_ms: u64, progress: ProgressSink, target: endpoint.Target, reconnect: bool) void {
    const pool = clients.pool.slice();
    const was_active = pool.items(.flags)[index].progress_active;
    const preserve_inflight_send = resetConnectionState(clients, index);

    const phase = clients.getPhase(index);
    const phase_before = phase.*;
    const delay: u64 = pool.items(.backoff_ms)[index];
    if (!builtin.is_test and !progress.suppressesLogs()) {
        if (clients.io) |io| {
            if (reconnectWarnAllowed(clients, io, now_ms)) {
                warnDisconnect(clients, io, index, err, delay, phase_before, target, reconnect);
            }
        }
    }

    client.close(clients, index, phase, preserve_inflight_send);
    const has_socket_work = preserve_inflight_send or pool.items(.flags)[index].close_armed or pool.items(.flags)[index].socket_live;
    if (comptime features.reconnect) {
        if (reconnect) {
            pool.items(.next_attempt_ms)[index] = now_ms +| jitteredDelay(delay, clients.reconnect_prng.random());
            pool.items(.backoff_ms)[index] = @intCast(@min(delay *| 2, max_backoff_ms));
            pool.items(.state)[index] = if (has_socket_work) .draining else .waiting;
            progress.scheduleReconnect(was_active);
            return;
        }
    }
    pool.items(.state)[index] = if (has_socket_work) .draining else .stopped;
    progress.noteDrop(was_active);
}

// Cold path, deliberately `noinline`: it instantiates std.fmt for every message
// below, and failClient's only caller (failRuntime) runs on every CQE handler.
noinline fn warnDisconnect(
    clients: *const ClientTable,
    io: Io,
    index: usize,
    err: anyerror,
    delay: u64,
    phase_before: client.Phase,
    target: endpoint.Target,
    reconnect: bool,
) void {
    var username_buffer: [16]u8 = undefined;
    const client_username = client.username(clients, index, &username_buffer) catch "<invalid>";
    var action_buffer: [40]u8 = undefined;
    const action: []const u8 = if (reconnect)
        std.fmt.bufPrint(&action_buffer, "reconnecting in {d}ms", .{delay}) catch "reconnecting"
    else
        "not reconnecting";
    switch (target) {
        .tcp => printStderr(io, "warning: client {s}@{s}:{d} disconnected: {t}; {s}\n", .{ client_username, clients.handshake_host, clients.handshake_port, err, action }),
        .unix => |unix| printStderr(io, "warning: client {s}@unix:{f} (handshake {s}:{d}) disconnected: {t}; {s}\n", .{ client_username, unix, clients.handshake_host, clients.handshake_port, err, action }),
    }
    if (comptime diagnostics_enabled) {
        const stats = clients.stats.slice();
        printStderr(io, "warning: client state at disconnect: phase={s} last_packet=0x{x}\n", .{ @tagName(phase_before), stats.items(.last_packet_id)[index] });
        printStderr(io, "warning: keep-alives answered={d}\n", .{stats.items(.keep_alives_answered)[index]});
    } else {
        printStderr(io, "warning: client state at disconnect: phase={s}\n", .{@tagName(phase_before)});
    }
}

fn recordJoinProgress(clients: *ClientTable, index: usize, progress: ProgressSink) void {
    const pool = clients.pool.slice();
    if (!client.joinedLogged(clients, index).*) return;
    // Real progress reached: safe to reset backoff so a healthy client that
    // later drops starts its next reconnect from the floor.
    pool.items(.backoff_ms)[index] = initial_backoff_ms;
    const was_active = pool.items(.flags)[index].progress_active;
    const was_counted = pool.items(.flags)[index].progress_counted;
    if (was_active and was_counted) return;
    pool.items(.flags)[index].progress_active = true;
    pool.items(.flags)[index].progress_counted = true;
    progress.enterPlay(!was_counted);
}

fn scheduleClient(ctx: *const LoopContext, index: usize) void {
    const pool = ctx.clients.pool.slice();
    switch (pool.items(.state)[index]) {
        .waiting => ctx.scheduler.update(index, pool.items(.next_attempt_ms)[index]),
        .connecting, .draining, .stopped => ctx.scheduler.update(index, null),
        .connected => {
            const phase = ctx.clients.phases.items[index];
            ctx.scheduler.update(index, client.nextTimerMs(ctx.clients, index, phase));
        },
    }
}

fn canFinishDraining(state: PoolState) bool {
    return state.state == .draining and !state.flags.close_armed and !state.flags.send_armed and !state.flags.socket_live;
}

fn finishDraining(ctx: *const LoopContext, index: usize) void {
    const pool = ctx.clients.pool.slice();
    const state: PoolState = ctx.clients.pool.get(index);
    if (!canFinishDraining(state)) return;
    client.close(ctx.clients, index, ctx.clients.getPhase(index), false);
    pool.items(.state)[index] = if (features.reconnect and ctx.reconnect) .waiting else .stopped;
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
    failClient(ctx.clients, index, err, now_ms, progress, ctx.target, ctx.reconnect);
    if (stats_enabled and ctx.reconnect) ctx.aggregate.reconnects += 1;
    scheduleClient(ctx, index);
}

fn noteKeepAliveQueued(ctx: *const LoopContext, index: usize, pending_bytes: u16, now_ms: u64) void {
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

// Equal-jitter backoff: keep at least half the delay, spread the rest randomly.
// A synchronized mass disconnect otherwise reschedules every client for the
// exact same instant, and they reconnect as one thundering herd every round.
fn jitteredDelay(delay: u64, rng: std.Random) u64 {
    if (comptime !features.reconnect) unreachable;
    if (delay == 0) return 0;
    const half = delay / 2;
    return half + rng.uintLessThan(u64, delay - half + 1);
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

fn armSend(ctx: *const LoopContext, index: usize) !void {
    const pool = ctx.clients.pool.slice();
    if (pool.items(.flags)[index].send_armed) return;
    if (pool.items(.state)[index] != .connected) return;
    if (!pool.items(.flags)[index].socket_live) return;

    var slices: [client.write_segment_capacity][]const u8 = undefined;
    const gathered = client.beginWriteGather(ctx.clients, index, &slices);
    if (gathered.count == 0) return;

    pool.items(.send_generation)[index] +%= 1;
    pool.items(.flags)[index].send_armed = true;
    errdefer {
        pool.items(.flags)[index].send_armed = false;
        client.cancelBeginWrite(ctx.clients, index);
    }
    const key = packCompletionKey(.{
        .kind = .send,
        .generation = pool.items(.send_generation)[index],
        .index = index,
    });
    if (gathered.count == 1) {
        try queueSendFixed(ctx.ring, key, @intCast(index), slices[0]);
        return;
    }

    // Flush every queued segment in one gathered submission instead of one
    // send round trip per segment.
    const iovecs = &ctx.send_iovecs[index];
    for (slices[0..gathered.count], iovecs[0..gathered.count]) |bytes, *iovec| {
        iovec.* = .{ .base = bytes.ptr, .len = bytes.len };
    }
    ctx.send_msghdrs[index] = .{
        .name = null,
        .namelen = 0,
        .iov = iovecs,
        .iovlen = gathered.count,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    try queueSendMsgFixed(ctx.ring, key, @intCast(index), &ctx.send_msghdrs[index]);
}

fn armRecv(ctx: *const LoopContext, index: usize) !void {
    const pool = ctx.clients.pool.slice();
    if (pool.items(.flags)[index].recv_armed) return;
    if (pool.items(.state)[index] != .connected) return;
    if (!pool.items(.flags)[index].socket_live) return;

    pool.items(.recv_generation)[index] +%= 1;
    pool.items(.flags)[index].recv_armed = true;
    try queueRecvMultishotFixed(ctx.recv_buffers, packCompletionKey(.{
        .kind = .recv,
        .generation = pool.items(.recv_generation)[index],
        .index = index,
    }), @intCast(index));
}

const reconnect_warn_window_ms: u64 = 1000;
const reconnect_warn_burst = 10;

// Rate-limits the per-client reconnect warning blocks so a reconnect storm
// cannot flood stderr: at most `reconnect_warn_burst` per shard per window,
// with skipped warnings reported once when the next window opens.
fn reconnectWarnAllowed(clients: *ClientTable, io: Io, now_ms: u64) bool {
    if (now_ms -| clients.warn_window_start_ms >= reconnect_warn_window_ms) {
        if (clients.warn_suppressed != 0) {
            printStderr(io, "warning: suppressed {d} reconnect warnings in the last {d}ms\n", .{
                clients.warn_suppressed,
                now_ms -| clients.warn_window_start_ms,
            });
        }
        clients.warn_window_start_ms = now_ms;
        clients.warn_in_window = 0;
        clients.warn_suppressed = 0;
    }
    if (clients.warn_in_window >= reconnect_warn_burst) {
        clients.warn_suppressed += 1;
        return false;
    }
    clients.warn_in_window += 1;
    return true;
}

fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var truncated = false;
    writer.print(fmt, args) catch {
        truncated = true;
    };
    writeStderr(io, writer.buffered(), truncated);
}

// Out of line so every printStderr instantiation shares one copy of the write
// instead of inlining the whole Io.Writer chain into each cold failure path.
noinline fn writeStderr(io: Io, bytes: []const u8, truncated: bool) void {
    const stderr = Io.File.stderr();
    stderr.writeStreamingAll(io, bytes) catch {};
    // The message did not fit the buffer: mark the prefix rather than drop it.
    if (truncated) stderr.writeStreamingAll(io, "...\n") catch {};
}

fn monotonicMs(io: Io) u64 {
    // Timestamp nanoseconds are i96, so toMilliseconds lowers to a __divti3
    // libcall. The monotonic clock is non-negative and fits u64 for centuries;
    // a u64 divide by a constant lowers to a multiply-shift instead.
    const ns: u64 = @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
    return ns / std.time.ns_per_ms;
}

fn shouldStop() bool {
    return stop_requested.load(.monotonic);
}

fn handleSignal(_: posix.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
    // A second signal means the graceful stop is not responding fast enough
    // (e.g. a pathological reconnect storm); force an immediate exit so the
    // user is never stuck. 128 + SIGINT(2) is the conventional exit code.
    if (stop_signal_count.fetchAdd(1, .monotonic) >= 1) {
        std.process.exit(130);
    }
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

test "jitteredDelay stays within the equal-jitter window" {
    if (comptime !features.reconnect) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const rng = prng.random();
    try std.testing.expectEqual(@as(u64, 0), jitteredDelay(0, rng));
    for (0..1000) |_| {
        const d = jitteredDelay(1000, rng);
        try std.testing.expect(d >= 500 and d <= 1000);
    }
    // Odd delay: half rounds down, upper bound is the full delay.
    for (0..1000) |_| {
        const d = jitteredDelay(251, rng);
        try std.testing.expect(d >= 125 and d <= 251);
    }
}

test "capTimeoutForStopCheck bounds indefinite and long io_uring waits" {
    try std.testing.expectEqual(@as(i32, stop_check_interval_ms), capTimeoutForStopCheck(-1));
    try std.testing.expectEqual(@as(i32, stop_check_interval_ms), capTimeoutForStopCheck(stop_check_interval_ms + 1));
    try std.testing.expectEqual(@as(i32, 10), capTimeoutForStopCheck(10));
    try std.testing.expectEqual(@as(i32, 0), capTimeoutForStopCheck(0));
}

test "failClient isolates one client and schedules reconnect backoff" {
    if (comptime !features.reconnect) return error.SkipZigTest;
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

    failClient(&clients, 0, error.Disconnected, 1_000, .none, .{ .tcp = .{ .host = "127.0.0.1" } }, true);

    try std.testing.expectEqual(ConnectionState.waiting, pool.items(.state)[0]);
    try std.testing.expectEqual(ConnectionState.connected, pool.items(.state)[1]);
    // Reconnect is scheduled with equal-jitter backoff: at least half the
    // 250ms delay, at most the full delay, relative to now (1_000).
    try std.testing.expect(pool.items(.next_attempt_ms)[0] >= 1_000 + 125);
    try std.testing.expect(pool.items(.next_attempt_ms)[0] <= 1_000 + 250);
    try std.testing.expectEqual(@as(u16, 500), pool.items(.backoff_ms)[0]);
    try std.testing.expectEqual(@as(u16, 8), pool.items(.connect_generation)[0]);
    try std.testing.expectEqual(@as(u16, 10), pool.items(.recv_generation)[0]);
    try std.testing.expect(!pool.items(.flags)[0].recv_armed);
    try std.testing.expectEqual(@as(u16, 12), pool.items(.send_generation)[0]);
    try std.testing.expect(!pool.items(.flags)[0].send_armed);
    try std.testing.expectEqual(client.Phase.disconnected, clients.phases.items[0]);
    try std.testing.expectEqual(client.Phase.play, clients.phases.items[1]);
}

test "failClient without reconnect drops the client instead of rescheduling" {
    const allocator = std.testing.allocator;
    var clients: ClientTable = .{};
    defer clients.deinit(allocator);
    try clients.ensureTotalCapacity(allocator, 1);
    clients.appendAssumeCapacity(0, 0);

    const pool = clients.pool.slice();
    pool.items(.state)[0] = .connected;
    clients.getPhase(0).* = .play;

    failClient(&clients, 0, error.Disconnected, 1_000, .none, .{ .tcp = .{ .host = "127.0.0.1" } }, false);

    try std.testing.expectEqual(ConnectionState.stopped, pool.items(.state)[0]);
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

    failClient(&clients, 0, error.Disconnected, 1000, .none, .{ .tcp = .{ .host = "127.0.0.1" } }, true);

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
