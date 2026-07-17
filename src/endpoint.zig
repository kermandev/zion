const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub const Address = union(enum) {
    ip: Io.net.IpAddress,
    unix: Io.net.UnixAddress,
};

pub const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
    un: posix.sockaddr.un,
};

pub const socket_receive_buffer_bytes: i32 = 32 * 1024;
pub const socket_send_buffer_bytes: i32 = 16 * 1024;

pub const default_port: u16 = 25565;
pub const default_handshake_host = "localhost";

pub const Target = union(enum) {
    tcp: Tcp,
    unix: Unix,

    pub const Tcp = struct {
        host: []const u8,
        port: u16 = default_port,
    };

    pub const Unix = struct {
        path: []const u8,
        handshake_host: []const u8 = default_handshake_host,
        handshake_port: u16 = default_port,
    };

    pub fn handshakeHost(target: Target) []const u8 {
        return switch (target) {
            .tcp => |tcp| tcp.host,
            .unix => |unix| unix.handshake_host,
        };
    }

    pub fn handshakePort(target: Target) u16 {
        return switch (target) {
            .tcp => |tcp| tcp.port,
            .unix => |unix| unix.handshake_port,
        };
    }
};

pub const ResolvedTarget = struct {
    target: Target,
    address: Address,
};

pub fn resolveAndProbe(io: Io, target: Target) !ResolvedTarget {
    switch (target) {
        .unix => |unix| {
            const address = try Io.net.UnixAddress.init(unix.path);
            var stream = try address.connect(io);
            stream.close(io);
            return .{ .target = target, .address = .{ .unix = address } };
        },
        .tcp => |tcp| {
            const connect_options: Io.net.IpAddress.ConnectOptions = .{
                .mode = .stream,
                .protocol = .tcp,
                .timeout = .none,
            };
            if (Io.net.IpAddress.resolve(io, tcp.host, tcp.port)) |address| {
                var stream = try address.connect(io, connect_options);
                stream.close(io);
                return .{ .target = target, .address = .{ .ip = address } };
            } else |_| {}

            const host = try Io.net.HostName.init(tcp.host);
            var stream = try host.connect(io, tcp.port, connect_options);
            defer stream.close(io);

            var peer: PosixAddress = undefined;
            var peer_len: posix.socklen_t = @sizeOf(PosixAddress);
            try posix.getpeername(stream.socket.handle, &peer.any, &peer_len);
            return .{ .target = target, .address = .{ .ip = try ipAddressFromPosix(&peer) } };
        },
    }
}

pub fn addressFamily(address: *const Address) posix.sa_family_t {
    return switch (address.*) {
        .ip => |*ip| Io.Threaded.posixAddressFamily(ip),
        .unix => posix.AF.UNIX,
    };
}

pub fn addressToPosix(address: *const Address, storage: *PosixAddress) posix.socklen_t {
    return switch (address.*) {
        .ip => |*ip| Io.Threaded.addressToPosix(ip, @ptrCast(storage)),
        .unix => |unix| addressUnixToPosix(unix, storage),
    };
}

fn addressUnixToPosix(address: Io.net.UnixAddress, storage: *PosixAddress) posix.socklen_t {
    storage.un.family = posix.AF.UNIX;
    @memcpy(storage.un.path[0..address.path.len], address.path);
    var path_len = address.path.len;
    if (path_len < storage.un.path.len) {
        storage.un.path[path_len] = 0;
        path_len += 1;
    }
    return @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len);
}

fn ipAddressFromPosix(storage: *const PosixAddress) error{InvalidAddressFamily}!Io.net.IpAddress {
    return switch (storage.any.family) {
        posix.AF.INET, posix.AF.INET6 => Io.Threaded.addressFromPosix(@ptrCast(storage)),
        else => error.InvalidAddressFamily,
    };
}

test "Address preserves IPv6 and Unix sockaddr representations" {
    const ipv6: Address = .{ .ip = try std.Io.net.IpAddress.parse("::1", 25565) };
    var ipv6_storage: PosixAddress = undefined;
    const ipv6_len = addressToPosix(&ipv6, &ipv6_storage);
    try std.testing.expectEqual(std.posix.AF.INET6, addressFamily(&ipv6));
    try std.testing.expectEqual(std.posix.AF.INET6, ipv6_storage.in6.family);
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 25565), ipv6_storage.in6.port);
    try std.testing.expectEqual(@as(u8, 1), ipv6_storage.in6.addr[15]);
    try std.testing.expectEqual(@as(std.posix.socklen_t, @sizeOf(std.posix.sockaddr.in6)), ipv6_len);

    const path = "/tmp/zion.sock";
    const unix: Address = .{ .unix = try std.Io.net.UnixAddress.init(path) };
    var unix_storage: PosixAddress = undefined;
    const unix_len = addressToPosix(&unix, &unix_storage);
    try std.testing.expectEqual(std.posix.AF.UNIX, addressFamily(&unix));
    try std.testing.expectEqualSlices(u8, path, unix_storage.un.path[0..path.len]);
    try std.testing.expectEqual(@as(u8, 0), unix_storage.un.path[path.len]);
    try std.testing.expectEqual(@as(std.posix.socklen_t, @offsetOf(std.posix.sockaddr.un, "path") + path.len + 1), unix_len);
}

test "IP addresses round trip through POSIX storage" {
    const inputs = [_]Io.net.IpAddress{
        try Io.net.IpAddress.parse("127.0.0.1", 25565),
        try Io.net.IpAddress.parse("2001:db8::42", 25570),
    };
    for (inputs) |input| {
        const address: Address = .{ .ip = input };
        var storage: PosixAddress = undefined;
        _ = addressToPosix(&address, &storage);

        const actual = try ipAddressFromPosix(&storage);

        switch (input) {
            .ip4 => |expected| {
                try std.testing.expectEqualSlices(u8, &expected.bytes, &actual.ip4.bytes);
                try std.testing.expectEqual(expected.port, actual.ip4.port);
            },
            .ip6 => |expected| {
                try std.testing.expectEqualSlices(u8, &expected.bytes, &actual.ip6.bytes);
                try std.testing.expectEqual(expected.port, actual.ip6.port);
            },
        }
    }
}
