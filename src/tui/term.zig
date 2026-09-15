//! Terminal control: raw mode, the alternate screen, window size and key input.
//!
//! Linux only, like the rest of Zion, so this talks to termios and TIOCGWINSZ
//! directly instead of carrying a terminfo database. 24-bit color and the
//! alternate screen are assumed; the dashboard is opt-in and falls back to the
//! plain progress line when stdout is not a TTY.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const theme = @import("theme.zig");

pub const Size = struct {
    cols: u16 = 0,
    rows: u16 = 0,

    pub fn eql(size: Size, other: Size) bool {
        return size.cols == other.cols and size.rows == other.rows;
    }
};

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    escape,
    tab,
    backspace,
    home,
    end,
    page_up,
    page_down,
};

const enter_alt_screen = "\x1b[?1049h";
const leave_alt_screen = "\x1b[?1049l";
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const reset_style = "\x1b[0m";

/// Everything needed to put the terminal back, kept in a global so the signal
/// path can restore it without a `Term` in hand. A wrecked terminal after a
/// crash is far worse than the cost of one extra global.
var restore_state: ?RestoreState = null;

/// Resets the terminal's default background to the user's configured one.
const reset_background = "\x1b]111\x07";

const RestoreState = struct {
    out_fd: posix.fd_t,
    in_fd: posix.fd_t,
    termios: posix.termios,
    /// Whether the default background was overridden and must be put back.
    background_set: bool = false,
};

/// The raw write syscall. `std.posix` does not wrap `write`, and the signal
/// path needs something that neither allocates nor takes a lock regardless.
fn writeAll(fd: posix.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes.ptr + written, bytes.len - written);
        switch (posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.WriteFailed;
                written += result;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

/// Async-signal-safe enough to call from a handler or a panic: one `write` of
/// a fixed string plus `tcsetattr`, no allocation and no formatting. Idempotent.
pub fn emergencyRestore() void {
    const state = restore_state orelse return;
    restore_state = null;
    posix.tcsetattr(state.in_fd, .FLUSH, state.termios) catch {};
    if (state.background_set) writeAll(state.out_fd, reset_background) catch {};
    writeAll(state.out_fd, reset_style ++ show_cursor ++ leave_alt_screen) catch {};
}

/// The terminal's current size, or null when it cannot be determined (a pty
/// with no size attached, or a stdout that is not one). Callers use this to
/// decide whether a dashboard is possible at all.
pub fn windowSize() ?Size {
    var winsize: posix.winsize = undefined;
    const result = linux.ioctl(Io.File.stdout().handle, linux.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (posix.errno(result) != .SUCCESS) return null;
    if (winsize.col == 0 or winsize.row == 0) return null;
    return .{ .cols = winsize.col, .rows = winsize.row };
}

pub const Term = struct {
    io: Io,
    out_fd: posix.fd_t,
    in_fd: posix.fd_t,
    original: posix.termios,
    size: Size,
    /// Input carried to the next frame: a partially-received escape sequence,
    /// or bytes past the caller's key array. Sized to the read buffer so a
    /// whole read can always be carried.
    pending: [128]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(io: Io) !Term {
        const out_fd = Io.File.stdout().handle;
        const in_fd = Io.File.stdin().handle;

        const original = try posix.tcgetattr(in_fd);
        var raw = original;
        // Canonical mode and echo off so keys arrive immediately and are not
        // painted over the dashboard. ISIG stays on: Ctrl-C must keep reaching
        // the existing shutdown handler.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.IEXTEN = false;
        // Leave the terminal's own flow control out of the way.
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        // A read returns whatever is buffered rather than blocking, so the
        // render loop paces itself instead of waiting on the keyboard.
        raw.cc[@backingInt(posix.V.MIN)] = 0;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(in_fd, .FLUSH, raw);

        restore_state = .{ .out_fd = out_fd, .in_fd = in_fd, .termios = original };
        errdefer emergencyRestore();

        try writeAll(out_fd, enter_alt_screen ++ hide_cursor);

        var term: Term = .{
            .io = io,
            .out_fd = out_fd,
            .in_fd = in_fd,
            .original = original,
            .size = .{},
        };
        term.refreshSize();
        return term;
    }

    pub fn deinit(term: *Term) void {
        _ = term;
        emergencyRestore();
    }

    /// Polled once per frame rather than driven by SIGWINCH: an ioctl at 20 Hz
    /// is free, and it keeps this module out of the signal handlers that
    /// `pool.zig` already installs for shutdown.
    pub fn refreshSize(term: *Term) void {
        // A failed or zero-sized query keeps the last known size rather than
        // blanking the screen for the rest of the run.
        term.size = windowSize() orelse return;
    }

    pub fn write(term: *const Term, bytes: []const u8) !void {
        try writeAll(term.out_fd, bytes);
    }

    /// Tells the terminal what the screen's background is, via OSC 11.
    ///
    /// A terminal that pads its window to a whole number of cells fills that
    /// padding with its *default* background, not with the color of the cell
    /// next to it. Without this the dashboard is framed by a strip of the
    /// user's theme background down the right and along the bottom. Restored
    /// on exit, including through the signal path.
    pub fn setDefaultBackground(term: *const Term, color: theme.Rgb) void {
        var buffer: [32]u8 = undefined;
        const sequence = std.fmt.bufPrint(&buffer, "\x1b]11;#{x:0>2}{x:0>2}{x:0>2}\x07", .{
            color.r,
            color.g,
            color.b,
        }) catch return;
        term.write(sequence) catch return;
        if (restore_state) |*state| state.background_set = true;
    }

    /// Decodes whatever input is buffered into `keys`, returning how many were
    /// produced. Never blocks: VMIN/VTIME are zero, so an idle terminal yields
    /// nothing and the caller carries on rendering.
    pub fn readKeys(term: *Term, keys: []Key) usize {
        var buffer: [128]u8 = undefined;
        @memcpy(buffer[0..term.pending_len], term.pending[0..term.pending_len]);
        const read = posix.read(term.in_fd, buffer[term.pending_len..]) catch 0;
        const total = term.pending_len + read;
        term.pending_len = 0;
        if (total == 0) return 0;

        var count: usize = 0;
        var index: usize = 0;
        while (index < total and count < keys.len) {
            const decoded = decode(buffer[index..total]) orelse break;
            index += decoded.len;
            if (decoded.key) |key| {
                keys[count] = key;
                count += 1;
            }
        }
        // Whatever is left is either an escape sequence split across reads or
        // input past the end of `keys`. Both are carried to the next frame:
        // mangling the first into stray keys and dropping the second were the
        // same bug, and only the split sequence was ever handled.
        const remaining = total - index;
        if (remaining != 0 and remaining <= term.pending.len) {
            @memcpy(term.pending[0..remaining], buffer[index..total]);
            term.pending_len = remaining;
        }
        return count;
    }
};

const Decoded = struct {
    key: ?Key,
    len: usize,
};

/// Returns null when `bytes` holds the start of an escape sequence that has not
/// arrived in full yet.
fn decode(bytes: []const u8) ?Decoded {
    std.debug.assert(bytes.len > 0);
    switch (bytes[0]) {
        0x1b => {
            if (bytes.len == 1) return .{ .key = .escape, .len = 1 };
            if (bytes[1] != '[' and bytes[1] != 'O') return .{ .key = .escape, .len = 1 };
            if (bytes.len == 2) return null;
            return switch (bytes[2]) {
                'A' => .{ .key = .up, .len = 3 },
                'B' => .{ .key = .down, .len = 3 },
                'C' => .{ .key = .right, .len = 3 },
                'D' => .{ .key = .left, .len = 3 },
                'H' => .{ .key = .home, .len = 3 },
                'F' => .{ .key = .end, .len = 3 },
                '0'...'9' => {
                    // A parameterised sequence: parameter and intermediate
                    // bytes, then a final byte in 0x40..0x7e. Scanning for the
                    // final byte rather than for `~` matters: a modified arrow
                    // key (ESC [ 1 ; 2 C) never carries one, and waiting for it
                    // would stall the decoder on every following keystroke.
                    var end: usize = 2;
                    while (end < bytes.len and !(bytes[end] >= 0x40 and bytes[end] <= 0x7e)) : (end += 1) {}
                    if (end == bytes.len) return null;
                    // Only `~` sequences name a key here, and they are named by
                    // the whole parameter rather than its first digit: ESC [ 15 ~
                    // is F5, not Home.
                    const key: ?Key = if (bytes[end] == '~') tildeKey(bytes[2..end]) else null;
                    return .{ .key = key, .len = end + 1 };
                },
                else => .{ .key = null, .len = 3 },
            };
        },
        '\r', '\n' => return .{ .key = .enter, .len = 1 },
        '\t' => return .{ .key = .tab, .len = 1 },
        0x7f, 0x08 => return .{ .key = .backspace, .len = 1 },
        else => return .{ .key = .{ .char = bytes[0] }, .len = 1 },
    }
}

/// The key a `~`-terminated CSI names, taken from its first parameter. A
/// modifier suffix (`ESC [ 5 ; 2 ~`, page-up with shift) names the same key.
fn tildeKey(parameters: []const u8) ?Key {
    var first = parameters;
    if (std.mem.indexOfAny(u8, first, ";:")) |cut| first = first[0..cut];
    if (std.mem.eql(u8, first, "1") or std.mem.eql(u8, first, "7")) return .home;
    if (std.mem.eql(u8, first, "4") or std.mem.eql(u8, first, "8")) return .end;
    if (std.mem.eql(u8, first, "5")) return .page_up;
    if (std.mem.eql(u8, first, "6")) return .page_down;
    return null;
}

test "decode reads arrow keys and plain characters" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    try std.testing.expectEqual(Key.up, decode("\x1b[A").?.key.?);
    try std.testing.expectEqual(Key.down, decode("\x1b[B").?.key.?);
    try std.testing.expectEqual(Key.page_up, decode("\x1b[5~").?.key.?);
    try std.testing.expectEqual(@as(u8, 'q'), decode("q").?.key.?.char);
    try std.testing.expectEqual(Key.enter, decode("\r").?.key.?);
    try std.testing.expectEqual(@as(usize, 4), decode("\x1b[5~").?.len);
}

test "decode reports an incomplete escape sequence instead of guessing" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    // Only the introducer has arrived; the caller must wait for more bytes.
    try std.testing.expectEqual(@as(?Decoded, null), decode("\x1b["));
    try std.testing.expectEqual(@as(?Decoded, null), decode("\x1b[5"));
    // A lone escape with nothing following it is the escape key.
    try std.testing.expectEqual(Key.escape, decode("\x1b").?.key.?);
}

test "decode consumes a modified key instead of waiting for a tilde" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    // Shift-Right: a CSI with parameters and no `~` at all. Consumed and
    // ignored; treating it as incomplete would stall every key after it.
    try std.testing.expectEqual(@as(usize, 6), decode("\x1b[1;2C").?.len);
    try std.testing.expectEqual(@as(?Key, null), decode("\x1b[1;5A").?.key);
    // A `~` sequence is named by its whole parameter: 15 is F5, not Home.
    try std.testing.expectEqual(@as(?Key, null), decode("\x1b[15~").?.key);
    try std.testing.expectEqual(@as(usize, 5), decode("\x1b[15~").?.len);
    // A modifier on a key that does have one still names that key.
    try std.testing.expectEqual(Key.page_up, decode("\x1b[5;2~").?.key.?);
    // Genuinely split sequences are still reported as incomplete.
    try std.testing.expectEqual(@as(?Decoded, null), decode("\x1b[1;2"));
}
