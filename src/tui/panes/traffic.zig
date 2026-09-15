//! The traffic pane.
//!
//! Throughput is the number a load generator has to be believed about, so the
//! charts take the full width and every series has its now, average and peak
//! spelled out underneath rather than left to be eyeballed off a plot.

const std = @import("std");

const features = @import("../../features.zig");
const report = @import("../../report.zig");
const model_module = @import("../model.zig");
const screen_module = @import("../screen.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const Canvas = screen_module.Canvas;
const FleetSeries = model_module.FleetSeries;
const Model = model_module.Model;
const Palette = theme.Palette;
const Span = model_module.Span;
const Style = screen_module.Style;
const View = model_module.View;

/// Chart heights are floors, not fixed sizes. Receive gets twice the other two
/// because it is the series that actually moves under load; the others only
/// need a shape.
const receive_rows: u16 = 4;
const secondary_rows: u16 = 2;
/// Rows the pane spends on labels, the x-axis, the gaps between sections and
/// the summary block, which is everything the charts do not get.
const furniture_rows: u16 = 8 + summary_rows;
/// Columns reserved for the tick labels and the rule they hang off.
const gutter: u16 = 10;
/// Height and width of the block beneath the charts.
const summary_rows: u16 = 8;
const summary_width: u16 = 54;
/// Column grid inside that block.
const field_width: u16 = 12;
const value_width: u16 = 14;
/// Longest receive-share bar, drawn relative to the busiest shard.
const share_bar: u16 = 20;
const shares_listed: usize = 3;

const span_hint = "←→ span";
const key_hints = "←→ span   p pause   c copy   q quit";
const receive_label = "receive";

/// Which formatter a chart's tick labels use.
const Scale = enum { bytes, count };

pub fn render(canvas: Canvas, data: *const Model, view: View) void {
    const palette = data.palette();
    const height = canvas.height();
    if (canvas.width() == 0 or height == 0) return;

    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };

    // The hints are what the footer is for; the sample cadence is a footnote
    // and steps aside rather than landing on top of them.
    const hints_end = canvas.text(0, height - 1, key_hints, faint);
    if (canvas.width() -| hints_end >= 16) {
        canvas.printRight(height - 1, faint, "{d}ms samples", .{model_module.sample_interval_ms});
    }

    const body = height -| 2;

    // The summary is a fixed cost and the charts take whatever is left, in the
    // ratio the pane is designed around, so a tall terminal buys plot rather
    // than empty rows.
    const spare = body -| furniture_rows -| (receive_rows + 2 * secondary_rows);
    const quarter = spare / 4;
    const primary = receive_rows + spare - 2 * quarter;
    const secondary = secondary_rows + quarter;

    var y: u16 = 1;
    if (y < body) {
        _ = canvas.text(0, y, receive_label, dim);
        spanSelector(canvas, y, view.span, palette);
    }
    y = chart(canvas, y + 1, body, &data.rx, view.span, primary, .bytes, palette, true);
    if (y < body) {
        offsets(canvas, y, view.span, data.elapsed_ms, faint);
        y += 1;
    }

    y += 1;
    if (y < body) _ = canvas.text(0, y, "send", dim);
    y = chart(canvas, y + 1, body, &data.tx, view.span, secondary, .bytes, palette, false);

    y += 1;
    if (y < body) _ = canvas.text(0, y, "inbound packets", dim);
    y = chart(canvas, y + 1, body, &data.packets, view.span, secondary, .count, palette, false);

    const top = @max(y + 1, body -| summary_rows);
    if (top >= body) return;
    const rows = body - top;
    figures(canvas.sub(0, top, summary_width, rows), data, palette);
    const divide = summary_width + 2;
    if (canvas.width() > divide) {
        shares(canvas.sub(divide, top, canvas.width() - divide, rows), data, palette);
    }
}

/// The four spans, with the active one lit. `←→` changes it.
fn spanSelector(canvas: Canvas, y: u16, active: Span, palette: Palette) void {
    var columns = screen_module.displayWidth(span_hint);
    for (std.enums.values(Span)) |span| columns += 2 + screen_module.displayWidth(span.label());

    const start = canvas.width() -| columns;
    // The section label shares this row and outranks the selector.
    if (start < screen_module.displayWidth(receive_label) + 2) return;

    var x = canvas.text(start, y, span_hint, .{ .fg = palette.faint });
    for (std.enums.values(Span)) |span| {
        x += 2;
        const style: Style = if (span == active)
            .{ .fg = palette.text, .bold = true }
        else
            .{ .fg = palette.faint };
        x = canvas.text(x, y, span.label(), style);
    }
}

/// Draws one chart and returns the row after it. `corner` asks for the `└`
/// that the x-axis labels sit beside, which only the receive chart carries.
fn chart(
    canvas: Canvas,
    y: u16,
    body: u16,
    series: *const FleetSeries,
    span: Span,
    rows: u16,
    scale: Scale,
    palette: Palette,
    corner: bool,
) u16 {
    const visible = @min(rows, body -| y);
    if (visible == 0) return y;
    const faint: Style = .{ .fg = palette.faint };

    if (corner) {
        widgets.chartAxis(canvas, gutter - 1, y, visible, faint);
    } else {
        for (0..visible) |row| canvas.set(gutter - 1, y + @as(u16, @intCast(row)), "┤", faint);
    }

    const maximum = series.maximum(span);
    tick(canvas, y, maximum, scale, faint);
    // A tall chart gets a midpoint so the eye has a reference between the
    // scale and the origin.
    if (visible >= 4) tick(canvas, y + visible / 2, maximum / 2, scale, faint);
    _ = canvas.text(gutter - 2, y + visible - 1, "0", faint);

    const width = canvas.width() -| gutter;
    if (width == 0) return y + visible;

    var buffer: [512]f32 = undefined;
    const columns: u16 = @intCast(@min(width, buffer.len));
    const samples = series.window(span, buffer[0..columns]);
    // The plot spans the whole width even when the sample buffer covers fewer
    // columns: `areaChart` right-aligns what it is given, which is what keeps
    // the newest sample under the `now` caption on a very wide terminal.
    widgets.areaChart(
        canvas,
        gutter,
        y,
        width,
        visible,
        samples,
        maximum,
        .{ .fg = palette.chart },
        .{ .fg = palette.chart_deep },
    );
    return y + visible;
}

/// A tick label, right-aligned against the rule. One too wide for the gutter
/// is dropped rather than allowed to run into the plot.
fn tick(canvas: Canvas, y: u16, value: f32, scale: Scale, style: Style) void {
    if (!(value > 0)) return;
    var buffer: [32]u8 = undefined;
    const rendered = switch (scale) {
        .bytes => std.fmt.bufPrint(&buffer, "{f}", .{report.bytes(value)}) catch return,
        .count => std.fmt.bufPrint(&buffer, "{f}", .{report.grouped(report.rounded(value))}) catch return,
    };
    const columns = screen_module.displayWidth(rendered);
    if (columns >= gutter) return;
    _ = canvas.text(gutter - 1 - columns, y, rendered, style);
}

/// How far back the left edge of a chart reaches. `run` is clamped to the
/// history actually retained, so the label never claims more than is plotted.
fn spanMillis(span: Span, elapsed_ms: u64) u64 {
    const covered = @as(u64, span.sampleCount()) * model_module.sample_interval_ms;
    return switch (span) {
        .run => @min(elapsed_ms, covered),
        else => covered,
    };
}

/// An age on the x-axis: seconds while the window is short enough to read as
/// seconds, `mm:ss` once it is not.
const Offset = struct {
    ms: u64,

    pub fn format(offset_value: Offset, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (offset_value.ms < 120_000) {
            try writer.print("{d}s", .{offset_value.ms / 1000});
        } else {
            try writer.print("{f}", .{widgets.clock(offset_value.ms)});
        }
    }
};

fn offset(ms: u64) Offset {
    return .{ .ms = ms };
}

fn offsets(canvas: Canvas, y: u16, span: Span, elapsed_ms: u64, style: Style) void {
    const width = canvas.width();
    if (width <= gutter) return;
    const covered = spanMillis(span, elapsed_ms);

    _ = canvas.print(gutter, y, style, "-{f}", .{offset(covered)});
    var buffer: [24]u8 = undefined;
    if (std.fmt.bufPrint(&buffer, "-{f}", .{offset(covered / 2)})) |middle| {
        const centre = gutter + (width - gutter) / 2;
        _ = canvas.text(centre -| screen_module.displayWidth(middle) / 2, y, middle, style);
    } else |_| {}
    canvas.textRight(y, "now", style);
}

fn figures(canvas: Canvas, data: *const Model, palette: Palette) void {
    const fleet = data.fleet;
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const normal: Style = .{ .fg = palette.text };

    _ = canvas.text(field_width, 0, "now", dim);
    _ = canvas.text(field_width + value_width, 0, "avg", dim);
    _ = canvas.text(field_width + 2 * value_width, 0, "peak", dim);

    tableRow(canvas, 1, "rx", "{f}", .{
        report.byteRate(fleet.rx_per_sec),
        report.byteRate(fleet.average_rx_per_sec),
        report.byteRate(fleet.peak_rx_per_sec),
    }, palette);
    tableRow(canvas, 2, "tx", "{f}", .{
        report.byteRate(fleet.tx_per_sec),
        report.byteRate(fleet.average_tx_per_sec),
        report.byteRate(fleet.peak_tx_per_sec),
    }, palette);
    tableRow(canvas, 3, "packets", "{f}/s", .{
        report.grouped(report.rounded(fleet.packets_per_sec)),
        report.grouped(report.rounded(fleet.average_packets_per_sec)),
        report.grouped(report.rounded(fleet.peak_packets_per_sec)),
    }, palette);

    _ = canvas.text(0, 5, "rx total", dim);
    const received = canvas.print(field_width, 5, normal, "{f}", .{report.bytes(@floatFromInt(fleet.bytes_received))});
    _ = canvas.print(received + 3, 5, faint, "{f} packets", .{report.grouped(fleet.packets_received)});

    _ = canvas.text(0, 6, "tx total", dim);
    _ = canvas.print(field_width, 6, normal, "{f}", .{report.bytes(@floatFromInt(fleet.bytes_sent))});

    _ = canvas.text(0, 7, "ratio", dim);
    const ratio = fleet.trafficRatio();
    const printed = canvas.print(field_width, 7, normal, "{d:.1} : 1", .{ratio});
    _ = canvas.text(printed + 3, 7, ratioNote(ratio), faint);
}

fn tableRow(
    canvas: Canvas,
    y: u16,
    name: []const u8,
    comptime fmt: []const u8,
    values: anytype,
    palette: Palette,
) void {
    _ = canvas.text(0, y, name, .{ .fg = palette.dim });
    // The current value is the one being watched, so it carries the weight.
    _ = canvas.print(field_width, y, .{ .fg = palette.text, .bold = true }, fmt, .{values[0]});
    _ = canvas.print(field_width + value_width, y, .{ .fg = palette.text }, fmt, .{values[1]});
    _ = canvas.print(field_width + 2 * value_width, y, .{ .fg = palette.text }, fmt, .{values[2]});
}

fn ratioNote(ratio: f64) []const u8 {
    if (!(ratio > 0)) return "";
    if (ratio >= 2) return "receive-dominated";
    if (ratio <= 0.5) return "send-dominated";
    return "balanced";
}

/// Receive share per shard, in the order the shards pane lists them, so the
/// two panes never disagree about which shard is which.
fn shares(canvas: Canvas, data: *const Model, palette: Palette) void {
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const normal: Style = .{ .fg = palette.text };

    _ = canvas.text(0, 0, "rx share by shard", dim);

    var busiest: f64 = 0;
    for (data.shards) |row| busiest = @max(busiest, row.rx_share);

    // Collapsing one straggler costs a row and says less than the row itself,
    // so a short fleet is listed in full.
    const listed = if (data.order.len <= shares_listed + 1) data.order.len else shares_listed;
    var y: u16 = 1;
    for (data.order[0..listed]) |index| {
        const row = data.shards[index];
        _ = canvas.print(0, y, dim, "{d:0>2}", .{row.id});
        const end = widgets.bar(canvas, 5, y, share_bar, if (busiest > 0) row.rx_share / busiest else 0, .{ .fg = palette.chart });
        _ = canvas.print(end + 2, y, normal, "{d:.1}%", .{row.rx_share * 100});
        y += 1;
    }

    if (listed < data.order.len) {
        var low = data.shards[data.order[listed]].rx_share;
        var high = low;
        for (data.order[listed..]) |index| {
            const share = data.shards[index].rx_share;
            low = @min(low, share);
            high = @max(high, share);
        }
        _ = canvas.text(0, y, "...", faint);
        _ = canvas.print(5, y, faint, "{d} more between {d:.1}% and {d:.1}%", .{
            data.order.len - listed,
            low * 100,
            high * 100,
        });
        y += 1;
    }

    // Pinned to the bottom of the block so these two line up with the totals
    // on the left however many shards were listed above them.
    const rows = canvas.height();
    if (rows < 2 or y > rows - 2) return;
    _ = canvas.text(0, rows - 2, "compression", dim);
    writeCompression(canvas, 14, rows - 2, data, normal, dim);
    _ = canvas.text(0, rows - 1, "bundles", dim);
    _ = canvas.print(14, rows - 1, normal, "{f} / {d} buffers", .{
        report.bytes(@floatFromInt(data.fleet.ring.max_bundle_bytes)),
        data.fleet.ring.max_bundle_buffers,
    });
}

/// Says what the run is actually doing, which is a different question from what
/// the binary can do. A build without compression can never compress; a build
/// with it compresses only if the server asked, and until a client is past
/// login nobody knows yet. Reporting the build flag alone read as "on" against
/// a server that had compression turned off.
fn writeCompression(canvas: Canvas, x: u16, y: u16, data: *const Model, normal: Style, dim: Style) void {
    if (comptime !features.compression) {
        _ = canvas.text(x, y, "off", normal);
        _ = canvas.text(x + 4, y, "-Denable-compression", dim);
        return;
    }
    switch (data.fleet.compression) {
        .unknown => _ = canvas.text(x, y, "-", dim),
        .off => {
            const end = canvas.text(x, y, "off", normal);
            _ = canvas.text(end, y, " server did not enable it", dim);
        },
        .on => {
            const end = canvas.text(x, y, "on", normal);
            _ = canvas.print(end, y, dim, " above {f}", .{
                report.bytes(@floatFromInt(@max(0, data.fleet.compression_threshold))),
            });
        },
    }
}

const testing = std.testing;

/// The bold cells of one row, concatenated: what the pane is emphasising.
fn boldRun(screen: *const screen_module.Screen, row: usize, buffer: []u8) []const u8 {
    var length: usize = 0;
    for (0..screen.cols) |column| {
        const cell = screen.back[row * screen.cols + column];
        if (!cell.style.bold) continue;
        const chunk = cell.text();
        if (length + chunk.len > buffer.len) break;
        @memcpy(buffer[length..][0..chunk.len], chunk);
        length += chunk.len;
    }
    return buffer[0..length];
}

test "traffic pane prints now, average and peak for every series" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 120 }, 12);
    defer data.deinit();

    data.elapsed_ms = 252_000;
    data.fleet.rx_per_sec = 12 * 1024 * 1024;
    data.fleet.average_rx_per_sec = 10 * 1024 * 1024;
    data.fleet.peak_rx_per_sec = 20 * 1024 * 1024;
    data.fleet.tx_per_sec = 1024 * 1024;
    data.fleet.packets_per_sec = 163_466;
    data.fleet.bytes_received = 4 * 1024 * 1024 * 1024;
    data.fleet.bytes_sent = 256 * 1024 * 1024;
    data.fleet.packets_received = 41_209_884;
    data.fleet.ring.max_bundle_bytes = 32 * 1024;
    data.fleet.ring.max_bundle_buffers = 8;
    for (data.shards, 0..) |*row, index| row.rx_share = if (index == 0) 0.093 else 0.0825;
    for (0..40) |index| data.rx.push(@floatFromInt(index * 100), index * 500);

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .traffic });

    var buffer: [8192]u8 = undefined;
    const frame = screen.frameText(&buffer);
    try testing.expect(std.mem.indexOf(u8, frame, "12.00 MiB/s") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "10.00 MiB/s") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "20.00 MiB/s") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "163,466/s") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "4.00 GiB") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "41,209,884 packets") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "16.0 : 1") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "receive-dominated") != null);
    // Three shards listed, the rest collapsed into their range.
    try testing.expect(std.mem.indexOf(u8, frame, "9.3%") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "9 more between 8.3% and 8.3%") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "32.00 KiB / 8 buffers") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "500ms samples") != null);
}

test "the compression line reports what the server negotiated, not the build" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime !features.compression) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);

    var data = try Model.init(testing.allocator, .{ .client_count = 120 }, 12);
    defer data.deinit();
    var buffer: [8192]u8 = undefined;

    // Before any client is past login the answer is not known yet, and must not
    // be guessed from whether the binary can compress.
    screen.clear(.{ .fg = theme.running.text });
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .traffic });
    try testing.expect(std.mem.indexOf(u8, screen.frameText(&buffer), "compression   -") != null);

    // A server that never sent set_compression: the old line claimed "on" here
    // purely because -Denable-compression was in the build.
    screen.clear(.{ .fg = theme.running.text });
    data.fleet.compression = .off;
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .traffic });
    const off = screen.frameText(&buffer);
    try testing.expect(std.mem.indexOf(u8, off, "off") != null);
    try testing.expect(std.mem.indexOf(u8, off, "server did not enable it") != null);

    // A server that did, with the threshold it asked for.
    screen.clear(.{ .fg = theme.running.text });
    data.fleet.compression = .on;
    data.fleet.compression_threshold = 256;
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .traffic });
    const on = screen.frameText(&buffer);
    try testing.expect(std.mem.indexOf(u8, on, "on above 256 B") != null);
}

test "traffic pane lights the active span and labels the axis to match" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);

    var data = try Model.init(testing.allocator, .{ .client_count = 10 }, 2);
    defer data.deinit();
    for (0..60) |index| data.rx.push(@floatFromInt(index), index * 500);

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    var run: [32]u8 = undefined;
    var buffer: [8192]u8 = undefined;

    screen.clear(.{ .fg = theme.running.text });
    render(canvas, &data, .{ .span = .s60 });
    try testing.expectEqualStrings("60s", boldRun(&screen, 1, &run));
    const short = screen.frameText(&buffer);
    try testing.expect(std.mem.indexOf(u8, short, "-60s") != null);
    try testing.expect(std.mem.indexOf(u8, short, "-30s") != null);

    screen.clear(.{ .fg = theme.running.text });
    render(canvas, &data, .{ .span = .m15 });
    try testing.expectEqualStrings("15m", boldRun(&screen, 1, &run));
    const long = screen.frameText(&buffer);
    try testing.expect(std.mem.indexOf(u8, long, "-15:00") != null);
    try testing.expect(std.mem.indexOf(u8, long, "-07:30") != null);
}

test "traffic pane keeps its footer and charts on a small canvas" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(30, 8);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 4 }, 1);
    defer data.deinit();
    data.fleet.rx_per_sec = 2048;
    for (0..10) |index| data.rx.push(4096, index * 500);

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    var buffer: [1024]u8 = undefined;
    const frame = screen.frameText(&buffer);
    // The pane sheds the summary before it sheds the chart or the key hints.
    try testing.expect(std.mem.indexOf(u8, frame, "receive") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "4.00 KiB") != null);
    try testing.expect(std.mem.indexOf(u8, frame, "p pause") != null);
}
