//! The fleet pane: the landing view.
//!
//! Four layouts live here because they are one pane at four points in a run,
//! and the caller never chooses between them. Before full join the ramp owns
//! the screen, since there is no steady traffic worth charting yet. Once the
//! fleet is in trouble the failing signals replace the headline gauges, because
//! a number that is fine is not worth the row. A build compiled without the
//! counters says which flag would provide them rather than drawing empty
//! fields: a dimmed zero and a real zero are indistinguishable.

const std = @import("std");
const features = @import("../../features.zig");
const report = @import("../../report.zig");
const telemetry = @import("../../telemetry.zig");
const model_module = @import("../model.zig");
const screen_module = @import("../screen.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const Canvas = screen_module.Canvas;
const Fleet = model_module.Fleet;
const Model = model_module.Model;
const Palette = theme.Palette;
const Severity = model_module.Severity;
const ShardRow = model_module.ShardRow;
const Span = model_module.Span;
const Style = screen_module.Style;
const View = model_module.View;

/// Byte, packet and rate counters.
const traffic = features.stats;
/// Ring, keepalive and disconnect-cause counters.
const diagnostics = features.diagnostics;
/// Neither: the pane falls back to what a bare build can actually answer.
const bare = !traffic and !diagnostics;

/// Chart gutter: the value label, then the axis rule, then air before the plot.
/// The label field is eleven columns, which is what `report.bytes` needs at its
/// widest (`1023.99 MiB`), so an axis label is never the thing that gets
/// truncated. Nine columns cut the unit off every rate from 100 of any unit
/// up, which is most of them: `163.44 MiB` came out as `163.44 Mi`.
const gutter = 14;
const axis_column = 12;
/// Shards a heat row stages on the stack. Wider than any fleet a terminal has
/// the columns to draw a swatch for.
const heat_stage_capacity = 256;
/// Columns of chart data staged on the stack. Past this a plot is right-aligned
/// in its own width and the left of it reads as a period with no traffic, so it
/// covers more columns than any terminal the dashboard is drawn on.
const chart_sample_capacity = 1024;
/// Label field ahead of a heat row, a ring line or a sparkline.
const label_width = 10;
/// The causes list and keepalive block are fixed-length text; this is all they
/// ever need, and they are never given more however much room is spare.
const health_side_width = 44;
/// The narrowest the left block goes. A shard list line is longer than a small
/// fleet's heat map, so it, not the swatches, sets the floor: the widest line
/// plus the gap and the `enter` marker that follow it.
const health_min_width = 64;
/// Below this the side column would take more than 40% of the pane, which is
/// more than fixed-length text earns; the layout drops to one column instead.
const health_split_minimum = health_side_width * 100 / 40;
/// Shards listed under the heat map, most concerning first.
const top_shard_rows: u16 = 4;
/// A shard list row at its widest, plus the gap and marker after it. The left
/// block aims for this so the list has room to say something rather than
/// leaving a field of air beside the causes column, and the list never grows
/// past it however wide the terminal is.
const shard_list_width: u16 = 94;

const drill_hint = "enter ▸";
const drill_hint_width: u16 = 7;

/// Draws a field only when it fits whole. Once one does not, the rest are
/// dropped as well, so a row always ends on a complete field.
fn appendField(canvas: Canvas, x: u16, y: u16, style: Style, limit: u16, room: *bool, text: []const u8) u16 {
    if (!room.*) return x;
    if (x + screen_module.displayWidth(text) > limit) {
        room.* = false;
        return x;
    }
    return canvas.text(x, y, text, style);
}

/// Heat rows plus the title, id row and the shard list beneath them.
const health_left_rows: u16 = 6 + top_shard_rows + (if (diagnostics) 2 else 0) + (if (traffic) 1 else 0);
/// The causes list and keepalive percentiles are taller than the heat map, so
/// they set the block height wherever they are compiled in.
const health_rows: u16 = if (diagnostics) @max(health_left_rows, 12) else health_left_rows;
const degraded_health_rows: u16 = 7 + (if (diagnostics) 2 else 0);
const spark_rows: u16 = if (traffic) 3 else 1;

const running_fixed: u16 = 11 + spark_rows + health_rows + (if (diagnostics) 2 else 0);
const joining_fixed: u16 = 16;
const degraded_fixed: u16 = 12 + degraded_health_rows;

pub fn render(canvas: Canvas, data: *const Model, view: View) void {
    if (canvas.width() == 0 or canvas.height() == 0) return;
    const palette = data.palette();
    if (comptime bare) return renderBare(canvas, data, palette);
    if (view.alerts) return renderDegraded(canvas, data, view, palette);
    if (!data.reached_full_join) return renderJoining(canvas, data, palette);
    renderRunning(canvas, data, view, palette);
}

fn renderRunning(canvas: Canvas, data: *const Model, view: View, palette: Palette) void {
    const fleet = data.fleet;
    const chart_rows = std.math.clamp((canvas.height() -| 1) -| running_fixed, 1, 8);

    contextLine(canvas, data, palette);
    const headline_columns: u16 = if (traffic) 4 else 2;
    const headline_cell = cellWidth(canvas.width(), headline_columns);
    runningHeadline(centredGrid(canvas, headline_cell, headline_columns), 2, headline_cell, data, palette);

    var y: u16 = 6;
    if (comptime traffic) {
        chartSection(canvas, y, chart_rows, palette, "receive rate", view.span, &data.rx, .bytes);
    } else {
        chartSection(canvas, y, chart_rows, palette, "reconnects /s", view.span, &data.churn, .count);
    }
    y += chart_rows + 3;

    var value: [96]u8 = undefined;
    if (comptime traffic) {
        sparkRow(canvas, y, "pkt/s", &data.packets, view.span, palette, palette.chart, std.fmt.bufPrint(&value, "{f}   peak {f}", .{
            report.grouped(report.rounded(fleet.packets_per_sec)),
            report.grouped(report.rounded(fleet.peak_packets_per_sec)),
        }) catch "");
        sparkRow(canvas, y + 1, "tx/s", &data.tx, view.span, palette, palette.chart, std.fmt.bufPrint(&value, "{f}", .{
            report.byteRate(fleet.tx_per_sec),
        }) catch "");
        y += 2;
    }
    sparkRow(canvas, y, "churn/s", &data.churn, view.span, palette, palette.warn, std.fmt.bufPrint(&value, "{d:.2}/s   {f} total", .{
        fleet.reconnects_per_sec,
        report.grouped(fleet.reconnects),
    }) catch "");
    y += 2;

    const left, const right = splitBlock(canvas, healthNaturalWidth(data));
    shardHealth(left, y, data, view, palette);
    if (comptime diagnostics) {
        if (right) |column| {
            disconnectCauses(column, y, data, palette);
            keepAliveBlock(column, y + 9, data, palette);
        }
    }
    y += health_rows + 1;

    if (comptime diagnostics) ringLine(canvas, y, data, palette);

    footer(canvas, palette, "enter shard   space alerts   ←→ chart span   p pause   s stats   c copy   q quit", "");
}

fn renderJoining(canvas: Canvas, data: *const Model, palette: Palette) void {
    const fleet = data.fleet;
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const chart_rows = std.math.clamp((canvas.height() -| 1) -| joining_fixed, 1, 20);

    contextLine(canvas, data, palette);
    const headline_cell = cellWidth(canvas.width(), 4);
    joiningHeadline(centredGrid(canvas, headline_cell, 4), 2, headline_cell, data, palette);

    var y: u16 = 6;
    _ = canvas.text(0, y, "clients in play", dim);
    canvas.printRight(y, faint, "since start · {d}ms samples", .{model_module.sample_interval_ms});

    // The ramp is measured against the whole run, not a rolling window: the
    // question is how far along it is, not what it did in the last minute.
    const plot_width = canvas.width() -| gutter;
    var samples: [chart_sample_capacity]f32 = undefined;
    const take = @min(plot_width, samples.len);
    const window = data.play_series.window(.run, samples[0..take]);
    widgets.chartAxis(canvas, axis_column, y + 1, chart_rows, faint);
    widgets.areaChart(canvas, gutter, y + 1, plot_width, chart_rows, window, @floatFromInt(@max(1, fleet.requested)), .{ .fg = palette.chart }, .{ .fg = palette.chart_deep });

    const gutter_canvas = canvas.sub(0, 0, axis_column -| 1, canvas.height());
    gutter_canvas.printRight(y + 1, faint, "{f}", .{report.grouped(fleet.requested)});
    if (chart_rows >= 2) gutter_canvas.printRight(y + chart_rows, faint, "0", .{});
    _ = canvas.text(gutter, y + 1 + chart_rows, "00:00", faint);
    canvas.printRight(y + 1 + chart_rows, faint, "{f}", .{widgets.clock(data.elapsed_ms)});
    y += chart_rows + 3;

    const left, const right = splitBlock(canvas, heatNaturalWidth(data));
    joinProgress(left, y, data, palette);
    if (comptime diagnostics) {
        if (right) |column| joinDiagnostics(column, y, data, palette);
    }

    footer(canvas, palette, "enter shard   p pause   q quit", "traffic and diagnostics fill in at full join");
}

fn renderDegraded(canvas: Canvas, data: *const Model, view: View, palette: Palette) void {
    const degradation = data.degradation;
    const dim: Style = .{ .fg = palette.dim };
    const chart_rows = std.math.clamp((canvas.height() -| 1) -| degraded_fixed, 1, 8);

    contextLine(canvas, data, palette);

    var alert: u16 = 2;
    if (degradation.reconnect_storm) {
        alertRow(canvas, alert, palette, .watch, "reconnect storm", .{ .rate = degradation.storm_rate });
        _ = canvas.print(alert_detail, alert, dim, "{f} since the last sample · was {d:.2}/s", .{
            report.grouped(degradation.storm_recent),
            degradation.storm_baseline,
        });
        alert += 1;
    }
    if (degradation.ring_overflow) {
        alertRow(canvas, alert, palette, .hot, "cq overflow", .{ .count = degradation.overflow_count });
        var x = canvas.print(alert_detail, alert, dim, "peak cq {d}/{d}", .{
            data.fleet.ring.peak_cq_ready,
            data.fleet.ring.peak_cq_entries,
        });
        if (degradation.hot_shard_count != 0) {
            x = canvas.text(x, alert, " · shards", dim);
            for (degradation.hot_shards[0..degradation.hot_shard_count]) |id| {
                x = canvas.print(x, alert, dim, " {d:0>2}", .{id});
            }
        }
        alert += 1;
    }
    if (degradation.keepalive_stalled) {
        alertRow(canvas, alert, palette, .hot, "keepalive p99", .{ .millis = degradation.keepalive_p99_ms });
        _ = canvas.text(alert_detail, alert, "the server may start dropping these clients", dim);
    }

    // Three alert rows are always reserved so the chart below does not move as
    // signals come and go.
    var y: u16 = 6;
    chartSection(canvas, y, chart_rows, palette, "reconnects /s", view.span, &data.churn, .count);
    // `began_at_ms` is when the run went degraded, whatever raised it, and it
    // is carried forward after the degradation clears. Naming the cause "storm"
    // would mislabel a ring-overflow episode, and printing it at all once the
    // run is healthy again would date an alert that is over.
    if (degradation.active and degradation.began_at_ms != 0) {
        const centre = (canvas.width() -| 16) / 2;
        _ = canvas.print(centre, y + 1 + chart_rows, .{ .fg = palette.warn }, "degraded {f}", .{widgets.clock(degradation.began_at_ms)});
    }
    y += chart_rows + 3;

    const left, const right = splitBlock(canvas, heatNaturalWidth(data));
    degradedHealth(left, y, data, palette);
    if (comptime diagnostics) {
        if (right) |column| disconnectCauses(column, y, data, palette);
    }
    y += degraded_health_rows + 1;

    _ = canvas.text(0, y, "hint", .{ .fg = palette.warn });
    _ = canvas.text(label_width, y, hintFor(data), dim);

    footer(canvas, palette, "space back   enter shard   5 log   p pause   s stats   c copy   q quit", "");
}

/// The layout for a build with neither `stats` nor `diagnostics`: joined and
/// play counts are the only numbers that exist, so they are the only ones shown.
fn renderBare(canvas: Canvas, data: *const Model, palette: Palette) void {
    const fleet = data.fleet;
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };

    contextLine(canvas, data, palette);

    const severity = playSeverity(fleet);
    _ = canvas.text(0, 2, "in play", dim);
    var x: u16 = 0;
    if (severity != .ok) x = canvas.print(x, 3, .{ .fg = severity.color(palette) }, "{s} ", .{severity.marker()});
    x = canvas.print(x, 3, .{ .fg = severity.color(palette), .bold = true }, "{f}", .{report.grouped(fleet.play)});
    _ = canvas.print(x, 3, dim, " / {f}   {d:.1}%", .{ report.grouped(fleet.requested), fleet.playFraction() * 100 });
    widgets.gauge(canvas, 0, 4, @min(canvas.width(), 36), fleet.playFraction(), .{ .fg = severity.color(palette) }, .{ .fg = palette.track });

    _ = canvas.text(0, 6, "id", dim);
    _ = canvas.text(6, 6, "joined", dim);
    _ = canvas.text(18, 6, "play", dim);
    _ = canvas.text(28, 6, "state", dim);

    // The closing note, the build-flag line and the footer claim the rows the
    // table is not allowed to take.
    const shown = @min(data.shards.len, canvas.height() -| 14);
    for (data.shards[0..shown], 0..) |row, index| {
        const y = 7 + @as(u16, @intCast(index));
        _ = canvas.print(0, y, dim, "{d:0>2}", .{row.id});
        _ = canvas.print(6, y, .{ .fg = palette.text }, "{d}/{d}", .{ row.joined, row.requested });
        _ = canvas.print(18, y, .{ .fg = palette.text }, "{d}", .{row.play});
        const state = shardState(row);
        _ = canvas.text(28, y, state.label, .{ .fg = state.severity.color(palette) });
    }

    var y: u16 = 7 + @as(u16, @intCast(shown));
    if (shown < data.shards.len) {
        _ = canvas.text(0, y, "...", faint);
        _ = canvas.print(6, y, faint, "{d} more", .{data.shards.len - shown});
        y += 1;
    }
    _ = canvas.text(0, y + 1, "no traffic, keepalive, ring or disconnect", dim);
    _ = canvas.text(0, y + 2, "counters exist in this build.", dim);
    _ = canvas.text(0, y + 4, "-Denable-stats -Denable-diagnostics", faint);

    footer(canvas, palette, "1-2 pane   q quit", "minimal");
}

fn contextLine(canvas: Canvas, data: *const Model, palette: Palette) void {
    const info = data.info;
    const dim: Style = .{ .fg = palette.dim };
    var x: u16 = 0;
    if (info.target.len != 0) x = canvas.print(x, 0, dim, "{s}  ·  ", .{info.target});
    if (info.minecraft_version.len != 0) x = canvas.print(x, 0, dim, "mc {s}  ·  ", .{info.minecraft_version});
    x = canvas.print(x, 0, dim, "{f} clients / {d} {s}", .{
        report.grouped(info.client_count),
        data.fleet.shard_count,
        if (data.fleet.shard_count == 1) "shard" else "shards",
    });
    if (!data.reached_full_join and info.connect_rate_per_sec != 0) {
        x = canvas.print(x, 0, dim, "  ·  ramp {d}/s", .{info.connect_rate_per_sec});
    }
    if (comptime features.movement) {
        if (info.movement.len != 0) x = canvas.print(x, 0, dim, "  ·  {s}", .{info.movement});
    }
    if (comptime features.broadcast) {
        if (info.broadcast.len != 0) x = canvas.print(x, 0, dim, "  ·  {s}", .{info.broadcast});
    }
    if (comptime features.client_tick) {
        if (info.client_tick.len != 0) x = canvas.print(x, 0, dim, "  ·  {s}", .{info.client_tick});
    }
}

fn runningHeadline(canvas: Canvas, y: u16, cell: u16, data: *const Model, palette: Palette) void {
    const fleet = data.fleet;
    const dim: Style = .{ .fg = palette.dim };
    const bold: Style = .{ .fg = palette.text, .bold = true };

    const play_cell = headlineColumn(canvas, 0, cell);
    const play = playSeverity(fleet);
    _ = play_cell.text(0, y, "in play", dim);
    var x: u16 = 0;
    if (play != .ok) x = play_cell.print(x, y + 1, .{ .fg = play.color(palette) }, "{s} ", .{play.marker()});
    x = play_cell.print(x, y + 1, .{ .fg = play.color(palette), .bold = true }, "{f}", .{report.grouped(fleet.play)});
    _ = play_cell.print(x, y + 1, dim, " / {f}   {d:.1}%", .{ report.grouped(fleet.requested), fleet.playFraction() * 100 });
    widgets.gauge(play_cell, 0, y + 2, cell, fleet.playFraction(), .{ .fg = play.color(palette) }, .{ .fg = palette.track });

    var slot: u16 = 1;
    if (comptime traffic) {
        const rx_cell = headlineColumn(canvas, slot, cell);
        columnRule(canvas, slot * (cell + 3) -| 2, y, palette);
        _ = rx_cell.text(0, y, "receive", dim);
        x = rx_cell.print(0, y + 1, bold, "{f}", .{report.byteRate(fleet.rx_per_sec)});
        _ = rx_cell.print(x, y + 1, dim, "  peak {f}", .{report.byteRate(fleet.peak_rx_per_sec)});
        widgets.gauge(rx_cell, 0, y + 2, cell, ratio(fleet.rx_per_sec, fleet.peak_rx_per_sec), .{ .fg = palette.chart }, .{ .fg = palette.track });
        slot += 1;

        const packets_cell = headlineColumn(canvas, slot, cell);
        columnRule(canvas, slot * (cell + 3) -| 2, y, palette);
        _ = packets_cell.text(0, y, "inbound packets", dim);
        x = packets_cell.print(0, y + 1, bold, "{f}/s", .{report.grouped(report.rounded(fleet.packets_per_sec))});
        _ = packets_cell.print(x, y + 1, dim, "  ka {f}", .{report.grouped(fleet.keep_alives)});
        widgets.gauge(packets_cell, 0, y + 2, cell, ratio(fleet.packets_per_sec, fleet.peak_packets_per_sec), .{ .fg = palette.chart }, .{ .fg = palette.track });
        slot += 1;
    }

    const churn_cell = headlineColumn(canvas, slot, cell);
    const churn = churnSeverity(data);
    columnRule(canvas, slot * (cell + 3) -| 2, y, palette);
    _ = churn_cell.text(0, y, "reconnects", dim);
    x = 0;
    if (churn != .ok) x = churn_cell.print(x, y + 1, .{ .fg = churn.color(palette) }, "{s} ", .{churn.marker()});
    x = churn_cell.print(x, y + 1, .{ .fg = churn.color(palette), .bold = true }, "{f}", .{report.grouped(fleet.reconnects)});
    _ = churn_cell.print(x, y + 1, dim, "  {d:.2}/s", .{fleet.reconnects_per_sec});
    // Sized like its neighbors rather than from what is left over: cellWidth
    // floors its division, so the remainder collects in the last column and a
    // gauge taking it would read as a longer bar for the same fraction. Each
    // gauge fills its cell, which leaves only the three-column separator
    // between two bars and puts the rule in the middle of it.
    widgets.gauge(churn_cell, 0, y + 2, cell, ratio(fleet.reconnects_per_sec, data.churn.peak), .{ .fg = palette.warn }, .{ .fg = palette.track });
}

fn joiningHeadline(canvas: Canvas, y: u16, cell: u16, data: *const Model, palette: Palette) void {
    const fleet = data.fleet;
    const dim: Style = .{ .fg = palette.dim };
    const bold: Style = .{ .fg = palette.text, .bold = true };
    const fraction = fleet.joinFraction();

    const joined_cell = headlineColumn(canvas, 0, cell);
    _ = joined_cell.text(0, y, "joined", dim);
    var x = joined_cell.print(0, y + 1, .{ .fg = palette.warn, .bold = true }, "{f}", .{report.grouped(fleet.joined)});
    _ = joined_cell.print(x, y + 1, dim, " / {f}   {d:.1}%", .{ report.grouped(fleet.requested), fraction * 100 });
    widgets.gauge(joined_cell, 0, y + 2, cell, fraction, .{ .fg = palette.warn }, .{ .fg = palette.track });

    const rate = joinRate(data);
    const rate_cell = headlineColumn(canvas, 1, cell);
    columnRule(canvas, (cell + 3) -| 2, y, palette);
    _ = rate_cell.text(0, y, "join rate", dim);
    x = rate_cell.print(0, y + 1, bold, "{d:.1}/s", .{rate});
    if (data.info.connect_rate_per_sec != 0) {
        const target: f64 = @floatFromInt(data.info.connect_rate_per_sec);
        _ = rate_cell.print(x, y + 1, dim, "  target {d}", .{data.info.connect_rate_per_sec});
        widgets.gauge(rate_cell, 0, y + 2, cell, ratio(rate, target), .{ .fg = palette.chart }, .{ .fg = palette.track });
    }

    // Everything past the TCP connect but short of play is one number to the
    // reader: clients the server is still working through.
    const connecting = fleet.connecting;
    const handshaking = fleet.connected -| fleet.play;
    const flight_cell = headlineColumn(canvas, 2, cell);
    columnRule(canvas, 2 * (cell + 3) -| 2, y, palette);
    _ = flight_cell.text(0, y, "in flight", dim);
    x = flight_cell.print(0, y + 1, bold, "{d}", .{connecting + handshaking});
    _ = flight_cell.print(x, y + 1, dim, "  {d} tcp · {d} config", .{ connecting, handshaking });
    // Measured against the clients still outstanding rather than the whole
    // fleet: against the fleet this is a sliver that never moves, while against
    // what is left it reads as saturation — low while the ramp meters clients
    // in, rising toward full when the server stops completing handshakes.
    const outstanding = fleet.requested -| fleet.joined;
    widgets.gauge(flight_cell, 0, y + 2, cell, ratio(@floatFromInt(connecting + handshaking), @floatFromInt(outstanding)), .{ .fg = palette.chart }, .{ .fg = palette.track });

    const eta_cell = headlineColumn(canvas, 3, cell);
    columnRule(canvas, 3 * (cell + 3) -| 2, y, palette);
    _ = eta_cell.text(0, y, "eta to full join", dim);
    const remaining: f64 = @floatFromInt(fleet.requested -| fleet.joined);
    // How far through the ramp the run is in time, which is what the estimate
    // beside it is actually counting down. Unknown until a rate exists, and
    // then it fills as the remaining time shrinks.
    var elapsed_fraction: f64 = 0;
    if (rate > 0) {
        const eta_ms = @min(3_599_000, remaining / rate * 1000);
        x = eta_cell.print(0, y + 1, bold, "{f}", .{widgets.clock(@intFromFloat(eta_ms))});
        const elapsed: f64 = @floatFromInt(data.elapsed_ms);
        elapsed_fraction = ratio(elapsed, elapsed + eta_ms);
    } else {
        x = eta_cell.text(0, y + 1, "--:--", dim);
    }
    _ = eta_cell.print(x, y + 1, dim, "  {f} waiting", .{report.grouped(fleet.waiting)});
    widgets.gauge(eta_cell, 0, y + 2, cell, elapsed_fraction, .{ .fg = palette.chart }, .{ .fg = palette.track });
}

/// Columns the degraded headline rows share.
const alert_value = 23;
const alert_detail = 37;

const AlertValue = union(enum) {
    rate: f64,
    count: u64,
    millis: u64,
};

fn alertRow(canvas: Canvas, y: u16, palette: Palette, severity: Severity, name: []const u8, value: AlertValue) void {
    const bold: Style = .{ .fg = severity.color(palette), .bold = true };
    _ = canvas.text(0, y, severity.marker(), .{ .fg = severity.color(palette) });
    _ = canvas.text(3, y, name, .{ .fg = palette.text });
    switch (value) {
        .rate => |rate| _ = canvas.print(alert_value, y, bold, "{d:.1}/s", .{rate}),
        .count => |count| _ = canvas.print(alert_value, y, bold, "{f}", .{report.grouped(count)}),
        .millis => |ms| _ = canvas.print(alert_value, y, bold, "{d}ms", .{ms}),
    }
}

const ChartScale = enum { bytes, count };

fn chartSection(
    canvas: Canvas,
    y: u16,
    rows: u16,
    palette: Palette,
    title: []const u8,
    span: Span,
    series: *const model_module.FleetSeries,
    scale: ChartScale,
) void {
    const faint: Style = .{ .fg = palette.faint };
    _ = canvas.text(0, y, title, .{ .fg = palette.dim });
    canvas.printRight(y, faint, "{s} window · {d}ms samples", .{ span.label(), model_module.sample_interval_ms });

    const plot_width = canvas.width() -| gutter;
    var samples: [chart_sample_capacity]f32 = undefined;
    const take = @min(plot_width, samples.len);
    const window = series.window(span, samples[0..take]);
    const maximum = series.maximum(span);

    widgets.chartAxis(canvas, axis_column, y + 1, rows, faint);
    widgets.areaChart(canvas, gutter, y + 1, plot_width, rows, window, maximum, .{ .fg = palette.chart }, .{ .fg = palette.chart_deep });

    const gutter_canvas = canvas.sub(0, 0, axis_column -| 1, canvas.height());
    axisLabel(gutter_canvas, y + 1, maximum, scale, faint);
    if (rows >= 3) axisLabel(gutter_canvas, y + 1 + rows / 2, maximum / 2, scale, faint);
    // A one-row plot has nowhere to put the origin: `y + rows` is the
    // maximum's own row, and both labels are right-aligned in the same gutter,
    // so the zero landed on the maximum's last digit and 25 read as 20.
    if (rows >= 2) gutter_canvas.printRight(y + rows, faint, "0", .{});

    _ = canvas.print(gutter, y + 1 + rows, faint, "-{s}", .{span.label()});
    canvas.textRight(y + 1 + rows, "now", faint);
}

fn axisLabel(canvas: Canvas, y: u16, value: f32, scale: ChartScale, style: Style) void {
    switch (scale) {
        .bytes => canvas.printRight(y, style, "{f}", .{report.bytes(value)}),
        // A churn axis whose whole range is below one would otherwise label
        // every row zero.
        .count => if (value < 10)
            canvas.printRight(y, style, "{d:.1}", .{@max(0, value)})
        else
            canvas.printRight(y, style, "{f}", .{report.grouped(report.rounded(value))}),
    }
}

/// Columns kept between a sparkline and the value beside it.
const spark_gap = 2;

/// A labelled sparkline with its value right-aligned. The plot is sized from
/// the value's rendered width rather than a guess, because the numbers here
/// reach eight figures under load and a fixed reservation eventually collides
/// with them.
fn sparkRow(
    canvas: Canvas,
    y: u16,
    label: []const u8,
    series: *const model_module.FleetSeries,
    span: Span,
    palette: Palette,
    color: theme.Rgb,
    value: []const u8,
) void {
    const width = canvas.width() -| (label_width + screen_module.displayWidth(value) + spark_gap);
    sparkLine(canvas, y, width, label, series, span, palette, color);
    canvas.textRight(y, value, .{ .fg = palette.dim });
}

fn sparkLine(
    canvas: Canvas,
    y: u16,
    width: u16,
    label: []const u8,
    series: *const model_module.FleetSeries,
    span: Span,
    palette: Palette,
    color: theme.Rgb,
) void {
    _ = canvas.text(0, y, label, .{ .fg = palette.dim });
    var samples: [chart_sample_capacity]f32 = undefined;
    const take = @min(width, samples.len);
    const window = series.window(span, samples[0..take]);
    widgets.sparkline(canvas, label_width, y, width, window, series.maximum(span), .{ .fg = color });
}

/// The two-column band the heat map shares with its neighbor. The right-hand
/// column is null when the terminal is too narrow to carry both.
/// What the heat map would occupy at its widest swatch geometry.
fn heatNaturalWidth(data: *const Model) u16 {
    if (data.shards.len == 0) return health_min_width;
    return label_width +| widgets.heatRowWidth(data.shards.len, 2, 3);
}

/// What the running layout's left block would use given the room: the wider of
/// its two occupants. The shard list is usually the one asking for more, which
/// is what keeps a small fleet from leaving a gap beside the causes column.
/// Only the running layout has that list; the others are sized by their heat
/// map alone, or they would reserve width nothing fills.
fn healthNaturalWidth(data: *const Model) u16 {
    return @max(heatNaturalWidth(data), shard_list_width);
}

fn splitBlock(canvas: Canvas, natural: u16) struct { Canvas, ?Canvas } {
    if (canvas.width() < health_split_minimum) return .{ canvas, null };
    const ceiling = canvas.width() -| (health_side_width + 2);
    // Sized from what the block's contents actually need rather than always
    // maximised, so a small fleet does not sit in a field of air. Derived from
    // the shard count, which is fixed for the run, so the split cannot twitch
    // as clients come and go.
    const left_w = std.math.clamp(natural, @min(health_min_width, ceiling), ceiling);
    // Placed against the left block rather than the far edge. Anchoring it
    // right leaves whatever is spare as a hole between the two, and a gap in
    // the middle reads as something missing where trailing margin does not.
    const right_x = @min(left_w + 2, canvas.width() -| health_side_width);
    return .{
        canvas.sub(0, 0, left_w, canvas.height()),
        canvas.sub(right_x, 0, health_side_width, canvas.height()),
    };
}

const HeatKind = enum { join, ramp, play, churn, keepalive, share, ring };

fn heatSeverity(kind: HeatKind, row: ShardRow, fleet: Fleet) Severity {
    return switch (kind) {
        .join => joinSeverity(row),
        .ramp => rampSeverity(row, fleet),
        .play => row.playSeverity(),
        .churn => row.churnSeverity(fleet),
        .keepalive => row.keepAliveSeverity(),
        .share => shareSeverity(row, fleet),
        .ring => row.ringSeverity(),
    };
}

fn heatLine(canvas: Canvas, y: u16, label: []const u8, kind: HeatKind, data: *const Model, palette: Palette, layout: HeatLayout) void {
    _ = canvas.text(0, y, label, .{ .fg = palette.dim });
    var severities: [heat_stage_capacity]Severity = undefined;
    for (data.shards[0..layout.shown], 0..) |row, index| severities[index] = heatSeverity(kind, row, data.fleet);
    widgets.heatRow(canvas, label_width, y, severities[0..layout.shown], palette, layout.glyphs, layout.stride);
}

fn shardIdRow(canvas: Canvas, y: u16, data: *const Model, palette: Palette, layout: HeatLayout) void {
    const faint: Style = .{ .fg = palette.faint };
    if (layout.shown == 0) return;
    // Ticks rather than a label under every swatch once they are too narrow
    // for one: a regular scale still lets a shard be located by counting, which
    // naming only the two ends does not.
    const step = layout.idStep();
    var index: usize = 0;
    var last_labelled: u16 = 0;
    var labelled_any = false;
    while (index < layout.shown) : (index += step) {
        const x = label_width + @as(u16, @intCast(index)) * layout.stride;
        _ = canvas.print(x, y, faint, "{d:0>2}", .{data.shards[index].id});
        last_labelled = x;
        labelled_any = true;
    }
    // The final shard anchors the scale, as long as it does not land on top of
    // the last regular tick.
    const final = layout.shown - 1;
    const final_x = label_width + @as(u16, @intCast(final)) * layout.stride;
    if (labelled_any and final_x >= last_labelled + 3) {
        _ = canvas.print(final_x, y, faint, "{d:0>2}", .{data.shards[final].id});
    }
    if (layout.shown < data.shards.len) canvas.textRight(y, "…", faint);
}

/// How the heat map draws its swatches: their width, spacing, and how many of
/// the fleet fit. A bigger fleet gives up the gap and then the second cell
/// before any shard is dropped, so 64 shards still all appear.
const HeatLayout = struct {
    glyphs: u16,
    stride: u16,
    shown: usize,

    /// True once swatches are too narrow to sit a two-digit id under each.
    fn idsFit(layout: HeatLayout) bool {
        return layout.stride >= 3;
    }

    /// Label every nth swatch, so a two-digit id plus its space always clears
    /// the next label. Denser swatches simply get sparser ticks.
    fn idStep(layout: HeatLayout) usize {
        if (layout.stride == 0) return 1;
        return std.math.divCeil(u16, 3, layout.stride) catch 1;
    }
};

fn heatLayout(canvas: Canvas, data: *const Model) HeatLayout {
    const available = canvas.width() -| label_width;
    // The stage `heatLine` builds a row in bounds the fleet as well as the
    // terminal does. Clamping here rather than there keeps `shown` the one
    // answer to how many swatches there are: the id row and the join meter
    // walk it too, and a stage that quietly held fewer left them labelling
    // shards with no swatch above them and suppressed the truncation marker
    // that says so.
    const count = @min(data.shards.len, heat_stage_capacity);
    if (count == 0) return .{ .glyphs = 2, .stride = 3, .shown = 0 };

    // The gap goes before the second cell does: a one-cell swatch with a gap
    // is narrower than a two-cell swatch without one, and a run of swatches
    // with no separator between them reads as a single bar in which no
    // individual shard can be found.
    const options = [_]struct { glyphs: u16, stride: u16 }{
        .{ .glyphs = 2, .stride = 3 },
        .{ .glyphs = 1, .stride = 2 },
        .{ .glyphs = 1, .stride = 1 },
    };
    for (options) |option| {
        if (widgets.heatRowWidth(count, option.glyphs, option.stride) <= available) {
            return .{ .glyphs = option.glyphs, .stride = option.stride, .shown = count };
        }
    }
    // Even at one cell each the fleet overflows: show as many as fit.
    return .{ .glyphs = 1, .stride = 1, .shown = @min(count, available) };
}

const LegendEntry = struct { severity: Severity, label: []const u8 };

/// A key for the heat map beneath it: the same swatch, in the color it will
/// actually be drawn there. Naming markers instead described glyphs the heat
/// map does not use, and drawing the key in one flat color showed none of the
/// distinction it claimed to explain.
fn severityLegend(canvas: Canvas, y: u16, palette: Palette, entries: []const LegendEntry) void {
    const faint: Style = .{ .fg = palette.faint };
    const gap = 2;

    var total: u16 = 0;
    for (entries) |entry| total += 3 + screen_module.displayWidth(entry.label) + gap;
    total -|= gap;
    if (total > canvas.width()) return;

    var x = canvas.width() - total;
    for (entries) |entry| {
        const style: Style = .{ .fg = widgets.heatColor(entry.severity, palette) };
        canvas.set(x, y, widgets.full_block, style);
        canvas.set(x + 1, y, widgets.full_block, style);
        x = canvas.text(x + 3, y, entry.label, faint) + gap;
    }
}

fn shardHealth(canvas: Canvas, y: u16, data: *const Model, view: View, palette: Palette) void {
    const dim: Style = .{ .fg = palette.dim };
    _ = canvas.text(0, y, "shard health", dim);
    severityLegend(canvas, y, palette, &.{
        .{ .severity = .ok, .label = "ok" },
        .{ .severity = .watch, .label = "watch" },
        .{ .severity = .hot, .label = "hot" },
    });

    const layout = heatLayout(canvas, data);
    var row = y + 1;
    heatLine(canvas, row, "join", .join, data, palette, layout);
    heatLine(canvas, row + 1, "play", .play, data, palette, layout);
    heatLine(canvas, row + 2, "churn", .churn, data, palette, layout);
    row += 3;
    if (comptime diagnostics) {
        heatLine(canvas, row, "ka p99", .keepalive, data, palette, layout);
        row += 1;
    }
    if (comptime traffic) {
        heatLine(canvas, row, "rx share", .share, data, palette, layout);
        row += 1;
    }
    if (comptime diagnostics) {
        heatLine(canvas, row, "ring", .ring, data, palette, layout);
        row += 1;
    }
    shardIdRow(canvas, row, data, palette, layout);
    row += 1;

    topShards(canvas, row, data, view, palette);
}

/// The shards worth looking at first, in the table's current order, with the
/// selection the arrow keys move and enter opens. The window follows the
/// cursor, so walking past the last visible row scrolls rather than dead-ends.
fn topShards(block: Canvas, y: u16, data: *const Model, view: View, palette: Palette) void {
    if (data.order.len == 0) return;
    const canvas = block.sub(0, 0, @min(shard_list_width, block.width()), block.height());
    const total = data.order.len;
    const selected = @min(view.selected, total - 1);
    const count = @min(@as(usize, top_shard_rows), total);
    const first = if (selected >= count) selected - count + 1 else 0;

    // Counted from the window, not the fleet, so it tracks the cursor.
    const remaining = total -| (first + count);
    if (remaining > 0) {
        canvas.printRight(y, .{ .fg = palette.faint }, "↑↓ select   {d} more below", .{remaining});
    } else if (first > 0) {
        canvas.printRight(y, .{ .fg = palette.faint }, "↑↓ select   {d} above", .{first});
    }

    for (0..count) |offset| {
        const index = first + offset;
        const shard_row = data.shards[data.order[index]];
        const line = y + 1 + @as(u16, @intCast(offset));
        const chosen = index == selected;
        const severity = shard_row.severity(data.fleet);
        const marker: Style = if (chosen)
            .{ .fg = palette.background, .bg = palette.text, .bold = true }
        else
            .{ .fg = severity.color(palette) };
        const body: Style = if (chosen)
            .{ .fg = palette.background, .bg = palette.text }
        else
            .{ .fg = palette.dim };

        _ = canvas.print(0, line, marker, "{s} {d:0>2}", .{ severity.marker(), shard_row.id });

        // Fields are appended while they fit whole, most telling first, so a
        // narrow pane sheds the least useful column instead of cutting one in
        // half.
        const limit = canvas.width() -| (spark_gap + drill_hint_width);
        var text: [64]u8 = undefined;
        var room = true;
        var x: u16 = label_width;
        x = appendField(canvas, x, line, body, limit, &room, std.fmt.bufPrint(&text, "{f} reconnects", .{report.grouped(shard_row.reconnects)}) catch "");
        if (comptime diagnostics) x = appendField(canvas, x, line, body, limit, &room, std.fmt.bufPrint(&text, " · ka p99 {d}ms", .{shard_row.keep_alive_p99_ms}) catch "");
        if (comptime traffic) x = appendField(canvas, x, line, body, limit, &room, std.fmt.bufPrint(&text, " · {f}", .{report.byteRate(shard_row.rx_per_sec)}) catch "");
        x = appendField(canvas, x, line, body, limit, &room, std.fmt.bufPrint(&text, " · {f} drops", .{report.grouped(shard_row.disconnects)}) catch "");
        x = appendField(canvas, x, line, body, limit, &room, std.fmt.bufPrint(&text, " · play {d}/{d}", .{ shard_row.play, shard_row.requested }) catch "");
        // Only when a gap is left for it: abutting the last figure reads as
        // part of the number rather than as a key hint.
        if (chosen and x + spark_gap + drill_hint_width <= canvas.width()) {
            canvas.textRight(line, drill_hint, .{ .fg = palette.faint });
        }
    }
}

fn degradedHealth(canvas: Canvas, y: u16, data: *const Model, palette: Palette) void {
    const fleet = data.fleet;
    const dim: Style = .{ .fg = palette.dim };
    _ = canvas.text(0, y, "shard health", dim);
    severityLegend(canvas, y, palette, &.{
        .{ .severity = .ok, .label = "ok" },
        .{ .severity = .watch, .label = "watch" },
        .{ .severity = .hot, .label = "failing" },
    });

    const layout = heatLayout(canvas, data);
    var row = y + 1;
    heatLine(canvas, row, "play", .play, data, palette, layout);
    heatLine(canvas, row + 1, "churn", .churn, data, palette, layout);
    row += 2;
    if (comptime diagnostics) {
        heatLine(canvas, row, "ka p99", .keepalive, data, palette, layout);
        heatLine(canvas, row + 1, "ring", .ring, data, palette, layout);
        row += 2;
    }
    shardIdRow(canvas, row, data, palette, layout);
    row += 2;

    const severity = playSeverity(fleet);
    _ = canvas.text(0, row, "in play", dim);
    const x = canvas.print(label_width, row, .{ .fg = severity.color(palette), .bold = true }, "{f}", .{report.grouped(fleet.play)});
    _ = canvas.print(x, row, dim, " / {f}   {d:.1}%", .{ report.grouped(fleet.requested), fleet.playFraction() * 100 });
    widgets.gauge(canvas, label_width, row + 1, canvas.width() -| label_width, fleet.playFraction(), .{ .fg = severity.color(palette) }, .{ .fg = palette.track });
}

fn joinProgress(canvas: Canvas, y: u16, data: *const Model, palette: Palette) void {
    const fleet = data.fleet;
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    _ = canvas.text(0, y, "join progress by shard", dim);
    severityLegend(canvas, y, palette, &.{
        .{ .severity = .ok, .label = "ahead" },
        .{ .severity = .watch, .label = "behind" },
    });

    const layout = heatLayout(canvas, data);
    heatLine(canvas, y + 1, "joined", .ramp, data, palette, layout);
    // Percentages need three columns each, so they are only legible while the
    // swatches are at their widest; the heat row carries the signal otherwise.
    // The label goes with them rather than heading an empty row.
    const percents = if (layout.idsFit()) layout.shown else 0;
    if (percents > 0) _ = canvas.text(0, y + 2, "%", dim);
    for (data.shards[0..percents], 0..) |row, index| {
        const x = label_width + @as(u16, @intCast(index)) * layout.stride;
        if (row.requested == 0) {
            _ = canvas.text(x, y + 2, "--", faint);
        } else if (row.joined >= row.requested) {
            _ = canvas.text(x, y + 2, "ok", .{ .fg = palette.ok });
        } else {
            _ = canvas.print(x, y + 2, faint, "{d:>2}", .{row.joined * 100 / row.requested});
        }
    }
    shardIdRow(canvas, y + 3, data, palette, layout);

    _ = canvas.text(0, y + 5, "phase", dim);
    var x = canvas.print(label_width, y + 5, .{ .fg = palette.text }, "waiting {f}", .{report.grouped(fleet.waiting)});
    x = canvas.text(x, y + 5, "  ·  ", dim);
    x = canvas.print(x, y + 5, .{ .fg = palette.text }, "tcp {f}", .{report.grouped(fleet.connecting)});
    x = canvas.text(x, y + 5, "  ·  ", dim);
    _ = canvas.print(x, y + 5, .{ .fg = palette.text }, "login/config {f}", .{report.grouped(fleet.connected -| fleet.play)});
}

fn joinDiagnostics(canvas: Canvas, y: u16, data: *const Model, palette: Palette) void {
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    _ = canvas.text(0, y, "join diagnostics", dim);
    var index: u16 = 0;
    while (index < 4) : (index += 1) {
        const event = data.log.at(index) orelse break;
        const row = y + 1 + index;
        _ = canvas.print(0, row, faint, "{f}", .{widgets.stamp(event.at_ms)});
        if (!event.fleet) _ = canvas.print(11, row, dim, "{d:0>2}", .{event.shard});
        const severity = eventSeverity(event);
        const style: Style = if (severity == .ok) .{ .fg = palette.text } else .{ .fg = severity.color(palette) };
        _ = canvas.text(19, row, eventSummary(event), style);
    }
}

fn disconnectCauses(canvas: Canvas, y: u16, data: *const Model, palette: Palette) void {
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const counts = data.fleet.disconnect_counts;

    var total: u64 = 0;
    var highest: u64 = 0;
    for (counts) |count| {
        total += count;
        highest = @max(highest, count);
    }
    _ = canvas.text(0, y, "disconnect causes", dim);
    canvas.printRight(y, faint, "{f}", .{report.grouped(total)});

    const label_field = 12;
    const bar_width = canvas.width() -| (label_field + 10);
    for (std.enums.values(telemetry.DisconnectCategory), 0..) |category, index| {
        const row = y + 1 + @as(u16, @intCast(index));
        const count = counts[@backingInt(category)];
        if (count == 0) {
            _ = canvas.text(0, row, category.label(), faint);
            _ = canvas.text(label_field, row, "·", .{ .fg = palette.track });
            canvas.printRight(row, faint, "0", .{});
            continue;
        }
        // Protocol, buffer and resource drops are the client's own fault or a
        // limit being hit; transport and server drops are the server's.
        const color = switch (category) {
            .protocol, .buffer_limit, .resource => palette.bad,
            else => palette.warn,
        };
        _ = canvas.text(0, row, category.label(), dim);
        _ = widgets.bar(canvas, label_field, row, bar_width, ratio(@floatFromInt(count), @floatFromInt(highest)), .{ .fg = color });
        canvas.printRight(row, .{ .fg = palette.text }, "{f}", .{report.grouped(count)});
    }
}

fn keepAliveBlock(canvas: Canvas, y: u16, data: *const Model, palette: Palette) void {
    const dim: Style = .{ .fg = palette.dim };
    const histogram = data.fleet.keep_alive;
    const p99 = histogram.percentile(0.99);

    _ = canvas.text(0, y, "keepalive reply", dim);
    _ = canvas.text(0, y + 1, "p50 p90", dim);
    _ = canvas.print(12, y + 1, .{ .fg = palette.text }, "{f}  {f}", .{
        widgets.millis(@floatFromInt(histogram.percentile(0.5))),
        widgets.millis(@floatFromInt(histogram.percentile(0.9))),
    });
    _ = canvas.text(0, y + 2, "p99 max", dim);
    const severity = model_module.keepAliveSeverityFor(p99);
    _ = canvas.text(10, y + 2, severity.marker(), .{ .fg = severity.color(palette) });
    const x = canvas.print(12, y + 2, .{ .fg = severity.color(palette) }, "{f}", .{widgets.millis(@floatFromInt(p99))});
    _ = canvas.print(x, y + 2, .{ .fg = palette.text }, "  {f}", .{widgets.millis(@floatFromInt(histogram.max))});
}

fn ringLine(canvas: Canvas, y: u16, data: *const Model, palette: Palette) void {
    const dim: Style = .{ .fg = palette.dim };
    const ring = data.fleet.ring;
    _ = canvas.text(0, y, "ring", dim);
    var x = canvas.print(label_width, y, dim, "cq {d}/{d}", .{ ring.peak_cq_ready, ring.peak_cq_entries });
    x = counterField(canvas, x, y, palette, "nobufs", ring.recv_nobufs);
    x = counterField(canvas, x, y, palette, "overflow", ring.cq_overflow);
    x = counterField(canvas, x, y, palette, "close fail", ring.close_failures);
    _ = canvas.print(x, y, dim, "   bundle {f}/{d}", .{
        report.bytes(@floatFromInt(ring.max_bundle_bytes)),
        ring.max_bundle_buffers,
    });
}

/// A counter that reads as ordinary at zero and carries a marker once it is not.
fn counterField(canvas: Canvas, x: u16, y: u16, palette: Palette, label: []const u8, value: u64) u16 {
    if (value == 0) return canvas.print(x, y, .{ .fg = palette.dim }, "   {s} 0", .{label});
    return canvas.print(x, y, .{ .fg = palette.bad }, "   ▲ {s} {f}", .{ label, report.grouped(value) });
}

fn footer(canvas: Canvas, palette: Palette, hints: []const u8, note: []const u8) void {
    const y = canvas.height() -| 1;
    const faint: Style = .{ .fg = palette.faint };
    // The blocks above are laid out at fixed offsets and clip to the canvas
    // rather than to this row, so on a short terminal one of them lands here.
    // Blank the row before writing: the footer owns it.
    canvas.repeat(0, y, canvas.width(), " ", faint);
    const keys_end = canvas.text(0, y, hints, faint);
    // The note is dropped rather than overprinted when the two do not both
    // fit, as every other split line in the dashboard does: the keys are the
    // half the reader needs, and a joining pane's note is long enough to eat
    // `q quit` off the end of them on anything under eighty columns.
    if (canvas.width() -| screen_module.displayWidth(note) > keys_end) canvas.textRight(y, note, faint);
}

fn columnRule(canvas: Canvas, x: u16, y: u16, palette: Palette) void {
    const style: Style = .{ .fg = palette.rule };
    canvas.set(x, y + 1, "│", style);
    canvas.set(x, y + 2, "│", style);
}

/// One headline column as a surface of its own, so a figure wider than the
/// cell is cut at the column's own edge. Drawn straight onto the shared canvas
/// a long value ran through the rule and landed in front of its neighbor's
/// number: at eighty columns `20  0 tcp · 20 config` left the eta reading
/// `i--:--`.
fn headlineColumn(canvas: Canvas, slot: u16, cell: u16) Canvas {
    return canvas.sub(slot * (cell + 3), 0, cell, canvas.height());
}

/// Even headline columns with a three-column rule between them.
fn cellWidth(width: u16, columns: u16) u16 {
    return (width -| (columns -| 1) * 3) / columns;
}

/// Centres a headline's grid of equal cells. The floor division above leaves a
/// remainder of up to `columns - 1`, and letting it all collect on the right
/// puts the whole row visibly off center.
fn centredGrid(canvas: Canvas, cell: u16, columns: u16) Canvas {
    const used = columns * cell + (columns -| 1) * 3;
    const slack = canvas.width() -| used;
    return canvas.sub(slack / 2, 0, used, canvas.height());
}

fn ratio(value: f64, of: f64) f64 {
    if (!(of > 0)) return 0;
    return value / of;
}

/// Average joins per second so far. The ramp is steady by construction, so the
/// average is a better eta input than a single window's rate.
fn joinRate(data: *const Model) f64 {
    if (data.elapsed_ms == 0) return 0;
    return @as(f64, @floatFromInt(data.fleet.joined)) * 1000 / @as(f64, @floatFromInt(data.elapsed_ms));
}

fn playSeverity(fleet: Fleet) Severity {
    // A fleet with nothing requested has a play fraction of zero, which the
    // model's rating would call hot; that is a guard for the caller to make.
    if (fleet.requested == 0) return .ok;
    return model_module.playSeverityFor(fleet.playFraction());
}

/// The headline reuses the model's own storm test rather than inventing a
/// second threshold, so the number and the run state can never disagree.
fn churnSeverity(data: *const Model) Severity {
    if (data.degradation.reconnect_storm) return .hot;
    if (data.fleet.reconnects > 0) return .watch;
    return .ok;
}

fn joinSeverity(row: ShardRow) Severity {
    if (row.requested == 0 or row.joined >= row.requested) return .ok;
    const fraction = @as(f64, @floatFromInt(row.joined)) / @as(f64, @floatFromInt(row.requested));
    return if (fraction < 0.9) .hot else .watch;
}

/// During the ramp a shard is only interesting relative to its neighbors:
/// every shard is behind, so absolute progress says nothing.
fn rampSeverity(row: ShardRow, fleet: Fleet) Severity {
    if (row.requested == 0) return .ok;
    const fraction = @as(f64, @floatFromInt(row.joined)) / @as(f64, @floatFromInt(row.requested));
    return if (fraction + 0.05 < fleet.joinFraction()) .watch else .ok;
}

fn shareSeverity(row: ShardRow, fleet: Fleet) Severity {
    if (fleet.shard_count == 0 or row.rx_share == 0) return .ok;
    const even = 1.0 / @as(f64, @floatFromInt(fleet.shard_count));
    const share = row.rx_share / even;
    if (share >= 4 or share <= 0.25) return .hot;
    if (share >= 2 or share <= 0.5) return .watch;
    return .ok;
}

fn shardState(row: ShardRow) struct { label: []const u8, severity: Severity } {
    if (row.done) return .{ .label = "done", .severity = .ok };
    if (row.requested == 0) return .{ .label = "starting", .severity = .watch };
    if (row.play >= row.requested) return .{ .label = "running", .severity = .ok };
    return .{ .label = "joining", .severity = .watch };
}

fn eventSummary(event: telemetry.Event) []const u8 {
    return switch (event.kind) {
        .run_started => "run started",
        .compression_on => "compression on",
        .entered_play => "entered play",
        .full_join => "full join",
        .disconnect => "disconnect",
        .reconnect => "reconnect scheduled",
        .keepalive => "keepalive reply",
        .protocol_error => "protocol error",
    };
}

fn eventSeverity(event: telemetry.Event) Severity {
    return switch (event.kind) {
        .protocol_error => .hot,
        .disconnect, .reconnect => .watch,
        else => .ok,
    };
}

/// What to change before re-running. The dominant alert picks the advice: a
/// ring that overflowed is a shard-count problem, a storm is not.
fn hintFor(data: *const Model) []const u8 {
    if (data.degradation.ring_overflow) return "raise --shards so fewer clients share one completion queue, then re-run";
    if (data.degradation.keepalive_stalled) return "the fleet cannot answer keepalives in time; lower --clients or raise --shards";
    if (data.degradation.reconnect_storm) return "the server is dropping clients faster than they rejoin; check its logs";
    return "no single signal dominates; the 5 log pane has the sequence";
}

const testing = std.testing;

/// The cell at (column, row), as its text.
fn cellText(screen: *const screen_module.Screen, row: u16, column: u16) []const u8 {
    return screen.back[@as(usize, row) * screen.cols + column].text();
}

/// Column where an ASCII `needle` starts on `row`, matching cell by cell.
/// Works in columns rather than bytes, which byte offsets into a rendered row
/// cannot do once multi-byte block glyphs are on it.
fn findColumn(screen: *const screen_module.Screen, row: u16, needle: []const u8) ?u16 {
    var column: u16 = 0;
    outer: while (column + needle.len <= screen.cols) : (column += 1) {
        for (needle, 0..) |byte, offset| {
            const text = cellText(screen, row, column + @as(u16, @intCast(offset)));
            if (text.len != 1 or text[0] != byte) continue :outer;
        }
        return column;
    }
    return null;
}

fn findRow(screen: *const screen_module.Screen, needle: []const u8) ?u16 {
    var buffer: [512]u8 = undefined;
    for (0..screen.rows) |row| {
        if (std.mem.indexOf(u8, screen.rowText(@intCast(row), &buffer), needle) != null) return @intCast(row);
    }
    return null;
}

test "the running layout shows the headline numbers" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 39);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{
        .target = "127.0.0.1:25565",
        .client_count = 5000,
    }, 12);
    defer data.deinit();
    data.reached_full_join = true;
    data.state = .running;
    data.fleet.play = 4987;
    data.fleet.joined = 5000;
    data.fleet.reconnects = 113;
    data.fleet.reconnects_per_sec = 0.45;
    data.fleet.rx_per_sec = 15.09 * 1024 * 1024;
    data.fleet.peak_rx_per_sec = 18.41 * 1024 * 1024;
    data.fleet.packets_per_sec = 163_466;

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    try testing.expect(screen.contains("in play"));
    try testing.expect(screen.contains("4,987 / 5,000   99.7%"));
    try testing.expect(screen.contains("5,000 clients / 12 shards"));
    try testing.expect(screen.contains("113  0.45/s"));
    if (comptime traffic) {
        try testing.expect(screen.contains("15.09 MiB/s"));
        try testing.expect(screen.contains("163,466/s"));
    }
    // The footer owns the canvas's last row, not whichever row the content ended on.
    var buffer: [1024]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, screen.rowText(38, &buffer), "q quit") != null);
}

test "the joining layout appears before full join" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 39);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{
        .client_count = 5000,
        .connect_rate_per_sec = 100,
    }, 12);
    defer data.deinit();
    data.state = .joining;
    data.elapsed_ms = 18_000;
    data.fleet.joined = 1842;
    data.fleet.connecting = 96;
    data.fleet.waiting = 3041;

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    try testing.expect(screen.contains("1,842 / 5,000   36.8%"));
    try testing.expect(screen.contains("eta to full join"));
    try testing.expect(screen.contains("ramp 100/s"));
    try testing.expect(screen.contains("clients in play"));
    // Nothing steady-state has anything to say yet.
    try testing.expect(!screen.contains("receive rate"));
}

/// The joining headline's gauge row, two below the row carrying its labels.
fn gaugeRow(screen: *const screen_module.Screen) ?u16 {
    var buffer: [512]u8 = undefined;
    for (0..screen.rows) |row| {
        const text = screen.rowText(@intCast(row), &buffer);
        if (std.mem.indexOf(u8, text, "eta to full join") != null) return @intCast(row + 2);
    }
    return null;
}

/// Counts cells on `row` drawn in `color`, so a test can tell a filled gauge
/// from a bare track without depending on where the gauge sits.
fn cellsColored(screen: *const screen_module.Screen, row: u16, color: theme.Rgb) usize {
    var count: usize = 0;
    for (0..screen.cols) |column| {
        const cell = screen.back[@as(usize, row) * screen.cols + column];
        if (cell.style.fg.eql(color)) count += 1;
    }
    return count;
}

test "the joining gauges track progress instead of sitting still" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 39);

    var data = try Model.init(testing.allocator, .{ .client_count = 1000, .connect_rate_per_sec = 100 }, 8);
    defer data.deinit();

    // Early: a little joined, most of the fleet still queued behind the ramp.
    screen.clear(.{ .fg = theme.running.text });
    data.elapsed_ms = 2_000;
    data.fleet = .{ .requested = 1000, .joined = 200, .connecting = 20, .connected = 210, .play = 200 };
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});
    // Located by its label rather than a fixed index, so the test survives the
    // headline moving.
    const row = gaugeRow(&screen) orelse return error.TestUnexpectedResult;
    const early_filled = cellsColored(&screen, row, theme.running.chart);

    // Later: further through the ramp, so more of the run's time has elapsed
    // and the in-flight backlog is a larger share of what is left.
    screen.clear(.{ .fg = theme.running.text });
    data.elapsed_ms = 8_000;
    data.fleet = .{ .requested = 1000, .joined = 800, .connecting = 60, .connected = 860, .play = 800 };
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});
    const late_filled = cellsColored(&screen, row, theme.running.chart);

    // Neither gauge may be dead: the row has to respond to the run's state.
    try testing.expect(early_filled > 0);
    try testing.expect(late_filled > early_filled);
}

test "the degraded layout names the failing signal" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 39);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 5000 }, 12);
    defer data.deinit();
    data.reached_full_join = true;
    data.state = .degraded;
    data.fleet.play = 3461;
    data.fleet.ring.peak_cq_ready = 4096;
    data.fleet.ring.peak_cq_entries = 4096;
    data.degradation = .{
        .active = true,
        .began_at_ms = 41_000,
        .ring_overflow = true,
        .overflow_count = 3918,
        .hot_shards = .{ 2, 5, 9 },
        .hot_shard_count = 3,
    };

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .alerts = true });

    try testing.expect(screen.contains("▲"));
    try testing.expect(screen.contains("cq overflow"));
    try testing.expect(screen.contains("3,918"));
    try testing.expect(screen.contains("peak cq 4096/4096 · shards 02 05 09"));
    try testing.expect(screen.contains("reconnects /s"));
    try testing.expect(screen.contains("raise --shards"));
    // This episode is a ring overflow, not a churn storm: the caption under the
    // chart dates the degradation without naming a cause it did not measure.
    try testing.expect(screen.contains("degraded 00:41"));
    try testing.expect(!screen.contains("storm 00:41"));

    // The alert layout is reachable at any time; once the run is healthy again
    // the caption goes with it rather than dating an alert that is over.
    screen.clear(.{ .fg = theme.running.text });
    data.state = .running;
    data.degradation.active = false;
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .alerts = true });
    try testing.expect(!screen.contains("degraded 00:41"));
}

test "a sparkline keeps clear of its value however large the number grows" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime !traffic) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(130, 42);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 1000 }, 8);
    defer data.deinit();
    data.reached_full_join = true;
    // Eight figures with a peak beside it, which is what a real run reaches
    // and what a fixed-width reservation collides with.
    data.fleet = .{
        .requested = 1000,
        .joined = 1000,
        .play = 1000,
        .shard_count = 8,
        .packets_per_sec = 17_871_626,
        .peak_packets_per_sec = 23_615_541,
    };
    for (0..200) |index| data.packets.push(17_000_000, index * model_module.sample_interval_ms);

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    // Anchored on the sparkline's own label: the headline above it prints the
    // same figure, and that row is not what this test is about.
    var row: u16 = 0;
    const found = while (row < screen.rows) : (row += 1) {
        if (findColumn(&screen, row, "pkt/s") != null and
            findColumn(&screen, row, "17,871,626") != null) break true;
    } else false;
    try testing.expect(found);
    const column = findColumn(&screen, row, "17,871,626") orelse return error.TestUnexpectedResult;
    // Whatever precedes the number, it must not be plot: there is clear space
    // between the sparkline and the value.
    try testing.expect(column >= spark_gap);
    for (1..spark_gap + 1) |back| {
        try testing.expectEqualStrings(" ", cellText(&screen, row, column - @as(u16, @intCast(back))));
    }
    // And the sparkline is still actually drawn, not squeezed to nothing.
    var plotted: usize = 0;
    for (0..column) |plot_column| {
        const cell = screen.back[@as(usize, row) * screen.cols + plot_column];
        if (cell.style.fg.eql(theme.running.chart)) plotted += 1;
    }
    try testing.expect(plotted > 50);
}

test "the clients-in-play chart spans the plot from the first samples" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(130, 42);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 60 }, 4);
    defer data.deinit();
    data.fleet = .{ .requested = 60, .joined = 16, .play = 16, .shard_count = 4 };
    // Eight seconds of ramp against a capacity of 1800 samples: the chart plots
    // the run so far, not a fraction of a window the run will never reach.
    for (0..16) |index| {
        data.play_series.push(@floatFromInt(index), index * model_module.sample_interval_ms);
    }

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    // The chart's baseline row is the last one carrying plot glyphs; find the
    // rightmost and leftmost drawn columns on it.
    var widest: usize = 0;
    for (0..screen.rows) |row| {
        var drawn: usize = 0;
        for (0..screen.cols) |column| {
            const cell = screen.back[row * screen.cols + column];
            if (cell.style.fg.eql(theme.running.chart) or cell.style.fg.eql(theme.running.chart_deep)) drawn += 1;
        }
        widest = @max(widest, drawn);
    }
    // A single filled column is the symptom of scaling a young run against the
    // full sample capacity; the plot should reach across the pane.
    try testing.expect(widest > 100);
}

test "the block split follows the fleet size in both directions" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(130, 42);
    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };

    for ([_]usize{ 2, 12, 24, 64 }) |shards| {
        var data = try Model.init(testing.allocator, .{ .client_count = shards * 10 }, shards);
        defer data.deinit();

        const left, const right = splitBlock(canvas, healthNaturalWidth(&data));
        // The side column is fixed-length text: it always gets exactly what it
        // needs, never the surplus.
        try testing.expectEqual(health_side_width, right.?.width());
        // Which is at most 40% of the pane wherever two columns are drawn.
        try testing.expect(right.?.width() * 100 / canvas.width() <= 40);
        // It sits against the left block, so whatever is spare ends up as
        // trailing margin rather than a hole between the two.
        try testing.expectEqual(left.width() + 2, right.?.rect.x);
        // And the pair always fits.
        try testing.expect(right.?.rect.x + right.?.width() <= canvas.width());
    }
}

test "every headline gauge is the same width" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();

    // Widths chosen so the cell division leaves a remainder, which is what used
    // to collect in the final column and stretch its bar.
    for ([_]u16{ 120, 130, 137, 140, 163 }) |width| {
        try screen.resize(width, 42);
        screen.clear(.{ .fg = theme.running.text });

        var data = try Model.init(testing.allocator, .{ .client_count = 1000 }, 8);
        defer data.deinit();
        data.reached_full_join = true;
        // Every gauge full, so each one's run of cells is its whole width.
        data.fleet = .{
            .requested = 1000,
            .joined = 1000,
            .play = 1000,
            .shard_count = 8,
            .rx_per_sec = 100,
            .peak_rx_per_sec = 100,
            .packets_per_sec = 100,
            .peak_packets_per_sec = 100,
        };

        render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

        // The gauge row is the third of the headline; measure each unbroken run
        // of track-or-fill cells across it.
        const row: u16 = 4;
        var runs: [8]u16 = @splat(0);
        var found: usize = 0;
        var current: u16 = 0;
        for (0..screen.cols) |column| {
            const cell = screen.back[@as(usize, row) * screen.cols + column];
            const is_bar = std.mem.eql(u8, cell.text(), widgets.full_block);
            if (is_bar) {
                current += 1;
            } else if (current > 0) {
                if (found < runs.len) runs[found] = current;
                found += 1;
                current = 0;
            }
        }
        if (current > 0 and found < runs.len) {
            runs[found] = current;
            found += 1;
        }

        try testing.expectEqual(@as(usize, if (traffic) 4 else 2), found);
        for (runs[1..found]) |run| try testing.expectEqual(runs[0], run);

        // And every column rule sits centred between two bars rather than
        // hugging one of them: exactly one blank column on each side.
        for (0..screen.cols) |column| {
            if (!std.mem.eql(u8, cellText(&screen, row, @intCast(column)), "│")) continue;
            try testing.expect(column >= 2 and column + 2 < screen.cols);
            try testing.expectEqualStrings(" ", cellText(&screen, row, @intCast(column - 1)));
            try testing.expectEqualStrings(" ", cellText(&screen, row, @intCast(column + 1)));
            try testing.expectEqualStrings(widgets.full_block, cellText(&screen, row, @intCast(column - 2)));
            try testing.expectEqualStrings(widgets.full_block, cellText(&screen, row, @intCast(column + 2)));
        }
    }
}

test "the shard list fills the block instead of leaving a gap beside it" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(140, 42);
    screen.clear(.{ .fg = theme.running.text });

    // Sixteen shards: the heat map needs well under half the pane, which is
    // where the hole used to open up.
    const shards = 16;
    var data = try Model.init(testing.allocator, .{ .client_count = shards * 10 }, shards);
    defer data.deinit();
    data.reached_full_join = true;
    data.fleet = .{ .requested = shards * 10, .joined = shards * 10, .play = shards * 10, .shard_count = shards };
    for (data.shards, 0..) |*row, index| {
        row.requested = 10;
        row.play = 10;
        row.disconnects = index;
        row.rx_per_sec = 8_360_000;
    }
    data.sortRows(.reconnects, true);

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    // The list carries the extra fields the width pays for...
    try testing.expect(screen.contains("drops"));
    try testing.expect(screen.contains("play 10/10"));

    // ...and the causes column sits against the block rather than across a gap.
    // The causes block is the diagnostics build's side column; a stats-only
    // build draws no side column for the list to sit against.
    if (comptime diagnostics) {
        const causes = findRow(&screen, "disconnect causes") orelse return error.TestUnexpectedResult;
        const causes_column = findColumn(&screen, causes, "disconnect causes") orelse return error.TestUnexpectedResult;
        const list = findRow(&screen, drill_hint) orelse return error.TestUnexpectedResult;
        const marker = findColumn(&screen, list, "enter") orelse return error.TestUnexpectedResult;
        // Whatever separates them is a couple of columns, not tens of them.
        try testing.expect(causes_column > marker);
        try testing.expect(causes_column - marker < 20);
    }
}

test "the severity key shows the colours the heat map actually uses" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(140, 42);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 40 }, 4);
    defer data.deinit();
    data.reached_full_join = true;
    data.fleet = .{ .requested = 40, .joined = 40, .play = 40, .shard_count = 4 };
    for (data.shards) |*row| {
        row.requested = 10;
        row.play = 10;
    }

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    const row = findRow(&screen, "shard health") orelse return error.TestUnexpectedResult;
    // Each entry's swatch carries its own severity color, so the key explains
    // the map rather than restating one flat color three times.
    for ([_]Severity{ .ok, .watch, .hot }) |severity| {
        const want = widgets.heatColor(severity, theme.running);
        var seen = false;
        for (0..screen.cols) |column| {
            const cell = screen.back[@as(usize, row) * screen.cols + column];
            if (std.mem.eql(u8, cell.text(), widgets.full_block) and cell.style.fg.eql(want)) seen = true;
        }
        try testing.expect(seen);
    }
}

test "watch and hot stay apart without colour" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    // The markers are the colourless carrier of severity, so two of them
    // reading the same would leave hue doing the work alone.
    try testing.expect(!std.mem.eql(u8, Severity.watch.marker(), Severity.hot.marker()));
    try testing.expect(!std.mem.eql(u8, Severity.ok.marker(), Severity.watch.marker()));
    // And each is a single column, as every glyph the dashboard draws must be.
    for ([_]Severity{ .ok, .watch, .hot }) |severity| {
        try testing.expectEqual(@as(u16, 1), screen_module.displayWidth(severity.marker()));
    }
}

test "the drill marker never abuts the figure before it" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();

    // A single shard puts the left block at its floor, which is the tightest
    // the list ever is and where the marker used to run into the rate.
    for ([_]u16{ 110, 130, 170 }) |width| {
        try screen.resize(width, 42);
        screen.clear(.{ .fg = theme.running.text });

        var data = try Model.init(testing.allocator, .{ .client_count = 4 }, 1);
        defer data.deinit();
        data.reached_full_join = true;
        data.fleet = .{ .requested = 4, .joined = 4, .play = 4, .shard_count = 1 };
        data.shards[0] = .{ .id = 0, .requested = 4, .play = 4, .rx_per_sec = 67_657 };

        render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

        const row = findRow(&screen, drill_hint) orelse continue;
        const column = findColumn(&screen, row, "enter") orelse continue;
        // Whatever precedes the hint is blank, not the tail of a number.
        try testing.expect(column >= spark_gap);
        for (1..spark_gap + 1) |back| {
            try testing.expectEqualStrings(" ", cellText(&screen, row, column - @as(u16, @intCast(back))));
        }
    }
}

test "the shard list keeps its hints beside the rows on a very wide terminal" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    // Wide enough that a 100-shard heat map stretches past 200 columns.
    try screen.resize(256, 42);
    screen.clear(.{ .fg = theme.running.text });

    const shards = 100;
    var data = try Model.init(testing.allocator, .{ .client_count = shards * 4 }, shards);
    defer data.deinit();
    data.reached_full_join = true;
    data.fleet = .{ .requested = shards * 4, .joined = shards * 4, .play = shards * 4, .shard_count = shards };
    for (data.shards) |*row| {
        row.requested = 4;
        row.play = 4;
    }

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    // The heat map really is sprawling, which is the condition being tested.
    // Measured as the widest run of swatches on any row, since several labels
    // appear both in the heat block and in the sparklines above it.
    var swatches: usize = 0;
    for (0..screen.rows) |row| {
        var on_row: usize = 0;
        for (0..screen.cols) |column| {
            if (std.mem.eql(u8, cellText(&screen, @intCast(row), @intCast(column)), widgets.full_block)) on_row += 1;
        }
        swatches = @max(swatches, on_row);
    }
    try testing.expect(swatches >= shards);

    // The hints stay next to the rows they belong to rather than being
    // right-aligned to a block several times their width.
    const marker = findRow(&screen, "enter ▸") orelse return error.TestUnexpectedResult;
    const marker_column = findColumn(&screen, marker, "enter") orelse return error.TestUnexpectedResult;
    try testing.expect(marker_column < shard_list_width);

    const hint = findRow(&screen, "more below") orelse return error.TestUnexpectedResult;
    const hint_column = findColumn(&screen, hint, "more below") orelse return error.TestUnexpectedResult;
    try testing.expect(hint_column < shard_list_width);
}

test "dense heat maps stay countable" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(130, 42);

    for ([_]usize{ 32, 64 }) |shards| {
        screen.clear(.{ .fg = theme.running.text });
        var data = try Model.init(testing.allocator, .{ .client_count = shards * 4 }, shards);
        defer data.deinit();
        data.reached_full_join = true;
        data.fleet = .{ .requested = shards * 4, .joined = shards * 4, .play = shards * 4, .shard_count = shards };
        for (data.shards) |*row| {
            row.requested = 4;
            row.play = 4;
        }
        render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

        // Every shard is represented rather than the fleet being truncated...
        const layout = heatLayout(.{ .screen = &screen, .rect = .{ .w = 130 - (health_side_width + 2), .h = 42 } }, &data);
        try testing.expectEqual(shards, layout.shown);
        // ...and the id row is a regular scale rather than just its two ends,
        // so a shard can be located by counting from the nearest tick.
        const step = layout.idStep();
        const last_tick = ((shards - 1) / step) * step;
        for ([_]usize{ 0, (last_tick / step / 2) * step, last_tick }) |index| {
            var label: [4]u8 = undefined;
            try testing.expect(screen.contains(try std.fmt.bufPrint(&label, "{d:0>2}", .{index})));
        }
        // Ticks never collide: two digits and a space apart at the very least.
        try testing.expect(step * layout.stride >= 3);
    }
}

test "the shard list follows the selection and counts what is off screen" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(130, 42);

    var data = try Model.init(testing.allocator, .{ .client_count = 240 }, 24);
    defer data.deinit();
    data.reached_full_join = true;
    data.fleet = .{ .requested = 240, .joined = 240, .play = 240, .shard_count = 24 };
    for (data.shards, 0..) |*row, index| {
        row.requested = 10;
        row.play = 10;
        row.reconnects = 24 - index;
    }
    data.sortRows(.reconnects, true);

    // At the top of the list: four shown, the rest counted below.
    screen.clear(.{ .fg = theme.running.text });
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .selected = 0 });
    try testing.expect(screen.contains("20 more below"));

    // At the bottom: the window has scrolled, so the remainder is above it.
    // A static count would still be claiming twenty rows below here.
    screen.clear(.{ .fg = theme.running.text });
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .selected = 23 });
    try testing.expect(!screen.contains("20 more below"));
    try testing.expect(screen.contains("20 above"));
}

test "the heat map shows every shard by narrowing its swatches" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    if (comptime bare) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(130, 42);

    var data = try Model.init(testing.allocator, .{ .client_count = 640 }, 64);
    defer data.deinit();
    data.reached_full_join = true;
    data.fleet = .{ .requested = 640, .joined = 640, .play = 640, .shard_count = 64 };
    for (data.shards) |*row| {
        row.requested = 10;
        row.play = 10;
    }
    screen.clear(.{ .fg = theme.running.text });
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});

    // Sixty-four shards cannot fit at three columns each, so the swatches
    // narrow rather than the fleet being truncated: the id row names the span
    // it is covering, ending on the last shard.
    try testing.expect(screen.contains("63"));
}

test "a small canvas clips instead of computing a negative width" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(testing.allocator);
    defer screen.deinit();

    var data = try Model.init(testing.allocator, .{ .client_count = 40 }, 2);
    defer data.deinit();
    data.fleet.play = 40;

    for ([_]model_module.RunState{ .joining, .running, .degraded }) |state| {
        data.state = state;
        data.reached_full_join = state != .joining;
        data.degradation.active = state == .degraded;
        for ([_][2]u16{ .{ 20, 6 }, .{ 40, 12 }, .{ 1, 1 }, .{ 120, 39 } }) |size| {
            try screen.resize(size[0], size[1]);
            screen.clear(.{ .fg = theme.running.text });
            render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{});
        }
    }
}
