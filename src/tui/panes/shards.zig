//! The shards pane: every shard as a row, and one shard in full.
//!
//! Both layouts live here because they share one list. The table lists the
//! fleet; `enter` shrinks that list to a rail down the left so ↑↓ keeps walking
//! the fleet while the detail follows the selection.

const std = @import("std");
const report = @import("../../report.zig");
const telemetry = @import("../../telemetry.zig");
const model = @import("../model.zig");
const RowWindow = model.RowWindow;
const rowWindow = model.rowWindow;

/// Says where the window sits rather than how big the fleet is, so walking the
/// selection down counts the remainder down with it.
fn writeWindowRemainder(canvas: Canvas, x: u16, y: u16, window: RowWindow, faint: Style) void {
    if (window.below > 0) {
        _ = canvas.print(x, y, faint, "... {d} more below", .{window.below});
    } else if (window.above > 0) {
        _ = canvas.print(x, y, faint, "... {d} above", .{window.above});
    }
}

const screen_module = @import("../screen.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const Canvas = screen_module.Canvas;
const Style = screen_module.Style;
const Fleet = model.Fleet;
const Model = model.Model;
const Severity = model.Severity;
const ShardRow = model.ShardRow;
const View = model.View;

/// Column origins for the full table, in the order the mock lists them.
///
/// Every value is drawn into its own column and clipped there. A number that
/// outgrows its column and truncates can still be recognised for what it is; a
/// number that runs into the column beside it merges with that one into a
/// figure that is neither of them, and nothing on screen says so.
///
/// The widths are sized for the figures a run actually produces. `joined`
/// carries two grouped counts and a slash, so `--clients 100000` across eight
/// shards prints `12,500/12,500`, which the twelve columns it used to have
/// could not hold; `drops` and `churn` reach seven figures on a long soak; and
/// `report.bytes` needs eleven at its widest.
const col_id: u16 = 0;
const col_joined: u16 = 5;
const col_play: u16 = 20;
const col_drops: u16 = 28;
const col_churn: u16 = 38;
const col_rx: u16 = 48;
const col_tx: u16 = 60;
const col_packets: u16 = 72;
const col_keepalive: u16 = 83;
const col_ring: u16 = 92;
const col_load: u16 = 104;
const load_width: u16 = 10;

/// The header cells that double as the sort menu: each names the sort column
/// `s` cycles to, so the strip and the sort can never drift apart.
const headers = [_]struct { column: model.SortColumn, x: u16 }{
    .{ .column = .id, .x = col_id },
    .{ .column = .joined, .x = col_joined },
    .{ .column = .play, .x = col_play },
    .{ .column = .drops, .x = col_drops },
    .{ .column = .reconnects, .x = col_churn },
    .{ .column = .rx, .x = col_rx },
    .{ .column = .tx, .x = col_tx },
    .{ .column = .packets, .x = col_packets },
    .{ .column = .keepalive, .x = col_keepalive },
    .{ .column = .ring, .x = col_ring },
};

/// The rail the drill-down keeps of the table: id, churn, load.
/// One table cell, clipped to the column it starts, so a wide value truncates
/// inside its own field instead of overwriting the one beside it. The column
/// runs to the start of the next one, less the space that separates them.
fn cell(canvas: Canvas, x: u16, y: u16, next_x: u16) Canvas {
    return canvas.sub(x, y, next_x -| x -| 1, 1);
}

const rail_width: u16 = 22;
const rail_churn: u16 = 5;
const rail_load: u16 = 12;
/// Where the detail starts: the rail plus its rule and a column of air.
const detail_x: u16 = rail_width + 2;

pub fn render(canvas: Canvas, data: *const Model, view: View) void {
    if (canvas.width() == 0 or canvas.height() == 0) return;
    if (view.drilled) renderDetail(canvas, data, view) else renderTable(canvas, data, view);
}

fn renderTable(canvas: Canvas, data: *const Model, view: View) void {
    const palette = data.palette();
    const text: Style = .{ .fg = palette.text };
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const height = canvas.height();
    const fleet = data.fleet;

    const per_shard: u64 = if (fleet.shard_count == 0)
        0
    else
        (fleet.requested + fleet.shard_count / 2) / fleet.shard_count;
    const summary_end = canvas.print(0, 1, dim, "{d} shards · {f} clients · about {f} each", .{
        fleet.shard_count,
        report.grouped(fleet.requested),
        report.grouped(per_shard),
    });

    const sort_hint = "   s sort";
    const sorted_width = 10 + screen_module.displayWidth(view.sort.label()) + 2 +
        screen_module.displayWidth(sort_hint);
    // Right-hand context is dropped rather than overprinted when the terminal
    // is too narrow to hold both halves of a line.
    if (canvas.width() -| sorted_width > summary_end) {
        var sorted_x = canvas.width() - sorted_width;
        sorted_x = canvas.text(sorted_x, 1, "sorted by ", dim);
        sorted_x = canvas.print(sorted_x, 1, text, "{s} ▾", .{view.sort.label()});
        _ = canvas.text(sorted_x, 1, sort_hint, faint);
    }

    for (headers) |header| {
        const style = if (header.column == view.sort) text else dim;
        _ = canvas.text(header.x, 3, header.column.label(), style);
    }
    _ = canvas.text(col_load, 3, "load", dim);

    // The rows start below the header and stop short of the totals, the two
    // spread lines and the footer.
    const rows_y: u16 = 4;
    const selected = data.selectedIndex(view);
    const window = rowWindow(data.order.len, selected, height -| 10);
    var y = rows_y;
    for (data.order[window.start..][0..window.count], 0..) |index, offset| {
        drawRow(canvas, data, y, &data.shards[index], window.start + offset == selected);
        y += 1;
    }
    if (window.below > 0 or window.above > 0) {
        writeWindowRemainder(canvas, col_id, y, window, faint);
        y += 1;
    }

    const limit = height -| 1;
    y += 1;
    if (y < limit) drawTotals(canvas, data, y);
    y += 2;
    if (y < limit) drawSpread(canvas, data, y);
    y += 1;
    if (y < limit) drawOutlier(canvas, data, y);

    const keys_end = canvas.text(0, limit, "↑↓ select   enter drill down   s sort   p pause   q quit", faint);
    if (canvas.width() -| 14 > keys_end) canvas.printRight(limit, faint, "{d} rows", .{data.order.len});
}

fn drawRow(canvas: Canvas, data: *const Model, y: u16, row: *const ShardRow, selected: bool) void {
    const palette = data.palette();
    const fleet = data.fleet;
    const severity = row.severity(fleet);
    const base: Style = if (selected)
        .{ .fg = palette.background, .bg = palette.text }
    else
        .{ .fg = palette.text };
    if (selected) canvas.repeat(0, y, canvas.width(), " ", base);

    const id_color = if (severity == .ok) palette.dim else severity.color(palette);
    _ = cell(canvas, col_id, y, col_joined).print(0, 0, tint(base, selected, id_color), "{d:0>2}{s}", .{ row.id, severity.marker() });
    _ = cell(canvas, col_joined, y, col_play).print(0, 0, base, "{f}/{f}", .{ report.grouped(row.joined), report.grouped(row.requested) });
    _ = cell(canvas, col_play, y, col_drops).print(0, 0, base, "{f}", .{report.grouped(row.play)});

    const churn_color = row.churnSeverity(fleet).color(palette);
    const churn_style = if (row.churnSeverity(fleet) == .ok) base else tint(base, selected, churn_color);
    _ = cell(canvas, col_drops, y, col_churn).print(0, 0, churn_style, "{f}", .{report.grouped(row.disconnects)});
    _ = cell(canvas, col_churn, y, col_rx).print(0, 0, churn_style, "{f}", .{report.grouped(row.reconnects)});

    _ = cell(canvas, col_rx, y, col_tx).print(0, 0, base, "{f}", .{report.bytes(row.rx_per_sec)});
    _ = cell(canvas, col_tx, y, col_packets).print(0, 0, base, "{f}", .{report.bytes(row.tx_per_sec)});
    _ = cell(canvas, col_packets, y, col_keepalive).print(0, 0, base, "{f}", .{report.grouped(report.rounded(row.packets_per_sec))});

    const keepalive = row.keepAliveSeverity();
    const keepalive_style = if (keepalive == .ok) base else tint(base, selected, keepalive.color(palette));
    _ = cell(canvas, col_keepalive, y, col_ring).print(0, 0, keepalive_style, "{d}ms", .{row.keep_alive_p99_ms});
    _ = cell(canvas, col_ring, y, col_load).print(0, 0, base, "{d}/{d}", .{ row.ring.peak_cq_ready, row.ring.peak_cq_entries });

    if (selected) {
        // A track behind a reversed row would read as a second bar, so the
        // selected row shows the filled part only.
        _ = widgets.bar(canvas, col_load, y, load_width, row.load, base);
    } else {
        const fill: Style = .{ .fg = if (severity == .ok) palette.chart else severity.color(palette) };
        widgets.gauge(canvas, col_load, y, load_width, row.load, fill, .{ .fg = palette.track });
    }
}

fn drawTotals(canvas: Canvas, data: *const Model, y: u16) void {
    const palette = data.palette();
    const text: Style = .{ .fg = palette.text };
    const fleet = data.fleet;

    _ = canvas.text(col_id, y, "all", .{ .fg = palette.dim });
    _ = cell(canvas, col_joined, y, col_play).print(0, 0, text, "{f}", .{report.grouped(fleet.joined)});
    _ = cell(canvas, col_play, y, col_drops).print(0, 0, text, "{f}", .{report.grouped(fleet.play)});
    _ = cell(canvas, col_drops, y, col_churn).print(0, 0, text, "{f}", .{report.grouped(fleet.disconnects)});
    _ = cell(canvas, col_churn, y, col_rx).print(0, 0, text, "{f}", .{report.grouped(fleet.reconnects)});
    _ = cell(canvas, col_rx, y, col_tx).print(0, 0, text, "{f}", .{report.bytes(fleet.rx_per_sec)});
    _ = cell(canvas, col_tx, y, col_packets).print(0, 0, text, "{f}", .{report.bytes(fleet.tx_per_sec)});
    _ = cell(canvas, col_packets, y, col_keepalive).print(0, 0, text, "{f}", .{report.grouped(report.rounded(fleet.packets_per_sec))});
    _ = cell(canvas, col_keepalive, y, col_ring).print(0, 0, text, "{d}ms", .{fleet.keep_alive.percentile(0.99)});
    _ = cell(canvas, col_ring, y, col_load).print(0, 0, text, "{d}/{d}", .{ fleet.ring.peak_cq_ready, fleet.ring.peak_cq_entries });
    _ = canvas.text(col_load, y, "fleet", .{ .fg = palette.faint });
}

fn drawSpread(canvas: Canvas, data: *const Model, y: u16) void {
    const palette = data.palette();
    const spread = data.receiveSpread();
    _ = canvas.text(0, y, "spread", .{ .fg = palette.dim });
    // Both ends carry the rate suffix. `report.bytes` and `report.byteRate`
    // pick their unit independently, so the usual "unit on the last term only"
    // range shorthand does not apply: dropping it off the low end left a size
    // against a rate, reading `rx 900.00 MiB - 1.20 GiB/s`.
    const after = canvas.print(11, y, .{ .fg = palette.dim }, "rx {f} - {f}", .{
        report.byteRate(spread.low),
        report.byteRate(spread.high),
    });

    const faint: Style = .{ .fg = palette.faint };
    if (spread.median <= 0) {
        _ = canvas.text(after, y, "   no receive traffic yet", faint);
        return;
    }
    const widest = @max(spread.high - spread.median, spread.median - spread.low) / spread.median;
    _ = canvas.print(after, y, faint, "   within {d:.0}% of the median{s}", .{
        widest * 100,
        if (widest < 0.25) ", no shard starved" else "",
    });
}

fn drawOutlier(canvas: Canvas, data: *const Model, y: u16) void {
    const palette = data.palette();
    const dim: Style = .{ .fg = palette.dim };
    _ = canvas.text(0, y, "outlier", dim);

    const busiest = busiestChurn(data) orelse {
        _ = canvas.text(11, y, "churn is even across the fleet", .{ .fg = palette.faint });
        return;
    };
    const severity = busiest.churnSeverity(data.fleet);
    const average = data.fleet.averageReconnectsPerShard();
    const ratio = if (average > 0) @as(f64, @floatFromInt(busiest.reconnects)) / average else 0;
    const after = canvas.print(11, y, .{ .fg = severity.color(palette) }, "{s} {d:0>2}", .{
        severity.marker(),
        busiest.id,
    });
    _ = canvas.print(after, y, dim, " carries {d:.1}x the fleet average churn", .{ratio});
}

fn renderDetail(canvas: Canvas, data: *const Model, view: View) void {
    const palette = data.palette();
    const faint: Style = .{ .fg = palette.faint };
    const height = canvas.height();
    const limit = height -| 1;
    const selected = data.selectedIndex(view);

    drawRail(canvas, data, selected);
    // A `for (1..limit)` here would be a reversed range on a pane one row tall,
    // which panics in a safe build and wraps to an unbounded loop in a fast one.
    var rule_row: u16 = 1;
    while (rule_row < limit) : (rule_row += 1) {
        canvas.set(rail_width, rule_row, "│", .{ .fg = palette.rule });
    }

    if (data.order.len == 0) {
        _ = canvas.text(detail_x, 1, "no shards", .{ .fg = palette.dim });
    } else {
        const row = &data.shards[data.order[selected]];
        drawDetail(canvas.sub(detail_x, 0, canvas.width() -| detail_x, height), data, view, row);
    }

    const keys_end = canvas.text(0, limit, if (view.drilled_from == .fleet)
        "↑↓ shard   esc back to fleet   c copy   q quit"
    else
        "↑↓ shard   esc back to table   c copy   q quit", faint);
    if (canvas.width() -| 18 > keys_end) canvas.printRight(limit, faint, "shard {d:0>2} of {d}", .{
        if (data.selectedRow(view)) |row| row.id else 0,
        data.order.len,
    });
}

fn drawRail(canvas: Canvas, data: *const Model, selected: usize) void {
    const palette = data.palette();
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const height = canvas.height();

    _ = canvas.text(col_id, 1, "id", dim);
    _ = canvas.text(rail_churn, 1, "churn", dim);
    _ = canvas.text(rail_load, 1, "load", dim);

    const window = rowWindow(data.order.len, selected, height -| 6);
    var y: u16 = 2;
    for (data.order[window.start..][0..window.count], 0..) |index, offset| {
        const row = &data.shards[index];
        const severity = row.severity(data.fleet);
        const is_selected = window.start + offset == selected;
        const base: Style = if (is_selected)
            .{ .fg = palette.background, .bg = palette.text }
        else
            .{ .fg = palette.text };
        if (is_selected) canvas.repeat(0, y, rail_width, " ", base);

        const id_color = if (severity == .ok) palette.dim else severity.color(palette);
        _ = cell(canvas, col_id, y, rail_churn).print(0, 0, tint(base, is_selected, id_color), "{d:0>2}{s}", .{ row.id, severity.marker() });
        _ = cell(canvas, rail_churn, y, rail_load).print(0, 0, base, "{f}", .{report.grouped(row.reconnects)});
        const fill: Style = if (is_selected)
            base
        else
            .{ .fg = if (severity == .ok) palette.ok_track else severity.color(palette) };
        _ = widgets.bar(canvas, rail_load, y, rail_width - rail_load, row.load, fill);
        y += 1;
    }
    if (window.below > 0 or window.above > 0) {
        writeWindowRemainder(canvas, col_id, y, window, faint);
        y += 1;
    }

    y += 1;
    if (y + 1 < height) {
        _ = canvas.text(0, y, "↑↓ walk", faint);
        _ = canvas.text(0, y + 1, "esc table", faint);
    }
}

fn drawDetail(canvas: Canvas, data: *const Model, view: View, row: *const ShardRow) void {
    const palette = data.palette();
    const text: Style = .{ .fg = palette.text };
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const ok: Style = .{ .fg = palette.ok };
    const fleet = data.fleet;

    var title = canvas.print(0, 1, .{ .fg = palette.text, .bold = true }, "shard {d:0>2}", .{row.id});
    title = canvas.print(title, 1, dim, "   {f} clients", .{report.grouped(row.requested)});
    if (concern(row, fleet)) |reason| {
        const severity = row.severity(fleet);
        const room = screen_module.displayWidth(reason) + 2;
        if (canvas.width() -| room > title) {
            canvas.printRight(1, .{ .fg = severity.color(palette) }, "{s} {s}", .{ severity.marker(), reason });
        }
    }

    _ = canvas.text(0, 3, "client states", dim);
    _ = canvas.text(0, 4, "connected", dim);
    _ = canvas.print(14, 4, ok, "{f}", .{report.grouped(row.connected)});
    _ = canvas.text(0, 5, "connecting", dim);
    _ = canvas.print(14, 5, count(text, faint, row.connecting), "{f}", .{report.grouped(row.connecting)});
    _ = canvas.text(0, 6, "waiting", dim);
    _ = canvas.print(14, 6, count(text, faint, row.waiting), "{f}", .{report.grouped(row.waiting)});
    _ = canvas.text(0, 7, "stopped", dim);
    _ = canvas.print(14, 7, count(text, faint, row.stopped), "{f}", .{report.grouped(row.stopped)});
    _ = canvas.text(0, 8, "phase play", dim);
    const play_style: Style = .{ .fg = row.playSeverity().color(palette) };
    const after_play = canvas.print(14, 8, play_style, "{f}", .{report.grouped(row.play)});
    _ = canvas.print(after_play, 8, faint, " / {f}", .{report.grouped(row.requested)});

    _ = canvas.text(32, 3, "traffic", dim);
    _ = canvas.text(32, 4, "rx/s", dim);
    _ = canvas.print(44, 4, .{ .fg = palette.text, .bold = true }, "{f}", .{report.bytes(row.rx_per_sec)});
    _ = canvas.text(32, 5, "tx/s", dim);
    _ = canvas.print(44, 5, text, "{f}", .{report.bytes(row.tx_per_sec)});
    _ = canvas.text(32, 6, "pkt/s", dim);
    _ = canvas.print(44, 6, text, "{f}", .{report.grouped(report.rounded(row.packets_per_sec))});
    _ = canvas.text(32, 7, "share", dim);
    const after_share = canvas.print(44, 7, text, "{d:.1}%", .{row.rx_share * 100});
    _ = canvas.text(after_share, 7, " of fleet", faint);
    _ = canvas.text(32, 8, "total rx", dim);
    _ = canvas.print(44, 8, text, "{f}", .{report.bytes(@floatFromInt(row.bytes_received))});

    _ = canvas.text(64, 3, "ring · churn", dim);
    _ = canvas.text(64, 4, "peak cq", dim);
    _ = canvas.print(76, 4, .{ .fg = row.ringSeverity().color(palette) }, "{d}/{d}", .{
        row.ring.peak_cq_ready,
        row.ring.peak_cq_entries,
    });
    _ = canvas.text(64, 5, "nobufs", dim);
    _ = canvas.print(76, 5, count(text, faint, row.ring.recv_nobufs), "{f}", .{report.grouped(row.ring.recv_nobufs)});
    _ = canvas.text(64, 6, "drops", dim);
    const churn_style: Style = .{ .fg = row.churnSeverity(fleet).color(palette) };
    _ = canvas.print(76, 6, churn_style, "{f}", .{report.grouped(row.disconnects)});
    _ = canvas.text(64, 7, "reconnects", dim);
    _ = canvas.print(76, 7, churn_style, "{f}", .{report.grouped(row.reconnects)});
    _ = canvas.text(64, 8, "ka p50/p99", dim);
    const after_p50 = canvas.print(76, 8, text, "{f}  ", .{widgets.millis(@floatFromInt(row.keep_alive_p50_ms))});
    _ = canvas.print(after_p50, 8, .{ .fg = row.keepAliveSeverity().color(palette) }, "{f}", .{
        widgets.millis(@floatFromInt(row.keep_alive_p99_ms)),
    });

    drawChart(canvas, data, view, row);

    const events_y: u16 = 15;
    _ = canvas.text(0, events_y, "recent events · this shard", dim);
    drawEvents(canvas, data, row, events_y + 1);
}

/// The shard's receive rate against the fleet's median, which is the number
/// that says whether this shard is carrying its share.
fn drawChart(canvas: Canvas, data: *const Model, view: View, row: *const ShardRow) void {
    const palette = data.palette();
    const faint: Style = .{ .fg = palette.faint };
    // Eleven columns, which is what `report.bytes` needs at its widest: nine
    // cut the unit off every rate from 100 of any unit up, so a 163 MiB/s run
    // labelled its axis `163.44 Mi`.
    const axis_x: u16 = 11;
    const chart_x: u16 = 13;
    const chart_y: u16 = 11;
    const rows: u16 = 2;
    // The caption sits on chart_y + rows, so the chart needs that row plus the
    // footer's; without the extra row the `now` label lands on the key hints.
    if (canvas.height() <= chart_y + rows + 1 or canvas.width() <= chart_x) return;

    const header_end = canvas.print(0, chart_y - 1, .{ .fg = palette.dim }, "receive rate · shard {d:0>2}", .{row.id});
    if (canvas.width() -| 26 > header_end) canvas.printRight(chart_y - 1, faint, "fleet median {f}", .{
        report.byteRate(data.receiveSpread().median),
    });

    var scratch: [1024]f32 = undefined;
    const width: u16 = @min(canvas.width() - chart_x, scratch.len);
    const samples = row.samples.window(view.span, scratch[0..width]);
    const maximum = row.samples.maximum(view.span);

    // The scale labels sit right up against the axis rule, so a wide value and
    // a bare zero line up the same way.
    widgets.chartAxis(canvas, axis_x, chart_y, rows, faint);
    canvas.sub(0, chart_y, axis_x, 1).printRight(0, faint, "{f}", .{report.bytes(maximum)});
    canvas.sub(0, chart_y + 1, axis_x, 1).printRight(0, faint, "0", .{});
    widgets.areaChart(
        canvas,
        chart_x,
        chart_y,
        width,
        rows,
        samples,
        maximum,
        .{ .fg = palette.chart },
        .{ .fg = palette.chart_deep },
    );
    _ = canvas.print(chart_x, chart_y + rows, faint, "-{s}", .{view.span.label()});
    canvas.printRight(chart_y + rows, faint, "now", .{});
}

fn drawEvents(canvas: Canvas, data: *const Model, row: *const ShardRow, start_y: u16) void {
    const palette = data.palette();
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };
    const limit = canvas.height() -| 1;

    var y = start_y;
    var index: usize = 0;
    while (index < data.log.len and y < limit) : (index += 1) {
        const event = data.log.at(index) orelse break;
        if (event.fleet or event.shard != row.id) continue;

        _ = canvas.print(0, y, faint, "{f}", .{widgets.stamp(event.at_ms)});
        const severity = eventSeverity(event);
        const label_style: Style = if (severity == .ok) .{ .fg = palette.text } else .{ .fg = severity.color(palette) };
        switch (event.kind) {
            .disconnect => _ = canvas.print(12, y, label_style, "{s} disconnect", .{event.category.label()}),
            .reconnect => _ = canvas.text(12, y, "reconnect scheduled", label_style),
            .keepalive => _ = canvas.print(12, y, label_style, "keepalive reply {d}ms", .{event.value}),
            .protocol_error => _ = canvas.text(12, y, "protocol error", label_style),
            else => _ = canvas.text(12, y, "entered play", label_style),
        }

        var name: [32]u8 = undefined;
        const after = canvas.print(34, y, dim, "{s}", .{data.username(event.client, &name)});
        switch (event.kind) {
            .reconnect => _ = canvas.print(after, y, faint, " · {s} · backoff {d}ms", .{
                event.category.label(),
                event.value,
            }),
            .entered_play => _ = canvas.print(after, y, faint, " · rejoin {d:.1}s", .{
                @as(f64, @floatFromInt(event.value)) / 1000,
            }),
            else => {},
        }
        y += 1;
    }
    if (y == start_y) _ = canvas.text(0, start_y, "none yet", faint);
}

/// A reversed row has already claimed both colors, so severity on it is carried
/// by the marker glyph alone.
fn tint(base: Style, selected: bool, color: theme.Rgb) Style {
    return if (selected) base else .{ .fg = color };
}

fn count(text: Style, faint: Style, value: u64) Style {
    return if (value == 0) faint else text;
}

/// The one line that says why this shard is worth looking at. Only the worst
/// signal is named; the numbers below carry the rest.
fn concern(row: *const ShardRow, fleet: Fleet) ?[]const u8 {
    if (row.churnSeverity(fleet) != .ok) return "churn above the fleet";
    if (row.ringSeverity() != .ok) return "ring pressure";
    if (row.keepAliveSeverity() != .ok) return "keepalive falling behind";
    if (row.playSeverity() != .ok) return "clients out of play";
    return null;
}

fn eventSeverity(event: telemetry.Event) Severity {
    return switch (event.kind) {
        .reconnect, .protocol_error => .watch,
        .disconnect => if (event.category == .server) .ok else .watch,
        else => .ok,
    };
}

/// The shard with the most reconnects, and only when it is far enough above the
/// fleet average to be worth naming.
fn busiestChurn(data: *const Model) ?*const ShardRow {
    var worst: ?*const ShardRow = null;
    for (data.shards) |*row| {
        if (row.reconnects == 0) continue;
        if (worst) |current| {
            if (row.reconnects <= current.reconnects) continue;
        }
        worst = row;
    }
    const row = worst orelse return null;
    if (row.churnSeverity(data.fleet) == .ok) return null;
    return row;
}

const testing = std.testing;
const Screen = screen_module.Screen;

test "both ends of the receive spread are labelled as rates" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 39);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 300 }, 3);
    defer data.deinit();
    // Ends far enough apart to scale to different units, which is what the
    // "unit on the last term only" shorthand cannot survive.
    const rates = [_]f64{ 900 * 1024 * 1024, 1024 * 1024 * 1024, 1536 * 1024 * 1024 };
    for (data.shards, rates) |*row, rate| {
        row.rx_per_sec = rate;
        row.requested = 100;
        row.joined = 100;
        row.play = 100;
    }

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, .{ .pane = .shards });

    // The low end used to render through `report.bytes`, giving
    // `rx 900.00 MiB - 1.50 GiB/s`: a size against a rate.
    try testing.expect(screen.contains("rx 900.00 MiB/s - 1.50 GiB/s"));
}

test "the table lists shards in the model's sorted order" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 39);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 900 }, 3);
    defer data.deinit();
    data.fleet.reconnects = 40;
    for (data.shards, [_]u64{ 10, 1, 30 }) |*row, reconnects| {
        row.reconnects = reconnects;
        row.requested = 300;
        row.joined = 300;
        row.play = 300;
    }
    data.sortRows(.reconnects, true);

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, .{ .pane = .shards });

    var buffer: [1024]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, screen.rowText(4, &buffer), "02"));
    try testing.expect(std.mem.startsWith(u8, screen.rowText(5, &buffer), "00"));
    try testing.expect(std.mem.startsWith(u8, screen.rowText(6, &buffer), "01"));
    // The totals row and the spread lines follow the last shard.
    try testing.expect(screen.contains("all"));
    try testing.expect(screen.contains("spread"));
    try testing.expect(screen.contains("3 rows"));
}

test "the drill-down shows the selected shard's detail" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 39);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 800 }, 2);
    defer data.deinit();
    data.shards[1].requested = 400;
    data.shards[1].connected = 397;
    data.shards[1].play = 397;
    data.shards[1].ring = .{ .peak_cq_ready = 398, .peak_cq_entries = 4096 };
    data.log.push(.{ .kind = .keepalive, .shard = 1, .client = 1226, .value = 19, .at_ms = 251_902 });

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, .{ .pane = .shards, .drilled = true, .selected = 1 });

    try testing.expect(screen.contains("shard 01"));
    try testing.expect(screen.contains("client states"));
    try testing.expect(screen.contains("398/4096"));
    try testing.expect(screen.contains("keepalive reply 19ms"));
    try testing.expect(screen.contains("Zion1227"));
    try testing.expect(screen.contains("shard 01 of 2"));
}

test "a pane too short for the drill-down clips instead of looping" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();

    var data = try Model.init(testing.allocator, .{ .client_count = 40 }, 2);
    defer data.deinit();

    // The drill-down's rule ran `for (1..height -| 1)`, which reverses on a pane
    // one row tall: a panic in a safe build, an unbounded loop in a fast one.
    // Every size down to nothing has to render and return.
    for ([_][2]u16{ .{ 1, 1 }, .{ 120, 1 }, .{ 120, 2 }, .{ 120, 3 }, .{ 3, 8 } }) |size| {
        try screen.resize(size[0], size[1]);
        screen.clear(.{ .fg = theme.running.text });
        const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
        for ([_]bool{ false, true }) |drilled| {
            for ([_]model.Pane{ .fleet, .shards }) |from| {
                render(canvas, &data, .{
                    .pane = .shards,
                    .drilled = drilled,
                    .drilled_from = from,
                    .selected = 1,
                });
            }
        }
    }

    // A canvas with no cells at all is a no-op rather than a draw off the edge.
    try screen.resize(40, 10);
    screen.clear(.{ .fg = theme.running.text });
    const empty: Canvas = .{ .screen = &screen, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
    render(empty, &data, .{ .pane = .shards, .drilled = true });
}

test "a fleet taller than the pane says how many rows it is not showing" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 24);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 6400 }, 64);
    defer data.deinit();

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    render(canvas, &data, .{ .pane = .shards });

    // Thirteen rows fit above the count line, which accounts for the rest.
    try testing.expect(screen.contains("... 51 more below"));
    try testing.expect(screen.contains("64 rows"));
    // The totals row still lands above the footer rather than being pushed off.
    try testing.expect(screen.contains("all"));
}

test "the row window scrolls to keep the selection visible" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    // A fleet that fits has nothing off screen in either direction.
    try testing.expectEqual(
        RowWindow{ .start = 0, .count = 12, .above = 0, .below = 0 },
        rowWindow(12, 0, 20),
    );
    // The last visible slot is reserved for the remainder line.
    const top = rowWindow(64, 0, 15);
    try testing.expectEqual(@as(usize, 0), top.start);
    try testing.expectEqual(@as(usize, 14), top.count);
    try testing.expectEqual(@as(usize, 50), top.below);
    try testing.expectEqual(@as(usize, 0), top.above);
    // Walking past the bottom scrolls rather than losing the selection.
    const walked = rowWindow(64, 40, 15);
    try testing.expectEqual(@as(usize, 27), walked.start);
    try testing.expect(walked.start + walked.count > 40);
    try testing.expectEqual(@as(usize, 50), rowWindow(64, 63, 15).start);
}

test "the remainder counts down as the selection walks the fleet" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    // The count is a property of where the window sits, not of the fleet size,
    // so moving the cursor has to move it.
    const first = rowWindow(64, 0, 15);
    const middle = rowWindow(64, 40, 15);
    const last = rowWindow(64, 63, 15);

    try testing.expect(first.below > middle.below);
    try testing.expect(middle.below > last.below);
    // At the bottom nothing remains below, and everything skipped is above.
    try testing.expectEqual(@as(usize, 0), last.below);
    try testing.expectEqual(@as(usize, 50), last.above);
    // Every row is always accounted for.
    for ([_]RowWindow{ first, middle, last }) |window| {
        try testing.expectEqual(@as(usize, 64), window.above + window.count + window.below);
    }
}

test "a five-figure fleet keeps every column's number whole" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(140, 39);
    screen.clear(.{ .fg = theme.running.text });

    // `--clients 100000` on an eight-core box: the counts a load test of that
    // size prints are wider than the columns used to be, and a value that runs
    // into the one beside it merges the two into a figure that is neither.
    var data = try Model.init(testing.allocator, .{ .client_count = 100_000 }, 8);
    defer data.deinit();
    for (data.shards) |*row| {
        row.requested = 12_500;
        row.joined = 12_500;
        row.play = 12_500;
        row.disconnects = 1_234_567;
        row.reconnects = 2_345_678;
    }

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .shards });

    try testing.expect(screen.contains("12,500/12,500"));
    try testing.expect(screen.contains("1,234,567"));
    try testing.expect(screen.contains("2,345,678"));
}

test "a chart axis label keeps the unit it is measuring in" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = Screen.init(testing.allocator);
    defer screen.deinit();
    try screen.resize(140, 39);
    screen.clear(.{ .fg = theme.running.text });

    var data = try Model.init(testing.allocator, .{ .client_count = 200 }, 2);
    defer data.deinit();
    // Any rate at or above 100 of its unit needs ten columns, and above 1000
    // eleven; a narrower gutter drops the suffix, which is the half of the
    // label that says what the number means.
    data.shards[0].samples.push(171_400_000, 0);

    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .shards, .drilled = true });

    try testing.expect(screen.contains("163.46 MiB"));
}
