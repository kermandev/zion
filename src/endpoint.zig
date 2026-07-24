const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;

pub const Address = union(enum) {
    ip: Io.net.IpAddress,
    unix: UnixAddress,
};

/// A Unix domain socket address. Kept separate from `Io.net.UnixAddress`
/// because that type always NUL terminates sun_path, and abstract namespace
/// names must not be terminated: unix(7) defines an abstract name as exactly
/// the sun_path bytes covered by the address length, so a trailing NUL would
/// name a different socket than the one the server bound.
pub const UnixAddress = struct {
    /// Filesystem path, or the abstract name without its leading NUL.
    name: []const u8,
    abstract: bool,

    const sun_path_len = @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len;

    /// Abstract names give up one sun_path byte to the leading NUL. Filesystem
    /// paths may fill sun_path exactly and then travel unterminated.
    pub fn maxNameLen(abstract: bool) usize {
        return if (abstract) sun_path_len - 1 else sun_path_len;
    }

    pub fn init(name: []const u8, abstract: bool) error{NameTooLong}!UnixAddress {
        if (name.len > maxNameLen(abstract)) return error.NameTooLong;
        return .{ .name = name, .abstract = abstract };
    }
};

pub const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
    un: posix.sockaddr.un,
};

// Non-positive values skip the setsockopt and leave the kernel's buffer
// autotuning in charge. Pinning the receive buffer at 32 KiB measurably
// throttled loopback runs: it caps the TCP window, so the server stalls on
// flow control and sends smaller segments (~10% less throughput at a higher
// CPU cost per byte on both sides). Autotuned buffers only consume memory
// for data actually queued, so this stays safe at high client counts.
pub const socket_receive_buffer_bytes: i32 = 0;
pub const socket_send_buffer_bytes: i32 = 0;

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
        /// Filesystem path, or the abstract name without its `@` marker.
        path: []const u8,
        abstract: bool = false,
        handshake_host: []const u8 = default_handshake_host,
        handshake_port: u16 = default_port,

        /// Renders the spelling the CLI accepts: `@name` when abstract.
        pub fn format(unix: Unix, writer: *Io.Writer) Io.Writer.Error!void {
            if (unix.abstract) try writer.writeByte('@');
            try writer.writeAll(unix.path);
        }
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

/// Resolves the target to one concrete address and proves the server is
/// reachable by opening a connection and closing it again.
pub fn resolveAndProbe(io: Io, target: Target) !ResolvedTarget {
    switch (target) {
        .unix => |unix| {
            const address = try UnixAddress.init(unix.path, unix.abstract);
            try probeUnix(&address);
            return .{ .target = target, .address = .{ .unix = address } };
        },
        .tcp => |tcp| {
            const connect_options: Io.net.IpAddress.ConnectOptions = .{
                .mode = .stream,
                .protocol = .tcp,
                .timeout = .none,
            };
            // IpAddress.resolve only parses literals (including IPv6 scopes);
            // a hostname fails here and falls through to the DNS path.
            if (Io.net.IpAddress.resolve(io, tcp.host, tcp.port) catch null) |address| {
                var stream = try address.connect(io, connect_options);
                stream.close(io);
                return .{ .target = target, .address = .{ .ip = address } };
            }

            // DNS can offer several addresses and HostName.connect picks the
            // first that answers. Read that peer back so every shard dials the
            // exact address the probe succeeded on.
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

/// Opens and closes one connection to prove the socket is live. This dials
/// through the same encoding the shards use rather than
/// `Io.net.UnixAddress.connect`, so an abstract name is probed exactly as it
/// will later be dialled.
fn probeUnix(address: *const UnixAddress) ProbeError!void {
    var storage: PosixAddress = undefined;
    const address_len = addressUnixToPosix(address.*, &storage);

    const socket_rc = linux.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    const socket: posix.fd_t = switch (linux.errno(socket_rc)) {
        .SUCCESS => @intCast(socket_rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM, .NOBUFS => return error.SystemResources,
        .AFNOSUPPORT, .PROTONOSUPPORT => return error.AddressFamilyUnsupported,
        else => |err| return posix.unexpectedErrno(err),
    };
    defer _ = linux.close(socket);

    while (true) {
        switch (linux.errno(linux.connect(socket, &storage.any, address_len))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.Timeout,
            .NAMETOOLONG => return error.NameTooLong,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

const ProbeError = error{
    FileNotFound,
    NotDir,
    SymLinkLoop,
    AccessDenied,
    PermissionDenied,
    ConnectionRefused,
    ConnectionResetByPeer,
    Timeout,
    NameTooLong,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    AddressFamilyUnsupported,
    Unexpected,
};

fn addressUnixToPosix(address: UnixAddress, storage: *PosixAddress) posix.socklen_t {
    storage.un.family = posix.AF.UNIX;
    // Re-check locally so a caller bypassing UnixAddress.init cannot overflow
    // the copy below.
    std.debug.assert(address.name.len <= UnixAddress.maxNameLen(address.abstract));

    var len: usize = 0;
    if (address.abstract) {
        storage.un.path[0] = 0;
        len = 1;
    }
    @memcpy(storage.un.path[len..][0..address.name.len], address.name);
    len += address.name.len;
    // Abstract names are never terminated: the kernel takes the name as every
    // sun_path byte covered by the returned length. A filesystem path that
    // exactly fills sun_path also travels unterminated; shorter ones carry
    // their NUL.
    if (!address.abstract and len < storage.un.path.len) {
        storage.un.path[len] = 0;
        len += 1;
    }
    return @intCast(@offsetOf(posix.sockaddr.un, "path") + len);
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
    const unix: Address = .{ .unix = try UnixAddress.init(path, false) };
    var unix_storage: PosixAddress = undefined;
    const unix_len = addressToPosix(&unix, &unix_storage);
    try std.testing.expectEqual(std.posix.AF.UNIX, addressFamily(&unix));
    try std.testing.expectEqualSlices(u8, path, unix_storage.un.path[0..path.len]);
    try std.testing.expectEqual(@as(u8, 0), unix_storage.un.path[path.len]);
    try std.testing.expectEqual(@as(std.posix.socklen_t, @offsetOf(std.posix.sockaddr.un, "path") + path.len + 1), unix_len);
}

test "abstract sockets carry a leading NUL and no terminator" {
    const name = "zion.sock";
    const address: Address = .{ .unix = try UnixAddress.init(name, true) };
    var storage: PosixAddress = undefined;
    const len = addressToPosix(&address, &storage);

    try std.testing.expectEqual(std.posix.AF.UNIX, addressFamily(&address));
    try std.testing.expectEqual(@as(u8, 0), storage.un.path[0]);
    try std.testing.expectEqualSlices(u8, name, storage.un.path[1 .. 1 + name.len]);
    // unix(7) takes the name as exactly the bytes the length covers, so the
    // terminator a filesystem path would carry must not be counted here.
    try std.testing.expectEqual(@as(std.posix.socklen_t, @offsetOf(std.posix.sockaddr.un, "path") + 1 + name.len), len);

    // The same spelling as a filesystem path is a different address. Here the
    // two encodings happen to be the same length (a leading NUL costs what a
    // trailing one would), so it is the sun_path bytes that distinguish them.
    const filesystem: Address = .{ .unix = try UnixAddress.init(name, false) };
    var filesystem_storage: PosixAddress = undefined;
    const filesystem_len = addressToPosix(&filesystem, &filesystem_storage);
    try std.testing.expectEqual(len, filesystem_len);
    try std.testing.expect(!std.mem.eql(u8, filesystem_storage.un.path[0..name.len], storage.un.path[0..name.len]));
    try std.testing.expectEqualSlices(u8, name, filesystem_storage.un.path[0..name.len]);
    try std.testing.expectEqual(@as(u8, 0), filesystem_storage.un.path[name.len]);
}

test "Unix names are bounded by sun_path, one byte tighter when abstract" {
    const sun_path_len = @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len;
    try std.testing.expectEqual(sun_path_len, UnixAddress.maxNameLen(false));
    try std.testing.expectEqual(sun_path_len - 1, UnixAddress.maxNameLen(true));

    const longest: [sun_path_len]u8 = @splat('a');
    _ = try UnixAddress.init(&longest, false);
    try std.testing.expectError(error.NameTooLong, UnixAddress.init(&longest, true));
    _ = try UnixAddress.init(longest[0 .. sun_path_len - 1], true);

    // A path filling sun_path exactly travels unterminated.
    const full: Address = .{ .unix = try UnixAddress.init(&longest, false) };
    var storage: PosixAddress = undefined;
    const len = addressToPosix(&full, &storage);
    try std.testing.expectEqual(@as(std.posix.socklen_t, @offsetOf(std.posix.sockaddr.un, "path") + sun_path_len), len);
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
