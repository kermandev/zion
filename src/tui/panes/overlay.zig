//! The stats overlay.
//!
//! Opens over whichever pane the user is on and reprints `report.writeStats`
//! verbatim. Nothing here reformats a number: the block read mid-run is the
//! same block that lands in scrollback when the run ends, so the two can never
//! disagree about a rounding.

const std = @import("std");
const client_table = @import("../../client_table.zig");
const report = @import("../../report.zig");
const model = @import("../model.zig");
const screen_module = @import("../screen.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const Canvas = screen_module.Canvas;
const Model = model.Model;
const Style = screen_module.Style;
const displayWidth = screen_module.displayWidth;

/// Clear columns between the border and the text on each side.
const padding: u16 = 2;
/// The note hangs under the label column's own two-space lead.
const note_indent: u16 = 2;

const hint = "c copy   esc close";
const note = "the run keeps going while this is open";

/// `canvas` is the whole screen, tab strip included: the overlay sits above
/// everything, not inside the pane's area.
pub fn render(canvas: Canvas, data: *const Model, stats: client_table.Stats) void {
    const palette = data.palette();
    dim(canvas, palette.rule);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    report.writeStats(&writer, stats) catch {};
    const rendered = writer.buffered();

    var stamp_buffer: [48]u8 = undefined;
    const stamp = std.fmt.bufPrint(&stamp_buffer, "  ·  snapshot at {f}", .{
        widgets.clock(data.elapsed_ms),
    }) catch "";

    var rows: u16 = 0;
    var content = @max(
        displayWidth("stats") + displayWidth(stamp) + 3 + displayWidth(hint),
        note_indent + displayWidth(note),
    );
    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| {
        if (!isValueLine(line)) continue;
        rows += 1;
        content = @max(content, displayWidth(line));
    }

    // Header, a blank, the values, a blank, the note, and a border either side.
    const box_w = @min(canvas.width(), content + padding * 2 + 2);
    const box_h = @min(canvas.height(), rows + 6);
    if (box_w < 4 or box_h < 3) return;

    const box = canvas.sub(
        (canvas.width() -| box_w) / 2,
        (canvas.height() -| box_h) / 2,
        box_w,
        box_h,
    );
    const solid: Style = .{ .fg = palette.text, .bg = palette.background };
    box.fill(" ", solid);
    border(box, .{ .fg = palette.rule, .bg = palette.background });

    const inner = box.sub(1 + padding, 1, box_w -| (2 + padding * 2), box_h -| 2);
    const label: Style = .{ .fg = palette.dim, .bg = palette.background };
    const faint: Style = .{ .fg = palette.faint, .bg = palette.background };

    const title_end = inner.text(0, 0, "stats", .{
        .fg = palette.text,
        .bg = palette.background,
        .bold = true,
    });
    _ = inner.text(title_end, 0, stamp, label);
    inner.textRight(0, hint, faint);

    // The note owns the last inner row. A box clamped to a short terminal holds
    // fewer value lines than the block has, and drawing them all would run one
    // into the note, which does not clear what it lands on: the two would share
    // a row as `the run keeps going while this is open=0 other=0`.
    const note_row = inner.height() -| 1;
    var row: u16 = 2;
    lines.reset();
    while (lines.next()) |line| {
        if (!isValueLine(line)) continue;
        if (row >= note_row) break;
        const split = @min(report.label_columns, line.len);
        const value_x = inner.text(0, row, line[0..split], label);
        _ = inner.text(value_x, row, line[split..], solid);
        row += 1;
    }

    _ = inner.text(note_indent, note_row, note, faint);
}

/// `writeStats` leads with a blank line and its own `stats:` heading; the box
/// carries that heading itself.
fn isValueLine(line: []const u8) bool {
    return line.len != 0 and !std.mem.eql(u8, line, "stats:");
}

/// Recolors what is already drawn instead of clearing it, so the pane keeps its
/// shape behind the overlay and the reader keeps their place.
fn dim(canvas: Canvas, color: theme.Rgb) void {
    const screen = canvas.screen;
    for (0..canvas.height()) |y| {
        const row = canvas.rect.y + @as(u16, @intCast(y));
        if (row >= screen.rows) break;
        for (0..canvas.width()) |x| {
            const column = canvas.rect.x + @as(u16, @intCast(x));
            if (column >= screen.cols) break;
            screen.back[@as(usize, row) * screen.cols + column].style.fg = color;
        }
    }
}

fn border(canvas: Canvas, style: Style) void {
    const w = canvas.width();
    const h = canvas.height();
    if (w == 0 or h == 0) return;
    canvas.repeat(1, 0, w -| 2, "─", style);
    canvas.repeat(1, h - 1, w -| 2, "─", style);
    for (1..h -| 1) |row| {
        canvas.set(0, @intCast(row), "│", style);
        canvas.set(w - 1, @intCast(row), "│", style);
    }
    canvas.set(0, 0, "┌", style);
    canvas.set(w - 1, 0, "┐", style);
    canvas.set(0, h - 1, "└", style);
    canvas.set(w - 1, h - 1, "┘", style);
}

const testing = std.testing;

fn testStats() client_table.Stats {
    return .{
        .requested = 100,
        .connected = 97,
        .play = 97,
        .waiting = 3,
        .reconnects = 41,
        .packets_received = 4_000,
        .keep_alives_answered = 120,
        .bytes_received = 2048,
        .bytes_sent = 1024,
        .duration_ms = 252_100,
    };
}

test "overlay shows the figures writeStats prints" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);
    screen.clear(.{ .fg = theme.running.text, .bg = theme.running.background });

    var data = try Model.init(testing.allocator, .{ .client_count = 100 }, 4);
    defer data.deinit();
    data.elapsed_ms = 252_100;

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, testStats());

    try testing.expect(screen.contains("runtime"));
    try testing.expect(screen.contains("252.10s"));
    try testing.expect(screen.contains("requested=100 connected=97"));
    // The box supplies its own heading and snapshot time, not writeStats'.
    try testing.expect(screen.contains("stats  ·  snapshot at 04:12"));
    try testing.expect(!screen.contains("stats:"));
    try testing.expect(screen.contains(note));
    try testing.expect(screen.contains("┌"));
}

test "overlay dims the pane behind without erasing it" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);
    screen.clear(.{ .fg = theme.running.text, .bg = theme.running.background });
    _ = screen.writeText(0, 0, "1 fleet   2 shards", .{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 100 }, 4);
    defer data.deinit();

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, testStats());

    // The strip is outside a centred box: still legible, just pushed back.
    var buffer: [256]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, screen.rowText(0, &buffer), "1 fleet   2 shards"));
    try testing.expect(screen.back[0].style.fg.eql(theme.running.rule));
    try testing.expect(!screen.back[0].style.fg.eql(theme.running.text));

    // Inside the box the text is drawn over a solid background instead.
    const middle = screen.back[@as(usize, 20) * 120 + 60];
    try testing.expect(middle.style.bg != null);
    try testing.expect(middle.style.bg.?.eql(theme.running.background));
    try testing.expect(!middle.style.fg.eql(theme.running.rule));
}

test "overlay clamps to a canvas smaller than its content" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(12, 5);
    screen.clear(.{ .fg = theme.running.text, .bg = theme.running.background });

    var data = try Model.init(testing.allocator, .{ .client_count = 100 }, 1);
    defer data.deinit();

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, testStats());

    // Origin clamps to zero rather than wrapping to a huge column.
    try testing.expectEqualStrings("┌", screen.back[0].text());
    try testing.expectEqualStrings("┐", screen.back[11].text());
    try testing.expectEqualStrings("└", screen.back[4 * 12].text());
    try testing.expectEqualStrings("┘", screen.back[4 * 12 + 11].text());
}
