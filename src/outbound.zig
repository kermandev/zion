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

    fn owned(slot: u1) StoredSource {
        return if (slot == 0) .owned_0 else .owned_1;
    }

    fn shared(source: SharedSource) StoredSource {
        return @enumFromInt(@intFromEnum(source) + 2);
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
        return if (raw >= 2) @enumFromInt(raw - 2) else null;
    }
};

const QueueState = packed struct(u8) {
    head: u2 = 0,
    count: u3 = 0,
    locked: bool = false,
    padding: u2 = 0,
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
        return self.state.locked;
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

        if (self.state.count > 0) {
            const tail_index = self.physicalIndex(self.state.count - 1);
            // Only extend storage whose live bytes still start at offset zero.
            // After a partial send, use the other owned slot so sent prefixes
            // cannot accumulate across repeated append/send cycles.
            if (self.sources[tail_index].ownedSlot()) |slot| {
                if (self.offsets[tail_index] != 0 or (self.state.locked and tail_index == self.state.head)) {
                    // The tail cannot be extended while its storage is in flight.
                } else {
                    try self.appendOwned(allocator, slot, bytes);
                    self.lengths[tail_index] = self.owned_lens[slot];
                    self.queued_bytes += @intCast(bytes.len);
                    return;
                }
            }
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
        self.state.locked = true;
        return pending;
    }

    pub fn peek(self: *const Queue) Pending {
        if (self.state.count == 0) return .empty;
        const head = self.state.head;
        const offset = self.offsets[head];
        const len = self.lengths[head];
        if (self.sources[head].ownedSlot()) |slot| {
            return .{ .owned = self.owned_buffers[slot].?[offset..len] };
        }
        return .{ .shared = .{
            .source = self.sources[head].sharedSource().?,
            .offset = offset,
            .len = len,
        } };
    }

    pub fn cancel(self: *Queue) void {
        self.state.locked = false;
    }

    pub fn complete(self: *Queue, count: usize) error{InvalidCompletion}!void {
        if (!self.state.locked or self.state.count == 0 or count == 0) return error.InvalidCompletion;
        const head = self.state.head;
        const remaining = self.lengths[head] - self.offsets[head];
        if (count > remaining) return error.InvalidCompletion;

        self.offsets[head] += @intCast(count);
        self.queued_bytes -= @intCast(count);
        self.state.locked = false;
        if (self.offsets[head] != self.lengths[head]) return;

        if (self.sources[head].ownedSlot()) |slot| self.owned_lens[slot] = 0;
        self.state.head = @intCast((@as(usize, head) + 1) % segment_capacity);
        self.state.count -= 1;
        if (self.state.count == 0) self.state.head = 0;
    }

    pub fn clearRetainingCapacity(self: *Queue) void {
        self.state = .{};
        self.queued_bytes = 0;
        self.owned_lens = .{ 0, 0 };
    }

    pub fn reset(self: *Queue, allocator: std.mem.Allocator, preserve_inflight: bool) void {
        if (preserve_inflight and self.state.locked and self.state.count > 0) {
            const head = self.state.head;
            const preserved_source = self.sources[head];
            const preserved_offset = self.offsets[head];
            const preserved_len = self.lengths[head];
            const preserved_owned = preserved_source.ownedSlot();
            for (&self.owned_buffers, 0..) |*buffer, slot| {
                if (preserved_owned != null and preserved_owned.? == slot) continue;
                if (buffer.*) |bytes| allocator.free(bytes[0..self.owned_capacities[slot]]);
                buffer.* = null;
                self.owned_capacities[slot] = 0;
                self.owned_lens[slot] = 0;
            }
            self.sources[0] = preserved_source;
            self.offsets[0] = preserved_offset;
            self.lengths[0] = preserved_len;
            self.state = .{ .count = 1, .locked = true };
            self.queued_bytes = preserved_len - preserved_offset;
            return;
        }

        for (&self.owned_buffers, 0..) |*buffer, slot| {
            if (buffer.*) |bytes| allocator.free(bytes[0..self.owned_capacities[slot]]);
            buffer.* = null;
            self.owned_capacities[slot] = 0;
        }
        self.clearRetainingCapacity();
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
        for (0..self.state.count) |logical| {
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
        switch (operation % 7) {
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
            else => unreachable,
        }
        try validateQueueInvariants(&queue);
    }
}

fn validateQueueInvariants(queue: *const Queue) !void {
    try std.testing.expect(queue.state.count <= segment_capacity);
    try std.testing.expect(!queue.state.locked or queue.state.count > 0);
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
