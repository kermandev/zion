const std = @import("std");
const client = @import("client.zig");
const stats_module = @import("stats.zig");

pub const IndexedBot = struct {
    global_index: u32,
};

pub const Stats = struct {
    requested: usize = 0,
    connected: usize = 0,
    waiting: usize = 0,
    connecting: usize = 0,
    play: usize = 0,
    reconnects: u64 = 0,
    packets_received: u64 = 0,
    keep_alives_answered: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,
    duration_ms: u64 = 0,

    pub fn add(stats: *Stats, other: Stats) void {
        stats.requested += other.requested;
        stats.connected += other.connected;
        stats.waiting += other.waiting;
        stats.connecting += other.connecting;
        stats.play += other.play;
        stats.reconnects += other.reconnects;
        stats.packets_received += other.packets_received;
        stats.keep_alives_answered += other.keep_alives_answered;
        stats.bytes_received += other.bytes_received;
        stats.bytes_sent += other.bytes_sent;
    }
};

pub fn collectStats(clients: *client.ClientTable) Stats {
    var stats: Stats = .{ .requested = clients.global_indices.items.len };
    const pool = clients.pool.slice();
    for (0..clients.global_indices.items.len) |i| {
        switch (pool.items(.state)[i]) {
            .waiting, .draining => stats.waiting += 1,
            .connecting => stats.connecting += 1,
            .connected => stats.connected += 1,
        }
        if (clients.phases.items[i] == .play) stats.play += 1;
    }
    return stats;
}

pub fn shardCount(requested: ?usize, client_count: usize) usize {
    if (client_count == 0) return 1;
    const default_clients_per_shard = 200;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const default_shards = @min(std.math.divCeil(usize, client_count, default_clients_per_shard) catch 1, cpu_count);
    const normalized = @max(requested orelse default_shards, 1);
    return @min(normalized, client_count);
}

pub fn partitionBots(allocator: std.mem.Allocator, client_count: usize, shard_count: usize) ![][]IndexedBot {
    if (client_count > std.math.maxInt(u32)) return error.TooManyClients;
    const counts = try allocator.alloc(usize, shard_count);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (0..client_count) |index| counts[shardFor(index, shard_count)] += 1;

    const partitions = try allocator.alloc([]IndexedBot, shard_count);
    errdefer allocator.free(partitions);

    var allocated: usize = 0;
    errdefer for (partitions[0..allocated]) |partition| allocator.free(partition);
    for (counts, 0..) |count, shard_id| {
        partitions[shard_id] = try allocator.alloc(IndexedBot, count);
        allocated += 1;
    }

    @memset(counts, 0);
    for (0..client_count) |index| {
        const shard_id = shardFor(index, shard_count);
        const offset = counts[shard_id];
        counts[shard_id] += 1;
        partitions[shard_id][offset] = .{ .global_index = @intCast(index) };
    }
    return partitions;
}

pub fn freeBotPartitions(allocator: std.mem.Allocator, partitions: [][]IndexedBot) void {
    for (partitions) |partition| allocator.free(partition);
    allocator.free(partitions);
}

pub fn shardFor(index: usize, shard_count: usize) usize {
    return index % shard_count;
}

pub fn initialConnectOffsetMs(index: usize, connect_rate_per_sec: u32) u64 {
    if (connect_rate_per_sec == 0) return 0;
    const offset = (@as(u128, index) * 1000) / connect_rate_per_sec;
    return @intCast(@min(offset, std.math.maxInt(u64)));
}

test "ClientTable appends identities and initializes runtime columns" {
    if (comptime !@import("features.zig").broadcast) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const cached = try client.CachedPacket.initOwned(allocator, try allocator.dupe(u8, "hello"));
    defer cached.deinit(allocator);

    var clients: client.ClientTable = .{
        .broadcast_packet = cached,
        .broadcast_interval_ms = 1000,
    };
    defer clients.deinit(allocator);

    try clients.ensureTotalCapacity(allocator, 2);
    clients.appendAssumeCapacity(0, 100);
    clients.appendAssumeCapacity(1, 100);

    try std.testing.expectEqual(@as(usize, 2), clients.global_indices.items.len);
    try std.testing.expectEqual(@as(usize, 2), clients.phases.items.len);
    try std.testing.expectEqual(@as(usize, 2), clients.sessions.len);
    if (stats_module.diagnostics_enabled) try std.testing.expectEqual(@as(usize, 2), clients.stats.len);

    try std.testing.expectEqual(@as(u32, 0), clients.global_indices.items[0]);
    try std.testing.expectEqual(@as(u32, 1), clients.global_indices.items[1]);
    try std.testing.expectEqualStrings("hello", clients.broadcast_packet.?.body);
    try std.testing.expectEqual(@as(u64, 1000), clients.broadcast_interval_ms);

    try std.testing.expectEqual(client.Phase.disconnected, clients.phases.items[0]);
    try std.testing.expectEqual(client.Phase.disconnected, clients.phases.items[1]);
    if (stats_module.diagnostics_enabled) {
        const stats = clients.stats.slice();
        try std.testing.expectEqual(@as(i32, -1), stats.items(.last_packet_id)[1]);
    }
}

test "getPhase mutates the selected client state column" {
    const allocator = std.testing.allocator;
    var clients: client.ClientTable = .{};
    defer clients.deinit(allocator);

    try clients.ensureTotalCapacity(allocator, 2);
    clients.appendAssumeCapacity(0, 0);
    clients.appendAssumeCapacity(1, 0);

    clients.getPhase(1).* = .play;
    if (stats_module.diagnostics_enabled) {
        const stats = clients.stats.slice();
        stats.items(.last_packet_id)[1] = 0x2b;
    }

    try std.testing.expectEqual(client.Phase.disconnected, clients.phases.items[0]);
    try std.testing.expectEqual(client.Phase.play, clients.phases.items[1]);
    if (stats_module.diagnostics_enabled) {
        const stats = clients.stats.slice();
        try std.testing.expectEqual(@as(i32, 0x2b), stats.items(.last_packet_id)[1]);
    }
}

test "client usernames are derived without per-client strings" {
    const allocator = std.testing.allocator;
    var clients: client.ClientTable = .{ .username_prefix = "Load" };
    defer clients.deinit(allocator);

    try clients.ensureTotalCapacity(allocator, 1);
    clients.appendAssumeCapacity(41, 0);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Load42", try client.username(&clients, 0, &buffer));
}

test "idle movement allocates no per-client motion state" {
    if (comptime !@import("features.zig").movement) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var clients: client.ClientTable = .{ .movement = .{ .profile = .idle } };
    defer clients.deinit(allocator);

    try clients.ensureTotalCapacity(allocator, 128);
    clients.appendAssumeCapacity(0, 0);

    try std.testing.expectEqual(@as(usize, 0), clients.motion_states.capacity);
    try std.testing.expectEqual(@as(usize, 0), clients.motion_states.items.len);
}

test "active movement allocates one motion state per client" {
    if (comptime !@import("features.zig").movement) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var clients: client.ClientTable = .{ .movement = .{ .profile = .walk } };
    defer clients.deinit(allocator);

    try clients.ensureTotalCapacity(allocator, 2);
    clients.appendAssumeCapacity(0, 0);
    clients.appendAssumeCapacity(1, 0);

    try std.testing.expectEqual(@as(usize, 2), clients.motion_states.items.len);
}

test "Stats.add aggregates shard counters without duration" {
    var stats: Stats = .{
        .requested = 10,
        .connected = 4,
        .waiting = 3,
        .connecting = 3,
        .play = 4,
        .reconnects = 2,
        .packets_received = 100,
        .keep_alives_answered = 5,
        .bytes_received = 8192,
        .bytes_sent = 1024,
        .duration_ms = 111,
    };

    stats.add(.{
        .requested = 5,
        .connected = 2,
        .waiting = 1,
        .connecting = 2,
        .play = 1,
        .reconnects = 7,
        .packets_received = 50,
        .keep_alives_answered = 3,
        .bytes_received = 4096,
        .bytes_sent = 2048,
        .duration_ms = 999,
    });

    try std.testing.expectEqual(@as(usize, 15), stats.requested);
    try std.testing.expectEqual(@as(usize, 6), stats.connected);
    try std.testing.expectEqual(@as(usize, 4), stats.waiting);
    try std.testing.expectEqual(@as(usize, 5), stats.connecting);
    try std.testing.expectEqual(@as(usize, 5), stats.play);
    try std.testing.expectEqual(@as(u64, 9), stats.reconnects);
    try std.testing.expectEqual(@as(u64, 150), stats.packets_received);
    try std.testing.expectEqual(@as(u64, 8), stats.keep_alives_answered);
    try std.testing.expectEqual(@as(u64, 12_288), stats.bytes_received);
    try std.testing.expectEqual(@as(u64, 3072), stats.bytes_sent);
    try std.testing.expectEqual(@as(u64, 111), stats.duration_ms);
}

test "collectStats aggregates hot columns from client table" {
    const allocator = std.testing.allocator;
    var clients: client.ClientTable = .{};
    defer clients.deinit(allocator);

    try clients.ensureTotalCapacity(allocator, 3);
    for (0..3) |i| {
        clients.appendAssumeCapacity(@intCast(i), 0);
    }

    const pool = clients.pool.slice();
    pool.items(.state)[0] = .connected;
    pool.items(.state)[1] = .connecting;
    pool.items(.state)[2] = .waiting;
    clients.getPhase(0).* = .play;
    clients.getPhase(1).* = .login;

    const stats = collectStats(&clients);
    try std.testing.expectEqual(@as(usize, 3), stats.requested);
    try std.testing.expectEqual(@as(usize, 1), stats.connected);
    try std.testing.expectEqual(@as(usize, 1), stats.connecting);
    try std.testing.expectEqual(@as(usize, 1), stats.waiting);
    try std.testing.expectEqual(@as(usize, 1), stats.play);
}

test "initialConnectOffsetMs ramps initial connection attempts" {
    try std.testing.expectEqual(@as(u64, 0), initialConnectOffsetMs(0, 25));
    try std.testing.expectEqual(@as(u64, 40), initialConnectOffsetMs(1, 25));
    try std.testing.expectEqual(@as(u64, 3960), initialConnectOffsetMs(99, 25));
    try std.testing.expectEqual(@as(u64, 0), initialConnectOffsetMs(99, 0));
    try std.testing.expectEqual(@as(u64, 1), initialConnectOffsetMs(3, 2000));
}

test "shardCount normalizes requested shards" {
    try std.testing.expectEqual(@as(usize, 1), shardCount(0, 100));
    try std.testing.expectEqual(@as(usize, 1), shardCount(1, 100));
    try std.testing.expectEqual(@as(usize, 4), shardCount(4, 100));
    try std.testing.expectEqual(@as(usize, 2), shardCount(8, 2));
    try std.testing.expectEqual(@as(usize, 1), shardCount(8, 0));
    const cpu_count = std.Thread.getCpuCount() catch 1;
    try std.testing.expectEqual(@as(usize, 1), shardCount(null, 100));
    try std.testing.expectEqual(@as(usize, 1), shardCount(null, 200));
    try std.testing.expectEqual(@min(@as(usize, 2), cpu_count), shardCount(null, 201));
    try std.testing.expectEqual(@min(@as(usize, 5), cpu_count), shardCount(null, 1000));
    try std.testing.expectEqual(cpu_count, shardCount(null, 50_000));
}

test "shardFor distributes every requested client across available shards" {
    var counts = [_]usize{ 0, 0, 0, 0 };
    for (0..20) |i| {
        counts[shardFor(i, counts.len)] += 1;
    }

    try std.testing.expectEqualSlices(usize, &.{ 5, 5, 5, 5 }, &counts);
}

test "partitionBots preserves identities and global indices" {
    const partitions = try partitionBots(std.testing.allocator, 4, 2);
    defer freeBotPartitions(std.testing.allocator, partitions);

    try std.testing.expectEqual(@as(usize, 2), partitions.len);
    try std.testing.expectEqual(@as(u32, 0), partitions[0][0].global_index);
    try std.testing.expectEqual(@as(u32, 2), partitions[0][1].global_index);
    try std.testing.expectEqual(@as(u32, 1), partitions[1][0].global_index);
}
