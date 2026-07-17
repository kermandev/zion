const std = @import("std");
const Io = std.Io;
const features = @import("features.zig");
const outbound = @import("outbound.zig");
pub const protocol = @import("protocol.zig");
const packet_ids = protocol.packet_ids;

const stats_module = @import("stats.zig");
const diagnostics_enabled = stats_module.diagnostics_enabled;
const StatsColumns = stats_module.StatsColumns;

pub const Phase = enum(u8) {
    disconnected,
    handshaking,
    status,
    login,
    configuration,
    play,
};

pub const CachedPacket = struct {
    body: []const u8,
    frame: []const u8,
    uncompressed_frame: if (protocol.compression_enabled) []const u8 else void = if (protocol.compression_enabled) &.{} else {},
    compressed_frame: if (protocol.compression_enabled) []const u8 else void = if (protocol.compression_enabled) &.{} else {},

    pub fn initOwned(allocator: std.mem.Allocator, owned_body: []const u8) Error!CachedPacket {
        errdefer allocator.free(owned_body);

        var frame: Io.Writer.Allocating = .init(allocator);
        defer frame.deinit();
        try protocol.appendPacketFrame(allocator, &frame, owned_body, .disabled);

        var uncompressed_frame: Io.Writer.Allocating = .init(allocator);
        defer uncompressed_frame.deinit();
        if (comptime protocol.compression_enabled) {
            try protocol.appendPacketFrame(allocator, &uncompressed_frame, owned_body, .{ .enabled = std.math.maxInt(i32) });
        }

        var compressed_frame: Io.Writer.Allocating = .init(allocator);
        defer compressed_frame.deinit();
        if (comptime protocol.compression_enabled) {
            try protocol.appendPacketFrame(allocator, &compressed_frame, owned_body, .{ .enabled = 0 });
        }

        const frame_slice = try frame.toOwnedSlice();
        errdefer allocator.free(frame_slice);

        const uncompressed_frame_slice = if (comptime protocol.compression_enabled)
            try uncompressed_frame.toOwnedSlice()
        else {};
        errdefer if (comptime protocol.compression_enabled) allocator.free(uncompressed_frame_slice);

        const compressed_frame_slice = if (comptime protocol.compression_enabled)
            try compressed_frame.toOwnedSlice()
        else {};

        return .{
            .body = owned_body,
            .frame = frame_slice,
            .uncompressed_frame = uncompressed_frame_slice,
            .compressed_frame = compressed_frame_slice,
        };
    }

    pub fn deinit(packet: CachedPacket, allocator: std.mem.Allocator) void {
        allocator.free(packet.body);
        allocator.free(packet.frame);
        if (comptime protocol.compression_enabled) {
            allocator.free(packet.uncompressed_frame);
            allocator.free(packet.compressed_frame);
        }
    }
};

pub const MovementProfile = if (features.movement) enum(u8) {
    idle,
    rotate,
    walk,
} else void;

pub const MovementConfig = if (features.movement) struct {
    profile: MovementProfile = .idle,
    interval_ms: u64 = 50,
    radius: f64 = 16.0,
    speed: f64 = 4.3,
    rotation_rate: f32 = 180.0,
    seed: u64 = 0,
} else void;

pub const ConnectionState = enum(u8) {
    waiting,
    connecting,
    connected,
    draining,
};

pub const initial_backoff_ms: u16 = 250;

pub const PoolFlags = packed struct(u8) {
    socket_live: bool = false,
    close_armed: bool = false,
    recv_armed: bool = false,
    send_armed: bool = false,
    progress_counted: bool = false,
    progress_active: bool = false,
    padding: u2 = 0,
};

pub const PoolState = struct {
    flags: PoolFlags = .{},
    state: ConnectionState = .waiting,
    next_attempt_ms: u64,
    backoff_ms: u16 = initial_backoff_ms,
    connect_generation: u16 = 0,
    close_generation: u16 = 0,
    recv_generation: u16 = 0,
    send_generation: u16 = 0,
};

pub const Error = error{
    OnlineModeUnsupported,
    Disconnected,
    ServerDisconnected,
    UnexpectedPacket,
    WouldBlock,
    ReadBufferLimitExceeded,
    WriteBufferLimitExceeded,
    UsernameTooLong,
} || protocol.PacketError || std.posix.PollError || Io.net.HostName.ValidateError || Io.net.HostName.ConnectError || Io.Cancelable;

const initial_read_buffer_size = 256;
pub const max_queued_write_bytes = outbound.max_queued_bytes;
const client_tick_interval_ms = 50;
const movement_interval_ms = 1000;

pub const ReadState = struct {
    buffer: ?[*]u8 = null,
    capacity: u32 = 0,
    len: u32 = 0,
    offset: u32 = 0,
    discard_remaining: u32 = 0,
};

pub const WriteState = outbound.Queue;

const no_deadline = std.math.maxInt(u64);

pub const TimerState = struct {
    next_broadcast_ms: if (features.broadcast) u64 else void = if (features.broadcast) no_deadline else {},
    next_client_tick_ms: if (features.client_tick) u64 else void = if (features.client_tick) no_deadline else {},
    next_movement_ms: if (features.movement) u64 else void = if (features.movement) no_deadline else {},
};

pub const MotionState = if (features.movement) struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,
    origin_x: f64 = 0,
    origin_z: f64 = 0,
    target_x: f64 = 0,
    target_z: f64 = 0,
    yaw: f32 = 0,
    pitch: f32 = 0,
    target_yaw: f32 = 0,
    target_pitch: f32 = 0,
    last_update_ms: u64 = 0,
    next_decision_ms: u64 = 0,
    rng: u64 = 0,
    initialized: bool = false,
    has_target: bool = false,
} else void;

pub const SessionColumns = struct {
    read: ReadState = .{},
    write: WriteState = .{},
    timers: TimerState = .{},
    compression: if (protocol.compression_enabled) protocol.Compression else void = if (protocol.compression_enabled) .disabled else {},
    joined_logged: bool = false,
};

pub const FrameResult = struct {
    packet_id: ?i32 = null,
    keep_alive: bool = false,
};

pub const ReadResult = struct {
    bytes: usize = 0,
    packets: usize = 0,
    keep_alives: usize = 0,
    last_packet_id: ?i32 = null,
    effects: ReadEffects = .{},
};

pub const ReadEffects = packed struct {
    write_ready: bool = false,
    deadline_changed: bool = false,
    progress_changed: bool = false,
};

const GlobalIndices = std.ArrayList(u32);
const ClientPhases = std.ArrayList(Phase);
const ClientStats = if (diagnostics_enabled) std.MultiArrayList(StatsColumns) else void;
const ClientSessions = std.MultiArrayList(SessionColumns);
const PoolStates = std.MultiArrayList(PoolState);
const MotionStates = if (features.movement) std.ArrayList(MotionState) else void;

fn soaElementBytes(comptime T: type) comptime_int {
    var total = 0;
    inline for (@typeInfo(T).@"struct".field_types) |Field| total += @sizeOf(Field);
    return total;
}

pub const dense_table_bytes_per_client = @sizeOf(u32) +
    @sizeOf(Phase) +
    soaElementBytes(StatsColumns) +
    soaElementBytes(SessionColumns) +
    soaElementBytes(PoolState);

test "dense client metadata stays compact" {
    try std.testing.expect(@sizeOf(Phase) == 1);
    try std.testing.expect(@sizeOf(PoolState) <= 24);
    try std.testing.expect(@sizeOf(ReadState) <= 24);
    try std.testing.expect(@sizeOf(TimerState) <= 24);
    try std.testing.expect(dense_table_bytes_per_client <= 140);
}

pub const ClientTable = struct {
    io: ?Io = null,
    allocator: std.mem.Allocator = undefined,
    global_indices: GlobalIndices = .empty,
    phases: ClientPhases = .empty,
    stats: ClientStats = if (diagnostics_enabled) .empty else {},
    sessions: ClientSessions = .empty,
    pool: PoolStates = .empty,
    motion_states: MotionStates = if (features.movement) .empty else {},
    read_buffer_bytes: usize = 0,
    read_buffer_limit: usize = std.math.maxInt(usize),
    handshake_host: []const u8 = "localhost",
    handshake_port: u16 = 25565,
    username_prefix: []const u8 = "Zion",
    username_override: ?[]const u8 = null,
    known_core_pack: bool = false,
    total_client_count: usize = 1,
    broadcast_packet: if (features.broadcast) ?CachedPacket else void = if (features.broadcast) null else {},
    broadcast_interval_ms: if (features.broadcast) u64 else void = if (features.broadcast) 0 else {},
    client_tick_packet: if (features.client_tick) ?CachedPacket else void = if (features.client_tick) null else {},
    movement: if (features.movement) MovementConfig else void = if (features.movement) .{} else {},

    pub fn deinit(clients: *ClientTable, allocator: std.mem.Allocator) void {
        const sessions = clients.sessions.slice();
        const reads = sessions.items(.read);
        const writes = sessions.items(.write);
        for (0..clients.global_indices.items.len) |i| {
            if (reads[i].buffer) |buffer| allocator.free(buffer[0..reads[i].capacity]);
            writes[i].deinit(allocator);
        }

        clients.global_indices.deinit(allocator);
        clients.phases.deinit(allocator);
        if (diagnostics_enabled) clients.stats.deinit(allocator);
        clients.sessions.deinit(allocator);
        clients.pool.deinit(allocator);
        if (comptime features.movement) clients.motion_states.deinit(allocator);
        clients.* = undefined;
    }

    pub fn ensureTotalCapacity(clients: *ClientTable, allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!void {
        try clients.global_indices.ensureTotalCapacity(allocator, count);
        try clients.phases.ensureTotalCapacity(allocator, count);
        if (diagnostics_enabled) try clients.stats.ensureTotalCapacity(allocator, count);
        try clients.sessions.ensureTotalCapacity(allocator, count);
        try clients.pool.ensureTotalCapacity(allocator, count);
        if (comptime features.movement) {
            if (clients.movement.profile != .idle) try clients.motion_states.ensureTotalCapacity(allocator, count);
        }
    }

    pub fn appendAssumeCapacity(
        clients: *ClientTable,
        global_index: u32,
        next_attempt_ms: u64,
    ) void {
        clients.global_indices.appendAssumeCapacity(global_index);
        clients.phases.appendAssumeCapacity(.disconnected);
        if (diagnostics_enabled) clients.stats.appendAssumeCapacity(.{});
        clients.sessions.appendAssumeCapacity(.{});
        clients.pool.appendAssumeCapacity(.{ .next_attempt_ms = next_attempt_ms });
        if (comptime features.movement) {
            if (clients.movement.profile != .idle) clients.motion_states.appendAssumeCapacity(.{});
        }
    }

    pub fn getPhase(clients: *ClientTable, index: usize) *Phase {
        return &clients.phases.items[index];
    }
};

inline fn releaseReadBuffer(clients: *ClientTable, state: *ReadState) void {
    if (state.buffer) |bytes| {
        std.debug.assert(clients.read_buffer_bytes >= state.capacity);
        clients.read_buffer_bytes -= state.capacity;
        clients.allocator.free(bytes[0..state.capacity]);
        state.buffer = null;
        state.capacity = 0;
    }
    state.len = 0;
    state.offset = 0;
}

fn resizeReadBuffer(clients: *ClientTable, state: *ReadState, new_capacity: usize) !void {
    const old_capacity = state.capacity;
    const without_old = clients.read_buffer_bytes - old_capacity;
    const new_total = std.math.add(usize, without_old, new_capacity) catch return error.ReadBufferLimitExceeded;
    if (new_total > clients.read_buffer_limit) return error.ReadBufferLimitExceeded;

    const resized = if (state.buffer) |buffer|
        try clients.allocator.realloc(buffer[0..state.capacity], new_capacity)
    else
        try clients.allocator.alloc(u8, new_capacity);
    state.buffer = resized.ptr;
    state.capacity = @intCast(resized.len);
    clients.read_buffer_bytes = new_total;
}

pub inline fn readState(clients: *ClientTable, index: usize) *ReadState {
    return &clients.sessions.items(.read)[index];
}
pub inline fn writeState(clients: *ClientTable, index: usize) *WriteState {
    return &clients.sessions.items(.write)[index];
}
pub inline fn compressionState(clients: *ClientTable, index: usize) if (protocol.compression_enabled) *protocol.Compression else *const protocol.Compression {
    if (comptime !protocol.compression_enabled) {
        const static = struct {
            const val: protocol.Compression = .disabled;
        };
        return &static.val;
    } else {
        return &clients.sessions.items(.compression)[index];
    }
}
pub inline fn timerState(clients: *ClientTable, index: usize) *TimerState {
    return &clients.sessions.items(.timers)[index];
}
pub inline fn motionState(clients: *ClientTable, index: usize) if (features.movement) *MotionState else void {
    if (comptime features.movement) {
        std.debug.assert(clients.movement.profile != .idle);
        return &clients.motion_states.items[index];
    }
    return {};
}
pub inline fn joinedLogged(clients: *ClientTable, index: usize) *bool {
    return &clients.sessions.items(.joined_logged)[index];
}

pub fn username(clients: *const ClientTable, index: usize, buffer: *[16]u8) error{UsernameTooLong}![]const u8 {
    if (clients.username_override) |override| return override;
    return std.fmt.bufPrint(buffer, "{s}{d}", .{ clients.username_prefix, clients.global_indices.items[index] + 1 }) catch error.UsernameTooLong;
}
pub fn onConnected(clients: *ClientTable, index: usize, phase: *Phase, now_ms: u64, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!void {
    phase.* = .disconnected;
    releaseReadBuffer(clients, readState(clients, index));
    readState(clients, index).discard_remaining = 0;
    writeState(clients, index).clearRetainingCapacity();
    if (comptime protocol.compression_enabled) {
        compressionState(clients, index).* = .disabled;
    }
    if (comptime features.broadcast) timerState(clients, index).next_broadcast_ms = no_deadline;
    if (comptime features.client_tick) {
        timerState(clients, index).next_client_tick_ms = if (clients.client_tick_packet != null)
            now_ms +| staggerOffsetMs(clients.global_indices.items[index], clients.total_client_count, client_tick_interval_ms)
        else
            no_deadline;
    }
    if (comptime features.movement) {
        const interval = if (clients.movement.profile == .idle) movement_interval_ms else clients.movement.interval_ms;
        timerState(clients, index).next_movement_ms = now_ms +| staggerOffsetMs(clients.global_indices.items[index], clients.total_client_count, interval);
        if (clients.movement.profile != .idle) {
            motionState(clients, index).* = .{ .rng = mixSeed(clients.movement.seed, clients.global_indices.items[index]) };
        }
    }
    if (comptime stats_module.diagnostics_enabled) {
        const client_stats = clients.stats.slice();
        client_stats.items(.last_packet_id)[index] = -1;
        client_stats.items(.keep_alives_answered)[index] = 0;
    }
    joinedLogged(clients, index).* = false;

    phase.* = .handshaking;
    {
        var packet = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.handshake.serverbound.intention);
        try protocol.version.writeHandshake(&packet.writer, clients.handshake_host, clients.handshake_port, .login);
        try enqueueBuiltPacket(clients, index, &packet, .disabled, write_temp_buf);
    }
    phase.* = .login;
    {
        var username_buffer: [16]u8 = undefined;
        const client_username = try username(clients, index, &username_buffer);
        var packet = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.login.serverbound.login_start);
        try protocol.version.writeLoginStart(&packet.writer, client_username);
        try enqueueBuiltPacket(clients, index, &packet, .disabled, write_temp_buf);
    }

    if (comptime features.broadcast) {
        if (clients.broadcast_packet != null and clients.broadcast_interval_ms > 0) {
            timerState(clients, index).next_broadcast_ms = now_ms +| staggerOffsetMs(clients.global_indices.items[index], clients.total_client_count, clients.broadcast_interval_ms);
        }
    }
}

pub fn onReadBytes(clients: *ClientTable, index: usize, phase: *Phase, bytes: []const u8, decompress_buf: anytype, decompress_window: anytype, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!ReadResult {
    if (bytes.len == 0) return error.Disconnected;

    const write_bytes_before = queuedWriteBytes(clients, index);
    const deadline_before = nextTimerMs(clients, index, phase.*);
    const joined_before = joinedLogged(clients, index).*;
    var result: ReadResult = .{ .bytes = bytes.len };
    var input_offset: usize = 0;
    if (readState(clients, index).discard_remaining > 0) {
        const discarded = @min(bytes.len, readState(clients, index).discard_remaining);
        readState(clients, index).discard_remaining -= @intCast(discarded);
        input_offset = discarded;
        if (input_offset == bytes.len) return finishReadResult(clients, index, phase.*, write_bytes_before, deadline_before, joined_before, result);
    }
    const input = bytes[input_offset..];

    if (readState(clients, index).offset != readState(clients, index).len) {
        compactReadBuffer(clients, index);
        try appendReadBufferSlice(clients, index, input);
        result = try drainPackets(clients, index, phase, decompress_buf, decompress_window, packet_builder_buf, write_temp_buf);
        result.bytes = bytes.len;
        return finishReadResult(clients, index, phase.*, write_bytes_before, deadline_before, joined_before, result);
    }

    if (readState(clients, index).buffer != null) {
        releaseReadBuffer(clients, readState(clients, index));
    }

    var offset: usize = 0;
    while (try nextFrame(input[offset..])) |frame| {
        const frame_res = try handleFrame(clients, index, phase, frame.bytes, decompress_buf, decompress_window, packet_builder_buf, write_temp_buf);
        if (frame_res.packet_id) |id| result.last_packet_id = id;
        if (frame_res.keep_alive) result.keep_alives += 1;
        result.packets += 1;
        offset += frame.consumed;
    }

    if (offset < input.len) {
        if (try incompleteSkippedFrameRemaining(clients, index, phase, input[offset..], decompress_window)) |remaining| {
            readState(clients, index).discard_remaining = @intCast(remaining);
            result.packets += 1;
        } else {
            try appendReadBufferSlice(clients, index, input[offset..]);
        }
    }
    return finishReadResult(clients, index, phase.*, write_bytes_before, deadline_before, joined_before, result);
}

fn finishReadResult(
    clients: *ClientTable,
    index: usize,
    phase: Phase,
    write_bytes_before: usize,
    deadline_before: ?u64,
    joined_before: bool,
    result_value: ReadResult,
) ReadResult {
    var result = result_value;
    result.effects = .{
        .write_ready = queuedWriteBytes(clients, index) != write_bytes_before,
        .deadline_changed = nextTimerMs(clients, index, phase) != deadline_before,
        .progress_changed = joinedLogged(clients, index).* != joined_before,
    };
    return result;
}

fn queuedWriteBytes(clients: *ClientTable, index: usize) usize {
    return writeState(clients, index).byteCount();
}

pub fn onTimer(clients: *ClientTable, index: usize, phase: *Phase, now_ms: u64, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!bool {
    if (comptime features.movement) {
        return switch (clients.movement.profile) {
            inline else => |profile| onTimerFor(profile, clients, index, phase, now_ms, packet_builder_buf, write_temp_buf),
        };
    } else {
        return onTimerFor({}, clients, index, phase, now_ms, packet_builder_buf, write_temp_buf);
    }
}

pub fn onTimerFor(
    comptime movement_profile: MovementProfile,
    clients: *ClientTable,
    index: usize,
    phase: *Phase,
    now_ms: u64,
    packet_builder_buf: *Io.Writer.Allocating,
    write_temp_buf: *Io.Writer.Allocating,
) Error!bool {
    if (phase.* != .play) return false;
    var wrote = false;
    const backpressured = writeState(clients, index).isLocked();
    if (comptime features.client_tick) {
        const due = timerState(clients, index).next_client_tick_ms;
        if (due != no_deadline) {
            if (now_ms >= due) {
                if (!backpressured) {
                    try enqueueCachedPacket(clients, index, .client_tick);
                    wrote = true;
                }
                timerState(clients, index).next_client_tick_ms = now_ms +| client_tick_interval_ms;
            }
        }
    }

    if (comptime features.movement) {
        std.debug.assert(clients.movement.profile == movement_profile);
        const due = timerState(clients, index).next_movement_ms;
        if (due != no_deadline) {
            if (now_ms >= due) {
                const config = clients.movement;
                if (!backpressured) switch (movement_profile) {
                    .idle => {
                        var packet = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.play.serverbound.move_player_status_only);
                        try protocol.version.writeMovementStatusOnly(&packet.writer);
                        try enqueueBuiltPacket(clients, index, &packet, compressionState(clients, index).*, write_temp_buf);
                        wrote = true;
                    },
                    .rotate => if (motionState(clients, index).initialized) {
                        updateMotion(.rotate, motionState(clients, index), config, now_ms);
                        var packet = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.play.serverbound.move_player_rotation);
                        try protocol.version.writeMovementRotation(&packet.writer, motionState(clients, index).yaw, motionState(clients, index).pitch);
                        try enqueueBuiltPacket(clients, index, &packet, compressionState(clients, index).*, write_temp_buf);
                        wrote = true;
                    },
                    .walk => if (motionState(clients, index).initialized) {
                        updateMotion(.walk, motionState(clients, index), config, now_ms);
                        var packet = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.play.serverbound.move_player_position_rotation);
                        try protocol.version.writeMovementPositionRotation(&packet.writer, motionState(clients, index).x, motionState(clients, index).y, motionState(clients, index).z, motionState(clients, index).yaw, motionState(clients, index).pitch);
                        try enqueueBuiltPacket(clients, index, &packet, compressionState(clients, index).*, write_temp_buf);
                        wrote = true;
                    },
                };
                const interval = if (movement_profile == .idle) movement_interval_ms else config.interval_ms;
                timerState(clients, index).next_movement_ms = now_ms +| interval;
            }
        }
    }

    if (comptime features.broadcast) {
        const due = timerState(clients, index).next_broadcast_ms;
        if (due == no_deadline) return wrote;
        if (now_ms < due) return wrote;

        if (clients.broadcast_packet != null) {
            if (!backpressured) {
                try enqueueCachedPacket(clients, index, .broadcast);
                wrote = true;
            }
            timerState(clients, index).next_broadcast_ms = now_ms +| clients.broadcast_interval_ms;
        }
    }
    return wrote;
}

pub fn close(clients: *ClientTable, index: usize, phase: *Phase, preserve_inflight_send: bool) void {
    phase.* = .disconnected;
    if (comptime protocol.compression_enabled) {
        compressionState(clients, index).* = .disabled;
    }
    releaseReadBuffer(clients, readState(clients, index));
    readState(clients, index).discard_remaining = 0;
    writeState(clients, index).reset(clients.allocator, preserve_inflight_send);
    if (comptime features.broadcast) timerState(clients, index).next_broadcast_ms = no_deadline;
    if (comptime features.client_tick) timerState(clients, index).next_client_tick_ms = no_deadline;
    if (comptime features.movement) {
        timerState(clients, index).next_movement_ms = no_deadline;
        if (clients.movement.profile != .idle) motionState(clients, index).* = .{};
    }
    joinedLogged(clients, index).* = false;
}

pub fn wantsWrite(clients: *ClientTable, index: usize) bool {
    return writeState(clients, index).segmentCount() != 0;
}

pub fn beginWrite(clients: *ClientTable, index: usize) []const u8 {
    return resolvePendingWrite(clients, writeState(clients, index).begin());
}

fn resolvePendingWrite(clients: *ClientTable, pending: outbound.Pending) []const u8 {
    return switch (pending) {
        .empty => &.{},
        .owned => |bytes| bytes,
        .shared => |shared| blk: {
            const frame = sharedFrame(clients, shared.source);
            std.debug.assert(shared.offset <= shared.len and shared.len <= frame.len);
            break :blk frame[shared.offset..shared.len];
        },
    };
}

fn sharedFrame(clients: *ClientTable, source: outbound.SharedSource) []const u8 {
    return switch (source) {
        .broadcast_plain => if (comptime features.broadcast) clients.broadcast_packet.?.frame else unreachable,
        .broadcast_uncompressed => if (comptime features.broadcast and protocol.compression_enabled) clients.broadcast_packet.?.uncompressed_frame else unreachable,
        .broadcast_compressed => if (comptime features.broadcast and protocol.compression_enabled) clients.broadcast_packet.?.compressed_frame else unreachable,
        .client_tick_plain => if (comptime features.client_tick) clients.client_tick_packet.?.frame else unreachable,
        .client_tick_uncompressed => if (comptime features.client_tick and protocol.compression_enabled) clients.client_tick_packet.?.uncompressed_frame else unreachable,
        .client_tick_compressed => if (comptime features.client_tick and protocol.compression_enabled) clients.client_tick_packet.?.compressed_frame else unreachable,
    };
}

pub fn cancelBeginWrite(clients: *ClientTable, index: usize) void {
    writeState(clients, index).cancel();
}

pub fn onWriteComplete(clients: *ClientTable, index: usize, phase: *Phase, count: usize) Error!void {
    _ = phase;
    writeState(clients, index).complete(count) catch return error.Disconnected;
}

pub fn nextTimerMs(clients: *ClientTable, index: usize, phase: Phase) ?u64 {
    if (phase != .play) return null;
    var next: ?u64 = null;
    if (comptime features.client_tick) next = minDeadline(next, timerState(clients, index).next_client_tick_ms);
    if (comptime features.movement) next = minDeadline(next, timerState(clients, index).next_movement_ms);
    if (comptime features.broadcast) next = minDeadline(next, timerState(clients, index).next_broadcast_ms);
    return next;
}

pub fn readBufferSlice(clients: *ClientTable, index: usize) []u8 {
    if (readState(clients, index).buffer) |buffer| {
        return buffer[0..readState(clients, index).len];
    }
    return &.{};
}

pub fn appendReadBufferSlice(clients: *ClientTable, index: usize, bytes: []const u8) !void {
    const state = readState(clients, index);
    const needed = std.math.add(usize, state.len, bytes.len) catch return error.ReadBufferLimitExceeded;
    const max_buffered_packet = protocol.max_packet_len + 5;
    if (needed > max_buffered_packet) return error.ReadBufferLimitExceeded;

    if (state.buffer == null) {
        try resizeReadBuffer(clients, state, @max(@as(usize, initial_read_buffer_size), needed));
        state.len = 0;
        state.offset = 0;
    } else if (needed > state.capacity) {
        const doubled = std.math.mul(usize, state.capacity, 2) catch max_buffered_packet;
        try resizeReadBuffer(clients, state, @min(max_buffered_packet, @max(needed, doubled)));
    }
    const slice = state.buffer.?;
    std.mem.copyForwards(u8, slice[state.len..needed], bytes);
    state.len = @intCast(needed);
}

fn appendWriteBufferSlice(clients: *ClientTable, index: usize, bytes: []const u8) Error!void {
    writeState(clients, index).enqueueOwned(clients.allocator, bytes) catch |err| return switch (err) {
        error.TooLarge, error.QueueFull, error.NoOwnedBuffer => error.WriteBufferLimitExceeded,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn drainPackets(clients: *ClientTable, index: usize, phase: *Phase, decompress_buf: anytype, decompress_window: anytype, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!ReadResult {
    const slice = readBufferSlice(clients, index);
    var result: ReadResult = .{};
    while (true) {
        const offset = readState(clients, index).offset;
        if (offset >= slice.len) break;
        if (try nextFrame(slice[offset..])) |frame| {
            const frame_res = try handleFrame(clients, index, phase, frame.bytes, decompress_buf, decompress_window, packet_builder_buf, write_temp_buf);
            if (frame_res.packet_id) |id| result.last_packet_id = id;
            if (frame_res.keep_alive) result.keep_alives += 1;
            result.packets += 1;
            readState(clients, index).offset += @intCast(frame.consumed);
        } else {
            if (try incompleteSkippedFrameRemaining(clients, index, phase, slice[offset..], decompress_window)) |remaining| {
                releaseReadBuffer(clients, readState(clients, index));
                readState(clients, index).discard_remaining = @intCast(remaining);
                result.packets += 1;
            }
            break;
        }
    }
    compactReadBuffer(clients, index);
    return result;
}

fn handleFrame(clients: *ClientTable, index: usize, phase: *Phase, frame: []const u8, decompress_buf: anytype, decompress_window: anytype, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!FrameResult {
    if (try shouldSkipFrame(clients, index, phase, frame, decompress_window)) {
        return .{ .packet_id = null, .keep_alive = false };
    }

    const packet = try protocol.readPacketFrame(clients.allocator, frame, compressionState(clients, index).*, if (comptime protocol.compression_enabled) decompress_buf else null, if (comptime protocol.compression_enabled) decompress_window else null);

    const keep_alive = try handlePacket(clients, index, phase, packet, packet_builder_buf, write_temp_buf);
    return .{ .packet_id = packet.id, .keep_alive = keep_alive };
}

fn compactReadBuffer(clients: *ClientTable, index: usize) void {
    if (readState(clients, index).buffer == null) return;
    if (readState(clients, index).offset == 0) return;
    if (readState(clients, index).offset == readState(clients, index).len) {
        releaseReadBuffer(clients, readState(clients, index));
        return;
    }
    const slice = readState(clients, index).buffer.?;
    std.mem.copyForwards(u8, slice[0 .. readState(clients, index).len - readState(clients, index).offset], slice[readState(clients, index).offset..readState(clients, index).len]);
    readState(clients, index).len -= readState(clients, index).offset;
    readState(clients, index).offset = 0;
}

fn shouldSkipFrame(clients: *ClientTable, index: usize, phase: *Phase, frame: []const u8, decompress_window: anytype) Error!bool {
    if (phase.* != .play) return false;
    if (comptime protocol.compression_enabled) {
        if (compressionState(clients, index).* == .enabled) {
            var frame_reader: Io.Reader = .fixed(frame);
            var packet_reader = protocol.PacketReader.init(&frame_reader);
            const data_len = try packet_reader.readVarInt();
            if (data_len < 0) return error.NegativeLength;
            if (data_len > 0) {
                const packet_id = try protocol.peekCompressedPacketId(frame[frame_reader.seek..], decompress_window);
                return !isHandledPlayPacket(packet_id);
            }
        }
    }
    const packet_id = peekPlayPacketId(clients, index, frame) orelse return false;
    return !isHandledPlayPacket(packet_id);
}

fn incompleteSkippedFrameRemaining(clients: *ClientTable, index: usize, phase: *Phase, buffer: []const u8, decompress_window: anytype) Error!?usize {
    if (phase.* != .play) return null;

    const outer = peekVarInt(buffer) orelse return null;
    if (outer.value < 0 or outer.value > protocol.max_packet_len) return null;
    const frame_end = outer.consumed + @as(usize, @intCast(outer.value));
    if (buffer.len >= frame_end) return null;

    var packet_prefix = buffer[outer.consumed..];
    if (comptime protocol.compression_enabled) {
        if (compressionState(clients, index).* == .enabled) {
            const data_len = peekVarInt(packet_prefix) orelse return null;
            if (data_len.value < 0) return null;
            if (data_len.value > 0) {
                const packet_id = protocol.peekCompressedPacketId(packet_prefix[data_len.consumed..], decompress_window) catch return null;
                return if (isHandledPlayPacket(packet_id)) null else frame_end - buffer.len;
            }
            packet_prefix = packet_prefix[data_len.consumed..];
        }
    }

    const packet_id = peekVarInt(packet_prefix) orelse return null;
    if (isHandledPlayPacket(packet_id.value)) return null;
    return frame_end - buffer.len;
}

fn peekPlayPacketId(clients: *ClientTable, index: usize, frame: []const u8) ?i32 {
    var reader: Io.Reader = .fixed(frame);
    var packet_reader = protocol.PacketReader.init(&reader);
    if (comptime protocol.compression_enabled) {
        if (compressionState(clients, index).* == .enabled) {
            const data_len = packet_reader.readVarInt() catch return null;
            if (data_len != 0) return null;
        }
    }
    return packet_reader.readVarInt() catch null;
}

fn handlePacket(clients: *ClientTable, index: usize, phase: *Phase, packet: protocol.Packet, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!bool {
    switch (phase.*) {
        .login => {
            try handleLoginPacket(clients, index, phase, packet, packet_builder_buf, write_temp_buf);
            return false;
        },
        .configuration => return try handleConfigurationPacket(clients, index, phase, packet, packet_builder_buf, write_temp_buf),
        .play => return try handlePlayPacket(clients, index, phase, packet, packet_builder_buf, write_temp_buf),
        else => return error.UnexpectedPacket,
    }
}

fn replyKeepAlive(clients: *ClientTable, index: usize, payload: []const u8, packet_id: i32, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!void {
    var payload_reader: Io.Reader = .fixed(payload);
    var packet_reader = protocol.PacketReader.init(&payload_reader);
    var reply = try protocol.PacketFrame.init(packet_builder_buf, packet_id);
    try protocol.version.writeKeepAlive(&reply.writer, try packet_reader.readI64());
    try enqueueBuiltPacket(clients, index, &reply, compressionState(clients, index).*, write_temp_buf);
}

fn replyPong(clients: *ClientTable, index: usize, payload: []const u8, packet_id: i32, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!void {
    var payload_reader: Io.Reader = .fixed(payload);
    var packet_reader = protocol.PacketReader.init(&payload_reader);
    var reply = try protocol.PacketFrame.init(packet_builder_buf, packet_id);
    try protocol.version.writePong(&reply.writer, try packet_reader.readI32());
    try enqueueBuiltPacket(clients, index, &reply, compressionState(clients, index).*, write_temp_buf);
}

fn handleLoginPacket(clients: *ClientTable, index: usize, phase: *Phase, packet: protocol.Packet, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!void {
    switch (packet.id) {
        packet_ids.login.clientbound.disconnect => return error.ServerDisconnected,
        packet_ids.login.clientbound.encryption_request => return error.OnlineModeUnsupported,
        packet_ids.login.clientbound.login_success => {
            var acknowledge = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.login.serverbound.acknowledged);
            try enqueueBuiltPacket(clients, index, &acknowledge, compressionState(clients, index).*, write_temp_buf);
            phase.* = .configuration;
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.configuration.serverbound.client_information);
            try protocol.version.writeClientInformation(&builder.writer);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);
        },
        packet_ids.login.clientbound.set_compression => {
            if (comptime !protocol.compression_enabled) return error.UnexpectedPacket;
            var payload_reader: Io.Reader = .fixed(packet.payload);
            var packet_reader = protocol.PacketReader.init(&payload_reader);
            compressionState(clients, index).* = .{ .enabled = try packet_reader.readVarInt() };
        },
        else => return error.UnexpectedPacket,
    }
}

fn handleConfigurationPacket(clients: *ClientTable, index: usize, phase: *Phase, packet: protocol.Packet, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!bool {
    switch (packet.id) {
        packet_ids.configuration.clientbound.plugin_message => {},
        packet_ids.configuration.clientbound.disconnect => return error.ServerDisconnected,
        packet_ids.configuration.clientbound.finish => {
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.configuration.serverbound.finish);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);

            phase.* = .play;
            joinedLogged(clients, index).* = true;
        },
        packet_ids.configuration.clientbound.keep_alive => {
            try replyKeepAlive(clients, index, packet.payload, packet_ids.configuration.serverbound.keep_alive, packet_builder_buf, write_temp_buf);
            return true;
        },
        packet_ids.configuration.clientbound.ping => {
            try replyPong(clients, index, packet.payload, packet_ids.configuration.serverbound.pong, packet_builder_buf, write_temp_buf);
        },
        packet_ids.configuration.clientbound.add_resource_pack => {
            var payload_reader: Io.Reader = .fixed(packet.payload);
            var packet_reader = protocol.PacketReader.init(&payload_reader);
            const uuid = try packet_reader.readUuid();
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.configuration.serverbound.resource_pack_response);
            try protocol.version.writeResourcePackResponse(&builder.writer, uuid);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);
        },
        packet_ids.configuration.clientbound.known_packs => {
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.configuration.serverbound.known_packs);
            const include_core = clients.known_core_pack and try offersCurrentCorePack(packet.payload);
            try protocol.version.writeKnownPacks(&builder.writer, include_core);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);
        },
        else => {},
    }
    return false;
}

fn offersCurrentCorePack(payload: []const u8) protocol.PacketError!bool {
    var payload_reader: Io.Reader = .fixed(payload);
    var reader = protocol.PacketReader.init(&payload_reader);
    const count = try reader.readVarInt();
    if (count < 0) return error.NegativeLength;
    var includes_core = false;
    for (0..@as(usize, @intCast(count))) |_| {
        const namespace = try reader.readString(protocol.max_string_chars);
        const id = try reader.readString(protocol.max_string_chars);
        const version = try reader.readString(protocol.max_string_chars);
        includes_core = includes_core or
            (std.mem.eql(u8, namespace, "minecraft") and
                std.mem.eql(u8, id, "core") and
                std.mem.eql(u8, version, protocol.current.minecraft_version));
    }
    return includes_core;
}

test "known core pack matching requires the selected Minecraft version" {
    var buffer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var packet = try protocol.PacketFrame.init(&buffer, 0);
    try packet.writer.writeVarInt(2);
    try packet.writer.writeString("example", protocol.max_string_chars);
    try packet.writer.writeString("other", protocol.max_string_chars);
    try packet.writer.writeString("1", protocol.max_string_chars);
    try packet.writer.writeString("minecraft", protocol.max_string_chars);
    try packet.writer.writeString("core", protocol.max_string_chars);
    try packet.writer.writeString(protocol.current.minecraft_version, protocol.max_string_chars);
    var reader: Io.Reader = .fixed(packet.packetData());
    var packet_reader = protocol.PacketReader.init(&reader);
    _ = try packet_reader.readVarInt();
    try std.testing.expect(try offersCurrentCorePack(packet.packetData()[reader.seek..]));

    packet = try protocol.PacketFrame.init(&buffer, 0);
    try packet.writer.writeVarInt(1);
    try packet.writer.writeString("minecraft", protocol.max_string_chars);
    try packet.writer.writeString("core", protocol.max_string_chars);
    try packet.writer.writeString("wrong-version", protocol.max_string_chars);
    reader = .fixed(packet.packetData());
    packet_reader = protocol.PacketReader.init(&reader);
    _ = try packet_reader.readVarInt();
    try std.testing.expect(!try offersCurrentCorePack(packet.packetData()[reader.seek..]));
}

test "configuration known-pack response advertises the selected core pack when enabled" {
    var phase: Phase = .configuration;
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .username = "Zion0",
        .known_core_pack = true,
    });
    defer test_session.deinit();

    var offer_buffer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer offer_buffer.deinit();
    var offer = try protocol.PacketFrame.init(&offer_buffer, packet_ids.configuration.clientbound.known_packs);
    try offer.writer.writeVarInt(1);
    try offer.writer.writeString("minecraft", protocol.max_string_chars);
    try offer.writer.writeString("core", protocol.max_string_chars);
    try offer.writer.writeString(protocol.current.minecraft_version, protocol.max_string_chars);
    var offer_reader: Io.Reader = .fixed(offer.packetData());
    var offer_packet_reader = protocol.PacketReader.init(&offer_reader);
    _ = try offer_packet_reader.readVarInt();

    _ = try handleConfigurationPacket(
        &test_session.clients,
        0,
        &phase,
        .{ .id = packet_ids.configuration.clientbound.known_packs, .payload = offer.packetData()[offer_reader.seek..] },
        &test_session.packet_builder_buf,
        &test_session.write_temp_buf,
    );

    var response_reader: Io.Reader = .fixed(test_session.writeBufferSlice());
    var response = protocol.PacketReader.init(&response_reader);
    _ = try response.readVarInt();
    try std.testing.expectEqual(packet_ids.configuration.serverbound.known_packs, try response.readVarInt());
    try std.testing.expectEqual(@as(i32, 1), try response.readVarInt());
    try std.testing.expectEqualStrings("minecraft", try response.readString(protocol.max_string_chars));
    try std.testing.expectEqualStrings("core", try response.readString(protocol.max_string_chars));
    try std.testing.expectEqualStrings(protocol.current.minecraft_version, try response.readString(protocol.max_string_chars));
}

fn handlePlayPacket(clients: *ClientTable, index: usize, phase: *Phase, packet: protocol.Packet, packet_builder_buf: *Io.Writer.Allocating, write_temp_buf: *Io.Writer.Allocating) Error!bool {
    switch (packet.id) {
        packet_ids.play.clientbound.disconnect => return error.ServerDisconnected,
        packet_ids.play.clientbound.chunk_batch_finished => {
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.play.serverbound.chunk_batch_received);
            try protocol.version.writeChunkBatchReceived(&builder.writer);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);
        },
        packet_ids.play.clientbound.keep_alive => {
            try replyKeepAlive(clients, index, packet.payload, packet_ids.play.serverbound.keep_alive, packet_builder_buf, write_temp_buf);
            return true;
        },
        packet_ids.play.clientbound.ping => {
            try replyPong(clients, index, packet.payload, packet_ids.play.serverbound.pong, packet_builder_buf, write_temp_buf);
        },
        packet_ids.play.clientbound.player_position => {
            var payload_reader: Io.Reader = .fixed(packet.payload);
            var packet_reader = protocol.PacketReader.init(&payload_reader);
            const teleport_id = try packet_reader.readVarInt();
            if (comptime features.movement) {
                if (clients.movement.profile != .idle) try applyServerPosition(motionState(clients, index), &packet_reader);
            }
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.play.serverbound.accept_teleportation);
            try protocol.version.writeAcceptTeleportation(&builder.writer, teleport_id);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);
        },
        packet_ids.play.clientbound.login => {
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.play.serverbound.player_loaded);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);

            joinedLogged(clients, index).* = true;
        },
        packet_ids.play.clientbound.start_configuration => {
            var builder = try protocol.PacketFrame.init(packet_builder_buf, packet_ids.play.serverbound.configuration_acknowledged);
            try enqueueBuiltPacket(clients, index, &builder, compressionState(clients, index).*, write_temp_buf);
            phase.* = .configuration;
        },
        else => {},
    }
    return false;
}

fn enqueueBuiltPacket(clients: *ClientTable, index: usize, packet: *protocol.PacketFrame, comp: protocol.Compression, write_temp_buf: *Io.Writer.Allocating) Error!void {
    try appendWritePacketFrame(clients, index, packet.packetData(), comp, write_temp_buf);
}

const CachedPacketKind = enum { broadcast, client_tick };

fn enqueueCachedPacket(clients: *ClientTable, index: usize, comptime kind: CachedPacketKind) Error!void {
    const packet = switch (kind) {
        .broadcast => if (comptime features.broadcast) clients.broadcast_packet.? else unreachable,
        .client_tick => if (comptime features.client_tick) clients.client_tick_packet.? else unreachable,
    };

    const variant: enum { plain, uncompressed, compressed } = if (comptime !protocol.compression_enabled)
        .plain
    else switch (compressionState(clients, index).*) {
        .disabled => .plain,
        .enabled => |threshold| if (threshold > 0 and packet.body.len < @as(usize, @intCast(threshold))) .uncompressed else .compressed,
    };
    const source: outbound.SharedSource = switch (kind) {
        .broadcast => switch (variant) {
            .plain => .broadcast_plain,
            .uncompressed => .broadcast_uncompressed,
            .compressed => .broadcast_compressed,
        },
        .client_tick => switch (variant) {
            .plain => .client_tick_plain,
            .uncompressed => .client_tick_uncompressed,
            .compressed => .client_tick_compressed,
        },
    };
    const frame = switch (variant) {
        .plain => packet.frame,
        .uncompressed => if (comptime protocol.compression_enabled) packet.uncompressed_frame else unreachable,
        .compressed => if (comptime protocol.compression_enabled) packet.compressed_frame else unreachable,
    };
    writeState(clients, index).enqueueShared(source, frame.len) catch return error.WriteBufferLimitExceeded;
}

fn appendWritePacketFrame(clients: *ClientTable, index: usize, packet_data: []const u8, comp: protocol.Compression, write_temp_buf: *Io.Writer.Allocating) Error!void {
    write_temp_buf.clearRetainingCapacity();
    try protocol.appendPacketFrame(clients.allocator, write_temp_buf, packet_data, comp);
    try appendWriteBufferSlice(clients, index, write_temp_buf.written());
}

pub const TestSession = struct {
    allocator: std.mem.Allocator,
    clients: ClientTable,
    decompress_buf: if (protocol.compression_enabled) std.ArrayList(u8) else void,
    decompress_window: if (protocol.compression_enabled) []u8 else void,
    packet_builder_buf: Io.Writer.Allocating,
    write_temp_buf: Io.Writer.Allocating,

    pub const TestConfig = struct {
        host: []const u8,
        port: u16 = 25565,
        username: []const u8,
        global_index: u32 = 0,
        movement: if (features.movement) MovementConfig else void = if (features.movement) .{} else {},
        known_core_pack: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, config: TestConfig) !TestSession {
        const decompress_window = if (comptime protocol.compression_enabled)
            try allocator.alloc(u8, std.compress.flate.max_window_len)
        else {};
        if (comptime protocol.compression_enabled) {
            errdefer allocator.free(decompress_window);
        }

        var clients: ClientTable = .{
            .allocator = allocator,
            .handshake_host = config.host,
            .handshake_port = config.port,
            .movement = if (comptime features.movement) config.movement else {},
            .known_core_pack = config.known_core_pack,
            .username_override = config.username,
        };
        errdefer clients.deinit(allocator);
        try clients.ensureTotalCapacity(allocator, 1);
        clients.appendAssumeCapacity(config.global_index, 0);

        return TestSession{
            .allocator = allocator,
            .clients = clients,
            .decompress_buf = if (comptime protocol.compression_enabled) std.ArrayList(u8).empty else {},
            .decompress_window = decompress_window,
            .packet_builder_buf = .init(allocator),
            .write_temp_buf = .init(allocator),
        };
    }

    pub fn deinit(self: *TestSession) void {
        if (comptime protocol.compression_enabled) {
            self.decompress_buf.deinit(self.allocator);
            self.allocator.free(self.decompress_window);
        }
        self.packet_builder_buf.deinit();
        self.write_temp_buf.deinit();
        self.clients.deinit(self.allocator);
    }

    pub fn writeBufferSlice(self: *TestSession) []const u8 {
        return resolvePendingWrite(&self.clients, self.clients.sessions.slice().items(.write)[0].peek());
    }

    pub fn clearWriteBuffer(self: *TestSession) void {
        self.clients.sessions.slice().items(.write)[0].clearRetainingCapacity();
    }
};

pub fn buildClientTickPacket(allocator: std.mem.Allocator) Error!CachedPacket {
    var buffer: Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    var packet = try protocol.PacketFrame.init(&buffer, packet_ids.play.serverbound.client_tick_end);
    return try CachedPacket.initOwned(allocator, try packet.takePacketData());
}

pub fn buildChatBroadcastPacket(allocator: std.mem.Allocator, message: []const u8, real_ms: i64) Error!CachedPacket {
    var buffer: Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    var packet = try protocol.PacketFrame.init(&buffer, packet_ids.play.serverbound.chat);
    try protocol.version.writeChatMessage(&packet.writer, message, real_ms);
    return try CachedPacket.initOwned(allocator, try packet.takePacketData());
}

fn minDeadline(current: ?u64, candidate: u64) ?u64 {
    if (candidate == no_deadline) return current;
    return if (current) |value| @min(value, candidate) else candidate;
}

fn staggerOffsetMs(index: u32, client_count: usize, interval_ms: u64) u64 {
    if (client_count == 0 or interval_ms == 0) return 0;
    const count: u64 = @intCast(client_count);
    return @intCast((@as(u128, index % count) * interval_ms) / count);
}

test "staggerOffsetMs spreads clients across one interval" {
    try std.testing.expectEqual(@as(u64, 0), staggerOffsetMs(0, 100, 2000));
    try std.testing.expectEqual(@as(u64, 20), staggerOffsetMs(1, 100, 2000));
    try std.testing.expectEqual(@as(u64, 1980), staggerOffsetMs(99, 100, 2000));
    try std.testing.expectEqual(@as(u64, 0), staggerOffsetMs(0, 100, 0));
}

fn mixSeed(seed: u64, index: u32) u64 {
    if (comptime !features.movement) return 0;
    var value = seed +% (@as(u64, @intCast(index)) *% 0x9e3779b97f4a7c15) +% 0x9e3779b97f4a7c15;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return value ^ (value >> 31);
}

fn randomUnit(state: *MotionState) f64 {
    state.rng +%= 0x9e3779b97f4a7c15;
    var value = state.rng;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    value ^= value >> 31;
    return @as(f64, @floatFromInt(value >> 11)) * (1.0 / 9007199254740992.0);
}

fn wrapDegrees(angle: f32) f32 {
    var result = @mod(angle + 180.0, 360.0);
    if (result < 0) result += 360.0;
    return result - 180.0;
}

fn approachAngle(current: f32, target: f32, maximum: f32) f32 {
    // Motion state keeps both angles in [-180, 180), so each difference and
    // sum can cross the boundary at most once. Avoid general floating modulo
    // in this per-client hot path.
    var delta = target - current;
    if (delta >= 180.0) {
        delta -= 360.0;
    } else if (delta < -180.0) {
        delta += 360.0;
    }
    delta = std.math.clamp(delta, -maximum, maximum);

    var result = current + delta;
    if (result >= 180.0) {
        result -= 360.0;
    } else if (result < -180.0) {
        result += 360.0;
    }
    return result;
}

fn chooseMotionTarget(comptime profile: MovementProfile, state: *MotionState, config: MovementConfig, now_ms: u64) void {
    if (comptime profile == .walk) {
        const angle = randomUnit(state) * 2.0 * std.math.pi;
        const distance = @sqrt(randomUnit(state)) * config.radius;
        state.target_x = state.origin_x + @cos(angle) * distance;
        state.target_z = state.origin_z + @sin(angle) * distance;
    } else {
        // Preserve the deterministic random sequence without doing unused
        // position and trigonometry work for rotation-only clients.
        _ = randomUnit(state);
        _ = randomUnit(state);
    }
    const random_yaw: f32 = @floatCast(randomUnit(state) * 360.0 - 180.0);
    state.target_yaw = if (comptime profile == .walk)
        @floatCast(std.math.atan2(state.x - state.target_x, state.target_z - state.z) * 180.0 / std.math.pi)
    else
        random_yaw;
    state.target_pitch = @floatCast(randomUnit(state) * 30.0 - 15.0);
    state.next_decision_ms = now_ms + 500 + @as(u64, @intFromFloat(randomUnit(state) * 1500.0));
    state.has_target = true;
}

fn updateMotion(comptime profile: MovementProfile, state: *MotionState, config: MovementConfig, now_ms: u64) void {
    if (!state.has_target or now_ms >= state.next_decision_ms) chooseMotionTarget(profile, state, config, now_ms);
    const elapsed_ms = if (state.last_update_ms == 0) config.interval_ms else @min(now_ms -| state.last_update_ms, 250);
    state.last_update_ms = now_ms;
    const elapsed = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

    if (comptime profile == .walk) {
        const dx = state.target_x - state.x;
        const dz = state.target_z - state.z;
        const distance = @sqrt(dx * dx + dz * dz);
        if (distance < 0.05) {
            state.has_target = false;
        } else {
            const step = @min(config.speed * elapsed, distance);
            state.x += dx / distance * step;
            state.z += dz / distance * step;
        }
    }

    const max_turn = config.rotation_rate * @as(f32, @floatCast(elapsed));
    state.yaw = approachAngle(state.yaw, state.target_yaw, max_turn);
    state.pitch += std.math.clamp(state.target_pitch - state.pitch, -max_turn, max_turn);
    state.pitch = std.math.clamp(state.pitch, -90.0, 90.0);
}

fn applyServerPosition(state: *MotionState, reader: *protocol.PacketReader) protocol.PacketError!void {
    const incoming_x = try reader.readF64();
    const incoming_y = try reader.readF64();
    const incoming_z = try reader.readF64();
    _ = try reader.readF64();
    _ = try reader.readF64();
    _ = try reader.readF64();
    const incoming_yaw = try reader.readF32();
    const incoming_pitch = try reader.readF32();
    const relative_flags = try reader.readI32();

    state.x = if ((relative_flags & (1 << 0)) != 0) state.x + incoming_x else incoming_x;
    state.y = if ((relative_flags & (1 << 1)) != 0) state.y + incoming_y else incoming_y;
    state.z = if ((relative_flags & (1 << 2)) != 0) state.z + incoming_z else incoming_z;
    state.yaw = wrapDegrees(if ((relative_flags & (1 << 3)) != 0) state.yaw + incoming_yaw else incoming_yaw);
    state.pitch = std.math.clamp(if ((relative_flags & (1 << 4)) != 0) state.pitch + incoming_pitch else incoming_pitch, -90.0, 90.0);
    if (!state.initialized) {
        state.origin_x = state.x;
        state.origin_z = state.z;
        state.initialized = true;
    }
    state.has_target = false;
    state.last_update_ms = 0;
}

fn peekVarInt(buffer: []const u8) ?struct { value: i32, consumed: usize } {
    var value: u32 = 0;
    var shift: u5 = 0;
    for (buffer[0..@min(buffer.len, 5)], 0..) |byte, i| {
        value |= @as(u32, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) {
            return .{ .value = @bitCast(value), .consumed = i + 1 };
        }
        if (i == 4) break;
        shift += 7;
    }
    return null;
}

fn isHandledPlayPacket(packet_id: i32) bool {
    return switch (packet_id) {
        packet_ids.play.clientbound.chunk_batch_finished,
        packet_ids.play.clientbound.disconnect,
        packet_ids.play.clientbound.keep_alive,
        packet_ids.play.clientbound.login,
        packet_ids.play.clientbound.ping,
        packet_ids.play.clientbound.player_position,
        packet_ids.play.clientbound.start_configuration,
        => true,
        else => false,
    };
}

const Frame = struct {
    bytes: []const u8,
    consumed: usize,
};

fn nextFrame(buffer: []const u8) Error!?Frame {
    if (peekVarInt(buffer)) |res| {
        if (res.value < 0) return error.NegativeLength;
        if (res.value > protocol.max_packet_len) return error.PacketTooLarge;
        const len: usize = @intCast(res.value);
        const end = res.consumed + len;
        if (buffer.len < end) return null;
        return .{
            .bytes = buffer[res.consumed..end],
            .consumed = end,
        };
    }
    if (buffer.len < 5) return null;
    return error.VarIntTooLong;
}

test "Session.onConnected queues login bytes without a socket read loop" {
    var phase: Phase = .disconnected;
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();

    if (comptime stats_module.diagnostics_enabled) {
        const client_stats = test_session.clients.stats.slice();
        client_stats.items(.last_packet_id)[0] = 42;
        client_stats.items(.keep_alives_answered)[0] = 3;
    }
    try onConnected(&test_session.clients, 0, &phase, 100, &test_session.packet_builder_buf, &test_session.write_temp_buf);

    try std.testing.expectEqual(Phase.login, phase);
    try std.testing.expect(wantsWrite(&test_session.clients, 0));
    try std.testing.expect(test_session.writeBufferSlice().len > 0);
    if (comptime stats_module.diagnostics_enabled) {
        const client_stats = test_session.clients.stats.slice();
        try std.testing.expectEqual(@as(i32, -1), client_stats.items(.last_packet_id)[0]);
        try std.testing.expectEqual(@as(u32, 0), client_stats.items(.keep_alives_answered)[0]);
    }
}

test "movement applies absolute and relative server positions" {
    if (comptime !features.movement) return error.SkipZigTest;
    var buffer: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var builder = try protocol.PacketFrame.init(&buffer, 0);
    try builder.writer.writeF64(10);
    try builder.writer.writeF64(64);
    try builder.writer.writeF64(-5);
    try builder.writer.writeF64(0);
    try builder.writer.writeF64(0);
    try builder.writer.writeF64(0);
    try builder.writer.writeF32(90);
    try builder.writer.writeF32(10);
    try builder.writer.writeI32(0);
    var payload_reader: Io.Reader = .fixed(builder.packetData()[1..]);
    var reader = protocol.PacketReader.init(&payload_reader);
    var state: MotionState = .{};
    try applyServerPosition(&state, &reader);
    try std.testing.expectEqual(@as(f64, 10), state.x);
    try std.testing.expectEqual(@as(f64, 64), state.y);
    try std.testing.expectEqual(@as(f64, -5), state.z);
    try std.testing.expect(state.initialized);

    builder = try protocol.PacketFrame.init(&buffer, 0);
    try builder.writer.writeF64(2);
    try builder.writer.writeF64(0);
    try builder.writer.writeF64(3);
    try builder.writer.writeF64(0);
    try builder.writer.writeF64(0);
    try builder.writer.writeF64(0);
    try builder.writer.writeF32(15);
    try builder.writer.writeF32(-5);
    try builder.writer.writeI32((1 << 0) | (1 << 2) | (1 << 3) | (1 << 4));
    payload_reader = .fixed(builder.packetData()[1..]);
    reader = protocol.PacketReader.init(&payload_reader);
    try applyServerPosition(&state, &reader);
    try std.testing.expectEqual(@as(f64, 12), state.x);
    try std.testing.expectEqual(@as(f64, -2), state.z);
    try std.testing.expectEqual(@as(f32, 105), state.yaw);
    try std.testing.expectEqual(@as(f32, 5), state.pitch);
}

test "bounded walk remains inside its configured radius" {
    if (comptime !features.movement) return error.SkipZigTest;
    const config: MovementConfig = .{ .profile = .walk, .interval_ms = 50, .radius = 8, .speed = 4.3, .seed = 7 };
    var state: MotionState = .{ .x = 4, .y = 64, .z = -3, .origin_x = 4, .origin_z = -3, .rng = mixSeed(config.seed, 42), .initialized = true };
    for (1..2001) |tick| {
        updateMotion(.walk, &state, config, @intCast(tick * config.interval_ms));
        const dx = state.x - state.origin_x;
        const dz = state.z - state.origin_z;
        try std.testing.expect(dx * dx + dz * dz <= config.radius * config.radius + 0.0001);
        try std.testing.expect(state.pitch >= -90 and state.pitch <= 90);
    }
}

test "bounded angle approach matches general degree wrapping" {
    const reference = struct {
        fn approach(current: f32, target: f32, maximum: f32) f32 {
            const delta = std.math.clamp(wrapDegrees(target - current), -maximum, maximum);
            return wrapDegrees(current + delta);
        }
    };
    const maxima = [_]f32{ 0.5, 5.0, 90.0, 180.0, 1000.0 };
    var current: f32 = -180.0;
    while (current < 180.0) : (current += 5.0) {
        var target: f32 = -180.0;
        while (target < 180.0) : (target += 5.0) {
            for (maxima) |maximum| {
                try std.testing.expectApproxEqAbs(reference.approach(current, target, maximum), approachAngle(current, target, maximum), 0.0001);
            }
        }
    }
}

test "Session.onReadBytes parses complete frames without retaining input" {
    const allocator = std.testing.allocator;
    var phase: Phase = .disconnected;
    var test_session = try TestSession.init(allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();
    try onConnected(&test_session.clients, 0, &phase, 100, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    test_session.clearWriteBuffer();

    var packet = try protocol.PacketFrame.init(&test_session.packet_builder_buf, packet_ids.login.clientbound.login_success);
    const frame = try packet.finish(.disabled);
    defer allocator.free(frame);

    _ = try onReadBytes(&test_session.clients, 0, &phase, frame, &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);

    try std.testing.expectEqual(Phase.configuration, phase);
    try std.testing.expectEqual(@as(usize, 0), readBufferSlice(&test_session.clients, 0).len);
}

test "Session.onReadBytes retains only fragmented tails" {
    const allocator = std.testing.allocator;
    var phase: Phase = .disconnected;
    var test_session = try TestSession.init(allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();
    try onConnected(&test_session.clients, 0, &phase, 100, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    test_session.clearWriteBuffer();

    var packet = try protocol.PacketFrame.init(&test_session.packet_builder_buf, packet_ids.login.clientbound.login_success);
    const frame = try packet.finish(.disabled);
    defer allocator.free(frame);

    _ = try onReadBytes(&test_session.clients, 0, &phase, frame[0..1], &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    try std.testing.expectEqual(@as(usize, 1), readBufferSlice(&test_session.clients, 0).len);
    try std.testing.expectEqual(@as(u32, initial_read_buffer_size), readState(&test_session.clients, 0).capacity);
    try std.testing.expectEqual(@as(usize, initial_read_buffer_size), test_session.clients.read_buffer_bytes);
    try std.testing.expectEqual(Phase.login, phase);

    _ = try onReadBytes(&test_session.clients, 0, &phase, frame[1..], &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);

    try std.testing.expectEqual(Phase.configuration, phase);
    try std.testing.expectEqual(@as(usize, 0), readBufferSlice(&test_session.clients, 0).len);
    try std.testing.expectEqual(@as(usize, 0), test_session.clients.read_buffer_bytes);
}

test "fragment buffering obeys the shard memory budget" {
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();
    test_session.clients.read_buffer_limit = initial_read_buffer_size;

    var bytes: [initial_read_buffer_size + 1]u8 = @splat(0);
    try std.testing.expectError(error.ReadBufferLimitExceeded, appendReadBufferSlice(&test_session.clients, 0, &bytes));
    try std.testing.expectEqual(@as(usize, 0), test_session.clients.read_buffer_bytes);
    try std.testing.expectEqual(@as(?[*]u8, null), readState(&test_session.clients, 0).buffer);
}

test "fragmented ignored play packets are discarded without allocation" {
    var phase: Phase = .play;
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();

    // A 1 MiB uncompressed play packet with an unhandled packet id. Only its
    // prefix is present; the remainder should be counted down across receives.
    const prefix = [_]u8{ 0x80, 0x80, 0x40, 0x01 };
    const result = try onReadBytes(&test_session.clients, 0, &phase, &prefix, &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    try std.testing.expectEqual(@as(usize, prefix.len), result.bytes);
    try std.testing.expectEqual(@as(usize, 1), result.packets);
    try std.testing.expect(!result.effects.write_ready);
    try std.testing.expect(!result.effects.deadline_changed);
    try std.testing.expect(!result.effects.progress_changed);
    try std.testing.expectEqual(@as(?[*]u8, null), readState(&test_session.clients, 0).buffer);
    try std.testing.expectEqual(@as(u32, 1024 * 1024 - 1), readState(&test_session.clients, 0).discard_remaining);

    const payload: [16]u8 = @splat(0);
    _ = try onReadBytes(&test_session.clients, 0, &phase, &payload, &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    try std.testing.expectEqual(@as(u32, 1024 * 1024 - 17), readState(&test_session.clients, 0).discard_remaining);
    try std.testing.expectEqual(@as(usize, 0), test_session.clients.read_buffer_bytes);
}

test "fragmented compressed play packets are discarded without allocation" {
    if (comptime !protocol.compression_enabled) return error.SkipZigTest;

    var phase: Phase = .play;
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();
    compressionState(&test_session.clients, 0).* = .{ .enabled = 0 };

    var payload: [4096]u8 = undefined;
    var random: u32 = 0x1234_5678;
    for (&payload) |*byte| {
        random = random *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(random >> 16);
    }
    var packet = try protocol.PacketFrame.init(&test_session.packet_builder_buf, 0x01);
    try packet.writer.writeBytes(&payload);
    const frame = try packet.finish(.{ .enabled = 0 });
    defer std.testing.allocator.free(frame);
    const split = frame.len / 2;

    _ = try onReadBytes(&test_session.clients, 0, &phase, frame[0..split], &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    try std.testing.expectEqual(@as(?[*]u8, null), readState(&test_session.clients, 0).buffer);
    try std.testing.expectEqual(@as(u32, @intCast(frame.len - split)), readState(&test_session.clients, 0).discard_remaining);
    try std.testing.expectEqual(@as(usize, 0), test_session.clients.read_buffer_bytes);
}

test "compressed play keep alive is decoded and queued" {
    if (comptime !protocol.compression_enabled) return error.SkipZigTest;

    var phase: Phase = .disconnected;
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();
    try onConnected(&test_session.clients, 0, &phase, 100, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    test_session.clearWriteBuffer();
    phase = .play;
    compressionState(&test_session.clients, 0).* = .{ .enabled = 0 };

    var packet = try protocol.PacketFrame.init(&test_session.packet_builder_buf, packet_ids.play.clientbound.keep_alive);
    try packet.writer.writeI64(0x0102_0304_0506_0708);
    const frame = try packet.finish(.{ .enabled = 0 });
    defer std.testing.allocator.free(frame);

    const result = try onReadBytes(&test_session.clients, 0, &phase, frame, &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    try std.testing.expectEqual(@as(usize, 1), result.keep_alives);
    try std.testing.expect(result.effects.write_ready);
    try std.testing.expect(!result.effects.deadline_changed);
    try std.testing.expect(!result.effects.progress_changed);
    try std.testing.expect(wantsWrite(&test_session.clients, 0));
}

test "outbound buffering has one aggregate per-client limit" {
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();

    const bytes = try std.testing.allocator.alloc(u8, max_queued_write_bytes + 1);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.WriteBufferLimitExceeded, appendWriteBufferSlice(&test_session.clients, 0, bytes));
    try std.testing.expectEqual(@as(?[*]u8, null), writeState(&test_session.clients, 0).owned_buffers[0]);
    try std.testing.expectEqual(@as(?[*]u8, null), writeState(&test_session.clients, 0).owned_buffers[1]);
}

test "cached packets retain an immutable fully compressed frame" {
    if (comptime !protocol.compression_enabled) return error.SkipZigTest;

    const body = try std.testing.allocator.dupe(u8, &.{ 0x01, 0x02, 0x03, 0x04 });
    const cached = try CachedPacket.initOwned(std.testing.allocator, body);
    defer cached.deinit(std.testing.allocator);

    var decompressed = std.ArrayList(u8).empty;
    defer decompressed.deinit(std.testing.allocator);
    const window = try std.testing.allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.testing.allocator.free(window);

    var frame_reader: Io.Reader = .fixed(cached.compressed_frame);
    var packet_reader = protocol.PacketReader.init(&frame_reader);
    const frame_len = try packet_reader.readVarInt();
    const packet = try protocol.readPacketFrame(
        std.testing.allocator,
        cached.compressed_frame[frame_reader.seek .. frame_reader.seek + @as(usize, @intCast(frame_len))],
        .{ .enabled = 0 },
        &decompressed,
        window,
    );
    try std.testing.expectEqual(@as(i32, 0x01), packet.id);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0x04 }, packet.payload);
}

test "cached packets retain an uncompressed frame for compression mode" {
    if (comptime !protocol.compression_enabled) return error.SkipZigTest;

    const body = try std.testing.allocator.dupe(u8, &.{ 0x01, 0x02, 0x03, 0x04 });
    const cached = try CachedPacket.initOwned(std.testing.allocator, body);
    defer cached.deinit(std.testing.allocator);

    var frame_reader: Io.Reader = .fixed(cached.uncompressed_frame);
    var packet_reader = protocol.PacketReader.init(&frame_reader);
    const frame_len = try packet_reader.readVarInt();
    const packet = try protocol.readPacketFrame(
        std.testing.allocator,
        cached.uncompressed_frame[frame_reader.seek .. frame_reader.seek + @as(usize, @intCast(frame_len))],
        .{ .enabled = 256 },
        null,
        null,
    );
    try std.testing.expectEqual(@as(i32, 0x01), packet.id);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0x04 }, packet.payload);
}

test "optional movement traffic is dropped while a send is in flight" {
    if (comptime !features.movement) return error.SkipZigTest;
    var phase: Phase = .disconnected;
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Zion0",
    });
    defer test_session.deinit();
    try onConnected(&test_session.clients, 0, &phase, 100, &test_session.packet_builder_buf, &test_session.write_temp_buf);
    _ = beginWrite(&test_session.clients, 0);
    phase = .play;
    timerState(&test_session.clients, 0).next_movement_ms = 100;

    try std.testing.expect(!try onTimer(&test_session.clients, 0, &phase, 100, &test_session.packet_builder_buf, &test_session.write_temp_buf));
    try std.testing.expectEqual(@as(u8, 1), writeState(&test_session.clients, 0).segmentCount());
    try std.testing.expectEqual(@as(u64, 1100), timerState(&test_session.clients, 0).next_movement_ms);
}

test "Session drains fragmented login compression packet" {
    if (comptime !protocol.compression_enabled) {
        return error.SkipZigTest;
    } else {
        const allocator = std.testing.allocator;
        var phase: Phase = .disconnected;
        var test_session = try TestSession.init(allocator, .{
            .host = "127.0.0.1",
            .port = 25565,
            .username = "Zion0",
        });
        defer test_session.deinit();
        try onConnected(&test_session.clients, 0, &phase, 100, &test_session.packet_builder_buf, &test_session.write_temp_buf);
        test_session.clearWriteBuffer();

        var packet = try protocol.PacketFrame.init(&test_session.packet_builder_buf, packet_ids.login.clientbound.set_compression);
        try packet.writer.writeVarInt(256);
        const frame = try packet.finish(.disabled);
        defer allocator.free(frame);

        try appendReadBufferSlice(&test_session.clients, 0, frame[0..1]);
        _ = try drainPackets(&test_session.clients, 0, &phase, &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);
        try std.testing.expectEqual(protocol.Compression.disabled, compressionState(&test_session.clients, 0).*);

        try appendReadBufferSlice(&test_session.clients, 0, frame[1..]);
        _ = try drainPackets(&test_session.clients, 0, &phase, &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf);
        try std.testing.expectEqual(protocol.Compression{ .enabled = 256 }, compressionState(&test_session.clients, 0).*);
    }
}

test "Session frame parser rejects five continuation bytes without overflowing" {
    try std.testing.expectError(error.VarIntTooLong, nextFrame(&.{ 0xff, 0xff, 0xff, 0xff, 0xff }));
}

test "Session fuzzes packet draining with Smith" {
    try std.testing.fuzz({}, fuzzSessionDrainPackets, .{
        .corpus = &.{
            // login + raw + a five-byte continuation VarInt
            "\x00\x00\x00\x00\x00\x00\x00\x00" ++
                "\x00\x00\x00\x00\x00\x00\x00\x00" ++
                "\x05\x00\x00\x00\xff\xff\xff\xff\xff",
            // login + known packet + a zero compression threshold
            "\x00\x00\x00\x00\x00\x00\x00\x00" ++
                "\x02\x00\x00\x00\x00\x00\x00\x00" ++
                "\x01\x00\x00\x00\x00",
        },
    });
}

fn fuzzSessionDrainPackets(_: void, smith: *std.testing.Smith) anyerror!void {
    const PhaseSeed = enum(u2) {
        login,
        configuration,
        play,
    };

    var phase: Phase = switch (smith.value(PhaseSeed)) {
        .login => .login,
        .configuration => .configuration,
        .play => .play,
    };
    var test_session = try TestSession.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 25565,
        .username = "Fuzz",
    });
    defer test_session.deinit();

    const InputShape = enum(u2) {
        raw,
        framed_random_packet,
        framed_known_packet,
    };

    var payload_buf: [256]u8 = undefined;
    switch (smith.value(InputShape)) {
        .raw => {
            const len: usize = smith.slice(&payload_buf);
            try appendReadBufferSlice(&test_session.clients, 0, payload_buf[0..len]);
        },
        .framed_random_packet => {
            var packet = try protocol.PacketFrame.init(&test_session.packet_builder_buf, smith.value(i16));
            const len: usize = smith.slice(&payload_buf);
            try packet.writer.writeBytes(payload_buf[0..len]);
            const frame = try packet.finish(.disabled);
            defer std.testing.allocator.free(frame);
            try appendReadBufferSlice(&test_session.clients, 0, frame);
        },
        .framed_known_packet => {
            const id: i32 = switch (phase) {
                .login => packet_ids.login.clientbound.set_compression,
                .configuration => packet_ids.configuration.clientbound.keep_alive,
                .play => packet_ids.play.clientbound.keep_alive,
                else => 0,
            };
            var packet = try protocol.PacketFrame.init(&test_session.packet_builder_buf, id);
            const len: usize = smith.slice(&payload_buf);
            try packet.writer.writeBytes(payload_buf[0..len]);
            const frame = try packet.finish(.disabled);
            defer std.testing.allocator.free(frame);
            try appendReadBufferSlice(&test_session.clients, 0, frame);
        },
    }

    _ = drainPackets(&test_session.clients, 0, &phase, &test_session.decompress_buf, test_session.decompress_window, &test_session.packet_builder_buf, &test_session.write_temp_buf) catch |err| switch (err) {
        error.Disconnected,
        error.ServerDisconnected,
        error.EndOfStream,
        error.MalformedPacket,
        error.NegativeLength,
        error.OnlineModeUnsupported,
        error.PacketTooLarge,
        error.StringTooLong,
        error.UnexpectedPacket,
        error.VarIntTooLong,
        => {},
        else => return err,
    };
}
