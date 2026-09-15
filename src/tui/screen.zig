//! A double-buffered character grid.
//!
//! Panes draw into cells; `flush` compares the new frame against the one on
//! screen and emits only what changed. At 20 Hz over a 120-column dashboard a
//! full repaint would be tens of kilobytes a second of escape codes, most of it
//! identical to what is already there.
//!
//! Every cell is exactly one column wide. The dashboard restricts itself to
//! single-width glyphs (block elements, box drawing, ASCII), so column
//! arithmetic in the panes is always exact.

const std = @import("std");
const Io = std.Io;
const theme = @import("theme.zig");
const Rgb = theme.Rgb;

pub const Style = struct {
    fg: Rgb,
    bg: ?Rgb = null,
    bold: bool = false,

    pub fn eql(style: Style, other: Style) bool {
        if (!style.fg.eql(other.fg) or style.bold != other.bold) return false;
        if (style.bg == null and other.bg == null) return true;
        const bg = style.bg orelse return false;
        const other_bg = other.bg orelse return false;
        return bg.eql(other_bg);
    }
};

/// One grid cell: a single-column grapheme plus its style. Four bytes covers
/// any UTF-8 scalar, which is all the dashboard draws.
pub const Cell = struct {
    bytes: [4]u8 = @splat(' '),
    len: u8 = 1,
    style: Style,

    pub fn text(cell: *const Cell) []const u8 {
        return cell.bytes[0..cell.len];
    }

    /// `setCell` re-defaults `bytes` to spaces before copying the grapheme, so
    /// the tail past `len` is always blank and the whole array compares as one
    /// word. Keep that true if you ever write `bytes` directly: comparing the
    /// runtime-length slices instead compiles to an out-of-line memcmp per
    /// cell, which is about half of `flush`.
    pub fn eql(cell: Cell, other: Cell) bool {
        if (cell.len != other.len) return false;
        if (@as(u32, @bitCast(cell.bytes)) != @as(u32, @bitCast(other.bytes))) return false;
        return cell.style.eql(other.style);
    }
};

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    /// A sub-rectangle in the parent's coordinates, clipped to it.
    pub fn sub(rect: Rect, x: u16, y: u16, w: u16, h: u16) Rect {
        const clipped_w = @min(w, rect.w -| x);
        const clipped_h = @min(h, rect.h -| y);
        return .{ .x = rect.x + x, .y = rect.y + y, .w = clipped_w, .h = clipped_h };
    }

    /// Splits `height` rows off the top, returning the top and bottom parts.
    pub fn splitTop(rect: Rect, height: u16) struct { Rect, Rect } {
        const top_h = @min(height, rect.h);
        return .{
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = top_h },
            .{ .x = rect.x, .y = rect.y + top_h, .w = rect.w, .h = rect.h - top_h },
        };
    }
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: u16 = 0,
    rows: u16 = 0,
    /// What is currently on the terminal.
    front: []Cell = &.{},
    /// What the frame being built looks like.
    back: []Cell = &.{},
    /// Forces the next flush to repaint everything, after a resize or a redraw
    /// request.
    dirty: bool = true,
    /// The frame's background, taken from the style `clear` was given. Panes
    /// draw foreground-only styles, so without this every cell they touch would
    /// fall back to the terminal's own background and the dashboard would show
    /// through in patches.
    background: ?Rgb = null,

    pub fn init(allocator: std.mem.Allocator) Screen {
        return .{ .allocator = allocator };
    }

    pub fn deinit(screen: *Screen) void {
        screen.allocator.free(screen.front);
        screen.allocator.free(screen.back);
        screen.* = undefined;
    }

    pub fn resize(screen: *Screen, cols: u16, rows: u16) !void {
        if (screen.cols == cols and screen.rows == rows) return;
        const count = @as(usize, cols) * @as(usize, rows);
        const front = try screen.allocator.alloc(Cell, count);
        errdefer screen.allocator.free(front);
        const back = try screen.allocator.alloc(Cell, count);

        // Freshly allocated cells are undefined, and a caller that reads before
        // its first `clear` would see garbage lengths. Blank them so an
        // un-cleared screen is merely empty rather than unsound.
        const blank: Cell = .{ .style = .{ .fg = .{ .r = 0, .g = 0, .b = 0 } } };
        @memset(front, blank);
        @memset(back, blank);

        screen.allocator.free(screen.front);
        screen.allocator.free(screen.back);
        screen.front = front;
        screen.back = back;
        screen.cols = cols;
        screen.rows = rows;
        screen.dirty = true;
    }

    pub fn bounds(screen: *const Screen) Rect {
        return .{ .x = 0, .y = 0, .w = screen.cols, .h = screen.rows };
    }

    /// Resets the frame under construction. Called once at the top of a frame.
    pub fn clear(screen: *Screen, style: Style) void {
        screen.background = style.bg;
        const blank: Cell = .{ .style = style };
        @memset(screen.back, blank);
    }

    pub fn setCell(screen: *Screen, x: u16, y: u16, grapheme: []const u8, style: Style) void {
        if (x >= screen.cols or y >= screen.rows) return;
        if (grapheme.len == 0 or grapheme.len > 4) return;
        const cell = &screen.back[@as(usize, y) * screen.cols + x];
        cell.* = .{ .len = @intCast(grapheme.len), .style = style };
        @memcpy(cell.bytes[0..grapheme.len], grapheme);
    }

    /// Writes UTF-8 text starting at (x, y), clipped to the row. Returns the
    /// number of columns advanced.
    pub fn writeText(screen: *Screen, x: u16, y: u16, text: []const u8, style: Style) u16 {
        if (y >= screen.rows) return 0;
        var column = x;
        var index: usize = 0;
        while (index < text.len and column < screen.cols) {
            const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            const end = @min(index + width, text.len);
            screen.setCell(column, y, text[index..end], style);
            index = end;
            column += 1;
        }
        return column -| x;
    }

    /// Emits the difference between `back` and `front` as ANSI, then swaps.
    pub fn flush(screen: *Screen, writer: *Io.Writer) !void {
        var current: ?Style = null;
        var cursor_row: ?u16 = null;
        var cursor_col: u16 = 0;

        for (0..screen.rows) |row_index| {
            const row: u16 = @intCast(row_index);
            const offset = @as(usize, row) * screen.cols;
            for (0..screen.cols) |column_index| {
                const column: u16 = @intCast(column_index);
                const cell = screen.back[offset + column];
                if (!screen.dirty and cell.eql(screen.front[offset + column])) continue;

                // Only re-address the cursor when the run is not contiguous
                // with what was just written.
                if (cursor_row != row or cursor_col != column) {
                    try writer.print("\x1b[{d};{d}H", .{ row + 1, column + 1 });
                    cursor_row = row;
                }
                const style: Style = .{
                    .fg = cell.style.fg,
                    .bg = cell.style.bg orelse screen.background,
                    .bold = cell.style.bold,
                };
                if (current == null or !current.?.eql(style)) {
                    try writeStyle(writer, style);
                    current = style;
                }
                try writer.writeAll(cell.text());
                cursor_col = column + 1;
            }
        }

        try writer.writeAll("\x1b[0m");
        // `front` has to end up holding what the terminal now shows, which a
        // swap says as well as a copy and without moving the grid: the next
        // frame opens with `clear`, which overwrites every cell of the new
        // `back` before anything reads it.
        std.mem.swap([]Cell, &screen.front, &screen.back);
        screen.dirty = false;
    }

    /// One rendered row as text. Tests assert on what a pane put on screen
    /// rather than on cell coordinates, which the multi-byte block glyphs the
    /// charts draw with make brittle.
    pub fn rowText(screen: *const Screen, row: u16, out: []u8) []const u8 {
        var length: usize = 0;
        for (0..screen.cols) |column| {
            const text = screen.back[@as(usize, row) * screen.cols + column].text();
            if (length + text.len > out.len) break;
            @memcpy(out[length..][0..text.len], text);
            length += text.len;
        }
        return out[0..length];
    }

    /// The whole frame as text, rows joined by newlines.
    pub fn frameText(screen: *const Screen, out: []u8) []const u8 {
        var length: usize = 0;
        for (0..screen.rows) |row| {
            length += screen.rowText(@intCast(row), out[length..]).len;
            if (length == out.len) break;
            out[length] = '\n';
            length += 1;
        }
        return out[0..length];
    }

    /// Whether `needle` appears on any one row. Row-at-a-time rather than over
    /// `frameText`, so a match can never straddle the wrap between two rows.
    pub fn contains(screen: *const Screen, needle: []const u8) bool {
        var buffer: [1024]u8 = undefined;
        for (0..screen.rows) |row| {
            if (std.mem.indexOf(u8, screen.rowText(@intCast(row), &buffer), needle) != null) return true;
        }
        return false;
    }
};

fn writeStyle(writer: *Io.Writer, style: Style) !void {
    try writer.writeAll("\x1b[0");
    if (style.bold) try writer.writeAll(";1");
    try writer.print(";38;2;{d};{d};{d}", .{ style.fg.r, style.fg.g, style.fg.b });
    if (style.bg) |bg| try writer.print(";48;2;{d};{d};{d}", .{ bg.r, bg.g, bg.b });
    try writer.writeAll("m");
}

/// A clipped drawing surface. Panes receive one and work in local coordinates,
/// so a pane can never scribble outside the region it was given.
pub const Canvas = struct {
    screen: *Screen,
    rect: Rect,

    pub fn sub(canvas: Canvas, x: u16, y: u16, w: u16, h: u16) Canvas {
        return .{ .screen = canvas.screen, .rect = canvas.rect.sub(x, y, w, h) };
    }

    pub fn area(canvas: Canvas, rect: Rect) Canvas {
        return .{ .screen = canvas.screen, .rect = rect };
    }

    pub fn width(canvas: Canvas) u16 {
        return canvas.rect.w;
    }

    pub fn height(canvas: Canvas) u16 {
        return canvas.rect.h;
    }

    pub fn set(canvas: Canvas, x: u16, y: u16, grapheme: []const u8, style: Style) void {
        if (x >= canvas.rect.w or y >= canvas.rect.h) return;
        canvas.screen.setCell(canvas.rect.x + x, canvas.rect.y + y, grapheme, style);
    }

    /// Draws `text` at (x, y), truncated at the canvas edge. Returns the
    /// column just past the text, so callers can chain runs of mixed styling.
    pub fn text(canvas: Canvas, x: u16, y: u16, value: []const u8, style: Style) u16 {
        if (y >= canvas.rect.h or x >= canvas.rect.w) return x;
        const limit = canvas.rect.w - x;
        var column = x;
        var index: usize = 0;
        while (index < value.len and column - x < limit) {
            const size = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
            const end = @min(index + size, value.len);
            canvas.set(column, y, value[index..end], style);
            index = end;
            column += 1;
        }
        return column;
    }

    /// Draws `value` so that it ends at the canvas's right edge.
    pub fn textRight(canvas: Canvas, y: u16, value: []const u8, style: Style) void {
        const columns = displayWidth(value);
        const x = canvas.rect.w -| columns;
        _ = canvas.text(x, y, value, style);
    }

    /// Formats into a stack buffer and draws it. Returns the column just past
    /// the text. Output longer than the buffer is truncated rather than lost.
    ///
    /// A fixed writer rather than `bufPrint`, which on overflow reports only
    /// that the output did not fit: the caller is then left drawing the whole
    /// buffer and trusting that formatting happened to fill it, rather than the
    /// prefix `buffered()` names outright.
    pub fn print(canvas: Canvas, x: u16, y: u16, style: Style, comptime fmt: []const u8, args: anytype) u16 {
        var buffer: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        writer.print(fmt, args) catch {};
        return canvas.text(x, y, writer.buffered(), style);
    }

    pub fn printRight(canvas: Canvas, y: u16, style: Style, comptime fmt: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        writer.print(fmt, args) catch {};
        canvas.textRight(y, writer.buffered(), style);
    }

    pub fn fill(canvas: Canvas, grapheme: []const u8, style: Style) void {
        for (0..canvas.rect.h) |y| {
            for (0..canvas.rect.w) |x| {
                canvas.set(@intCast(x), @intCast(y), grapheme, style);
            }
        }
    }

    /// Repeats `grapheme` for `count` columns starting at (x, y).
    pub fn repeat(canvas: Canvas, x: u16, y: u16, count: u16, grapheme: []const u8, style: Style) void {
        for (0..count) |offset| canvas.set(x + @as(u16, @intCast(offset)), y, grapheme, style);
    }
};

/// Column count of UTF-8 text, on the dashboard's single-width assumption.
pub fn displayWidth(text: []const u8) u16 {
    var columns: u16 = 0;
    var index: usize = 0;
    while (index < text.len) {
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        columns += 1;
    }
    return columns;
}

test "writeText clips at the screen edge instead of wrapping" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(4, 2);
    screen.clear(.{ .fg = theme.running.text });

    const style: Style = .{ .fg = theme.running.text };
    _ = screen.writeText(2, 0, "abcd", style);
    try std.testing.expectEqualStrings("a", screen.back[2].text());
    try std.testing.expectEqualStrings("b", screen.back[3].text());
    // Row 1 must be untouched: nothing wrapped past the edge.
    try std.testing.expectEqualStrings(" ", screen.back[4].text());
}

test "flush emits only changed cells" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(8, 1);

    const style: Style = .{ .fg = theme.running.text };
    var buffer: [4096]u8 = undefined;

    screen.clear(style);
    _ = screen.writeText(0, 0, "hello", style);
    var first: Io.Writer = .fixed(&buffer);
    try screen.flush(&first);
    try std.testing.expect(std.mem.indexOf(u8, first.buffered(), "hello") != null);

    // An identical frame produces no cell output at all.
    screen.clear(style);
    _ = screen.writeText(0, 0, "hello", style);
    var second: Io.Writer = .fixed(&buffer);
    try screen.flush(&second);
    try std.testing.expect(std.mem.indexOf(u8, second.buffered(), "hello") == null);

    // Changing one character redraws that character, not the whole row.
    screen.clear(style);
    _ = screen.writeText(0, 0, "hellp", style);
    var third: Io.Writer = .fixed(&buffer);
    try screen.flush(&third);
    try std.testing.expect(std.mem.indexOf(u8, third.buffered(), "p") != null);
    try std.testing.expect(std.mem.indexOf(u8, third.buffered(), "hell") == null);
}

test "canvas clips drawing to its own rectangle" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(10, 3);
    const style: Style = .{ .fg = theme.running.text };
    screen.clear(style);

    const canvas: Canvas = .{ .screen = &screen, .rect = .{ .x = 2, .y = 1, .w = 3, .h = 1 } };
    _ = canvas.text(0, 0, "abcdef", style);

    // Wrote inside the rect...
    try std.testing.expectEqualStrings("a", screen.back[1 * 10 + 2].text());
    try std.testing.expectEqualStrings("c", screen.back[1 * 10 + 4].text());
    // ...and stopped at its right edge.
    try std.testing.expectEqualStrings(" ", screen.back[1 * 10 + 5].text());
    // A row outside the rect is untouched.
    try std.testing.expectEqualStrings(" ", screen.back[2].text());
}

test "foreground-only draws still get the frame background" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(8, 1);

    const palette = theme.running;
    screen.clear(.{ .fg = palette.text, .bg = palette.background });
    // What every pane does: a style with no background of its own.
    _ = screen.writeText(0, 0, "hi", .{ .fg = palette.ok });

    var buffer: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try screen.flush(&writer);
    const output = writer.buffered();

    // The background is emitted for the drawn cells, not just the blank ones,
    // so the terminal's own background never shows through the dashboard.
    var expected: [32]u8 = undefined;
    const background = try std.fmt.bufPrint(&expected, "48;2;{d};{d};{d}", .{
        palette.background.r,
        palette.background.g,
        palette.background.b,
    });
    try std.testing.expect(std.mem.indexOf(u8, output, background) != null);
    // An explicit background still wins over the frame's.
    screen.dirty = true;
    screen.clear(.{ .fg = palette.text, .bg = palette.background });
    _ = screen.writeText(0, 0, "hi", .{ .fg = palette.background, .bg = palette.text });
    var second: Io.Writer = .fixed(&buffer);
    try screen.flush(&second);
    var reversed: [32]u8 = undefined;
    const highlight = try std.fmt.bufPrint(&reversed, "48;2;{d};{d};{d}", .{
        palette.text.r,
        palette.text.g,
        palette.text.b,
    });
    try std.testing.expect(std.mem.indexOf(u8, second.buffered(), highlight) != null);
}

test "displayWidth counts columns not bytes" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u16, 5), displayWidth("hello"));
    // Block elements are three bytes each but one column each.
    try std.testing.expectEqual(@as(u16, 3), displayWidth("███"));
    try std.testing.expectEqual(@as(u16, 2), displayWidth("▲ "));
}
