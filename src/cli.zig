const std = @import("std");
const endpoint = @import("endpoint.zig");
const features = @import("features.zig");
const client = @import("client.zig");

pub const BroadcastOptions = if (features.broadcast) struct {
    interval_ms: u64,
    message: []const u8,
} else void;

pub const RunOptions = struct {
    target: endpoint.Target,
    clients: usize,
    shards: ?usize = null,
    connect_rate_per_sec: u32 = 100,
    reconnect: bool = features.reconnect,
    username_prefix: []const u8 = "Zion",
    known_core_pack: bool = false,
    broadcast: if (features.broadcast) ?BroadcastOptions else void = if (features.broadcast) null else {},
    client_tick: if (features.client_tick) bool else void = if (features.client_tick) false else {},
    progress_detail: if (features.diagnostics) bool else void = if (features.diagnostics) false else {},
    movement: if (features.movement) client.MovementConfig else void = if (features.movement) .{} else {},
    tui: if (features.tui) bool else void = if (features.tui) true else {},
};

pub const Action = union(enum) {
    help,
    version,
    run: RunOptions,
};

const RawOptions = struct {
    target: ?endpoint.Target = null,
    handshake_host: ?[]const u8 = null,
    handshake_port: ?u16 = null,
    clients: ?usize = null,
    shards: ?usize = null,
    connect_rate_per_sec: u32 = 100,
    no_reconnect: bool = false,
    username_prefix: []const u8 = "Zion",
    known_core_pack: bool = false,
    broadcast_ms: if (features.broadcast) ?u64 else void = if (features.broadcast) null else {},
    broadcast_message: if (features.broadcast) ?[]const u8 else void = if (features.broadcast) null else {},
    client_tick: if (features.client_tick) bool else void = if (features.client_tick) false else {},
    progress_detail: if (features.diagnostics) bool else void = if (features.diagnostics) false else {},
    movement: if (features.movement) client.MovementConfig else void = if (features.movement) .{} else {},
    no_tui: if (features.tui) bool else void = if (features.tui) false else {},
    help: bool = false,
    version: bool = false,
};

const Flag = enum {
    @"--target",
    @"--handshake-host",
    @"--handshake-port",
    @"--clients",
    @"--shards",
    @"--connect-rate",
    @"--username-prefix",
    @"--no-reconnect",
    @"--known-core-pack",
    @"--broadcast-ms",
    @"--broadcast",
    @"--client-tick",
    @"--progress-detail",
    @"--no-tui",
    @"--movement",
    @"--movement-ms",
    @"--movement-radius",
    @"--movement-speed",
    @"--rotation-rate",
    @"--movement-seed",
    @"--help",
    @"-h",
    @"--version",
    @"-V",
};

pub fn parse(args: *std.process.Args.Iterator) !Action {
    var raw: RawOptions = .{};
    var unknown_flag = false;
    while (args.next()) |arg| {
        // Defer the unknown-flag error so --help/--version anywhere in argv still wins.
        const flag = std.meta.stringToEnum(Flag, arg) orelse {
            unknown_flag = true;
            continue;
        };
        switch (flag) {
            .@"--target" => raw.target = parseTarget(try nextValue(args)) catch return error.InvalidArgs,
            .@"--handshake-host" => {
                const host = try nextValue(args);
                if (host.len == 0) return error.InvalidArgs;
                raw.handshake_host = host;
            },
            .@"--handshake-port" => raw.handshake_port = parsePort(try nextValue(args)) catch return error.InvalidArgs,
            .@"--clients" => raw.clients = try parseIntArg(usize, try nextValue(args)),
            .@"--shards" => raw.shards = try parseIntArg(usize, try nextValue(args)),
            .@"--connect-rate" => raw.connect_rate_per_sec = try parseIntArg(u32, try nextValue(args)),
            .@"--username-prefix" => {
                raw.username_prefix = try nextValue(args);
                if (raw.username_prefix.len == 0) return error.InvalidArgs;
            },
            .@"--no-reconnect" => {
                if (comptime !features.reconnect) return error.FeatureDisabled;
                raw.no_reconnect = true;
            },
            .@"--known-core-pack" => raw.known_core_pack = true,
            .@"--broadcast-ms" => {
                if (comptime !features.broadcast) return error.FeatureDisabled;
                const interval_ms = try parseIntArg(u64, try nextValue(args));
                if (interval_ms == 0) return error.InvalidArgs;
                raw.broadcast_ms = interval_ms;
            },
            .@"--broadcast" => {
                if (comptime !features.broadcast) return error.FeatureDisabled;
                raw.broadcast_message = try nextValue(args);
            },
            .@"--client-tick" => {
                if (comptime !features.client_tick) return error.FeatureDisabled;
                raw.client_tick = true;
            },
            .@"--progress-detail" => {
                if (comptime !features.diagnostics) return error.FeatureDisabled;
                raw.progress_detail = true;
            },
            .@"--no-tui" => {
                if (comptime !features.tui) return error.FeatureDisabled;
                raw.no_tui = true;
            },
            .@"--movement" => {
                if (comptime !features.movement) return error.FeatureDisabled;
                raw.movement.profile = std.meta.stringToEnum(client.MovementProfile, try nextValue(args)) orelse return error.InvalidArgs;
            },
            .@"--movement-ms" => {
                if (comptime !features.movement) return error.FeatureDisabled;
                raw.movement.interval_ms = try parseIntArg(u64, try nextValue(args));
                if (raw.movement.interval_ms == 0) return error.InvalidArgs;
            },
            .@"--movement-radius" => {
                if (comptime !features.movement) return error.FeatureDisabled;
                raw.movement.radius = try parsePositiveFloat(f64, try nextValue(args));
            },
            .@"--movement-speed" => {
                if (comptime !features.movement) return error.FeatureDisabled;
                raw.movement.speed = try parsePositiveFloat(f64, try nextValue(args));
            },
            .@"--rotation-rate" => {
                if (comptime !features.movement) return error.FeatureDisabled;
                raw.movement.rotation_rate = try parsePositiveFloat(f32, try nextValue(args));
            },
            .@"--movement-seed" => {
                if (comptime !features.movement) return error.FeatureDisabled;
                raw.movement.seed = try parseIntArg(u64, try nextValue(args));
            },
            .@"--help", .@"-h" => raw.help = true,
            .@"--version", .@"-V" => raw.version = true,
        }
    }

    if (raw.help) return .help;
    if (raw.version) return .version;
    if (unknown_flag) return error.InvalidArgs;

    if (comptime features.broadcast) {
        if ((raw.broadcast_ms == null) != (raw.broadcast_message == null)) return error.InvalidArgs;
    }

    var target = raw.target orelse return error.InvalidArgs;
    switch (target) {
        .tcp => if (raw.handshake_host != null or raw.handshake_port != null) return error.InvalidArgs,
        .unix => |*unix| {
            if (raw.handshake_host) |host| unix.handshake_host = host;
            if (raw.handshake_port) |port| unix.handshake_port = port;
        },
    }

    const clients = raw.clients orelse return error.InvalidArgs;
    if (clients == 0) return error.InvalidArgs;
    if (raw.shards) |shards| if (shards == 0) return error.InvalidArgs;

    // Minecraft caps usernames at 16 characters. Usernames are the prefix
    // followed by a 1-based client number, so the prefix plus the digits of
    // the highest client number must fit.
    const client_digits: usize = std.math.log10_int(clients) + 1;
    if (raw.username_prefix.len + client_digits > 16) return error.InvalidArgs;

    return .{ .run = .{
        .target = target,
        .clients = clients,
        .shards = raw.shards,
        .connect_rate_per_sec = raw.connect_rate_per_sec,
        .reconnect = features.reconnect and !raw.no_reconnect,
        .username_prefix = raw.username_prefix,
        .known_core_pack = raw.known_core_pack,
        .broadcast = if (comptime features.broadcast) if (raw.broadcast_ms) |interval_ms| .{
            .interval_ms = interval_ms,
            .message = raw.broadcast_message.?,
        } else null else {},
        .client_tick = if (comptime features.client_tick) raw.client_tick else {},
        .progress_detail = if (comptime features.diagnostics) raw.progress_detail else {},
        .movement = if (comptime features.movement) raw.movement else {},
        .tui = if (comptime features.tui) !raw.no_tui else {},
    } };
}

test "parse version does not require run options" {
    const argv = [_][*:0]const u8{ "zion", "--version" };
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = &argv }, std.testing.allocator);
    defer args.deinit();
    _ = args.skip();

    try std.testing.expectEqual(Action.version, try parse(&args));
}

test "parse lets help and version win over semantic validation" {
    if (comptime features.broadcast) {
        // --broadcast without --broadcast-ms is semantically invalid, but
        // --help must still short-circuit.
        const help_argv = [_][*:0]const u8{ "zion", "--broadcast", "hello", "--help" };
        var help_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &help_argv }, std.testing.allocator);
        defer help_args.deinit();
        _ = help_args.skip();
        try std.testing.expectEqual(Action.help, try parse(&help_args));
    }

    const version_argv = [_][*:0]const u8{ "zion", "--clients", "0", "--version" };
    var version_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &version_argv }, std.testing.allocator);
    defer version_args.deinit();
    _ = version_args.skip();
    try std.testing.expectEqual(Action.version, try parse(&version_args));

    const unknown_argv = [_][*:0]const u8{ "zion", "--frobnicate", "--help" };
    var unknown_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &unknown_argv }, std.testing.allocator);
    defer unknown_args.deinit();
    _ = unknown_args.skip();
    try std.testing.expectEqual(Action.help, try parse(&unknown_args));

    const invalid_argv = [_][*:0]const u8{ "zion", "--frobnicate", "--target", "127.0.0.1", "--clients", "10" };
    var invalid_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &invalid_argv }, std.testing.allocator);
    defer invalid_args.deinit();
    _ = invalid_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&invalid_args));
}

test "parse validates username prefix length against the client count" {
    const empty_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "10", "--username-prefix", "" };
    var empty_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &empty_argv }, std.testing.allocator);
    defer empty_args.deinit();
    _ = empty_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&empty_args));

    // 14-char prefix + 2 digits ("10") = 16: fits exactly.
    const fits_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "10", "--username-prefix", "AAAAAAAAAAAAAA" };
    var fits_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &fits_argv }, std.testing.allocator);
    defer fits_args.deinit();
    _ = fits_args.skip();
    const fits = (try parse(&fits_args)).run;
    try std.testing.expectEqualStrings("AAAAAAAAAAAAAA", fits.username_prefix);

    // 14-char prefix + 3 digits ("100") = 17: exceeds the 16-char limit.
    const overflow_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "100", "--username-prefix", "AAAAAAAAAAAAAA" };
    var overflow_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &overflow_argv }, std.testing.allocator);
    defer overflow_args.deinit();
    _ = overflow_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&overflow_args));
}

fn nextValue(args: *std.process.Args.Iterator) ![]const u8 {
    const value = args.next() orelse return error.InvalidArgs;
    if (std.mem.startsWith(u8, value, "--")) return error.InvalidArgs;
    return value;
}

fn parseIntArg(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidArgs;
}

// Always parses as f64 and narrows, so the binary carries one parseFloat
// instantiation. The narrowing is exact: f64 keeps more than 2*24+2 bits, so
// the second rounding cannot change the f32 result. The range check runs on the
// narrowed value, so an f32 that overflowed to inf or flushed to zero is still
// rejected. The negated comparison also rejects NaN.
fn parsePositiveFloat(comptime T: type, value: []const u8) error{InvalidArgs}!T {
    const parsed: T = @floatCast(std.fmt.parseFloat(f64, value) catch return error.InvalidArgs);
    if (!(parsed > 0) or !std.math.isFinite(parsed)) return error.InvalidArgs;
    return parsed;
}

pub fn parseTarget(value: []const u8) error{InvalidTarget}!endpoint.Target {
    if (value.len == 0) return error.InvalidTarget;
    if (std.mem.startsWith(u8, value, "unix:")) {
        // A leading `@` selects the Linux abstract namespace, the spelling ss(8)
        // and systemd use. The name lives outside the filesystem, so it is
        // taken verbatim rather than resolved as a path.
        const rest = value["unix:".len..];
        const abstract = std.mem.startsWith(u8, rest, "@");
        const name = if (abstract) rest[1..] else rest;
        if (name.len == 0) return error.InvalidTarget;
        if (name.len > endpoint.UnixAddress.maxNameLen(abstract)) return error.InvalidTarget;
        return .{ .unix = .{ .path = name, .abstract = abstract } };
    }

    if (value[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, value, ']') orelse return error.InvalidTarget;
        const host = value[1..closing];
        if (host.len == 0) return error.InvalidTarget;
        try validateIpv6(host);
        const suffix = value[closing + 1 ..];
        if (suffix.len == 0) return .{ .tcp = .{ .host = host } };
        if (suffix[0] != ':' or suffix.len == 1) return error.InvalidTarget;
        return .{ .tcp = .{ .host = host, .port = try parsePort(suffix[1..]) } };
    }

    var colon_count: usize = 0;
    var colon_index: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte == ':') {
            colon_count += 1;
            colon_index = index;
        }
    }
    if (colon_count == 0) {
        try validateHost(value);
        return .{ .tcp = .{ .host = value } };
    }
    if (colon_count > 1) {
        try validateIpv6(value);
        return .{ .tcp = .{ .host = value } };
    }
    if (colon_index == 0 or colon_index + 1 == value.len) return error.InvalidTarget;
    try validateHost(value[0..colon_index]);
    return .{ .tcp = .{
        .host = value[0..colon_index],
        .port = try parsePort(value[colon_index + 1 ..]),
    } };
}

fn parsePort(value: []const u8) error{InvalidTarget}!u16 {
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidTarget;
    if (port == 0) return error.InvalidTarget;
    return port;
}

fn validateIpv6(value: []const u8) error{InvalidTarget}!void {
    const address = if (std.mem.indexOfScalar(u8, value, '%')) |scope_index| blk: {
        if (scope_index == 0 or scope_index + 1 == value.len) return error.InvalidTarget;
        break :blk value[0..scope_index];
    } else value;
    _ = std.Io.net.IpAddress.parseIp6(address, 0) catch return error.InvalidTarget;
}

fn validateHost(value: []const u8) error{InvalidTarget}!void {
    _ = std.Io.net.HostName.init(value) catch return error.InvalidTarget;
}

test "parse produces validated run options for a Unix target" {
    const argv = [_][*:0]const u8{
        "zion", "--target", "unix:/run/minecraft.sock", "--handshake-host", "play.example.com", "--handshake-port", "25570", "--clients", "10",
    };
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = &argv }, std.testing.allocator);
    defer args.deinit();
    _ = args.skip();

    const action = try parse(&args);
    const options = action.run;
    try std.testing.expectEqual(@as(usize, 10), options.clients);
    try std.testing.expectEqualStrings("/run/minecraft.sock", options.target.unix.path);
    try std.testing.expectEqualStrings("play.example.com", options.target.unix.handshake_host);
    try std.testing.expectEqual(@as(u16, 25570), options.target.unix.handshake_port);
    try std.testing.expect(!options.known_core_pack);
}

test "parse rejects removed endpoint flags and TCP handshake overrides" {
    const old_argv = [_][*:0]const u8{ "zion", "--host", "127.0.0.1", "--clients", "10" };
    var old_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &old_argv }, std.testing.allocator);
    defer old_args.deinit();
    _ = old_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&old_args));

    const override_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--handshake-host", "example.com", "--clients", "10" };
    var override_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &override_argv }, std.testing.allocator);
    defer override_args.deinit();
    _ = override_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&override_args));
}

test "parse rejects zero clients and shards" {
    const clients_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "0" };
    var clients_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &clients_argv }, std.testing.allocator);
    defer clients_args.deinit();
    _ = clients_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&clients_args));

    const shards_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "10", "--shards", "0" };
    var shards_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &shards_argv }, std.testing.allocator);
    defer shards_args.deinit();
    _ = shards_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&shards_args));
}

test "parse accepts optional feature tuning" {
    if (comptime !(features.client_tick and features.diagnostics and features.movement)) return error.SkipZigTest;
    const argv = [_][*:0]const u8{
        "zion", "--target", "127.0.0.1", "--clients", "10", "--known-core-pack", "--client-tick", "--progress-detail", "--movement", "walk", "--movement-radius", "24", "--movement-speed", "3.5", "--movement-seed", "99",
    };
    var args = try std.process.Args.Iterator.initAllocator(.{ .vector = &argv }, std.testing.allocator);
    defer args.deinit();
    _ = args.skip();

    const options = (try parse(&args)).run;
    try std.testing.expect(options.client_tick);
    try std.testing.expect(options.known_core_pack);
    try std.testing.expect(options.progress_detail);
    try std.testing.expectEqual(client.MovementProfile.walk, options.movement.profile);
    try std.testing.expectEqual(@as(f64, 24), options.movement.radius);
    try std.testing.expectEqual(@as(f64, 3.5), options.movement.speed);
    try std.testing.expectEqual(@as(u64, 99), options.movement.seed);
}

test "parse defaults reconnect on and --no-reconnect turns it off" {
    if (comptime !features.reconnect) return error.SkipZigTest;
    const default_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "10" };
    var default_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &default_argv }, std.testing.allocator);
    defer default_args.deinit();
    _ = default_args.skip();
    try std.testing.expectEqual(features.reconnect, (try parse(&default_args)).run.reconnect);

    const off_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "10", "--no-reconnect" };
    var off_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &off_argv }, std.testing.allocator);
    defer off_args.deinit();
    _ = off_args.skip();
    try std.testing.expectEqual(false, (try parse(&off_args)).run.reconnect);
}

test "parse rejects incomplete broadcasts and infinite movement" {
    if (comptime !(features.broadcast and features.movement)) return error.SkipZigTest;
    const broadcast_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "10", "--broadcast", "hello" };
    var broadcast_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &broadcast_argv }, std.testing.allocator);
    defer broadcast_args.deinit();
    _ = broadcast_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&broadcast_args));

    const movement_argv = [_][*:0]const u8{ "zion", "--target", "127.0.0.1", "--clients", "10", "--movement-radius", "inf" };
    var movement_args = try std.process.Args.Iterator.initAllocator(.{ .vector = &movement_argv }, std.testing.allocator);
    defer movement_args.deinit();
    _ = movement_args.skip();
    try std.testing.expectError(error.InvalidArgs, parse(&movement_args));
}

test "parseTarget accepts TCP IPv6 and Unix forms" {
    const hostname = try parseTarget("minecraft.example.com");
    try std.testing.expectEqualStrings("minecraft.example.com", hostname.tcp.host);
    try std.testing.expectEqual(@as(u16, 25565), hostname.tcp.port);

    const ipv4 = try parseTarget("127.0.0.1:25570");
    try std.testing.expectEqualStrings("127.0.0.1", ipv4.tcp.host);
    try std.testing.expectEqual(@as(u16, 25570), ipv4.tcp.port);

    const ipv6 = try parseTarget("[::1]:25570");
    try std.testing.expectEqualStrings("::1", ipv6.tcp.host);
    try std.testing.expectEqual(@as(u16, 25570), ipv6.tcp.port);

    const default_ipv6 = try parseTarget("::1");
    try std.testing.expectEqualStrings("::1", default_ipv6.tcp.host);
    try std.testing.expectEqual(@as(u16, 25565), default_ipv6.tcp.port);

    const scoped_ipv6 = try parseTarget("[fe80::1%lo]:25565");
    try std.testing.expectEqualStrings("fe80::1%lo", scoped_ipv6.tcp.host);

    const unix = try parseTarget("unix:/run/minecraft.sock");
    try std.testing.expectEqualStrings("/run/minecraft.sock", unix.unix.path);
    try std.testing.expect(!unix.unix.abstract);
    try std.testing.expectEqualStrings("localhost", unix.unix.handshake_host);
    try std.testing.expectEqual(@as(u16, 25565), unix.unix.handshake_port);
}

test "parseTarget reads @ as the abstract namespace" {
    const abstract = try parseTarget("unix:@minecraft");
    try std.testing.expect(abstract.unix.abstract);
    // The marker is not part of the name the kernel sees.
    try std.testing.expectEqualStrings("minecraft", abstract.unix.path);
    try std.testing.expectEqualStrings("localhost", abstract.unix.handshake_host);

    // A path merely containing @ stays a filesystem path.
    const filesystem = try parseTarget("unix:/run/user@host.sock");
    try std.testing.expect(!filesystem.unix.abstract);
    try std.testing.expectEqualStrings("/run/user@host.sock", filesystem.unix.path);

    // @ alone names nothing. The empty abstract name is a real Linux address
    // (autobind), but a load tester has no use for one it cannot address.
    try std.testing.expectError(error.InvalidTarget, parseTarget("unix:@"));

    const prefix = "unix:@";
    var too_long: [prefix.len + endpoint.UnixAddress.maxNameLen(true) + 1]u8 = @splat('a');
    @memcpy(too_long[0..prefix.len], prefix);
    try std.testing.expectError(error.InvalidTarget, parseTarget(&too_long));

    // One byte shorter is the longest name the kernel can hold.
    try std.testing.expect((try parseTarget(too_long[0 .. too_long.len - 1])).unix.abstract);
}

test "abstract targets render with their @ marker" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const target = try parseTarget("unix:@minecraft");
    try writer.print("{f}", .{target.unix});
    try std.testing.expectEqualStrings("@minecraft", writer.buffered());
}

test "parseTarget rejects malformed targets and port zero" {
    try std.testing.expectError(error.InvalidTarget, parseTarget(""));
    try std.testing.expectError(error.InvalidTarget, parseTarget("unix:"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("[]:25565"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("localhost:0"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("[::1"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("[::1]garbage"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("[localhost]:25565"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("foo:bar:baz"));
    try std.testing.expectError(error.InvalidTarget, parseTarget("not a host"));
}
