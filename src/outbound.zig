const std = @import("std");

pub const segment_capacity: u8 = 4;
pub const max_queued_bytes: usize = 16 * 1024;
const initial_owned_capacity: usize = 512;

pub const SharedSource = enum(u8) {
    broadcast_plain,
    broadcast_uncompressed,
    broadcast_compressed,
    client_tick_plain,
    client_tick_uncompressed,
    client_tick_compressed,
};

pub const SharedSlice = struct {
    source: SharedSource,
    offset: u32,
    len: u32,
};

pub const Pending = union(enum) {
    empty,
    owned: []const u8,
    shared: SharedSlice,
};

const StoredSource = enum(u8) {
    owned_0,
    owned_1,
    broadcast_plain,
    broadcast_uncompressed,
    broadcast_compressed,
    client_tick_plain,
    client_tick_uncompressed,
    client_tick_compressed,

    // SharedSource maps onto the tail of this enum by adding the number of
    // owned variants, which must therefore come first and in the same order.
    const shared_offset = @intFromEnum(StoredSource.broadcast_plain);

    comptime {
        const shared_info = @typeInfo(SharedSource).@"enum";
        const stored_info = @typeInfo(StoredSource).@"enum";
        std.debug.assert(stored_info.field_names.len == shared_offset + shared_info.field_names.len);
        for (
            shared_info.field_names,
            shared_info.field_values,
            stored_info.field_names[shared_offset..],
            stored_info.field_values[shared_offset..],
        ) |shared_name, shared_value, stored_name, stored_value| {
            std.debug.assert(std.mem.eql(u8, shared_name, stored_name));
            std.debug.assert(shared_value + shared_offset == stored_value);
        }
    }

    fn owned(slot: u1) StoredSource {
        return if (slot == 0) .owned_0 else .owned_1;
    }

    fn shared(source: SharedSource) StoredSource {
        return @enumFromInt(@intFromEnum(source) + shared_offset);
    }

    fn ownedSlot(source: StoredSource) ?u1 {
        return switch (source) {
            .owned_0 => 0,
            .owned_1 => 1,
            else => null,
        };
    }

    fn sharedSource(source: StoredSource) ?SharedSource {
        const raw = @intFromEnum(source);
        return if (raw >= shared_offset) @enumFromInt(raw - shared_offset) else null;
    }
};

const QueueState = packed struct(u8) {
    // Sized so it wraps at segment_capacity (a power of two) on overflow;
    // complete() relies on that instead of a modulo.
    head: std.math.IntFittingRange(0, segment_capacity - 1) = 0,
    count: u3 = 0,
    // Number of segments (from the head, in logical order) whose bytes are in
    // flight in one gathered send. Their storage must stay stable until
    // complete() or cancel().
    inflight: u3 = 0,
};

pub const Queue = struct {
    owned_buffers: [2]?[*]u8 = .{ null, null },
    owned_capacities: [2]u16 = .{ 0, 0 },
    owned_lens: [2]u16 = .{ 0, 0 },
    sources: [segment_capacity]StoredSource = undefined,
    offsets: [segment_capacity]u16 = undefined,
    lengths: [segment_capacity]u16 = undefined,
    queued_bytes: u16 = 0,
    state: QueueState = .{},

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.reset(allocator, false);
        self.* = .{};
    }

    pub fn segmentCount(self: *const Queue) u8 {
        return self.state.count;
    }

    pub fn byteCount(self: *const Queue) usize {
        return self.queued_bytes;
    }

    pub fn isLocked(self: *const Queue) bool {
        return self.state.inflight != 0;
    }

    pub fn enqueueShared(self: *Queue, source: SharedSource, len: usize) error{ TooLarge, QueueFull }!void {
        if (len == 0) return;
        try self.ensureQueueCapacity(len);
        if (self.state.count == segment_capacity) return error.QueueFull;
        self.push(.shared(source), @intCast(len));
        self.queued_bytes += @intCast(len);
    }

    pub fn enqueueOwned(self: *Queue, allocator: std.mem.Allocator, bytes: []const u8) (error{ TooLarge, QueueFull, NoOwnedBuffer } || std.mem.Allocator.Error)!void {
        if (bytes.len == 0) return;
        try self.ensureQueueCapacity(bytes.len);

        if (self.state.count > 0) coalesce: {
            const tail_logical: u3 = self.state.count - 1;
            const tail_index = self.physicalIndex(tail_logical);
            const slot = self.sources[tail_index].ownedSlot() orelse break :coalesce;
            // Extend the tail only while its live bytes still start at offset zero
            // and its storage is not in flight. After a partial send the other
            // owned slot is used instead, so sent prefixes cannot accumulate
            // across repeated append/send cycles.
            if (self.offsets[tail_index] != 0 or tail_logical < self.state.inflight) break :coalesce;
            try self.appendOwned(allocator, slot, bytes);
            self.lengths[tail_index] = self.owned_lens[slot];
            self.queued_bytes += @intCast(bytes.len);
            return;
        }

        if (self.state.count == segment_capacity) return error.QueueFull;
        const slot = self.freeOwnedSlot() orelse return error.NoOwnedBuffer;
        self.owned_lens[slot] = 0;
        try self.appendOwned(allocator, slot, bytes);
        self.push(.owned(slot), self.owned_lens[slot]);
        self.queued_bytes += @intCast(bytes.len);
    }

    pub fn begin(self: *Queue) Pending {
        const pending = self.peek();
        if (pending == .empty) return .empty;
        self.state.inflight = 1;
        return pending;
    }

    /// Locks every queued segment for one gathered send and fills `out` with
    /// their pending views in FIFO order. Returns the segment count.
    pub fn beginAll(self: *Queue, out: *[segment_capacity]Pending) u8 {
        // count never exceeds segment_capacity, but its u3 type does not say so;
        // the @min gives LLVM the trip count and stops it unrolling 7 copies of
        // pendingAt into armSend.
        const count = @min(self.state.count, segment_capacity);
        for (0..count) |logical| out[logical] = self.pendingAt(@intCast(logical));
        self.state.inflight = count;
        return count;
    }

    pub fn peek(self: *const Queue) Pending {
        if (self.state.count == 0) return .empty;
        return self.pendingAt(0);
    }

    fn pendingAt(self: *const Queue, logical: u3) Pending {
        const index = self.physicalIndex(logical);
        const offset = self.offsets[index];
        const len = self.lengths[index];
        if (self.sources[index].ownedSlot()) |slot| {
            return .{ .owned = self.owned_buffers[slot].?[offset..len] };
        }
        return .{ .shared = .{
            .source = self.sources[index].sharedSource().?,
            .offset = offset,
            .len = len,
        } };
    }

    pub fn cancel(self: *Queue) void {
        self.state.inflight = 0;
    }

    pub fn complete(self: *Queue, count: usize) error{InvalidCompletion}!void {
        const inflight = self.state.inflight;
        if (inflight == 0 or self.state.count == 0 or count == 0) return error.InvalidCompletion;
        var in_flight_bytes: usize = 0;
        for (0..inflight) |logical| {
            const index = self.physicalIndex(@intCast(logical));
            in_flight_bytes += self.lengths[index] - self.offsets[index];
        }
        if (count > in_flight_bytes) return error.InvalidCompletion;

        self.queued_bytes -= @intCast(count);
        self.state.inflight = 0;
        var left = count;
        while (left > 0) {
            const head = self.state.head;
            const remaining = self.lengths[head] - self.offsets[head];
            if (left < remaining) {
                self.offsets[head] += @intCast(left);
                break;
            }
            left -= remaining;
            if (self.sources[head].ownedSlot()) |slot| self.owned_lens[slot] = 0;
            self.state.head +%= 1;
            self.state.count -= 1;
        }
        if (self.state.count == 0) self.state.head = 0;
    }

    pub fn clearRetainingCapacity(self: *Queue) void {
        self.state = .{};
        self.queued_bytes = 0;
        self.owned_lens = .{ 0, 0 };
    }

    pub fn reset(self: *Queue, allocator: std.mem.Allocator, preserve_inflight: bool) void {
        const inflight = self.state.inflight;
        if (!preserve_inflight or inflight == 0 or self.state.count == 0) {
            self.freeOwnedBuffers(allocator, .{ false, false });
            self.clearRetainingCapacity();
            return;
        }

        // Keep every in-flight segment: the kernel may still read any of their
        // bytes until the gathered send completes.
        const Segment = struct { source: StoredSource, offset: u16, len: u16 };
        var preserved: [segment_capacity]Segment = undefined;
        var keep_owned = [2]bool{ false, false };
        var preserved_bytes: usize = 0;
        for (preserved[0..inflight], 0..) |*segment, logical| {
            const index = self.physicalIndex(@intCast(logical));
            segment.* = .{
                .source = self.sources[index],
                .offset = self.offsets[index],
                .len = self.lengths[index],
            };
            if (segment.source.ownedSlot()) |slot| keep_owned[slot] = true;
            preserved_bytes += segment.len - segment.offset;
        }
        self.freeOwnedBuffers(allocator, keep_owned);
        for (preserved[0..inflight], 0..) |segment, logical| {
            self.sources[logical] = segment.source;
            self.offsets[logical] = segment.offset;
            self.lengths[logical] = segment.len;
        }
        self.state = .{ .count = inflight, .inflight = inflight };
        self.queued_bytes = @intCast(preserved_bytes);
    }

    fn freeOwnedBuffers(self: *Queue, allocator: std.mem.Allocator, keep: [2]bool) void {
        for (&self.owned_buffers, 0..) |*buffer, slot| {
            if (keep[slot]) continue;
            if (buffer.*) |bytes| allocator.free(bytes[0..self.owned_capacities[slot]]);
            buffer.* = null;
            self.owned_capacities[slot] = 0;
            self.owned_lens[slot] = 0;
        }
    }

    fn ensureQueueCapacity(self: *const Queue, additional: usize) error{TooLarge}!void {
        const total = std.math.add(usize, self.queued_bytes, additional) catch return error.TooLarge;
        if (total > max_queued_bytes) return error.TooLarge;
    }

    fn physicalIndex(self: *const Queue, logical: u3) usize {
        return (@as(usize, self.state.head) + logical) % segment_capacity;
    }

    fn push(self: *Queue, source: StoredSource, len: u16) void {
        std.debug.assert(self.state.count < segment_capacity);
        const index = self.physicalIndex(self.state.count);
        self.sources[index] = source;
        self.offsets[index] = 0;
        self.lengths[index] = len;
        self.state.count += 1;
    }

    fn freeOwnedSlot(self: *const Queue) ?u1 {
        var used = [2]bool{ false, false };
        // See beginAll: the @min bounds the unroll at segment_capacity.
        for (0..@min(self.state.count, segment_capacity)) |logical| {
            const source = self.sources[self.physicalIndex(@intCast(logical))];
            if (source.ownedSlot()) |slot| used[slot] = true;
        }
        if (!used[0]) return 0;
        if (!used[1]) return 1;
        return null;
    }

    fn appendOwned(self: *Queue, allocator: std.mem.Allocator, slot: u1, bytes: []const u8) std.mem.Allocator.Error!void {
        const old_len = self.owned_lens[slot];
        const needed = old_len + bytes.len;
        if (self.owned_buffers[slot] == null) {
            const allocated = try allocator.alloc(u8, @max(initial_owned_capacity, needed));
            self.owned_buffers[slot] = allocated.ptr;
            self.owned_capacities[slot] = @intCast(allocated.len);
        } else if (needed > self.owned_capacities[slot]) {
            const doubled = @min(max_queued_bytes, @as(usize, self.owned_capacities[slot]) * 2);
            const resized = try allocator.realloc(self.owned_buffers[slot].?[0..self.owned_capacities[slot]], @max(needed, doubled));
            self.owned_buffers[slot] = resized.ptr;
            self.owned_capacities[slot] = @intCast(resized.len);
        }
        @memcpy(self.owned_buffers[slot].?[old_len..needed], bytes);
        self.owned_lens[slot] = @intCast(needed);
    }
};

test "empty queue metadata stays compact" {
    try std.testing.expect(@sizeOf(Queue) <= 48);
}

test "owned and shared segments retain FIFO order without copying shared bytes" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "owned");
    try queue.enqueueShared(.broadcast_plain, 6);

    const first = queue.begin();
    try std.testing.expectEqualStrings("owned", first.owned);
    try queue.complete(5);

    const second = queue.begin();
    try std.testing.expectEqual(SharedSource.broadcast_plain, second.shared.source);
    try std.testing.expectEqual(@as(u32, 0), second.shared.offset);
    try std.testing.expectEqual(@as(u32, 6), second.shared.len);
}

test "partial completion resumes at the unsent owned byte" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "abcdef");
    try std.testing.expectEqualStrings("abcdef", queue.begin().owned);
    try queue.complete(2);
    try std.testing.expectEqualStrings("cdef", queue.begin().owned);
    try queue.complete(4);
    try std.testing.expect(queue.begin() == .empty);
}

test "appending after a partial send does not retain the sent prefix" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "abcdef");
    _ = queue.begin();
    try queue.complete(2);
    try queue.enqueueOwned(std.testing.allocator, "next");

    try std.testing.expectEqual(@as(u8, 2), queue.segmentCount());
    try std.testing.expectEqualStrings("cdef", queue.begin().owned);
    try queue.complete(4);
    try std.testing.expectEqualStrings("next", queue.begin().owned);
}

test "owned writes coalesce until their segment is in flight" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "a");
    try queue.enqueueOwned(std.testing.allocator, "b");
    try std.testing.expectEqual(@as(u8, 1), queue.segmentCount());
    try std.testing.expectEqualStrings("ab", queue.begin().owned);

    try queue.enqueueOwned(std.testing.allocator, "deferred");
    try std.testing.expectEqual(@as(u8, 2), queue.segmentCount());
    try queue.complete(2);
    try std.testing.expectEqualStrings("deferred", queue.begin().owned);
}

test "segment queue and total bytes are bounded" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    inline for (0..segment_capacity) |i| {
        try queue.enqueueShared(@enumFromInt(i % @typeInfo(SharedSource).@"enum".field_names.len), 1);
    }
    try std.testing.expectError(error.QueueFull, queue.enqueueShared(.broadcast_plain, 1));
    queue.clearRetainingCapacity();

    var bytes: [max_queued_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.TooLarge, queue.enqueueOwned(std.testing.allocator, &bytes));
}

test "reset can preserve only the in-flight head" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "inflight");
    _ = queue.begin();
    try queue.enqueueOwned(std.testing.allocator, "discarded");
    queue.reset(std.testing.allocator, true);

    try std.testing.expectEqual(@as(u8, 1), queue.segmentCount());
    try std.testing.expect(queue.isLocked());
    try std.testing.expectEqualStrings("inflight", queue.begin().owned);
    try queue.complete(8);
    try std.testing.expect(queue.begin() == .empty);
}

test "gathered begin locks every segment and completes them in one call" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "reply");
    try queue.enqueueShared(.client_tick_plain, 3);
    try queue.enqueueShared(.broadcast_plain, 7);

    var pendings: [segment_capacity]Pending = undefined;
    try std.testing.expectEqual(@as(u8, 3), queue.beginAll(&pendings));
    try std.testing.expect(queue.isLocked());
    try std.testing.expectEqualStrings("reply", pendings[0].owned);
    try std.testing.expectEqual(SharedSource.client_tick_plain, pendings[1].shared.source);
    try std.testing.expectEqual(SharedSource.broadcast_plain, pendings[2].shared.source);

    // In-flight segments never grow, so a new append lands in a new segment.
    try queue.enqueueOwned(std.testing.allocator, "x");
    try std.testing.expectEqual(@as(u8, 4), queue.segmentCount());

    try queue.complete(5 + 3 + 7);
    try std.testing.expectEqual(@as(u8, 1), queue.segmentCount());
    try std.testing.expectEqual(@as(usize, 1), queue.byteCount());
    try std.testing.expect(!queue.isLocked());
    try std.testing.expectEqualStrings("x", queue.begin().owned);
}

test "gathered completion resumes mid-segment after a short send" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "abcd");
    try queue.enqueueShared(.broadcast_plain, 6);

    var pendings: [segment_capacity]Pending = undefined;
    try std.testing.expectEqual(@as(u8, 2), queue.beginAll(&pendings));
    // 4 owned bytes plus 2 of the shared frame.
    try queue.complete(6);

    try std.testing.expectEqual(@as(u8, 1), queue.segmentCount());
    try std.testing.expectEqual(@as(usize, 4), queue.byteCount());
    const head = queue.peek();
    try std.testing.expectEqual(@as(u32, 2), head.shared.offset);
    try std.testing.expectEqual(@as(u32, 6), head.shared.len);

    // Overcompleting the remaining bytes is rejected.
    _ = queue.beginAll(&pendings);
    try std.testing.expectError(error.InvalidCompletion, queue.complete(5));
    try queue.complete(4);
    try std.testing.expect(queue.begin() == .empty);
}

test "gathered completion allows appending a new segment while in flight" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "first");
    var pendings: [segment_capacity]Pending = undefined;
    try std.testing.expectEqual(@as(u8, 1), queue.beginAll(&pendings));

    // The in-flight tail cannot be extended, but a fresh segment can queue.
    try queue.enqueueOwned(std.testing.allocator, "second");
    try std.testing.expectEqual(@as(u8, 2), queue.segmentCount());

    try queue.complete(5);
    try std.testing.expectEqual(@as(u8, 1), queue.beginAll(&pendings));
    try std.testing.expectEqualStrings("second", pendings[0].owned);
}

test "reset preserves every in-flight segment of a gathered send" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    try queue.enqueueOwned(std.testing.allocator, "inflight");
    try queue.enqueueShared(.client_tick_plain, 4);
    var pendings: [segment_capacity]Pending = undefined;
    try std.testing.expectEqual(@as(u8, 2), queue.beginAll(&pendings));
    queue.reset(std.testing.allocator, true);

    try std.testing.expectEqual(@as(u8, 2), queue.segmentCount());
    try std.testing.expect(queue.isLocked());
    try std.testing.expectEqual(@as(usize, 12), queue.byteCount());
    try queue.complete(12);
    try std.testing.expect(queue.begin() == .empty);
}

test "randomized gathered-send state transitions preserve queue invariants" {
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    var rng: u64 = 0x2545_f491_4f6c_dd1d;
    for (0..50_000) |_| {
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        const operation: u8 = @truncate(rng >> 33);
        const argument: u8 = @truncate(rng >> 41);
        switch (operation % 8) {
            0 => {
                var bytes: [64]u8 = undefined;
                const len: usize = argument % bytes.len + 1;
                for (bytes[0..len], 0..) |*byte, byte_index| byte.* = @truncate(byte_index + argument);
                queue.enqueueOwned(std.testing.allocator, bytes[0..len]) catch |err| switch (err) {
                    error.QueueFull, error.NoOwnedBuffer, error.TooLarge => {},
                    else => return err,
                };
            },
            1 => queue.enqueueShared(@enumFromInt(argument % @typeInfo(SharedSource).@"enum".field_names.len), @as(usize, argument) + 1) catch |err| switch (err) {
                error.QueueFull, error.TooLarge => {},
            },
            2 => _ = queue.begin(),
            3 => {
                var pendings: [segment_capacity]Pending = undefined;
                _ = queue.beginAll(&pendings);
            },
            4 => queue.complete(@as(usize, argument) + 1) catch |err| switch (err) {
                error.InvalidCompletion => {},
            },
            5 => queue.cancel(),
            6 => queue.reset(std.testing.allocator, argument & 1 != 0),
            7 => queue.clearRetainingCapacity(),
            else => unreachable,
        }
        try validateQueueInvariants(&queue);
    }
}

test "fuzz outbound queue state transitions" {
    try std.testing.fuzz({}, fuzzQueueStateTransitions, .{ .corpus = &.{
        "\x08\x00\x00\x00\x00\x03\x02\x05\x04\x01\x03\x07",
        "\x0c\x00\x00\x00\x01\x01\x02\x00\x02\x03\x04\x00\x05\x00\x06\x01",
    } });
}

fn fuzzQueueStateTransitions(_: void, smith: *std.testing.Smith) anyerror!void {
    var operations: [512]u8 = undefined;
    const operation_count: usize = smith.slice(&operations);
    var queue: Queue = .{};
    defer queue.deinit(std.testing.allocator);

    var index: usize = 0;
    while (index < operation_count) : (index += 1) {
        const operation = operations[index];
        const argument = if (index + 1 < operation_count) operations[index + 1] else operation;
        switch (operation % 8) {
            0 => {
                var bytes: [64]u8 = undefined;
                const len: usize = argument % bytes.len + 1;
                for (bytes[0..len], 0..) |*byte, byte_index| byte.* = @truncate(byte_index + argument);
                queue.enqueueOwned(std.testing.allocator, bytes[0..len]) catch |err| switch (err) {
                    error.QueueFull, error.NoOwnedBuffer, error.TooLarge => {},
                    else => return err,
                };
            },
            1 => queue.enqueueShared(@enumFromInt(argument % @typeInfo(SharedSource).@"enum".field_names.len), @as(usize, argument) + 1) catch |err| switch (err) {
                error.QueueFull, error.TooLarge => {},
            },
            2 => _ = queue.begin(),
            3 => queue.complete(@as(usize, argument) + 1) catch |err| switch (err) {
                error.InvalidCompletion => {},
            },
            4 => queue.cancel(),
            5 => queue.reset(std.testing.allocator, argument & 1 != 0),
            6 => queue.clearRetainingCapacity(),
            7 => {
                var pendings: [segment_capacity]Pending = undefined;
                _ = queue.beginAll(&pendings);
            },
            else => unreachable,
        }
        try validateQueueInvariants(&queue);
    }
}

fn validateQueueInvariants(queue: *const Queue) !void {
    try std.testing.expect(queue.state.count <= segment_capacity);
    try std.testing.expect(queue.state.inflight <= queue.state.count);
    if (queue.state.count == 0) try std.testing.expectEqual(@as(u2, 0), queue.state.head);

    var queued_bytes: usize = 0;
    var used_owned = [2]bool{ false, false };
    for (0..queue.state.count) |logical| {
        const physical = queue.physicalIndex(@intCast(logical));
        const offset = queue.offsets[physical];
        const len = queue.lengths[physical];
        try std.testing.expect(offset <= len);
        queued_bytes += len - offset;
        if (queue.sources[physical].ownedSlot()) |slot| {
            try std.testing.expect(!used_owned[slot]);
            used_owned[slot] = true;
            try std.testing.expect(queue.owned_buffers[slot] != null);
            try std.testing.expectEqual(queue.owned_lens[slot], len);
            try std.testing.expect(len <= queue.owned_capacities[slot]);
        } else {
            try std.testing.expect(queue.sources[physical].sharedSource() != null);
        }
    }
    try std.testing.expectEqual(queued_bytes, queue.byteCount());

    const pending = queue.peek();
    if (queue.state.count == 0) {
        try std.testing.expect(pending == .empty);
    } else switch (pending) {
        .empty => return error.TestUnexpectedResult,
        .owned => |bytes| try std.testing.expectEqual(queuedHeadLength(queue), bytes.len),
        .shared => |shared| try std.testing.expectEqual(queuedHeadLength(queue), shared.len - shared.offset),
    }
}

fn queuedHeadLength(queue: *const Queue) u32 {
    return queue.lengths[queue.state.head] - queue.offsets[queue.state.head];
}
