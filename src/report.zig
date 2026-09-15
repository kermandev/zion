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
        \\  Abstract Unix socket       unix:@minecraft
        \\
        \\options:
        \\  --target <endpoint>         Server endpoint (required)
        \\  --handshake-host <host>     Unix-only handshake host. Default: localhost
        \\  --handshake-port <port>     Unix-only handshake port. Default: 25565
        \\  --clients <count>           Number of simulated clients (required)
        \\  --shards <count>            Number of threads/shards. Default: about 200 clients per shard
        \\  --connect-rate <per-sec>    Connection rate per second; 0 disables the ramp and connects all clients at once. Default: 100
        \\  --username-prefix <prefix>  Prefix for client usernames. Default: "Zion"
        \\  --known-core-pack           Advertise minecraft:core for the compiled version
        \\
    );
    if (comptime features.reconnect) try writer.writeAll(
        \\  --no-reconnect              Do not reconnect dropped clients; they stay disconnected
        \\
    );
    // Feature order matches writeVersion: movement, broadcast, client-tick,
    // diagnostics (stats and compression have no CLI flags).
    if (comptime features.movement) try writer.writeAll(
        \\  --movement <mode>           idle, rotate, or walk (bounded random walk). Default: idle
        \\  --movement-ms <ms>          Active movement interval. Default: 50
        \\  --movement-radius <blocks>  Walk radius. Default: 16
        \\  --movement-speed <blocks/s> Walk speed. Default: 4.3
        \\  --rotation-rate <degrees/s> Maximum turn rate. Default: 180
        \\  --movement-seed <seed>      Deterministic movement seed. Default: 0
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
    if (comptime features.diagnostics) try writer.writeAll(
        \\  --progress-detail           Print detailed join logs instead of progress bar
        \\
    );
    if (comptime features.tui) try writer.writeAll(
        \\  --no-tui                    Use the single-line progress output instead of the dashboard
        \\
    );
    try writer.writeAll(
        \\  -V, --version               Show version information
        \\  -h, --help                  Show this help message
        \\
    );
}

pub fn writeVersion(writer: *Io.Writer) !void {
    // Snapshot protocol versions set bit 30; print the snapshot ordinal
    // instead of the opaque combined number.
    const snapshot_bit: i32 = 1 << 30;
    const protocol_version = client.protocol.current.protocol_version;
    try writer.print("zion {s} (Minecraft Java {s}, ", .{
        build_options.zion_version,
        client.protocol.current.minecraft_version,
    });
    if (comptime protocol_version & snapshot_bit != 0) {
        try writer.print("protocol snapshot {d}", .{protocol_version & ~snapshot_bit});
    } else {
        try writer.print("protocol {d}", .{protocol_version});
    }
    try writer.print("; Zig {s}; features:{s})\n", .{ builtin.zig_version_string, feature_list });
}

// Space prefixed list of the enabled features, or " none" when the build has
// none. writeUsage documents the same set but leads with --no-reconnect.
const feature_list = list: {
    var list: []const u8 = "";
    if (features.stats) list = list ++ " stats";
    if (features.compression) list = list ++ " compression";
    if (features.movement) list = list ++ " movement";
    if (features.broadcast) list = list ++ " broadcast";
    if (features.client_tick) list = list ++ " client-tick";
    if (features.diagnostics) list = list ++ " diagnostics";
    if (features.reconnect) list = list ++ " reconnect";
    if (features.tui) list = list ++ " tui";
    break :list if (list.len == 0) " none" else list;
};

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
        .tcp => |tcp| try writer.print("{f}", .{hostPort(tcp.host, tcp.port)}),
        .unix => |unix| try writer.print("unix:{f} (handshake {f})", .{
            unix,
            hostPort(unix.handshake_host, unix.handshake_port),
        }),
    }
}

fn hostPort(host: []const u8, port: u16) HostPort {
    return .{ .host = host, .port = port };
}

const HostPort = struct {
    host: []const u8,
    port: u16,

    pub fn format(host_port: HostPort, writer: *Io.Writer) Io.Writer.Error!void {
        // Bracket IPv6 literals so the ":port" suffix stays unambiguous.
        if (std.mem.indexOfScalar(u8, host_port.host, ':') != null) {
            try writer.print("[{s}]:{d}", .{ host_port.host, host_port.port });
        } else {
            try writer.print("{s}:{d}", .{ host_port.host, host_port.port });
        }
    }
};

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
    try writeLabel(writer, "runtime");
    try writer.print("{d:.2}s\n", .{seconds});

    try writeLabel(writer, "clients");
    try writer.print("requested={d} connected={d} ({d:.1}%) play={d} ({d:.1}%)", .{ stats.requested, stats.connected, connected_percent, stats.play, play_percent });
    // Transient states are usually zero at the end of a run; only show them
    // when they carry information.
    if (stats.connecting > 0) try writer.print(" connecting={d}", .{stats.connecting});
    if (stats.waiting > 0) try writer.print(" waiting={d}", .{stats.waiting});
    if (stats.stopped > 0) try writer.print(" stopped={d}", .{stats.stopped});
    try writer.writeByte('\n');

    if (comptime stats_module.stats_enabled) {
        const packets_per_sec = @as(f64, @floatFromInt(stats.packets_received)) / rate_seconds;
        const reconnects_per_sec = @as(f64, @floatFromInt(stats.reconnects)) / rate_seconds;
        const rx_per_sec = @as(f64, @floatFromInt(stats.bytes_received)) / rate_seconds;
        const tx_per_sec = @as(f64, @floatFromInt(stats.bytes_sent)) / rate_seconds;

        try writeLabel(writer, "reconnects");
        try writer.print("total={f} avg={d:.3}/s\n", .{ grouped(stats.reconnects), reconnects_per_sec });

        try writeLabel(writer, "packets");
        try writer.print("received={f} keepalives={f} avg={f}/s\n", .{
            grouped(stats.packets_received),
            grouped(stats.keep_alives_answered),
            groupedFixed(packets_per_sec),
        });

        try writeLabel(writer, "traffic");
        try writer.print("rx={f} tx={f} total={f}\n", .{
            bytes(@floatFromInt(stats.bytes_received)),
            bytes(@floatFromInt(stats.bytes_sent)),
            bytes(@floatFromInt(stats.bytes_received +| stats.bytes_sent)),
        });

        try writeLabel(writer, "rates");
        try writer.print("rx={f} tx={f}\n", .{ byteRate(rx_per_sec), byteRate(tx_per_sec) });
    } else {
        try writeLabel(writer, "counters");
        try writer.writeAll("disabled at compile time (-Denable-stats=false)\n");
    }

    if (comptime stats_module.diagnostics_enabled) {
        const diagnostics = stats.diagnostics;
        const keep_alive_avg_ms = if (diagnostics.keep_alive_send_samples == 0)
            0.0
        else
            @as(f64, @floatFromInt(diagnostics.keep_alive_send_total_ms)) /
                @as(f64, @floatFromInt(diagnostics.keep_alive_send_samples));

        try writeLabel(writer, "diagnostics");
        try writer.print("recv_nobufs={d} cq_overflow={d} close_failures={d} peak_cq={d}/{d} max_recv_bundle={f}/{d} recv_buffers={s}\n", .{
            diagnostics.recv_nobufs,
            diagnostics.cq_overflow,
            diagnostics.close_failures,
            diagnostics.max_cq_ready,
            diagnostics.max_cq_entries,
            bytes(@floatFromInt(diagnostics.max_recv_bundle_bytes)),
            diagnostics.max_recv_bundle_buffers,
            // The kernel decides this, not the build: a run that fell back to
            // retiring whole buffers has a fraction of the ring capacity, which
            // is otherwise invisible when comparing two runs.
            if (diagnostics.incremental_buffers) "incremental" else "whole",
        });

        try writeLabel(writer, "keepalive");
        try writer.print("samples={d} avg={d:.3}ms max={d}ms\n", .{ diagnostics.keep_alive_send_samples, keep_alive_avg_ms, diagnostics.keep_alive_send_max_ms });

        try writeLabel(writer, "disconnects");
        try writeDisconnects(writer, diagnostics.disconnects);
        try writer.writeByte('\n');
    }
}

/// Columns `writeLabel` reserves before every value: two spaces, an
/// eleven-column name, two more spaces. Exported because the overlay reprints
/// these lines and has to split them at the same column.
pub const label_columns: usize = 15;

// Left aligned label column so every value starts at the same offset.
pub fn writeLabel(writer: *Io.Writer, name: []const u8) !void {
    try writer.print("  {s:<11}  ", .{name});
}

/// A per-second rate as a whole number. Guards the conversion: a rate is f64
/// and `@intFromFloat` has no answer for a negative or a NaN.
pub fn rounded(value: f64) u64 {
    if (!(value > 0)) return 0;
    return @intFromFloat(@round(value));
}

fn writeDisconnects(writer: *Io.Writer, disconnects: stats_module.Disconnects) !void {
    const Category = struct { name: []const u8, count: u64 };
    var categories = [_]Category{
        .{ .name = "connect", .count = disconnects.connect },
        .{ .name = "transport", .count = disconnects.transport },
        .{ .name = "server", .count = disconnects.server },
        .{ .name = "protocol", .count = disconnects.protocol },
        .{ .name = "resource", .count = disconnects.resource },
        .{ .name = "buffer", .count = disconnects.buffer_limit },
        .{ .name = "other", .count = disconnects.other },
    };
    // Show only the categories that fired, most frequent first, so the common
    // failure modes lead and the all-zero noise is dropped. The sort is stable,
    // so equal counts keep the order above.
    std.sort.insertion(Category, &categories, {}, struct {
        fn desc(_: void, a: Category, b: Category) bool {
            return a.count > b.count;
        }
    }.desc);
    var any = false;
    for (categories) |category| {
        if (category.count == 0) continue;
        if (any) try writer.writeByte(' ');
        try writer.print("{s}={f}", .{ category.name, grouped(category.count) });
        any = true;
    }
    if (!any) try writer.writeAll("none");
}

pub fn grouped(value: u64) Grouped {
    return .{ .value = value };
}

fn groupedFixed(value: f64) GroupedFixed {
    return .{ .value = value };
}

// Thousands separated integer: 1234567 prints as 1,234,567.
pub const Grouped = struct {
    value: u64,

    pub fn format(self: Grouped, writer: *Io.Writer) Io.Writer.Error!void {
        var buffer: [20]u8 = undefined;
        const digits = std.fmt.bufPrint(&buffer, "{d}", .{self.value}) catch unreachable;
        try writeGroupedDigits(writer, digits);
    }
};

// Thousands separated fixed-point number; only the integer part is grouped.
const GroupedFixed = struct {
    value: f64,

    pub fn format(self: GroupedFixed, writer: *Io.Writer) Io.Writer.Error!void {
        var buffer: [40]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d:.2}", .{self.value}) catch unreachable;
        const point = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
        try writeGroupedDigits(writer, text[0..point]);
        try writer.writeAll(text[point..]);
    }
};

fn writeGroupedDigits(writer: *Io.Writer, digits: []const u8) !void {
    for (digits, 0..) |digit, index| {
        if (index != 0 and (digits.len - index) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

pub fn bytes(value: f64) Bytes {
    return .{ .value = value };
}

pub fn byteRate(value: f64) Bytes {
    return .{ .value = value, .per_second = true };
}

pub const Bytes = struct {
    value: f64,
    per_second: bool = false,

    pub fn format(self: Bytes, writer: *Io.Writer) Io.Writer.Error!void {
        const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
        var scaled = self.value;
        var unit: usize = 0;
        while (scaled >= 1024.0 and unit + 1 < units.len) : (unit += 1) scaled /= 1024.0;
        if (unit == 0) try writer.print("{d:.0} {s}", .{ scaled, units[unit] }) else try writer.print("{d:.2} {s}", .{ scaled, units[unit] });
        if (self.per_second) try writer.writeAll("/s");
    }
};

pub fn writeReachabilityError(writer: *Io.Writer, target: endpoint.Target, err: anyerror) !void {
    switch (target) {
        .unix => |unix| switch (err) {
            // An abstract name that nobody bound is refused rather than
            // missing: it never existed as a filesystem entry to look up.
            error.ConnectionRefused => if (unix.abstract)
                try writer.print("nothing is listening on abstract Unix socket {f}\n", .{unix})
            else
                try writer.print("Unix socket {f} exists but refused the connection; check that the server is still listening\n", .{unix}),
            error.FileNotFound => try writer.print("Unix socket {f} does not exist\n", .{unix}),
            error.NotDir => try writer.print("a parent component of Unix socket {f} is not a directory\n", .{unix}),
            error.AccessDenied, error.PermissionDenied => try writer.print("permission denied connecting to Unix socket {f}\n", .{unix}),
            error.NameTooLong => try writer.print("Unix socket name is too long: {f}\n", .{unix}),
            else => try writer.print("unable to connect to Unix socket {f}: {t}\n", .{ unix, err }),
        },
        .tcp => |tcp| {
            const server = hostPort(tcp.host, tcp.port);
            switch (err) {
                error.ConnectionRefused => try writer.print("server {f} refused the connection; check that the Minecraft server is running and listening on that host/port\n", .{server}),
                error.HostUnreachable => try writer.print("server host {f} is unreachable; check the address, route, firewall, or container networking\n", .{server}),
                error.NetworkUnreachable => try writer.print("network is unreachable while connecting to {f}; check local network configuration\n", .{server}),
                error.ConnectionTimedOut, error.Timeout => try writer.print("timed out connecting to {f}; check that the server is reachable and accepting status connections\n", .{server}),
                else => try writer.print("unable to connect to {f}: {t}\n", .{ server, err }),
            }
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
    if (comptime client.protocol.current.protocol_version & (1 << 30) != 0) {
        try std.testing.expect(std.mem.indexOf(u8, output, "protocol snapshot ") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output, "protocol snapshot") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "protocol ") != null);
    }
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
    var stats: client_table.Stats = .{
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
    };
    if (comptime stats_module.diagnostics_enabled) {
        stats.diagnostics = .{
            .recv_nobufs = 3,
            .cq_overflow = 4,
            .close_failures = 5,
            .max_cq_ready = 128,
            .max_cq_entries = 512,
            .max_recv_bundle_bytes = 8192,
            .max_recv_bundle_buffers = 2,
            .keep_alive_send_samples = 2,
            .keep_alive_send_total_ms = 7,
            .keep_alive_send_max_ms = 5,
            .incremental_buffers = true,
            .disconnects = .{ .server = 1, .transport = 2, .other = 1 },
        };
    }
    try writeStats(&writer, stats);
    const output = writer.buffered();
    // connecting/waiting are non-zero here, so both are shown; zeros are hidden.
    try std.testing.expect(std.mem.indexOf(u8, output, "requested=100 connected=80 (80.0%) play=75 (75.0%) connecting=10 waiting=10") != null);
    if (comptime stats_module.stats_enabled) {
        try std.testing.expect(std.mem.indexOf(u8, output, "total=4 avg=2.000/s") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "rx=2.00 KiB tx=1.00 KiB total=3.00 KiB") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output, "disabled at compile time") != null);
    }
    if (comptime stats_module.diagnostics_enabled) {
        try std.testing.expect(std.mem.indexOf(u8, output, "recv_nobufs=3 cq_overflow=4 close_failures=5 peak_cq=128/512 max_recv_bundle=8.00 KiB/2 recv_buffers=incremental") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "samples=2 avg=3.500ms max=5ms") != null);
        // Only fired categories, most frequent first; the zero ones are dropped.
        try std.testing.expect(std.mem.indexOf(u8, output, "disconnects  transport=2 server=1 other=1") != null);
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
