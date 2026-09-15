//! The event log.
//!
//! Everything the progress line has to swallow while it owns stdout: joins,
//! drops, reconnects, protocol failures. Newest first, because during a run the
//! question is always "what just happened", never "what happened first".
//!
//! The filter strip's counts come from the buffer's own tallies rather than a
//! rescan, so offering six live counts costs nothing per frame.

const std = @import("std");
const report = @import("../../report.zig");
const telemetry = @import("../../telemetry.zig");
const model = @import("../model.zig");
const screen_module = @import("../screen.zig");
const theme = @import("../theme.zig");
const widgets = @import("../widgets.zig");

const Canvas = screen_module.Canvas;
const Style = screen_module.Style;
const Model = model.Model;
const View = model.View;
const Palette = theme.Palette;

/// Fixed column starts. Timestamp, shard and event kind are the fields an eye
/// scans down, so they are ruled; the subject and its detail flow after them
/// because a detail is prose about its subject, not a column of its own.
const shard_column: u16 = 12;
const kind_column: u16 = 20;
const subject_column: u16 = 40;
const gap: u16 = 2;

/// Rows the filter strip, follow line and footer occupy together, whatever the
/// terminal size. What is left over is the event list.
const chrome_rows: u16 = 7;

/// Ceiling on the events collected per frame, so the page is a stack array. No
/// terminal shows this many log rows at once.
const max_rows = 128;

pub fn render(canvas: Canvas, data: *const Model, view: View) void {
    const height = canvas.height();
    if (height == 0 or canvas.width() == 0) return;
    const palette = data.palette();

    if (height > 1) renderFilters(canvas, data, view, 1);

    const list_top: u16 = 3;
    const list_rows = @min(height -| chrome_rows, max_rows);
    var page: [max_rows]telemetry.Event = undefined;
    const events = data.log.collect(view.log_filter, view.log_scroll, page[0..list_rows]);
    for (events, 0..) |event, index| {
        renderEvent(canvas, data, list_top + @as(u16, @intCast(index)), event);
    }
    if (events.len == 0 and list_rows > 0) {
        const dim: Style = .{ .fg = palette.dim };
        if (view.log_filter == .all) {
            _ = canvas.text(0, list_top, "no events yet", dim);
        } else {
            _ = canvas.print(0, list_top, dim, "no {s} events yet", .{view.log_filter.label()});
        }
    }

    // The bottom block is anchored to the last row. Below these heights it
    // would land on the filter strip, so it is dropped instead.
    if (height >= 5) renderFollow(canvas, data, view, height - 3);
    if (height >= 3) renderFooter(canvas, palette, height - 1);
}

fn renderFilters(canvas: Canvas, data: *const Model, view: View, y: u16) void {
    const palette = data.palette();
    var x: u16 = 0;
    for (std.enums.values(model.LogFilter)) |filter| {
        const style: Style = if (filter == view.log_filter)
            .{ .fg = palette.background, .bg = palette.text, .bold = true }
        else
            .{ .fg = palette.dim };
        x = canvas.print(x, y, style, " {s} {f} ", .{ filter.label(), report.grouped(data.log.count(filter)) });
        // The gap is left blank rather than drawn: chips change width as their
        // counts grow, and the cleared frame is already the pane's background.
        x +|= 1;
    }
    canvas.textRight(y, "←→ tab cycle", .{ .fg = palette.faint });
}

fn renderEvent(canvas: Canvas, data: *const Model, y: u16, event: telemetry.Event) void {
    const palette = data.palette();
    const dim: Style = .{ .fg = palette.dim };
    const faint: Style = .{ .fg = palette.faint };

    _ = canvas.print(0, y, faint, "{f}", .{widgets.stamp(event.at_ms)});
    if (event.fleet) {
        _ = canvas.text(shard_column, y, "all", dim);
    } else {
        _ = canvas.print(shard_column, y, dim, "{d:0>2}", .{event.shard});
    }
    _ = canvas.text(kind_column, y, kindText(event), .{ .fg = kindColor(event, palette) });

    var name_buffer: [64]u8 = undefined;
    const name = data.username(event.client, &name_buffer);

    switch (event.kind) {
        .run_started => {
            const end = canvas.text(subject_column, y, data.info.target, dim);
            _ = canvas.print(end +| gap, y, faint, "{f} clients · {d} {s}", .{
                report.grouped(data.info.client_count),
                data.fleet.shard_count,
                if (data.fleet.shard_count == 1) "shard" else "shards",
            });
        },
        .compression_on => {
            const end = canvas.text(subject_column, y, "enabled", dim);
            _ = canvas.print(end +| gap, y, faint, "above {f}", .{report.bytes(@floatFromInt(event.value))});
        },
        .entered_play => {
            const end = canvas.text(subject_column, y, name, dim);
            // A first join has no rejoin time to report; a reconnect does.
            if (event.value != 0) {
                _ = canvas.print(end +| gap, y, faint, "rejoin {d:.1}s", .{seconds(event.value)});
            }
        },
        .full_join => {
            const end = canvas.print(subject_column, y, dim, "{f}/{f}", .{
                report.grouped(event.value),
                report.grouped(data.info.client_count),
            });
            _ = canvas.print(end +| gap, y, faint, "in {d:.1}s", .{seconds(event.at_ms)});
        },
        .disconnect, .protocol_error => {
            const end = canvas.text(subject_column, y, name, dim);
            _ = canvas.text(end +| gap, y, event.category.label(), faint);
        },
        .reconnect => {
            const end = canvas.text(subject_column, y, name, dim);
            _ = canvas.print(end +| gap, y, faint, "{s} · backoff {d}ms", .{
                event.category.label(),
                event.value,
            });
        },
        .keepalive => {
            const end = canvas.print(subject_column, y, dim, "reply {d}ms", .{event.value});
            _ = canvas.text(end +| gap, y, name, faint);
        },
    }
}

fn renderFollow(canvas: Canvas, data: *const Model, view: View, y: u16) void {
    const palette = data.palette();
    const faint: Style = .{ .fg = palette.faint };

    const after_state = if (view.log_follow)
        canvas.text(0, y, "▶ following", .{ .fg = palette.ok })
    else
        canvas.print(0, y, .{ .fg = palette.warn }, "■ scrolled back {f}", .{report.grouped(view.log_scroll)});

    var x = canvas.print(after_state +| gap, y, faint, "newest first · {f} events", .{
        report.grouped(data.log.total),
    });
    // Says why scrolling stops before the run's first event.
    if (data.log.len < data.log.total) {
        x = canvas.print(x, y, faint, " · {f} retained", .{report.grouped(data.log.len)});
    }
    if (data.log.dropped > 0) {
        _ = canvas.print(x, y, faint, " · {f} dropped by a full shard ring", .{
            report.grouped(data.log.dropped),
        });
    }
}

fn renderFooter(canvas: Canvas, palette: Palette, y: u16) void {
    const faint: Style = .{ .fg = palette.faint };
    _ = canvas.text(0, y, "↑↓ scroll   ←→ filter   f follow   p pause   q quit", faint);
    canvas.printRight(y, faint, "log buffer {f} lines", .{report.grouped(model.log_capacity)});
}

fn kindText(event: telemetry.Event) []const u8 {
    return switch (event.kind) {
        .run_started => "run started",
        .compression_on => "compression",
        .entered_play => "entered play",
        .full_join => "full join",
        // Named apart because the two read completely differently: the server
        // chose to drop this client, rather than the link failing under it.
        .disconnect => if (event.category == .server) "server disconnect" else "disconnect",
        .reconnect => "reconnect",
        .keepalive => "keepalive",
        .protocol_error => "protocol error",
    };
}

/// The row's hue only restates what its own wording already says, so nothing is
/// lost on a monochrome terminal or to a reader who cannot separate the hues.
fn kindColor(event: telemetry.Event, palette: Palette) theme.Rgb {
    return switch (event.kind) {
        .full_join => palette.ok,
        .disconnect, .reconnect => palette.warn,
        .protocol_error => palette.bad,
        // Warm at the threshold the shards pane uses, so a reply the log calls
        // slow is one that pane calls slow. Deliberately not `severity.color`:
        // a second hue here would say something the wording does not.
        .keepalive => if (model.keepAliveSeverityFor(event.value) != .ok) palette.warn else palette.text,
        .run_started, .compression_on, .entered_play => palette.text,
    };
}

fn seconds(ms: u64) f64 {
    return @as(f64, @floatFromInt(ms)) / 1000.0;
}

fn testModel(allocator: std.mem.Allocator) !Model {
    return Model.init(allocator, .{
        .target = "127.0.0.1:25565",
        .client_count = 5000,
        .username_prefix = "Zion",
    }, 12);
}

test "the log lists matching events newest first" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);

    var data = try testModel(std.testing.allocator);
    defer data.deinit();
    data.log.push(.{ .kind = .run_started, .fleet = true, .at_ms = 0 });
    data.log.push(.{ .kind = .entered_play, .shard = 7, .client = 3340, .value = 5800, .at_ms = 251_440 });
    data.log.push(.{ .kind = .keepalive, .shard = 2, .client = 1226, .value = 19, .at_ms = 251_902 });

    screen.clear(.{ .fg = theme.running.text, .bg = theme.running.background });
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .log });

    var buffer: [512]u8 = undefined;
    const newest = screen.rowText(3, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, newest, "04:11.902") != null);
    try std.testing.expect(std.mem.indexOf(u8, newest, "keepalive") != null);
    try std.testing.expect(std.mem.indexOf(u8, newest, "reply 19ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, newest, "Zion1227") != null);

    const older = screen.rowText(4, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, older, "entered play") != null);
    try std.testing.expect(std.mem.indexOf(u8, older, "Zion3341") != null);
    try std.testing.expect(std.mem.indexOf(u8, older, "rejoin 5.8s") != null);

    // The fleet-wide event names no shard.
    const oldest = screen.rowText(5, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, oldest, "run started") != null);
    try std.testing.expect(std.mem.indexOf(u8, oldest, "all") != null);
    try std.testing.expect(std.mem.indexOf(u8, oldest, "5,000 clients · 12 shards") != null);
}

test "a filter narrows the list and the strip counts what it kept" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);

    var data = try testModel(std.testing.allocator);
    defer data.deinit();
    data.log.push(.{ .kind = .entered_play, .shard = 1, .client = 0, .at_ms = 1_000 });
    data.log.push(.{ .kind = .entered_play, .shard = 1, .client = 1, .at_ms = 2_000 });
    data.log.push(.{ .kind = .disconnect, .category = .server, .shard = 2, .client = 890, .at_ms = 3_000 });
    data.log.push(.{ .kind = .reconnect, .category = .transport, .shard = 2, .client = 890, .value = 200, .at_ms = 4_000 });

    screen.clear(.{ .fg = theme.running.text, .bg = theme.running.background });
    render(.{ .screen = &screen, .rect = screen.bounds() }, &data, .{ .pane = .log, .log_filter = .drops });

    var buffer: [512]u8 = undefined;
    const strip = screen.rowText(1, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, strip, "all 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, strip, "joins 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, strip, "drops 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, strip, "protocol 0") != null);

    // Only the disconnect survives the filter, and the category stands in for
    // the server's own text, which the event does not carry.
    const only = screen.rowText(3, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, only, "server disconnect") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, "Zion891") != null);
    try std.testing.expect(std.mem.indexOf(u8, only, "server") != null);

    const empty = screen.rowText(4, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, empty, "entered play") == null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "reconnect") == null);
}

test "the status line follows or reports how far back it is held" {
    if (comptime !@import("../../features.zig").tui) return error.SkipZigTest;
    var screen = screen_module.Screen.init(std.testing.allocator);
    defer screen.deinit();
    try screen.resize(120, 40);

    var data = try testModel(std.testing.allocator);
    defer data.deinit();
    for (0..3) |index| data.log.push(.{ .kind = .entered_play, .at_ms = index * 1000 });
    data.log.dropped = 12;

    const canvas: Canvas = .{ .screen = &screen, .rect = screen.bounds() };
    var buffer: [512]u8 = undefined;

    screen.clear(.{ .fg = theme.running.text, .bg = theme.running.background });
    render(canvas, &data, .{ .pane = .log });
    const following = screen.rowText(37, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, following, "▶ following") != null);
    try std.testing.expect(std.mem.indexOf(u8, following, "newest first · 3 events") != null);
    try std.testing.expect(std.mem.indexOf(u8, following, "12 dropped") != null);

    screen.clear(.{ .fg = theme.running.text, .bg = theme.running.background });
    render(canvas, &data, .{ .pane = .log, .log_follow = false, .log_scroll = 2 });
    const held = screen.rowText(37, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, held, "scrolled back 2") != null);

    // The scrolled page starts two events further into history.
    const row = screen.rowText(3, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, row, "00:00.000") != null);

    const footer = screen.rowText(39, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "←→ filter") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "log buffer 4,096 lines") != null);
}
