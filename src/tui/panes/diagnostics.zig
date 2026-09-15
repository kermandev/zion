//! The diagnostics pane.
//!
//! Three questions a diagnostics build exists to answer: is the ring keeping
//! up, are keepalive replies going out promptly, and what is actually dropping
//! the clients. Ring pressure is per shard because a saturated completion queue
//! is nearly always one shard's problem, while the latency distribution and the
//! disconnect causes are fleet-wide and sit side by side underneath.

const std = @import("std");
const report = @import("../../report.zig");
const telemetry = @import("../../telemetry.zig");
const model_module = @import("../model.zig");
const screen_module = @import("../screen.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const Canvas = screen_module.Canvas;
const Style = screen_module.Style;
const Model = model_module.Model;
const View = model_module.View;
const RingPressure = model_module.RingPressure;
const Severity = model_module.Severity;
const Palette = theme.Palette;

/// Ring table geometry. The shard id, the occupancy bar's `ready/entries`
/// readout and the four counter columns are fixed; only the bar itself gives
/// ground when the terminal is narrow.
const id_width: u16 = 6;
const gauge_max: u16 = 36;
const value_width: u16 = 14;
const nobufs_width: u16 = 11;
const overflow_width: u16 = 14;
const close_width: u16 = 13;
const bundle_width: u16 = 11;
const ring_minimum: u16 = id_width + value_width + nobufs_width + overflow_width + close_width + bundle_width;

/// First ring row; the two rows above it are the section title and the header.
const ring_top: u16 = 3;
/// Distribution and disconnect causes are the same height by construction:
/// five buckets plus figures on one side, seven categories plus rejoin on the
/// other.
const lower_height: u16 = 10;
const keepalive_width: u16 = 58;
const column_gap: u16 = 2;

pub fn render(canvas: Canvas, data: *const Model, view: View) void {
    const width = canvas.width();
    const height = canvas.height();
    if (width == 0 or height == 0) return;

    const palette = data.palette();
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };

    const footer_y = height - 1;
    // The ring table is the only part that grows with the fleet, so it gets
    // every row up to where the lower half would have to start.
    //
    // The lower half is only admitted once what is left above it still reaches
    // past `ring_top`, which is the row the fleet totals go on. A looser bound
    // hands the table a capacity of zero and it draws nothing: a header
    // over empty space, and the one line that says whether the fleet lost
    // completions gone, on a terminal a row shorter than one that fits ten.
    const lower_limit: u16 = if (height >= lower_height + ring_top + 4) height - 2 - lower_height else 0;
    const ring_bottom = if (lower_limit != 0) lower_limit - 1 else footer_y;

    _ = canvas.text(0, 1, "ring pressure", dim);
    // The buffer mode belongs beside these figures: it is what decides whether
    // the ring's capacity is its buffer count or its byte count, so a nobufs
    // column cannot be read without it.
    // Kept to the width the subtitle already had, so the mode does not push the
    // line into the section title on a narrow pane. What is peaking is named by
    // the column header a row below.
    canvas.textRight(1, if (data.fleet.ring.incremental_buffers)
        "recv buffers incremental · peak over the run"
    else
        "recv buffers whole · peak over the run", faint);
    const columns = Columns.forWidth(width);
    renderRingHeader(canvas, columns, palette);
    const ring_end = renderRingRows(canvas, data, view, columns, ring_bottom, palette);

    if (lower_limit != 0) {
        // A short fleet leaves its slack at the bottom of the pane rather than
        // as a hole in the middle of it.
        const lower_y = @min(lower_limit, ring_end + 1);
        renderKeepAlive(canvas.sub(0, lower_y, keepalive_width, lower_height), data, palette);
        const right_x = keepalive_width + column_gap;
        renderDisconnects(canvas.sub(right_x, lower_y, width -| right_x, lower_height), data, palette);
    }

    _ = canvas.text(0, footer_y, "↑↓ shard   enter drill down   c copy   q quit", faint);
    canvas.textRight(footer_y, "-Denable-diagnostics", faint);
}

const Columns = struct {
    gauge_width: u16,
    value: u16,
    nobufs: u16,
    overflow: u16,
    close: u16,
    bundle: u16,

    fn forWidth(width: u16) Columns {
        const gauge_width = @min(gauge_max, width -| ring_minimum);
        const nobufs = id_width + gauge_width + value_width;
        return .{
            .gauge_width = gauge_width,
            .value = id_width + gauge_width + column_gap,
            .nobufs = nobufs,
            .overflow = nobufs + nobufs_width,
            .close = nobufs + nobufs_width + overflow_width,
            .bundle = nobufs + nobufs_width + overflow_width + close_width,
        };
    }
};

/// One table cell, clipped to its own column so a wide value on a narrow
/// terminal truncates instead of overwriting the column beside it.
fn cell(canvas: Canvas, x: u16, y: u16, width: u16) Canvas {
    return canvas.sub(x, y, width, 1);
}

fn renderRingHeader(canvas: Canvas, columns: Columns, palette: Palette) void {
    const dim: Style = .{ .fg = palette.dim };
    _ = canvas.text(0, 2, "id", dim);
    _ = cell(canvas, id_width, 2, columns.nobufs -| id_width).text(0, 0, "peak cq / entries", dim);
    _ = cell(canvas, columns.nobufs, 2, nobufs_width).text(0, 0, "nobufs", dim);
    _ = cell(canvas, columns.overflow, 2, overflow_width).text(0, 0, "cq overflow", dim);
    _ = cell(canvas, columns.close, 2, close_width).text(0, 0, "close fail", dim);
    _ = canvas.text(columns.bundle, 2, "max bundle", dim);
}

/// Draws the table and returns the row just past its last line.
fn renderRingRows(
    canvas: Canvas,
    data: *const Model,
    view: View,
    columns: Columns,
    ring_bottom: u16,
    palette: Palette,
) u16 {
    const capacity = ring_bottom -| ring_top;
    if (capacity == 0) return ring_top;

    // The totals row is never dropped: it is the one line that answers whether
    // the fleet as a whole lost completions.
    const window = model_module.rowWindow(data.order.len, view.selected, capacity -| 1);

    const selected = if (data.order.len == 0) 0 else data.order[data.selectedIndex(view)];
    var y = ring_top;
    for (data.order[window.start..][0..window.count]) |index| {
        const row = data.shards[index];
        var label: [8]u8 = undefined;
        ringRow(canvas, y, columns, .{
            .label = std.fmt.bufPrint(&label, "{d:0>2}", .{row.id}) catch "??",
            .ring = row.ring,
            .severity = row.ringSeverity(),
            .emphasis = index == selected,
        }, palette);
        y += 1;
    }

    if ((window.above > 0 or window.below > 0) and y + 1 < ring_bottom) {
        collapsedRow(canvas, y, columns, window, data, palette);
        y += 1;
    }

    ringRow(canvas, y, columns, .{
        .label = "all",
        .ring = data.fleet.ring,
        .severity = data.fleet.ring.severity(),
    }, palette);
    return y + 1;
}

const Row = struct {
    label: []const u8,
    ring: RingPressure,
    severity: Severity,
    /// The row the shards pane's selection is sitting on.
    emphasis: bool = false,
};

fn ringRow(canvas: Canvas, y: u16, columns: Columns, row: Row, palette: Palette) void {
    const label_color = if (row.emphasis) palette.text else palette.dim;
    _ = canvas.text(0, y, row.label, .{ .fg = label_color, .bold = row.emphasis });
    // The bar's hue repeats what the marker and the ready/entries figure beside
    // it already say, so a monochrome terminal loses nothing.
    if (row.severity != .ok) {
        canvas.set(4, y, row.severity.marker(), .{ .fg = row.severity.color(palette) });
    }

    widgets.gauge(
        canvas,
        id_width,
        y,
        columns.gauge_width,
        row.ring.occupancy(),
        .{ .fg = row.severity.color(palette) },
        .{ .fg = palette.track },
    );
    _ = cell(canvas, columns.value, y, columns.nobufs -| columns.value).print(0, 0, .{ .fg = palette.dim }, "{d}/{d}", .{
        row.ring.peak_cq_ready,
        row.ring.peak_cq_entries,
    });

    counter(canvas, columns.nobufs, y, nobufs_width, row.ring.recv_nobufs, .watch, palette, false);
    counter(canvas, columns.overflow, y, overflow_width, row.ring.cq_overflow, .hot, palette, false);
    counter(canvas, columns.close, y, close_width, row.ring.close_failures, .watch, palette, false);
    bundle(canvas, columns.bundle, y, row.ring, palette, false);
}

/// The shards that did not fit, folded into one line: their counters summed so
/// a failure cannot hide below the fold, and the busiest of their queues named
/// as the ceiling for the group.
fn collapsedRow(canvas: Canvas, y: u16, columns: Columns, window: model_module.RowWindow, data: *const Model, palette: Palette) void {
    const faint: Style = .{ .fg = palette.faint };
    var total: RingPressure = .{};
    var busiest: RingPressure = .{};
    // Everything outside the window, above it as well as below: once the table
    // scrolls, a failure could otherwise hide off the top instead of the
    // bottom.
    for (data.order, 0..) |index, position| {
        if (position >= window.start and position < window.start + window.count) continue;
        const ring = data.shards[index].ring;
        total.recv_nobufs += ring.recv_nobufs;
        total.cq_overflow += ring.cq_overflow;
        total.close_failures += ring.close_failures;
        total.max_bundle_bytes = @max(total.max_bundle_bytes, ring.max_bundle_bytes);
        total.max_bundle_buffers = @max(total.max_bundle_buffers, ring.max_bundle_buffers);
        if (ring.occupancy() > busiest.occupancy()) busiest = ring;
    }

    _ = canvas.text(0, y, "...", faint);
    const message = cell(canvas, id_width, y, columns.nobufs -| id_width);
    // Counted from where the window sits, so walking the selection down counts
    // the remainder down with it instead of restating the fleet's size.
    if (busiest.peak_cq_entries == 0) {
        _ = message.print(0, 0, faint, "{d} below · {d} above", .{ window.below, window.above });
    } else {
        _ = message.print(0, 0, faint, "{d} below · {d} above, all under {d}/{d}", .{
            window.below,
            window.above,
            busiest.peak_cq_ready,
            busiest.peak_cq_entries,
        });
    }
    counter(canvas, columns.nobufs, y, nobufs_width, total.recv_nobufs, .watch, palette, true);
    counter(canvas, columns.overflow, y, overflow_width, total.cq_overflow, .hot, palette, true);
    counter(canvas, columns.close, y, close_width, total.close_failures, .watch, palette, true);
    bundle(canvas, columns.bundle, y, total, palette, true);
}

/// A counter column. Zero prints as `0` rather than as blank, so an untripped
/// counter and a missing one are never confused.
fn counter(canvas: Canvas, x: u16, y: u16, width: u16, value: u64, raised: Severity, palette: Palette, muted: bool) void {
    const color = if (value == 0)
        if (muted) palette.faint else palette.dim
    else
        raised.color(palette);
    _ = cell(canvas, x, y, width).print(0, 0, .{ .fg = color }, "{f}", .{report.grouped(value)});
}

fn bundle(canvas: Canvas, x: u16, y: u16, ring: RingPressure, palette: Palette, muted: bool) void {
    const style: Style = .{ .fg = if (muted) palette.faint else palette.text };
    _ = canvas.print(x, y, style, "{f}/{d}", .{
        report.bytes(@floatFromInt(ring.max_bundle_bytes)),
        ring.max_bundle_buffers,
    });
}

/// Bucket label column, then the bar, then the count sitting just past whatever
/// the bar reached.
const bucket_label_width: u16 = 10;
const bucket_bar_max: u16 = 26;
/// Slot the two percentile figures on a row share.
const figure_width: u16 = 8;

fn figure(canvas: Canvas, y: u16, slot: u16, style: Style, ms: f64) void {
    _ = cell(canvas, bucket_label_width + slot * figure_width, y, figure_width).print(0, 0, style, "{f}", .{widgets.millis(ms)});
}

fn renderKeepAlive(canvas: Canvas, data: *const Model, palette: Palette) void {
    const text: Style = .{ .fg = palette.text };
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const histogram = data.fleet.keep_alive;

    _ = canvas.text(0, 0, "keepalive reply latency", dim);
    canvas.printRight(0, faint, "{f} samples", .{report.grouped(histogram.samples)});

    const rows = histogram.displayRows();
    var busiest: u64 = 0;
    for (rows) |count| busiest = @max(busiest, count);
    const bar_width = @min(bucket_bar_max, canvas.width() -| (bucket_label_width + 10));

    for (rows, telemetry.Histogram.display_labels, 0..) |count, label, index| {
        const y: u16 = @intCast(index + 1);
        _ = canvas.text(0, y, label, if (count == 0) faint else dim);
        var end = bucket_label_width;
        if (count == 0) {
            // An empty bucket still gets a mark, so its row reads as measured
            // and empty rather than as absent.
            canvas.set(bucket_label_width, y, "·", .{ .fg = palette.rule });
            end += 1;
        } else {
            const fraction = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(@max(1, busiest)));
            end = widgets.bar(canvas, bucket_label_width, y, bar_width, fraction, .{ .fg = bucketColor(index, palette) });
        }
        _ = canvas.print(end + column_gap, y, if (count == 0) faint else text, "{f}", .{report.grouped(count)});
    }

    const p50 = histogram.percentile(0.5);
    const p90 = histogram.percentile(0.9);
    const p99 = histogram.percentile(0.99);
    _ = canvas.text(0, 7, "p50 p90", dim);
    figure(canvas, 7, 0, text, @floatFromInt(p50));
    figure(canvas, 7, 1, text, @floatFromInt(p90));
    _ = canvas.print(bucket_label_width + 2 * figure_width, 7, faint, "mean {f}", .{widgets.millis(histogram.mean())});

    _ = canvas.text(0, 8, "p99 max", dim);
    figure(canvas, 8, 0, latencyStyle(p99, palette), @floatFromInt(p99));
    figure(canvas, 8, 1, latencyStyle(histogram.max, palette), @floatFromInt(histogram.max));
    if (worstShard(data)) |shard| {
        _ = canvas.print(bucket_label_width + 2 * figure_width, 8, faint, "on shard {d:0>2}", .{shard});
    }

    _ = canvas.text(0, 9, "measured", dim);
    _ = canvas.text(bucket_label_width, 9, "from queued reply to last byte sent", faint);
}

/// Latency worth noticing is warm; the rest reads as ordinary text rather than
/// as a healthy green, which would make every row shout.
fn latencyStyle(ms: u64, palette: Palette) Style {
    // The thresholds belong to the model; this pane only asks it for a rating.
    return switch (model_module.keepAliveSeverityFor(ms)) {
        .ok => .{ .fg = palette.text },
        else => |severity| .{ .fg = severity.color(palette) },
    };
}

fn bucketColor(index: usize, palette: Palette) theme.Rgb {
    return switch (index) {
        0, 1 => palette.chart,
        2, 3 => palette.warn,
        else => palette.bad,
    };
}

/// The shard holding the fleet's slowest keepalive reply. The model keeps no
/// timestamp for it, so the row names the shard and stops there.
fn worstShard(data: *const Model) ?u16 {
    var highest: u64 = 0;
    var found: ?u16 = null;
    for (data.shards) |row| {
        if (row.keep_alive.max <= highest) continue;
        highest = row.keep_alive.max;
        found = row.id;
    }
    return found;
}

const cause_count_x: u16 = 12;
// Wide enough for a grouped count that has run into seven figures: the cell is
// clipped to its column, so a narrower one truncates `100,000` to `100,00` and
// reports a plausible wrong number rather than a visibly cut one.
const cause_detail_x: u16 = 26;

fn renderDisconnects(canvas: Canvas, data: *const Model, palette: Palette) void {
    const text: Style = .{ .fg = palette.text };
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };

    var total: u64 = 0;
    for (data.fleet.disconnect_counts) |count| total += count;

    _ = canvas.text(0, 0, "disconnect causes", dim);
    canvas.printRight(0, faint, "{f} total", .{report.grouped(total)});

    // Categories that never fired stay on the list, faint: which causes are
    // absent is as much of the answer as which are present.
    for (std.enums.values(telemetry.DisconnectCategory), 0..) |category, index| {
        const y: u16 = @intCast(index + 1);
        const count = data.fleet.disconnect_counts[@backingInt(category)];
        const fired = count > 0;
        _ = cell(canvas, 0, y, cause_count_x).text(0, 0, category.label(), if (fired) dim else faint);
        _ = cell(canvas, cause_count_x, y, cause_detail_x - cause_count_x)
            .print(0, 0, if (fired) text else faint, "{f}", .{report.grouped(count)});
        _ = canvas.text(cause_detail_x, y, category.detail(), faint);
    }

    const rejoin = data.fleet.rejoin;
    _ = canvas.text(0, 9, "rejoin", dim);
    if (rejoin.samples == 0) {
        _ = canvas.text(cause_count_x, 9, "nothing has had to rejoin", faint);
        return;
    }
    const median = @as(f64, @floatFromInt(rejoin.percentile(0.5))) / 1000.0;
    const end = canvas.print(cause_count_x, 9, text, "{d:.1}s median", .{median});
    _ = canvas.print(end + 3, 9, faint, "{f} of {f} recovered", .{
        report.grouped(rejoin.samples),
        report.grouped(total),
    });
}

test "the ring section names the buffer mode the kernel granted" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);

    var data = try Model.init(std.testing.allocator, .{ .client_count = 120 }, 2);
    defer data.deinit();
    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    var buffer: [8192]u8 = undefined;

    // A pre-6.12 kernel rejects IOU_PBUF_RING_INC and retires a whole buffer
    // per completion, which is the regime the nobufs column has to be read in.
    screen.clear(.{ .fg = theme.running.text });
    data.fleet.ring = .{ .peak_cq_ready = 412, .peak_cq_entries = 4096 };
    render(canvas, &data, .{ .pane = .diagnostics });
    try std.testing.expect(std.mem.indexOf(u8, screen.frameText(&buffer), "recv buffers whole") != null);

    screen.clear(.{ .fg = theme.running.text });
    data.fleet.ring = .{ .peak_cq_ready = 412, .peak_cq_entries = 4096, .incremental_buffers = true };
    render(canvas, &data, .{ .pane = .diagnostics });
    try std.testing.expect(std.mem.indexOf(u8, screen.frameText(&buffer), "recv buffers incremental") != null);
}

test "ring pressure lists shards above a fleet total" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(std.testing.allocator, .{ .client_count = 120 }, 3);
    defer data.deinit();
    data.shards[0].ring = .{
        .peak_cq_ready = 398,
        .peak_cq_entries = 4096,
        .max_bundle_bytes = 32768,
        .max_bundle_buffers = 8,
    };
    data.shards[1].ring = .{ .peak_cq_ready = 341, .peak_cq_entries = 4096, .cq_overflow = 12 };
    data.fleet.ring = .{ .peak_cq_ready = 412, .peak_cq_entries = 4096, .cq_overflow = 12 };

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, .{ .pane = .diagnostics });

    var buffer: [8192]u8 = undefined;
    const frame = screen.frameText(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, frame, "peak cq / entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "398/4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "32.00 KiB/8") != null);
    // The totals row carries the fleet's overflow count, not a dash.
    try std.testing.expect(std.mem.indexOf(u8, frame, "412/4096") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "-Denable-diagnostics") != null);
}

test "keepalive distribution shows every bucket with its count" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(std.testing.allocator, .{ .client_count = 40 }, 2);
    defer data.deinit();
    for (0..1200) |_| data.fleet.keep_alive.record(0);
    for (0..300) |_| data.fleet.keep_alive.record(2);
    for (0..8) |_| data.fleet.keep_alive.record(20);
    data.shards[1].keep_alive.record(41);

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, .{ .pane = .diagnostics });

    var buffer: [8192]u8 = undefined;
    const frame = screen.frameText(&buffer);
    for (telemetry.Histogram.display_labels) |label| {
        try std.testing.expect(std.mem.indexOf(u8, frame, label) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, frame, "1,508 samples") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "1,200") != null);
    // An empty bucket still prints its zero.
    try std.testing.expect(std.mem.indexOf(u8, frame, "0") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "on shard 01") != null);
}

test "a fired disconnect category shows its count beside the quiet ones" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(std.testing.allocator, .{ .client_count = 40 }, 2);
    defer data.deinit();
    data.fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.transport)] = 71;
    data.fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.server)] = 38;
    for (0..109) |_| data.fleet.rejoin.record(6300);

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, .{ .pane = .diagnostics });

    var buffer: [8192]u8 = undefined;
    const frame = screen.frameText(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, frame, "transport") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "71") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "109 total") != null);
    // A category with no disconnects keeps its row and its detail text.
    try std.testing.expect(std.mem.indexOf(u8, frame, "read/write limit exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "109 of 109 recovered") != null);
}

test "the ring totals row survives every height the table is drawn at" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();

    var data = try Model.init(std.testing.allocator, .{ .client_count = 40 }, 4);
    defer data.deinit();

    // The lower half taking over must not leave the table with a header and
    // nothing under it: `all` answers whether the fleet lost completions, and
    // a terminal one row shorter used to show ten shard rows beside it.
    var height: u16 = 5;
    while (height <= 45) : (height += 1) {
        try screen.resize(140, height);
        screen.clear(.{ .fg = theme.running.text });
        render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .diagnostics });
        try std.testing.expect(screen.contains("all"));
    }
}
