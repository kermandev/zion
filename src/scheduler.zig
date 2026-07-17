const std = @import("std");

pub const slot_count: usize = 65_536;
const none = std.math.maxInt(u32);
const no_deadline = std.math.maxInt(u64);

/// Shard-local intrusive timing wheel. Each client owns at most one entry, so
/// scheduling and cancellation do not allocate and do not touch another shard.
pub const TimerWheel = struct {
    allocator: std.mem.Allocator,
    heads: []u32,
    next: []u32,
    previous: []u32,
    deadlines: []u64,
    cursor_ms: u64,
    cached_next: ?u64 = null,
    next_dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, client_count: usize, now_ms: u64) !TimerWheel {
        if (client_count > std.math.maxInt(u32)) return error.TooManyClients;
        const heads = try allocator.alloc(u32, slot_count);
        errdefer allocator.free(heads);
        @memset(heads, none);
        const next = try allocator.alloc(u32, client_count);
        errdefer allocator.free(next);
        @memset(next, none);
        const previous = try allocator.alloc(u32, client_count);
        errdefer allocator.free(previous);
        @memset(previous, none);
        const deadlines = try allocator.alloc(u64, client_count);
        errdefer allocator.free(deadlines);
        @memset(deadlines, no_deadline);
        return .{
            .allocator = allocator,
            .heads = heads,
            .next = next,
            .previous = previous,
            .deadlines = deadlines,
            .cursor_ms = now_ms,
        };
    }

    pub fn deinit(self: *TimerWheel) void {
        self.allocator.free(self.heads);
        self.allocator.free(self.next);
        self.allocator.free(self.previous);
        self.allocator.free(self.deadlines);
        self.* = undefined;
    }

    pub fn schedule(self: *TimerWheel, index: usize, deadline_ms: u64) void {
        std.debug.assert(index < self.deadlines.len);
        self.cancel(index);
        // takeDue advances cursor_ms past every slot it has inspected. Clamp
        // overdue work to that cursor so it remains visible on the next pass.
        const effective_deadline = @max(deadline_ms, self.cursor_ms);
        const slot = slotFor(effective_deadline);
        const old_head = self.heads[slot];
        self.heads[slot] = @intCast(index);
        self.next[index] = old_head;
        self.previous[index] = none;
        if (old_head != none) self.previous[old_head] = @intCast(index);
        self.deadlines[index] = effective_deadline;
        if (self.cached_next == null or effective_deadline < self.cached_next.?) self.cached_next = effective_deadline;
    }

    pub fn update(self: *TimerWheel, index: usize, deadline_ms: ?u64) void {
        const deadline = deadline_ms orelse {
            self.cancel(index);
            return;
        };
        const effective_deadline = @max(deadline, self.cursor_ms);
        if (self.deadlines[index] != no_deadline and self.deadlines[index] == effective_deadline) return;
        self.schedule(index, effective_deadline);
    }

    pub fn cancel(self: *TimerWheel, index: usize) void {
        if (self.deadlines[index] == no_deadline) return;
        if (self.cached_next == self.deadlines[index]) self.next_dirty = true;
        self.unlink(index);
    }

    pub fn takeDue(self: *TimerWheel, now_ms: u64, out: []u32) usize {
        var count: usize = 0;
        while (self.cursor_ms <= now_ms) : (self.cursor_ms += 1) {
            const slot = slotFor(self.cursor_ms);
            var current = self.heads[slot];
            while (current != none) {
                const index: usize = current;
                const following = self.next[index];
                if (self.deadlines[index] <= now_ms) {
                    std.debug.assert(count < out.len);
                    if (self.cached_next == self.deadlines[index]) self.next_dirty = true;
                    self.unlink(index);
                    out[count] = @intCast(index);
                    count += 1;
                }
                current = following;
            }
        }
        if (self.next_dirty) self.recomputeNext();
        return count;
    }

    pub fn nextDeadline(self: *TimerWheel) ?u64 {
        if (self.next_dirty) self.recomputeNext();
        return self.cached_next;
    }

    fn unlink(self: *TimerWheel, index: usize) void {
        const slot = slotFor(self.deadlines[index]);
        const before = self.previous[index];
        const after = self.next[index];
        if (before == none) self.heads[slot] = after else self.next[before] = after;
        if (after != none) self.previous[after] = before;
        self.next[index] = none;
        self.previous[index] = none;
        self.deadlines[index] = no_deadline;
    }

    fn recomputeNext(self: *TimerWheel) void {
        var earliest: ?u64 = null;
        for (self.deadlines) |deadline| {
            if (deadline == no_deadline) continue;
            earliest = if (earliest) |current| @min(current, deadline) else deadline;
        }
        self.cached_next = earliest;
        self.next_dirty = false;
    }
};

fn slotFor(deadline_ms: u64) usize {
    return @intCast(deadline_ms & (slot_count - 1));
}

test "timing wheel schedules cancels and crosses slot rollover" {
    var wheel = try TimerWheel.init(std.testing.allocator, 4, slot_count - 2);
    defer wheel.deinit();
    var due: [4]u32 = undefined;

    wheel.schedule(0, slot_count - 1);
    wheel.schedule(1, slot_count + 2);
    wheel.schedule(2, slot_count + 1);
    wheel.cancel(2);
    try std.testing.expectEqual(@as(?u64, slot_count - 1), wheel.nextDeadline());
    try std.testing.expectEqual(@as(usize, 0), wheel.takeDue(slot_count - 2, &due));
    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(slot_count - 1, &due));
    try std.testing.expectEqual(@as(u32, 0), due[0]);
    try std.testing.expectEqual(@as(?u64, slot_count + 2), wheel.nextDeadline());
    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(slot_count + 2, &due));
    try std.testing.expectEqual(@as(u32, 1), due[0]);
    try std.testing.expectEqual(@as(?u64, null), wheel.nextDeadline());
}

test "rescheduling keeps one intrusive entry per client" {
    var wheel = try TimerWheel.init(std.testing.allocator, 2, 100);
    defer wheel.deinit();
    var due: [2]u32 = undefined;
    wheel.schedule(0, 200);
    wheel.schedule(0, 150);
    try std.testing.expectEqual(@as(?u64, 150), wheel.nextDeadline());
    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(150, &due));
    try std.testing.expectEqual(@as(u32, 0), due[0]);
    try std.testing.expectEqual(@as(usize, 0), wheel.takeDue(200, &due));
}

test "overdue work scheduled behind the cursor runs on the next pass" {
    var wheel = try TimerWheel.init(std.testing.allocator, 1, 100);
    defer wheel.deinit();
    var due: [1]u32 = undefined;

    try std.testing.expectEqual(@as(usize, 0), wheel.takeDue(125, &due));
    try std.testing.expectEqual(@as(u64, 126), wheel.cursor_ms);

    wheel.schedule(0, 100);
    try std.testing.expectEqual(@as(?u64, 126), wheel.nextDeadline());
    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(126, &due));
    try std.testing.expectEqual(@as(u32, 0), due[0]);
}

test "updating an unchanged deadline preserves the cached minimum" {
    var wheel = try TimerWheel.init(std.testing.allocator, 2, 100);
    defer wheel.deinit();

    wheel.schedule(0, 150);
    wheel.schedule(1, 200);
    try std.testing.expectEqual(@as(?u64, 150), wheel.nextDeadline());
    try std.testing.expect(!wheel.next_dirty);

    wheel.update(0, 150);
    try std.testing.expect(!wheel.next_dirty);
    try std.testing.expectEqual(@as(?u64, 150), wheel.nextDeadline());

    wheel.update(0, null);
    try std.testing.expectEqual(@as(?u64, 200), wheel.nextDeadline());
}
