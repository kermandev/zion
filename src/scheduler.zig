const std = @import("std");

pub const slot_count: usize = 65_536;
const none = std.math.maxInt(u32);
const no_deadline = std.math.maxInt(u64);

// Hierarchical occupancy bitmap over the 65,536 one-ms slots. A set bit marks a
// slot whose intrusive chain is non-empty: `occupancy` tracks slots, `summary`
// tracks occupancy words, `top` tracks summary words. Nesting them this way
// finds the nearest occupied slot (for the next deadline and for skipping idle
// gaps) in a bounded number of steps that does not depend on the client count.
//
// Invariant relied on by the scans: every live deadline sits in the half-open
// window [cursor_ms, cursor_ms + slot_count). `schedule` clamps to that window
// (lower bound via @max, upper bound via @min), so within one revolution slot
// order is time order and the nearest occupied slot in ring order from the
// cursor holds the earliest deadline. Real deadlines never exceed a 30 s backoff
// (< slot_count ms), so the upper clamp is only a safety net; a far-future
// deadline degrades to firing at the window edge rather than corrupting the scan.
const slot_words = slot_count / 64;
const summary_words = slot_words / 64;

/// Shard-local intrusive timing wheel. Each client owns at most one entry, so
/// scheduling and cancellation do not allocate and do not touch another shard.
pub const TimerWheel = struct {
    allocator: std.mem.Allocator,
    heads: []u32,
    next: []u32,
    previous: []u32,
    deadlines: []u64,
    occupancy: []u64,
    summary: []u64,
    top: u64,
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
        const occupancy = try allocator.alloc(u64, slot_words);
        errdefer allocator.free(occupancy);
        @memset(occupancy, 0);
        const summary = try allocator.alloc(u64, summary_words);
        errdefer allocator.free(summary);
        @memset(summary, 0);
        return .{
            .allocator = allocator,
            .heads = heads,
            .next = next,
            .previous = previous,
            .deadlines = deadlines,
            .occupancy = occupancy,
            .summary = summary,
            .top = 0,
            .cursor_ms = now_ms,
        };
    }

    pub fn deinit(self: *TimerWheel) void {
        self.allocator.free(self.heads);
        self.allocator.free(self.next);
        self.allocator.free(self.previous);
        self.allocator.free(self.deadlines);
        self.allocator.free(self.occupancy);
        self.allocator.free(self.summary);
        self.* = undefined;
    }

    pub fn schedule(self: *TimerWheel, index: usize, deadline_ms: u64) void {
        std.debug.assert(index < self.deadlines.len);
        self.cancel(index);
        // takeDue advances cursor_ms past every slot it has inspected. Clamp
        // overdue work up to that cursor so it stays visible on the next pass,
        // and clamp far-future work down to the last slot of this revolution so
        // the occupancy scans stay valid (see the module comment above).
        const effective_deadline = @min(@max(deadline_ms, self.cursor_ms), self.cursor_ms + slot_count - 1);
        const slot = slotFor(effective_deadline);
        const old_head = self.heads[slot];
        self.heads[slot] = @intCast(index);
        self.next[index] = old_head;
        self.previous[index] = none;
        if (old_head != none) self.previous[old_head] = @intCast(index);
        self.deadlines[index] = effective_deadline;
        self.markOccupied(slot);
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

    /// Fires every entry whose deadline is <= now_ms into `out`, returning the
    /// count. Caller invariant: `out.len` >= number of live entries. Each client
    /// owns at most one entry, so sizing `out` to the shard's client count (as
    /// pool.zig does) always suffices; the assert below guards that contract.
    pub fn takeDue(self: *TimerWheel, now_ms: u64, out: []u32) usize {
        var count: usize = 0;
        while (self.cursor_ms <= now_ms) {
            const slot = slotFor(self.cursor_ms);
            if (self.heads[slot] == none) {
                // Idle gap: jump straight to the next occupied slot instead of
                // stepping one ms at a time (a 30 s sleep would be 30k steps).
                self.cursor_ms = self.nextCursor(now_ms);
                continue;
            }
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
            self.cursor_ms += 1;
        }
        return count;
    }

    pub fn nextDeadline(self: *TimerWheel) ?u64 {
        if (self.next_dirty) self.recomputeNext();
        return self.cached_next;
    }

    // Advances the cursor to the next occupied slot's ms, or to now_ms + 1 if no
    // occupied slot falls at-or-before now_ms (which also ends the takeDue loop).
    fn nextCursor(self: *const TimerWheel, now_ms: u64) u64 {
        const start = slotFor(self.cursor_ms);
        const target = self.firstOccupiedRing(start) orelse return now_ms + 1;
        // Ring distance from the (empty) cursor slot to the target slot; always
        // >= 1 since the cursor slot itself is empty.
        const delta = (target -% start) & (slot_count - 1);
        const candidate = self.cursor_ms + delta;
        return if (candidate > now_ms) now_ms + 1 else candidate;
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
        if (self.heads[slot] == none) self.markEmpty(slot);
    }

    fn recomputeNext(self: *TimerWheel) void {
        const slot = self.firstOccupiedRing(slotFor(self.cursor_ms)) orelse {
            self.cached_next = null;
            self.next_dirty = false;
            return;
        };
        // The nearest occupied slot in ring order holds the earliest deadline
        // (window invariant). Chains are short; take the min across this one.
        var earliest: u64 = no_deadline;
        var current = self.heads[slot];
        while (current != none) : (current = self.next[current]) {
            earliest = @min(earliest, self.deadlines[current]);
        }
        self.cached_next = earliest;
        self.next_dirty = false;
    }

    fn markOccupied(self: *TimerWheel, slot: usize) void {
        const word = slot >> 6;
        self.occupancy[word] |= bit(slot);
        const summary_word = word >> 6;
        self.summary[summary_word] |= bit(word);
        self.top |= bit(summary_word);
    }

    fn markEmpty(self: *TimerWheel, slot: usize) void {
        const word = slot >> 6;
        self.occupancy[word] &= ~bit(slot);
        if (self.occupancy[word] != 0) return;
        const summary_word = word >> 6;
        self.summary[summary_word] &= ~bit(word);
        if (self.summary[summary_word] != 0) return;
        self.top &= ~bit(summary_word);
    }

    // Single-bit mask for `index` within its own 64-bit word.
    fn bit(index: usize) u64 {
        return @as(u64, 1) << @intCast(index & 63);
    }

    // Nearest occupied slot at-or-after `start` in ring order (wrapping once),
    // or null if the wheel is empty.
    fn firstOccupiedRing(self: *const TimerWheel, start: usize) ?usize {
        if (self.scanFrom(start)) |slot| return slot;
        if (start == 0) return null;
        return self.scanFrom(0);
    }

    // Smallest occupied slot index >= `start`, without wrapping, via the
    // occupancy/summary/top hierarchy. Null if none in [start, slot_count).
    fn scanFrom(self: *const TimerWheel, start: usize) ?usize {
        std.debug.assert(start < slot_count);

        const word = start >> 6;
        const slot_bits = bitsFrom(self.occupancy[word], start);
        if (slot_bits != 0) return (word << 6) | @ctz(slot_bits);

        const next_word = word + 1;
        if (next_word >= slot_words) return null;
        const summary_word = next_word >> 6;

        const occupied_word = found: {
            const word_bits = bitsFrom(self.summary[summary_word], next_word);
            if (word_bits != 0) break :found (summary_word << 6) | @ctz(word_bits);

            const next_summary_word = summary_word + 1;
            if (next_summary_word >= summary_words) return null;
            const summary_bits = bitsFrom(self.top, next_summary_word);
            if (summary_bits == 0) return null;
            // usize, not @ctz's u7: `<< 6` truncates in the operand type.
            const occupied_summary: usize = @ctz(summary_bits);
            break :found (occupied_summary << 6) | @ctz(self.summary[occupied_summary]);
        };
        return (occupied_word << 6) | @ctz(self.occupancy[occupied_word]);
    }

    // `word` with every bit below `index`'s position cleared.
    fn bitsFrom(word: u64, index: usize) u64 {
        const shift: u6 = @intCast(index & 63);
        return (word >> shift) << shift;
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

test "far-future deadlines clamp into the current revolution" {
    var wheel = try TimerWheel.init(std.testing.allocator, 2, 100);
    defer wheel.deinit();
    var due: [2]u32 = undefined;

    const far = 100 + slot_count + 500;
    const clamp = 100 + slot_count - 1;
    wheel.schedule(0, far);
    try std.testing.expectEqual(@as(u64, clamp), wheel.deadlines[0]);
    try std.testing.expectEqual(@as(?u64, clamp), wheel.nextDeadline());

    // A genuinely nearer deadline is still reported as the minimum.
    wheel.schedule(1, 200);
    try std.testing.expectEqual(@as(?u64, 200), wheel.nextDeadline());
    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(200, &due));
    try std.testing.expectEqual(@as(u32, 1), due[0]);

    // The clamped entry fires at the window edge, not at its far-future request.
    try std.testing.expectEqual(@as(?u64, clamp), wheel.nextDeadline());
    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(clamp, &due));
    try std.testing.expectEqual(@as(u32, 0), due[0]);
    try std.testing.expectEqual(@as(?u64, null), wheel.nextDeadline());
}

test "takeDue skips idle gaps without losing entries" {
    var wheel = try TimerWheel.init(std.testing.allocator, 2, 0);
    defer wheel.deinit();
    var due: [2]u32 = undefined;

    wheel.schedule(0, 5);
    wheel.schedule(1, 30_000); // a 30 s gap after entry 0

    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(5, &due));
    try std.testing.expectEqual(@as(u32, 0), due[0]);
    try std.testing.expectEqual(@as(u64, 6), wheel.cursor_ms);

    // Nothing due mid-gap; the cursor jumps to now+1 instead of crawling.
    try std.testing.expectEqual(@as(usize, 0), wheel.takeDue(20_000, &due));
    try std.testing.expectEqual(@as(u64, 20_001), wheel.cursor_ms);
    try std.testing.expectEqual(@as(?u64, 30_000), wheel.nextDeadline());

    try std.testing.expectEqual(@as(usize, 1), wheel.takeDue(30_000, &due));
    try std.testing.expectEqual(@as(u32, 1), due[0]);
    try std.testing.expectEqual(@as(u64, 30_001), wheel.cursor_ms);
}

test "next deadline recomputes after cancelling the minimum" {
    var wheel = try TimerWheel.init(std.testing.allocator, 3, 0);
    defer wheel.deinit();

    wheel.schedule(0, 100);
    wheel.schedule(1, 50);
    wheel.schedule(2, 75);
    try std.testing.expectEqual(@as(?u64, 50), wheel.nextDeadline());

    wheel.cancel(1); // cancel the current minimum
    try std.testing.expectEqual(@as(?u64, 75), wheel.nextDeadline());

    wheel.cancel(2); // cancel the new minimum
    try std.testing.expectEqual(@as(?u64, 100), wheel.nextDeadline());

    wheel.cancel(0);
    try std.testing.expectEqual(@as(?u64, null), wheel.nextDeadline());
}
