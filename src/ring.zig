const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

pub const min_ring_entries: u16 = 64;
pub const max_ring_entries: u16 = 32768;
pub const min_recv_buffers: u16 = 64;
pub const max_recv_buffers: u16 = 256;
pub const bundled_min_recv_buffers: u16 = 512;
// The provided-buffer ring is shared by every client on a shard and is only
// replenished after userspace retires each completion, so it must be sized well
// above the client count or bursts drain it and recv completions start failing
// with ENOBUFS. Scale with the client count up to this ceiling (64 MiB of 4 KiB
// buffers) instead of flatlining at a low cap.
pub const bundled_max_recv_buffers: u16 = 16384;
pub const ordinary_recv_buffer_size: u32 = 16 * 1024;
pub const bundled_recv_buffer_size: u32 = 4 * 1024;
pub const completion_batch_size: u32 = 32;
pub const completion_batch_wait_us: u32 = 50;

// Set once per process to the shared stop flag so the blocking retry loops here
// can bail on a pending shutdown instead of spinning on repeated EINTR.
var stop_signal: ?*const std.atomic.Value(bool) = null;

pub fn setStopSignal(flag: *const std.atomic.Value(bool)) void {
    stop_signal = flag;
}

fn stopRequested() bool {
    return if (stop_signal) |flag| flag.load(.monotonic) else false;
}

// Feature bits std.os.linux does not define yet.
const IORING_FEAT_RECVSEND_BUNDLE: u32 = 1 << 14;
const IORING_FEAT_MIN_TIMEOUT: u32 = 1 << 15;

const GetEventsArg = extern struct {
    sigmask: u64 = 0,
    sigmask_sz: u32 = 0,
    min_wait_usec: u32 = 0,
    ts: u64 = 0,
};

pub const CompletionKind = enum(u8) {
    timeout = 1,
    recv = 2,
    send = 3,
    connect = 4,
    socket = 5,
    socket_option = 6,
    close = 7,
    poll = 8,
};

pub const CompletionKey = struct {
    kind: CompletionKind,
    generation: u16,
    index: usize,
};

/// Bit layout of an SQE `user_data` word.
const PackedKey = packed struct(u64) {
    index: u40,
    generation: u16,
    kind: u8,
};

pub fn packCompletionKey(key: CompletionKey) u64 {
    std.debug.assert(key.index <= std.math.maxInt(u40));
    return @bitCast(PackedKey{
        .index = @intCast(key.index),
        .generation = key.generation,
        .kind = @intFromEnum(key.kind),
    });
}

pub fn unpackCompletionKey(value: u64) ?CompletionKey {
    const key: PackedKey = @bitCast(value);
    return .{
        .kind = std.enums.fromInt(CompletionKind, key.kind) orelse return null,
        .generation = key.generation,
        .index = key.index,
    };
}

pub fn openUring(client_count: usize) !IoUring {
    const entries = ioUringEntries(client_count);
    // Multishot recv can complete in bursts far beyond the default 2x CQ; a 4x
    // CQ absorbs them without overflow (the kernel caps CQ size at 2x its
    // maximum SQ size, so clamp accordingly).
    const cq_entries: u32 = @intCast(@min(@as(u32, entries) *| 4, 2 * @as(u32, max_ring_entries)));
    const base_flags = linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_CQSIZE;
    var ring = initWithCqSize(entries, base_flags | linux.IORING_SETUP_DEFER_TASKRUN, cq_entries) catch |err| switch (err) {
        error.ArgumentsInvalid => try initWithCqSize(entries, base_flags, cq_entries),
        else => return err,
    };
    errdefer ring.deinit();
    // Timed waits rely on IORING_ENTER_EXT_ARG unconditionally; the feature
    // exists since kernel 5.11, far below the documented 6.7 kernel floor.
    if ((ring.features & linux.IORING_FEAT_EXT_ARG) == 0) return error.IoUringExtArgUnsupported;
    return ring;
}

fn initWithCqSize(entries: u16, flags: u32, cq_entries: u32) !IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = flags,
        .sq_thread_idle = 1000,
        .cq_entries = cq_entries,
    });
    return IoUring.init_params(entries, &params);
}

pub fn ioUringEntries(client_count: usize) u16 {
    return boundedPowerOfTwo(client_count *| 4 +| 64, min_ring_entries, max_ring_entries);
}

pub fn recvBufferCount(client_count: usize) u16 {
    return boundedPowerOfTwo(client_count, min_recv_buffers, max_recv_buffers);
}

fn boundedPowerOfTwo(wanted: usize, minimum: u16, maximum: u16) u16 {
    const clamped = std.math.clamp(wanted, minimum, maximum);
    return @min(std.math.ceilPowerOfTwoAssert(usize, clamped), maximum);
}

pub const RecvLayout = struct {
    buffer_size: u32,
    buffer_count: u16,
    bundled: bool,
};

pub fn recvLayout(ring: *const IoUring, client_count: usize) RecvLayout {
    const bundled = (ring.features & IORING_FEAT_RECVSEND_BUNDLE) != 0;
    if (!bundled) return .{
        .buffer_size = ordinary_recv_buffer_size,
        .buffer_count = recvBufferCount(client_count),
        .bundled = false,
    };
    return .{
        .buffer_size = bundled_recv_buffer_size,
        .buffer_count = boundedPowerOfTwo(client_count, bundled_min_recv_buffers, bundled_max_recv_buffers),
        .bundled = true,
    };
}

pub const RecvSlice = struct {
    buffer_id: u16,
    len: usize,
};

pub const RecvBatch = struct {
    next_id: u16,
    remaining: usize,
    buffer_size: u32,
    buffer_count: u16,

    pub fn init(start_id: u16, total_len: usize, buffer_size: u32, buffer_count: u16) error{InvalidBatch}!RecvBatch {
        // Power-of-two counts (guaranteed by boundedPowerOfTwo) let next() wrap
        // with a mask; a runtime `%` would emit a hardware divide per slice.
        if (buffer_size == 0 or !std.math.isPowerOfTwo(buffer_count) or start_id >= buffer_count or total_len == 0) return error.InvalidBatch;
        if (total_len > @as(usize, buffer_size) * buffer_count) return error.InvalidBatch;
        return .{
            .next_id = start_id,
            .remaining = total_len,
            .buffer_size = buffer_size,
            .buffer_count = buffer_count,
        };
    }

    pub fn next(self: *RecvBatch) ?RecvSlice {
        if (self.remaining == 0) return null;
        const len = @min(self.remaining, self.buffer_size);
        const result: RecvSlice = .{ .buffer_id = self.next_id, .len = len };
        self.remaining -= len;
        self.next_id = (self.next_id + 1) & (self.buffer_count - 1);
        return result;
    }
};

pub const RecvBufferGroup = struct {
    ring: *IoUring,
    br: *align(std.heap.page_size_min) linux.io_uring_buf_ring,
    buffers: []u8,
    buffer_size: u32,
    buffer_count: u16,
    group_id: u16,
    bundled: bool,

    pub fn init(ring: *IoUring, allocator: std.mem.Allocator, group_id: u16, layout: RecvLayout) !RecvBufferGroup {
        const buffers = try allocator.alloc(u8, @as(usize, layout.buffer_size) * layout.buffer_count);
        errdefer allocator.free(buffers);
        const br = try IoUring.setup_buf_ring(ring.fd, layout.buffer_count, group_id, .{ .inc = false });
        IoUring.buf_ring_init(br);
        const group: RecvBufferGroup = .{
            .ring = ring,
            .br = br,
            .buffers = buffers,
            .buffer_size = layout.buffer_size,
            .buffer_count = layout.buffer_count,
            .group_id = group_id,
            .bundled = layout.bundled,
        };
        const mask = IoUring.buf_ring_mask(layout.buffer_count);
        for (0..layout.buffer_count) |id| {
            IoUring.buf_ring_add(br, group.bufferAt(@intCast(id)), @intCast(id), mask, @intCast(id));
        }
        IoUring.buf_ring_advance(br, layout.buffer_count);
        return group;
    }

    pub fn deinit(self: *RecvBufferGroup, allocator: std.mem.Allocator) void {
        IoUring.free_buf_ring(self.ring.fd, self.br, self.buffer_count, self.group_id);
        allocator.free(self.buffers);
        self.* = undefined;
    }

    pub fn recvMultishotFixed(self: *const RecvBufferGroup, user_data: u64, slot: u32) !*linux.io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        sqe.prep_rw(.RECV, @intCast(slot), 0, 0, 0);
        sqe.flags |= linux.IOSQE_BUFFER_SELECT | linux.IOSQE_FIXED_FILE;
        sqe.buf_index = self.group_id;
        sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
        if (self.bundled) sqe.ioprio |= linux.IORING_RECVSEND_BUNDLE;
        sqe.user_data = user_data;
        return sqe;
    }

    pub fn batch(self: *const RecvBufferGroup, event: linux.io_uring_cqe) !RecvBatch {
        return RecvBatch.init(try event.buffer_id(), @intCast(event.res), self.buffer_size, self.buffer_count);
    }

    fn bufferAt(self: *const RecvBufferGroup, buffer_id: u16) []u8 {
        const start = @as(usize, self.buffer_size) * buffer_id;
        return self.buffers[start..][0..self.buffer_size];
    }

    pub fn bytes(self: *const RecvBufferGroup, slice: RecvSlice) []u8 {
        return self.bufferAt(slice.buffer_id)[0..slice.len];
    }

    pub fn releaseBatch(self: *const RecvBufferGroup, batch_value: RecvBatch) void {
        var iterator = batch_value;
        const mask = IoUring.buf_ring_mask(self.buffer_count);
        var released: u16 = 0;
        while (iterator.next()) |slice| {
            IoUring.buf_ring_add(self.br, self.bufferAt(slice.buffer_id), slice.buffer_id, mask, released);
            released += 1;
        }
        if (released > 0) IoUring.buf_ring_advance(self.br, released);
    }
};

pub fn timeoutTimespec(timeout_ms: i32) linux.kernel_timespec {
    const ms: i64 = @intCast(@max(timeout_ms, 0));
    return .{
        .sec = @divTrunc(ms, 1000),
        .nsec = @rem(ms, 1000) * std.time.ns_per_ms,
    };
}

pub fn waitForUringEvents(ring: *IoUring, timeout_ms: i32, should_stop: *const std.atomic.Value(bool)) !void {
    // Ready completions are drained immediately; the 50us min-timeout batching
    // only applies while idle, as a wakeup coalescing window. EXT_ARG support
    // is guaranteed by openUring.
    if (ring.cq_ready() > 0 or timeout_ms <= 0) {
        try submitAndRunTaskWork(ring, should_stop);
        return;
    }
    try submitAndWaitTimed(ring, timeout_ms, should_stop);
}

fn submitAndRunTaskWork(ring: *IoUring, should_stop: *const std.atomic.Value(bool)) !void {
    while (true) {
        const submitted = ring.flush_sq();
        _ = ring.enter(submitted, 0, linux.IORING_ENTER_GETEVENTS) catch |err| switch (err) {
            error.SignalInterrupt => if (should_stop.load(.monotonic)) return else continue,
            else => return err,
        };
        return;
    }
}

fn submitAndWaitTimed(ring: *IoUring, timeout_ms: i32, should_stop: *const std.atomic.Value(bool)) !void {
    const use_min_timeout = (ring.features & IORING_FEAT_MIN_TIMEOUT) != 0;
    var timeout = timeoutTimespec(timeout_ms);
    var args: GetEventsArg = .{
        .min_wait_usec = if (use_min_timeout) completion_batch_wait_us else 0,
        .ts = @intFromPtr(&timeout),
    };
    const wait_nr: u32 = if (use_min_timeout) completion_batch_size else 1;

    while (true) {
        const submitted = ring.flush_sq();
        const result = linux.syscall6(
            .io_uring_enter,
            @as(u32, @bitCast(ring.fd)),
            submitted,
            wait_nr,
            linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG,
            @intFromPtr(&args),
            @sizeOf(GetEventsArg),
        );
        switch (linux.errno(result)) {
            .SUCCESS, .TIME => return,
            .INTR => if (should_stop.load(.monotonic)) return else continue,
            .AGAIN => return error.SystemResources,
            .BADF => return error.FileDescriptorInvalid,
            .BADFD => return error.FileDescriptorInBadState,
            .BUSY => return error.CompletionQueueOvercommitted,
            .INVAL => return error.SubmissionQueueEntryInvalid,
            .FAULT => return error.BufferInvalid,
            .NXIO => return error.RingShuttingDown,
            .OPNOTSUPP => return error.OpcodeNotSupported,
            else => |errno| return posix.unexpectedErrno(errno),
        }
    }
}

pub fn copyReadyCqes(ring: *IoUring, events: []linux.io_uring_cqe, should_stop: *const std.atomic.Value(bool)) !usize {
    while (true) {
        return ring.copy_cqes(events, 0) catch |err| switch (err) {
            error.SignalInterrupt => if (should_stop.load(.monotonic)) 0 else continue,
            else => return err,
        };
    }
}

pub fn submitNoWait(ring: *IoUring, should_stop: *const std.atomic.Value(bool)) !void {
    while (true) {
        _ = ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => if (should_stop.load(.monotonic)) return else continue,
            else => return err,
        };
        return;
    }
}

pub fn registerFixedFiles(ring: *IoUring, count: usize) !void {
    try ring.register_files_sparse(@intCast(count));
}

pub fn queuePollOut(ring: *IoUring, user_data: u64, slot: u32) !void {
    try ensureSqeCapacity(ring, 1);
    const sqe = try ring.poll_add(user_data, @intCast(slot), linux.POLL.OUT);
    sqe.flags |= linux.IOSQE_FIXED_FILE;
}

pub fn queueSocketDirect(ring: *IoUring, user_data: u64, slot: u32, family: u32, protocol: u32) !void {
    try ensureSqeCapacity(ring, 1);
    _ = try ring.socket_direct(
        user_data,
        family,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
        protocol,
        0,
        slot,
    );
}

pub fn queueConfigureAndConnectFixed(
    ring: *IoUring,
    option_user_data: u64,
    connect_user_data: u64,
    slot: u32,
    tcp: bool,
    receive_buffer_bytes: *const i32,
    send_buffer_bytes: *const i32,
    tcp_nodelay: *const i32,
    address: *const posix.sockaddr,
    address_len: posix.socklen_t,
) !void {
    // Non-positive buffer sizes leave the socket on kernel autotuning.
    const set_rcvbuf = receive_buffer_bytes.* > 0;
    const set_sndbuf = send_buffer_bytes.* > 0;
    // One SQE for the connect, plus one per option actually set. Summing
    // @intFromBool results directly would do the arithmetic in u1 and overflow.
    var option_count: u32 = 1;
    if (set_rcvbuf) option_count += 1;
    if (set_sndbuf) option_count += 1;
    if (tcp) option_count += 1;
    try ensureSqeCapacity(ring, option_count);
    if (set_rcvbuf) try queueFixedSocketOption(ring, option_user_data, slot, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(receive_buffer_bytes));
    if (set_sndbuf) try queueFixedSocketOption(ring, option_user_data, slot, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(send_buffer_bytes));
    if (tcp) try queueFixedSocketOption(ring, option_user_data, slot, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(tcp_nodelay));

    const sqe = try ring.connect(connect_user_data, @intCast(slot), address, address_len);
    sqe.flags |= linux.IOSQE_FIXED_FILE;
}

fn queueFixedSocketOption(ring: *IoUring, user_data: u64, slot: u32, level: u32, option: u32, value: []const u8) !void {
    const sqe = try ring.setsockopt(user_data, @intCast(slot), level, option, value);
    sqe.flags |= linux.IOSQE_FIXED_FILE | linux.IOSQE_IO_HARDLINK;
    if ((ring.features & linux.IORING_FEAT_CQE_SKIP) != 0) sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
}

pub fn queueSendFixed(ring: *IoUring, user_data: u64, slot: u32, bytes: []const u8) !void {
    try ensureSqeCapacity(ring, 1);
    const sqe = try ring.send(user_data, @intCast(slot), bytes, posix.MSG.NOSIGNAL);
    sqe.flags |= linux.IOSQE_FIXED_FILE;
}

/// Queues a gathered send over `msg`'s iovec array. The msghdr and iovecs must
/// stay valid until the completion arrives.
pub fn queueSendMsgFixed(ring: *IoUring, user_data: u64, slot: u32, msg: *const linux.msghdr_const) !void {
    try ensureSqeCapacity(ring, 1);
    const sqe = try ring.sendmsg(user_data, @intCast(slot), msg, posix.MSG.NOSIGNAL);
    sqe.flags |= linux.IOSQE_FIXED_FILE;
}

pub fn queueRecvMultishotFixed(recv_buffers: *const RecvBufferGroup, user_data: u64, slot: u32) !void {
    try ensureSqeCapacity(recv_buffers.ring, 1);
    _ = try recv_buffers.recvMultishotFixed(user_data, slot);
}

pub fn queueShutdownAndCloseFixed(ring: *IoUring, ignored_user_data: u64, close_user_data: u64, slot: u32) !void {
    try ensureSqeCapacity(ring, 2);
    const shutdown_sqe = try ring.shutdown(ignored_user_data, @intCast(slot), std.os.linux.SHUT.RDWR);
    shutdown_sqe.flags |= linux.IOSQE_FIXED_FILE | linux.IOSQE_IO_HARDLINK;
    if ((ring.features & linux.IORING_FEAT_CQE_SKIP) != 0) shutdown_sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
    _ = try ring.close_direct(close_user_data, slot);
}

fn ensureSqeCapacity(ring: *IoUring, needed: u32) !void {
    if (ring.sq_ready() + needed <= ring.sq.sqes.len) return;
    while (true) {
        _ = ring.submit() catch |err| switch (err) {
            // Every other retry site checks the stop flag; this one used to
            // continue unconditionally, so a SIGINT that landed inside a submit
            // during a full-SQ storm was swallowed and Ctrl-C appeared dead.
            error.SignalInterrupt => if (stopRequested()) return else continue,
            else => return err,
        };
        return;
    }
}

test "completion keys preserve kind generation and index" {
    const key: CompletionKey = .{
        .kind = .recv,
        .generation = 0xbeef,
        .index = 0x00aa_bbcc_ddee,
    };
    const decoded = unpackCompletionKey(packCompletionKey(key)).?;
    try std.testing.expectEqual(key.kind, decoded.kind);
    try std.testing.expectEqual(key.generation, decoded.generation);
    try std.testing.expectEqual(key.index, decoded.index);
    try std.testing.expectEqual(CompletionKind.send, unpackCompletionKey(packCompletionKey(.{
        .kind = .send,
        .generation = 1,
        .index = 2,
    })).?.kind);
    inline for (.{ CompletionKind.socket, CompletionKind.socket_option, CompletionKind.close }) |kind| {
        try std.testing.expectEqual(kind, unpackCompletionKey(packCompletionKey(.{
            .kind = kind,
            .generation = 2,
            .index = 3,
        })).?.kind);
    }
    try std.testing.expectEqual(@as(?CompletionKey, null), unpackCompletionKey(0xff << 56));
}

test "ioUringEntries rounds client counts to bounded powers of two" {
    try std.testing.expectEqual(@as(u16, min_ring_entries), ioUringEntries(0));
    try std.testing.expectEqual(@as(u16, 128), ioUringEntries(10));
    try std.testing.expectEqual(@as(u16, 4096), ioUringEntries(1000));
    try std.testing.expectEqual(@as(u16, max_ring_entries), ioUringEntries(100_000));
}

test "receive batches split total bytes across contiguous buffers" {
    var batch = try RecvBatch.init(2, 9000, 4096, 8);
    try std.testing.expectEqual(RecvSlice{ .buffer_id = 2, .len = 4096 }, batch.next().?);
    try std.testing.expectEqual(RecvSlice{ .buffer_id = 3, .len = 4096 }, batch.next().?);
    try std.testing.expectEqual(RecvSlice{ .buffer_id = 4, .len = 808 }, batch.next().?);
    try std.testing.expectEqual(@as(?RecvSlice, null), batch.next());
}

test "receive batches wrap buffer ids and validate capacity" {
    var batch = try RecvBatch.init(3, 5000, 2048, 4);
    try std.testing.expectEqual(RecvSlice{ .buffer_id = 3, .len = 2048 }, batch.next().?);
    try std.testing.expectEqual(RecvSlice{ .buffer_id = 0, .len = 2048 }, batch.next().?);
    try std.testing.expectEqual(RecvSlice{ .buffer_id = 1, .len = 904 }, batch.next().?);
    try std.testing.expectEqual(@as(?RecvSlice, null), batch.next());

    try std.testing.expectError(error.InvalidBatch, RecvBatch.init(0, 1, 0, 4));
    try std.testing.expectError(error.InvalidBatch, RecvBatch.init(0, 8193, 2048, 4));
}

test "recvBufferCount scales shared buffer rings by shard size" {
    try std.testing.expectEqual(@as(u16, min_recv_buffers), recvBufferCount(0));
    try std.testing.expectEqual(@as(u16, min_recv_buffers), recvBufferCount(10));
    try std.testing.expectEqual(@as(u16, max_recv_buffers), recvBufferCount(1000));
    try std.testing.expectEqual(@as(u16, max_recv_buffers), recvBufferCount(100_000));
}

test "boundedPowerOfTwo clamps and rounds capacities" {
    try std.testing.expectEqual(@as(u16, 64), boundedPowerOfTwo(0, 64, 1024));
    try std.testing.expectEqual(@as(u16, 128), boundedPowerOfTwo(65, 64, 1024));
    try std.testing.expectEqual(@as(u16, 1024), boundedPowerOfTwo(100_000, 64, 1024));
}

test "timed enter argument preserves timeout and batching ABI" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(GetEventsArg));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(GetEventsArg, "min_wait_usec"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(GetEventsArg, "ts"));
    try std.testing.expect(completion_batch_size > 1);
    try std.testing.expect(completion_batch_wait_us > 0);
}
