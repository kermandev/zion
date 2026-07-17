const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const endpoint = @import("endpoint.zig");
const features = @import("features.zig");
const client = @import("client.zig");
const client_table = @import("client_table.zig");
const stats_module = @import("stats.zig");

pub const BroadcastSummary = if (features.broadcast) struct {
    interval_ms: u64,
    label: []const u8,
} else void;

pub const RunHeader = struct {
    target: endpoint.Target,
    client_count: usize,
    shard_count: usize,
    known_core_pack: bool = false,
    broadcast: if (features.broadcast) ?BroadcastSummary else void = if (features.broadcast) null else {},
    client_tick: if (features.client_tick) bool else void = if (features.client_tick) false else {},
    progress_detail: if (features.diagnostics) bool else void = if (features.diagnostics) false else {},
    movement: if (features.movement) client.MovementConfig else void = if (features.movement) .{} else {},
};

pub fn writeUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\usage:
        \\  zion --target <endpoint> --clients <count> [options]
        \\
        \\endpoints:
        \\  hostname or IPv4[:port]     minecraft.example.com or 127.0.0.1:25565
        \\  IPv6                       ::1 or [::1]:25565
        \\  Unix socket                unix:/run/minecraft.sock
        \\
        \\options:
        \\  --target <endpoint>         Server endpoint (required)
        \\  --handshake-host <host>     Unix-only handshake host. Default: localhost
        \\  --handshake-port <port>     Unix-only handshake port. Default: 25565
        \\  --clients <count>           Number of simulated clients (required)
        \\  --shards <count>            Number of threads/shards. Default: about 200 clients per shard
        \\  --connect-rate <per-sec>    Connection rate per second. Default: 100
        \\  --username-prefix <prefix>  Prefix for client usernames. Default: "Zion"
        \\  --known-core-pack           Advertise minecraft:core for the compiled version
        \\
    );
    if (comptime features.broadcast) try writer.writeAll(
        \\  --broadcast-ms <ms>         Interval for periodic broadcast chat message
        \\  --broadcast <message>       The text of the broadcast message
        \\
    );
    if (comptime features.client_tick) try writer.writeAll(
        \\  --client-tick               Enable sending client tick packets every 50ms
        \\
    );
    if (comptime features.movement) try writer.writeAll(
        \\  --movement <mode>           idle, rotate, or bounded walk. Default: idle
        \\  --movement-ms <ms>          Active movement interval. Default: 50
        \\  --movement-radius <blocks>  Walk radius. Default: 16
        \\  --movement-speed <blocks/s> Walk speed. Default: 4.3
        \\  --rotation-rate <degrees/s> Maximum turn rate. Default: 180
        \\  --movement-seed <seed>      Deterministic movement seed. Default: 0
        \\
    );
    if (comptime features.diagnostics) try writer.writeAll(
        \\  --progress-detail           Print detailed join logs instead of progress bar
        \\
    );
    try writer.writeAll(
        \\  -V, --version               Show version information
        \\  -h, --help                  Show this help message
        \\
    );
}

pub fn writeVersion(writer: *Io.Writer) !void {
    try writer.print("zion {s} (Minecraft Java {s}, protocol {d}; Zig {s}; features:", .{
        build_options.zion_version,
        client.protocol.current.minecraft_version,
        client.protocol.current.protocol_version,
        builtin.zig_version_string,
    });
    if (comptime features.stats) try writer.writeAll(" stats");
    if (comptime features.compression) try writer.writeAll(" compression");
    if (comptime features.movement) try writer.writeAll(" movement");
    if (comptime features.broadcast) try writer.writeAll(" broadcast");
    if (comptime features.client_tick) try writer.writeAll(" client-tick");
    if (comptime features.diagnostics) try writer.writeAll(" diagnostics");
    if (comptime !features.stats and !features.compression and !features.movement and !features.broadcast and !features.client_tick and !features.diagnostics) {
        try writer.writeAll(" none");
    }
    try writer.writeAll(")\n");
}

pub fn writeRunHeader(writer: *Io.Writer, header: RunHeader) !void {
    try writer.writeAll("target: ");
    try writeTarget(writer, header.target);
    try writer.writeByte('\n');
    try writer.print("clients: {d} across {d} {s}\n", .{ header.client_count, header.shard_count, if (header.shard_count == 1) "shard" else "shards" });
    if (header.known_core_pack) try writer.print("known pack: minecraft:core:{s}\n", .{client.protocol.current.minecraft_version});
    if (comptime features.broadcast) {
        if (header.broadcast) |broadcast| try writer.print("broadcast: every {d}ms: {s}\n", .{ broadcast.interval_ms, broadcast.label });
    }
    if (comptime features.client_tick) {
        if (header.client_tick) try writer.writeAll("client tick: every 50ms\n");
    }
    if (comptime features.movement) {
        try writer.print("movement: {s}", .{@tagName(header.movement.profile)});
        if (header.movement.profile != .idle) try writer.print(" every {d}ms", .{header.movement.interval_ms});
        try writer.writeByte('\n');
    }
    if (comptime features.diagnostics) {
        if (header.progress_detail) try writer.writeAll("progress: detailed join diagnostics\n");
    }
}

pub fn writeTarget(writer: *Io.Writer, target: endpoint.Target) !void {
    switch (target) {
        .tcp => |tcp| try writeHostPort(writer, tcp.host, tcp.port),
        .unix => |unix| {
            try writer.print("unix:{s} (handshake ", .{unix.path});
            try writeHostPort(writer, unix.handshake_host, unix.handshake_port);
            try writer.writeByte(')');
        },
    }
}

fn writeHostPort(writer: *Io.Writer, host: []const u8, port: u16) !void {
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        try writer.print("[{s}]:{d}", .{ host, port });
    } else {
        try writer.print("{s}:{d}", .{ host, port });
    }
}

pub fn writeStatsBlocking(io: Io, stats: client_table.Stats) !void {
    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeStats(&writer, stats);
    try Io.File.stdout().writeStreamingAll(io, writer.buffered());
}

pub fn writeStats(writer: *Io.Writer, stats: client_table.Stats) !void {
    const seconds = @as(f64, @floatFromInt(stats.duration_ms)) / 1000.0;
    const rate_seconds = @max(seconds, 0.001);
    const requested = @as(f64, @floatFromInt(stats.requested));
    const connected_percent = if (stats.requested == 0) 0.0 else @as(f64, @floatFromInt(stats.connected)) * 100.0 / requested;
    const play_percent = if (stats.requested == 0) 0.0 else @as(f64, @floatFromInt(stats.play)) * 100.0 / requested;

    try writer.writeAll("\nstats:\n");
    try writer.print(
        "  runtime: {d:.2}s\n" ++
            "  clients: requested={d} connected={d} ({d:.1}%) play={d} ({d:.1}%) connecting={d} waiting={d}\n",
        .{ seconds, stats.requested, stats.connected, connected_percent, stats.play, play_percent, stats.connecting, stats.waiting },
    );

    if (comptime !stats_module.stats_enabled) {
        try writer.writeAll("  counters: disabled at compile time (-Denable-stats=false)\n");
        return;
    }

    const packets_per_sec = @as(f64, @floatFromInt(stats.packets_received)) / rate_seconds;
    const reconnects_per_sec = @as(f64, @floatFromInt(stats.reconnects)) / rate_seconds;
    const rx_per_sec = @as(f64, @floatFromInt(stats.bytes_received)) / rate_seconds;
    const tx_per_sec = @as(f64, @floatFromInt(stats.bytes_sent)) / rate_seconds;
    try writer.print(
        "  reconnects: total={d} avg={d:.3}/s\n" ++
            "  packets: received={d} keepalives={d} avg={d:.2}/s\n",
        .{ stats.reconnects, reconnects_per_sec, stats.packets_received, stats.keep_alives_answered, packets_per_sec },
    );
    try writer.writeAll("  traffic: rx=");
    try writeBytes(writer, @floatFromInt(stats.bytes_received), false);
    try writer.writeAll(" tx=");
    try writeBytes(writer, @floatFromInt(stats.bytes_sent), false);
    try writer.writeAll(" total=");
    try writeBytes(writer, @floatFromInt(stats.bytes_received +| stats.bytes_sent), false);
    try writer.writeByte('\n');
    try writer.writeAll("  rates: rx=");
    try writeBytes(writer, rx_per_sec, true);
    try writer.writeAll(" tx=");
    try writeBytes(writer, tx_per_sec, true);
    try writer.writeByte('\n');
}

fn writeBytes(writer: *Io.Writer, value: f64, per_second: bool) !void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var scaled = value;
    var unit_index: usize = 0;
    while (scaled >= 1024.0 and unit_index + 1 < units.len) : (unit_index += 1) scaled /= 1024.0;
    if (unit_index == 0) try writer.print("{d:.0} {s}", .{ scaled, units[unit_index] }) else try writer.print("{d:.2} {s}", .{ scaled, units[unit_index] });
    if (per_second) try writer.writeAll("/s");
}

pub fn writeReachabilityError(writer: *Io.Writer, target: endpoint.Target, err: anyerror) !void {
    switch (target) {
        .unix => |unix| switch (err) {
            error.FileNotFound => try writer.print("Unix socket {s} does not exist\n", .{unix.path}),
            error.NotDir => try writer.print("a parent component of Unix socket {s} is not a directory\n", .{unix.path}),
            error.AccessDenied, error.PermissionDenied => try writer.print("permission denied connecting to Unix socket {s}\n", .{unix.path}),
            error.NameTooLong => try writer.print("Unix socket path is too long: {s}\n", .{unix.path}),
            else => try writer.print("unable to connect to Unix socket {s}: {t}\n", .{ unix.path, err }),
        },
        .tcp => |tcp| switch (err) {
            error.ConnectionRefused => {
                try writer.writeAll("server ");
                try writeHostPort(writer, tcp.host, tcp.port);
                try writer.writeAll(" refused the connection; check that the Minecraft server is running and listening on that host/port\n");
            },
            error.HostUnreachable => {
                try writer.writeAll("server host ");
                try writeHostPort(writer, tcp.host, tcp.port);
                try writer.writeAll(" is unreachable; check the address, route, firewall, or container networking\n");
            },
            error.NetworkUnreachable => {
                try writer.writeAll("network is unreachable while connecting to ");
                try writeHostPort(writer, tcp.host, tcp.port);
                try writer.writeAll("; check local network configuration\n");
            },
            error.ConnectionTimedOut, error.Timeout => {
                try writer.writeAll("timed out connecting to ");
                try writeHostPort(writer, tcp.host, tcp.port);
                try writer.writeAll("; check that the server is reachable and accepting status connections\n");
            },
            else => {
                try writer.writeAll("unable to connect to ");
                try writeHostPort(writer, tcp.host, tcp.port);
                try writer.print(": {t}\n", .{err});
            },
        },
    }
}

test "writeUsage documents only the unified target syntax" {
    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    try writeUsage(&writer);

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "zion --target <endpoint> --clients <count> [options]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--handshake-host <host>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--known-core-pack") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--version") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--host <host>") == null);
    try std.testing.expect(std.mem.endsWith(u8, output, "Show this help message\n"));
}

test "writeVersion identifies the application and compiled protocol" {
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    try writeVersion(&writer);

    const output = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, output, "zion " ++ build_options.zion_version ++ " (Minecraft Java "));
    try std.testing.expect(std.mem.indexOf(u8, output, client.protocol.current.minecraft_version) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, builtin.zig_version_string) != null);
    try std.testing.expect(std.mem.endsWith(u8, output, ")\n"));
}

test "writeTarget formats IPv6 and Unix handshake endpoints" {
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    try writeTarget(&writer, .{ .tcp = .{ .host = "::1" } });
    try writer.writeByte('\n');
    try writeTarget(&writer, .{ .unix = .{
        .path = "/tmp/minecraft.sock",
        .handshake_host = "2001:db8::1",
        .handshake_port = 25570,
    } });

    try std.testing.expectEqualStrings("[::1]:25565\nunix:/tmp/minecraft.sock (handshake [2001:db8::1]:25570)", writer.buffered());
}

test "writeStats includes client packet and traffic rates" {
    var buffer: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeStats(&writer, .{
        .requested = 100,
        .connected = 80,
        .waiting = 10,
        .connecting = 10,
        .play = 75,
        .reconnects = 4,
        .packets_received = 200,
        .keep_alives_answered = 12,
        .bytes_received = 2048,
        .bytes_sent = 1024,
        .duration_ms = 2000,
    });
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "requested=100 connected=80 (80.0%) play=75 (75.0%)") != null);
    if (comptime stats_module.stats_enabled) {
        try std.testing.expect(std.mem.indexOf(u8, output, "reconnects: total=4 avg=2.000/s") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "traffic: rx=2.00 KiB tx=1.00 KiB total=3.00 KiB") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output, "counters: disabled at compile time") != null);
    }
}

test "writeRunHeader shows enabled load features" {
    if (comptime !(features.broadcast and features.client_tick and features.diagnostics and features.movement)) return error.SkipZigTest;
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeRunHeader(&writer, .{
        .target = .{ .tcp = .{ .host = "127.0.0.1" } },
        .client_count = 10,
        .shard_count = 1,
        .known_core_pack = true,
        .broadcast = .{ .interval_ms = 2000, .label = "hello" },
        .client_tick = true,
        .progress_detail = true,
        .movement = .{},
    });
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "target: 127.0.0.1:25565\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "clients: 10 across 1 shard\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "known pack: minecraft:core:" ++ client.protocol.current.minecraft_version ++ "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "broadcast: every 2000ms: hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "client tick: every 50ms\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "progress: detailed join diagnostics\n") != null);
}

test "writeReachabilityError brackets IPv6 endpoints" {
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeReachabilityError(&writer, .{ .tcp = .{ .host = "::1" } }, error.ConnectionRefused);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "server [::1]:25565 refused the connection"));
}
