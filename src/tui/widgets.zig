//! Drawing primitives shared by the panes.
//!
//! Everything here is built from block elements so it composes on a character
//! grid: a gauge is a run of cells, a chart row is a run of cells. Nothing
//! depends on partial-cell tricks or a proportional font.

const std = @import("std");
const screen_module = @import("screen.zig");
const theme = @import("theme.zig");

const Canvas = screen_module.Canvas;
const Style = screen_module.Style;
const Rgb = theme.Rgb;

/// Eighth-height blocks, tallest last. Index 0 is empty.
const vertical_blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
/// Eighth-width blocks for sub-cell precision on horizontal bars.
const horizontal_blocks = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };

pub const full_block = "█";

/// A filled bar over a visible track, so the total is always legible even when
/// the value is near zero.
pub fn gauge(
    canvas: Canvas,
    x: u16,
    y: u16,
    width: u16,
    fraction: f64,
    fill_style: Style,
    track_style: Style,
) void {
    if (width == 0) return;
    const clamped = std.math.clamp(fraction, 0, 1);
    const filled: u16 = @intFromFloat(@round(clamped * @as(f64, @floatFromInt(width))));
    for (0..width) |offset| {
        const column = x + @as(u16, @intCast(offset));
        const style = if (offset < filled) fill_style else track_style;
        canvas.set(column, y, full_block, style);
    }
}

/// A bar without a track, sized to `fraction` of `width`, using eighth-width
/// blocks so small values stay visible instead of rounding away to nothing.
pub fn bar(canvas: Canvas, x: u16, y: u16, width: u16, fraction: f64, style: Style) u16 {
    if (width == 0) return x;
    const clamped = std.math.clamp(fraction, 0, 1);
    const eighths: u32 = @intFromFloat(@round(clamped * @as(f64, @floatFromInt(width)) * 8));
    const whole: u16 = @intCast(eighths / 8);
    const remainder: usize = @intCast(eighths % 8);

    var column = x;
    for (0..@min(whole, width)) |_| {
        canvas.set(column, y, full_block, style);
        column += 1;
    }
    if (remainder != 0 and column < x + width) {
        canvas.set(column, y, horizontal_blocks[remainder], style);
        column += 1;
    }
    // A non-zero value must never render as nothing.
    if (column == x and clamped > 0) {
        canvas.set(column, y, horizontal_blocks[1], style);
        column += 1;
    }
    return column;
}

/// A single-row sparkline. `samples` is oldest-first; the newest sample lands
/// at the right edge and the series is truncated from the left if it is longer
/// than `width`.
pub fn sparkline(canvas: Canvas, x: u16, y: u16, width: u16, samples: []const f32, maximum: f32, style: Style) void {
    if (width == 0 or samples.len == 0) return;
    const visible = samples[samples.len -| width..];
    const scale = if (maximum > 0) maximum else 1;
    // Right-align: a partly-filled window grows from the right as it fills.
    const start = width -| @as(u16, @intCast(visible.len));
    for (visible, 0..) |sample, index| {
        const level = levelFor(sample, scale, 8);
        canvas.set(x + start + @as(u16, @intCast(index)), y, vertical_blocks[level], style);
    }
}

/// A multi-row area chart. Row 0 is the top of the plot. Each column is filled
/// from the bottom up, so a tall series stacks full blocks in the lower rows
/// and a partial block in the row where it runs out.
///
/// `deep_style` paints the bottom row, which is where every non-zero series has
/// something, so the chart keeps a readable baseline.
pub fn areaChart(
    canvas: Canvas,
    x: u16,
    y: u16,
    width: u16,
    rows: u16,
    samples: []const f32,
    maximum: f32,
    style: Style,
    deep_style: Style,
) void {
    if (width == 0 or rows == 0 or samples.len == 0) return;
    const visible = samples[samples.len -| width..];
    const scale = if (maximum > 0) maximum else 1;
    const start = width -| @as(u16, @intCast(visible.len));

    for (visible, 0..) |sample, index| {
        const column = x + start + @as(u16, @intCast(index));
        // Total eighths of height this sample occupies across all rows.
        const total_eighths = levelFor(sample, scale, @as(u32, rows) * 8);
        for (0..rows) |row_offset| {
            // Row 0 is the top, so the bottom row consumes the first eighths.
            const from_bottom = rows - 1 - @as(u16, @intCast(row_offset));
            const row_base = @as(u32, from_bottom) * 8;
            const level: usize = if (total_eighths <= row_base)
                0
            else
                @min(8, total_eighths - row_base);
            if (level == 0) continue;
            const row_style = if (from_bottom == 0) deep_style else style;
            canvas.set(column, y + @as(u16, @intCast(row_offset)), vertical_blocks[level], row_style);
        }
    }
}

/// Scales `value` into `0..steps` eighth-levels, clamped. A non-zero value
/// always reaches at least the first level so it cannot vanish.
fn levelFor(value: f32, maximum: f32, steps: u32) u32 {
    if (!(value > 0)) return 0;
    const ratio = std.math.clamp(@as(f64, value) / @as(f64, maximum), 0, 1);
    const level: u32 = @intFromFloat(@round(ratio * @as(f64, @floatFromInt(steps))));
    return @max(1, level);
}

/// The `▁▂▃` axis rule drawn down the left of a chart.
pub fn chartAxis(canvas: Canvas, x: u16, y: u16, rows: u16, style: Style) void {
    for (0..rows) |row| canvas.set(x, y + @as(u16, @intCast(row)), "┤", style);
    canvas.set(x, y + rows, "└", style);
}

/// One heatmap swatch per shard, colored by severity. `glyphs` is how many
/// cells a swatch occupies and `stride` how far apart they start, so a caller
/// can trade the gap and the second cell away to fit a larger fleet rather than
/// hiding shards. The caller draws the id row beneath.
pub fn heatRow(
    canvas: Canvas,
    x: u16,
    y: u16,
    severities: []const theme.Severity,
    palette: theme.Palette,
    glyphs: u16,
    stride: u16,
) void {
    for (severities, 0..) |severity, index| {
        const column = x + @as(u16, @intCast(index)) * stride;
        const style: Style = .{ .fg = heatColor(severity, palette) };
        for (0..glyphs) |offset| canvas.set(column + @as(u16, @intCast(offset)), y, full_block, style);
    }
}

/// The color a severity takes in a heat map. Shared with whatever draws the
/// key for one, so the two can never disagree about what a color means.
pub fn heatColor(severity: theme.Severity, palette: theme.Palette) Rgb {
    return switch (severity) {
        // `ok` uses the muted track green so the warm cells stand out against a
        // calm field rather than competing with it.
        .ok => palette.ok_track,
        .watch => palette.warn,
        .hot => palette.bad,
    };
}

/// Width in columns a `heatRow` of `count` swatches occupies.
///
/// Saturates rather than trapping. The result is a column count that every
/// caller weighs against a terminal width, and no terminal is 65,535 columns
/// wide, so the clamped answer means what the exact one would. `heatLayout`
/// bounds `count` to its stage before asking, but `heatNaturalWidth` asks
/// about the whole fleet, and that one would have trapped from 21,846 shards.
pub fn heatRowWidth(count: usize, glyphs: u16, stride: u16) u16 {
    if (count == 0) return 0;
    const total = (count - 1) * stride + glyphs;
    return std.math.cast(u16, total) orelse std.math.maxInt(u16);
}

/// Formats a duration as `mm:ss`, the run clock shown in the status strip.
pub const Clock = struct {
    ms: u64,

    pub fn format(value: Clock, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const total_seconds = value.ms / 1000;
        try writer.print("{d:0>2}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 });
    }
};

pub fn clock(ms: u64) Clock {
    return .{ .ms = ms };
}

/// Formats a duration as `mm:ss.mmm`, the timestamp column in the log pane.
pub const Stamp = struct {
    ms: u64,

    pub fn format(value: Stamp, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const total_seconds = value.ms / 1000;
        try writer.print("{d:0>2}:{d:0>2}.{d:0>3}", .{ total_seconds / 60, total_seconds % 60, value.ms % 1000 });
    }
};

pub fn stamp(ms: u64) Stamp {
    return .{ .ms = ms };
}

/// Milliseconds rendered the way the panes show latency: sub-millisecond and
/// small values keep a decimal, larger ones do not.
pub const Millis = struct {
    value: f64,

    pub fn format(self: Millis, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.value < 10) {
            try writer.print("{d:.1}ms", .{self.value});
        } else {
            try writer.print("{d:.0}ms", .{self.value});
        }
    }
};

pub fn millis(value: f64) Millis {
    return .{ .value = value };
}

test "gauge fills the requested fraction over a full-width track" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(10, 1);
    const fill: Style = .{ .fg = theme.running.ok };
    const track: Style = .{ .fg = theme.running.track };
    screen.clear(track);

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    gauge(canvas, 0, 0, 10, 0.5, fill, track);

    // Every cell is drawn; the first half carries the fill color.
    try std.testing.expect(screen.back[0].style.fg.eql(theme.running.ok));
    try std.testing.expect(screen.back[4].style.fg.eql(theme.running.ok));
    try std.testing.expect(screen.back[5].style.fg.eql(theme.running.track));
    try std.testing.expectEqualStrings(full_block, screen.back[9].text());
}

test "bar keeps a small non-zero value visible" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(20, 1);
    const style: Style = .{ .fg = theme.running.chart };
    screen.clear(style);
    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };

    // 0.1% of twenty columns rounds to nothing, but must still show a mark.
    const end = bar(canvas, 0, 0, 20, 0.001, style);
    try std.testing.expectEqual(@as(u16, 1), end);
    try std.testing.expect(!std.mem.eql(u8, " ", screen.back[0].text()));

    // A true zero draws nothing.
    screen.clear(style);
    try std.testing.expectEqual(@as(u16, 0), bar(canvas, 0, 0, 20, 0, style));
    try std.testing.expectEqualStrings(" ", screen.back[0].text());
}

test "a heat row wider than the column count saturates rather than trapping" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u16, 0), heatRowWidth(0, 2, 3));
    try std.testing.expectEqual(@as(u16, 2), heatRowWidth(1, 2, 3));
    try std.testing.expectEqual(@as(u16, 11), heatRowWidth(4, 2, 3));
    // 21,846 shards at stride 3 is the first count past u16, and the fleet
    // width asks about the whole fleet rather than what a stage holds.
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), heatRowWidth(21_846, 2, 3));
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), heatRowWidth(std.math.maxInt(usize), 1, 1));
}

test "areaChart stacks a full-height sample across every row" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(4, 3);
    const style: Style = .{ .fg = theme.running.chart };
    const deep: Style = .{ .fg = theme.running.chart_deep };
    screen.clear(style);
    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };

    const samples = [_]f32{ 0, 0, 0, 10 };
    areaChart(canvas, 0, 0, 4, 3, &samples, 10, style, deep);

    // The newest sample is at the right edge and fills the full column.
    try std.testing.expectEqualStrings("█", screen.back[0 * 4 + 3].text());
    try std.testing.expectEqualStrings("█", screen.back[1 * 4 + 3].text());
    try std.testing.expectEqualStrings("█", screen.back[2 * 4 + 3].text());
    // The bottom row carries the deep style.
    try std.testing.expect(screen.back[2 * 4 + 3].style.fg.eql(theme.running.chart_deep));
    // A zero sample leaves its column empty.
    try std.testing.expectEqualStrings(" ", screen.back[2 * 4 + 0].text());
}

test "areaChart puts a half-height sample in the lower rows only" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(1, 2);
    const style: Style = .{ .fg = theme.running.chart };
    const deep: Style = .{ .fg = theme.running.chart_deep };
    screen.clear(style);
    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };

    areaChart(canvas, 0, 0, 1, 2, &[_]f32{5}, 10, style, deep);
    // Top row empty, bottom row full.
    try std.testing.expectEqualStrings(" ", screen.back[0].text());
    try std.testing.expectEqualStrings("█", screen.back[1].text());
}

test "sparkline right-aligns a partially filled window" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(6, 1);
    const style: Style = .{ .fg = theme.running.chart };
    screen.clear(style);
    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };

    sparkline(canvas, 0, 0, 6, &[_]f32{ 10, 10 }, 10, style);
    // Two samples in a six-wide slot sit at the right.
    try std.testing.expectEqualStrings(" ", screen.back[0].text());
    try std.testing.expectEqualStrings("█", screen.back[4].text());
    try std.testing.expectEqualStrings("█", screen.back[5].text());
}

test "clock and stamp format the run timers" {
    if (comptime !@import("../features.zig").tui) return error.SkipZigTest;
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("04:12", try std.fmt.bufPrint(&buffer, "{f}", .{clock(252_000)}));
    try std.testing.expectEqualStrings("04:11.902", try std.fmt.bufPrint(&buffer, "{f}", .{stamp(251_902)}));
    try std.testing.expectEqualStrings("1.8ms", try std.fmt.bufPrint(&buffer, "{f}", .{millis(1.812)}));
    try std.testing.expectEqualStrings("41ms", try std.fmt.bufPrint(&buffer, "{f}", .{millis(41)}));
}
