//! The full-screen dashboard.
//!
//! Compiled only when the `tui` feature is on. The whole module reduces to a
//! handful of empty stubs otherwise, so `pool.zig` and `main.zig` carry one
//! shape of call regardless of the build.
//!
//! The dashboard runs on the main thread while the shards run on theirs. It
//! reads published telemetry, never shard-owned state, so a slow terminal can
//! never slow the fleet down.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const features = @import("features.zig");
const telemetry = @import("telemetry.zig");
const report = @import("report.zig");
const client_table = @import("client_table.zig");
const stats_module = @import("stats.zig");

pub const enabled = features.tui;

pub const model = @import("tui/model.zig");
const term_module = @import("tui/term.zig");
const screen_module = @import("tui/screen.zig");
const theme = @import("tui/theme.zig");
const widgets = @import("tui/widgets.zig");

const panes = struct {
    const fleet = @import("tui/panes/fleet.zig");
    const shards = @import("tui/panes/shards.zig");
    const traffic = @import("tui/panes/traffic.zig");
    const diagnostics = @import("tui/panes/diagnostics.zig");
    const log = @import("tui/panes/log.zig");
    const overlay = @import("tui/panes/overlay.zig");
};

const Model = model.Model;
const View = model.View;
const Canvas = screen_module.Canvas;
const Style = screen_module.Style;

/// Repaint cadence. Fast enough to feel live, slow enough that the diffing
/// renderer emits only a few hundred bytes a frame.
const frame_interval_ms: u64 = 50;

/// Peaks worth keeping in scrollback once the alternate screen is released.
pub const Summary = struct {
    valid: bool = false,
    peak_rx_per_sec: f64 = 0,
    peak_rx_at_ms: u64 = 0,
    peak_packets_per_sec: f64 = 0,
    peak_packets_at_ms: u64 = 0,
    busiest_shard: u16 = 0,
    busiest_reconnects: u64 = 0,
    busiest_keepalive_p99_ms: u64 = 0,
    events_seen: u64 = 0,
};

/// Created by `main`, handed to `pool.run`, read back afterwards. Keeping the
/// summary here rather than in `Stats` leaves the stats block that lands in
/// scrollback byte-for-byte what it has always been.
pub const Dashboard = struct {
    info: model.RunInfo = .{},
    summary: Summary = .{},
};

/// Whether a dashboard should be opened for this run. A redirected stdout gets
/// the plain progress line, exactly as before.
pub fn shouldRun(io: Io, requested: bool) bool {
    if (comptime !enabled) return false;
    if (!requested or builtin.is_test) return false;
    if (!(Io.File.stdout().isTty(io) catch false)) return false;
    // The dashboard drives stdin as well: `Term.init` puts it in raw mode and
    // reads keys from it. A redirected or closed stdin can do neither, and by
    // the time `Term.init` fails the progress line has already been given up,
    // so the run would be left with no output at all. `isTty` reports a closed
    // descriptor as false, which also keeps `tcgetattr` off its EBADF path.
    if (!(Io.File.stdin().isTty(io) catch false)) return false;
    // A terminal that will not report its size cannot be drawn on; the progress
    // line is a better answer than a blank alternate screen for a whole run.
    return term_module.windowSize() != null;
}

/// Restores the terminal from a signal handler or a panic. Safe to call when
/// no dashboard is open.
pub fn emergencyRestore() void {
    if (comptime !enabled) return;
    term_module.emergencyRestore();
}

/// Drives the dashboard until the user quits or every shard finishes.
/// `request_stop` is the pool's shutdown flag: quitting the dashboard stops the
/// run the same way Ctrl-C does.
pub fn run(
    io: Io,
    allocator: std.mem.Allocator,
    dashboard: *Dashboard,
    shards: []telemetry.Shard,
    request_stop: *std.atomic.Value(bool),
) void {
    if (comptime !enabled) return;
    App.drive(io, allocator, dashboard, shards, request_stop) catch |err| {
        // A dashboard failure must never take the run with it: restore the
        // terminal, say why, and let the run finish headless.
        term_module.emergencyRestore();
        var buffer: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&buffer);
        writer.print("warning: dashboard stopped ({t}); the run continues\n", .{err}) catch {};
        Io.File.stderr().writeStreamingAll(io, writer.buffered()) catch {};
    };
}

const App = struct {
    io: Io,
    term: term_module.Term,
    screen: screen_module.Screen,
    data: Model,
    view: View = .{},
    shards: []telemetry.Shard,
    request_stop: *std.atomic.Value(bool),
    started_ms: u64,
    last_sample_ms: u64 = 0,
    /// Set by `q`; distinguishes a user quit from every shard finishing.
    quit: bool = false,
    /// Feedback for actions with no visible result of their own, such as copy.
    notice: [64]u8 = @splat(0),
    notice_len: usize = 0,
    notice_until_ms: u64 = 0,

    fn drive(
        io: Io,
        allocator: std.mem.Allocator,
        dashboard: *Dashboard,
        shards: []telemetry.Shard,
        request_stop: *std.atomic.Value(bool),
    ) !void {
        var app: App = .{
            .io = io,
            .term = try term_module.Term.init(io),
            .screen = screen_module.Screen.init(allocator),
            .data = try Model.init(allocator, dashboard.info, shards.len),
            .shards = shards,
            .request_stop = request_stop,
            .started_ms = nowMs(io),
        };
        // One palette for the whole run, so the padding around the grid is
        // handed to the terminal once here rather than compared every frame.
        // OSC 11 is sticky; a resize does not need it re-sent.
        app.term.setDefaultBackground(app.data.palette().background);

        // Declared so the terminal is restored first: anything these teardowns
        // print must land on the real screen, not the alternate one.
        defer app.data.deinit();
        defer app.screen.deinit();
        defer app.term.deinit();

        // The first pane the build can actually show; a minimal build has no
        // traffic or diagnostics data to land on.
        app.view.pane = .fleet;
        app.view.sort = .reconnects;

        app.data.log.push(.{
            .kind = .run_started,
            .fleet = true,
            .value = dashboard.info.client_count,
        });

        while (true) {
            const now = nowMs(io) -| app.started_ms;
            app.handleKeys(now);
            if (app.quit) break;

            app.drainLog(shards);
            if (!app.view.paused and now -| app.last_sample_ms >= model.sample_interval_ms) {
                app.last_sample_ms = now;
                app.data.update(shards, now);
                app.data.sortRowsKeepingSelection(&app.view, app.view.sort, app.view.sort != .id);
            }

            try app.render(now);

            if (app.allShardsDone()) break;
            if (request_stop.load(.monotonic)) break;
            Io.sleep(io, Io.Duration.fromMilliseconds(frame_interval_ms), .awake) catch break;
        }

        // A user-driven quit stops the fleet; shards finishing on their own
        // means the run already ended.
        if (app.quit) request_stop.store(true, .monotonic);

        dashboard.summary = app.summarize();
    }

    /// Drains the shards' event rings and holds a scrolled-back reader on the
    /// events they were reading.
    ///
    /// `log_scroll` is an offset from the newest match, not an anchor on an
    /// event, so every match that arrives slides the page one row under
    /// someone who is reading it. Pausing cannot stand in for this: the drain
    /// has to keep running whatever the view is doing, or a shard's 256-slot
    /// ring backs up and starts dropping.
    fn drainLog(app: *App, shards: []telemetry.Shard) void {
        const before = app.data.log.count(app.view.log_filter);
        app.data.drainEvents(shards);
        if (app.view.log_scroll == 0) return;
        const arrived: usize = @intCast(app.data.log.count(app.view.log_filter) -| before);
        if (arrived == 0) return;
        const retained = app.data.log.matching(app.view.log_filter);
        app.view.log_scroll = @min(app.view.log_scroll +| arrived, retained -| 1);
    }

    fn allShardsDone(app: *const App) bool {
        for (app.shards) |*shard| {
            if (!shard.progress.done.load(.acquire)) return false;
        }
        return true;
    }

    fn summarize(app: *const App) Summary {
        var summary: Summary = .{
            .valid = true,
            .peak_rx_per_sec = app.data.fleet.peak_rx_per_sec,
            .peak_rx_at_ms = app.data.fleet.peak_rx_at_ms,
            .peak_packets_per_sec = app.data.fleet.peak_packets_per_sec,
            .peak_packets_at_ms = app.data.fleet.peak_packets_at_ms,
            .events_seen = app.data.log.total,
        };
        for (app.data.shards) |row| {
            if (row.reconnects < summary.busiest_reconnects) continue;
            summary.busiest_shard = row.id;
            summary.busiest_reconnects = row.reconnects;
            summary.busiest_keepalive_p99_ms = row.keep_alive_p99_ms;
        }
        return summary;
    }

    fn handleKeys(app: *App, now_ms: u64) void {
        var keys: [16]term_module.Key = undefined;
        const count = app.term.readKeys(&keys);
        for (keys[0..count]) |key| app.handleKey(key, now_ms);
    }

    fn handleKey(app: *App, key: term_module.Key, now_ms: u64) void {
        // The overlay swallows navigation while it is open: only closing it and
        // its own actions apply.
        if (app.view.overlay) {
            switch (key) {
                .escape => app.view.overlay = false,
                .char => |c| switch (c) {
                    's', 'q' => app.view.overlay = false,
                    'c' => app.copyStats(now_ms),
                    else => {},
                },
                else => {},
            }
            return;
        }

        switch (key) {
            .char => |c| switch (c) {
                'q' => app.quit = true,
                '1'...'5' => app.view.selectPane(@fromBackingInt(@intCast(c - '1'))),
                // The shards pane spends `s` on its sort column, so the stats
                // overlay is reachable from every other pane.
                's' => if (app.view.pane == .shards) app.cycleSort() else {
                    app.view.overlay = true;
                },
                ' ' => app.view.toggleAlerts(),
                'p' => app.view.paused = !app.view.paused,
                'f' => app.view.toggleFollow(),
                'c' => app.copyStats(now_ms),
                else => {},
            },
            .tab => if (app.view.pane == .log) {
                app.view.log_filter = app.view.log_filter.next();
                app.view.log_scroll = 0;
            },
            .up => app.moveSelection(-1),
            .down => app.moveSelection(1),
            .page_up => app.moveSelection(-10),
            .page_down => app.moveSelection(10),
            // The log pane has no chart to span, so its arrows walk the filter
            // strip instead.
            .left => if (app.view.pane == .log) {
                app.view.log_filter = app.view.log_filter.previous();
                app.view.log_scroll = 0;
            } else {
                app.view.span = app.view.span.previous();
            },
            .right => if (app.view.pane == .log) {
                app.view.log_filter = app.view.log_filter.next();
                app.view.log_scroll = 0;
            } else {
                app.view.span = app.view.span.next();
            },
            .enter => app.view.drillDown(),
            .escape => _ = app.view.back(),
            .home => app.jumpSelection(.first),
            .end => app.jumpSelection(.last),
            else => {},
        }
    }

    fn cycleSort(app: *App) void {
        app.view.sort = app.view.sort.next();
        app.data.sortRowsKeepingSelection(&app.view, app.view.sort, app.view.sort != .id);
    }

    /// Home and End, which address whatever the arrows address: the window
    /// into history on the log pane, the shard selection everywhere else.
    /// Beside `moveSelection` because the two answer for the same keys and had
    /// drifted apart, leaving Home and End moving a shard selection the log
    /// pane does not show.
    fn jumpSelection(app: *App, edge: enum { first, last }) void {
        if (app.view.pane == .log) {
            app.view.scrollLog(switch (edge) {
                .first => std.math.minInt(i32),
                .last => std.math.maxInt(i32),
            }, app.data.log.matching(app.view.log_filter));
            return;
        }
        if (app.data.order.len == 0) return;
        app.view.selected = switch (edge) {
            .first => 0,
            .last => app.data.order.len - 1,
        };
    }

    fn moveSelection(app: *App, delta: i32) void {
        if (app.view.pane == .log) {
            // The log lists newest first, so down walks into history and up
            // walks back toward the newest event.
            app.view.scrollLog(delta, app.data.log.matching(app.view.log_filter));
            return;
        }
        if (app.data.order.len == 0) return;
        const selected: i64 = @as(i64, @intCast(app.view.selected)) + delta;
        app.view.selected = @intCast(std.math.clamp(selected, 0, @as(i64, @intCast(app.data.order.len - 1))));
    }

    /// Copies the stats block to the system clipboard with OSC 52, which works
    /// over ssh and inside multiplexers that allow it. There is no way to know
    /// whether the terminal honoured it, so the notice says what was sent.
    fn copyStats(app: *App, now_ms: u64) void {
        var text_buffer: [4096]u8 = undefined;
        var text: Io.Writer = .fixed(&text_buffer);
        report.writeStats(&text, app.statsSnapshot()) catch {};
        const payload = text.buffered();

        var encoded_buffer: [8192]u8 = undefined;
        const encoder = std.base64.standard.Encoder;
        if (encoder.calcSize(payload.len) > encoded_buffer.len) return;
        const encoded = encoder.encode(&encoded_buffer, payload);

        app.term.write("\x1b]52;c;") catch return;
        app.term.write(encoded) catch return;
        app.term.write("\x07") catch return;
        app.setNotice("stats copied to the clipboard", now_ms);
    }

    fn setNotice(app: *App, text: []const u8, now_ms: u64) void {
        const length = @min(text.len, app.notice.len);
        @memcpy(app.notice[0..length], text[0..length]);
        app.notice_len = length;
        app.notice_until_ms = now_ms + 2000;
    }

    /// Builds the same `Stats` shape `report.writeStats` prints at the end of a
    /// run, so a mid-run copy is identical to what lands in scrollback.
    fn statsSnapshot(app: *const App) client_table.Stats {
        const fleet = app.data.fleet;
        var stats: client_table.Stats = .{
            .requested = fleet.requested,
            .connected = fleet.connected,
            .waiting = fleet.waiting,
            .connecting = fleet.connecting,
            .stopped = fleet.stopped,
            .play = fleet.play,
            .reconnects = fleet.reconnects,
            .packets_received = fleet.packets_received,
            .keep_alives_answered = fleet.keep_alives,
            .bytes_received = fleet.bytes_received,
            .bytes_sent = fleet.bytes_sent,
            .duration_ms = app.data.elapsed_ms,
        };
        if (comptime stats_module.diagnostics_enabled) {
            stats.diagnostics = .{
                .recv_nobufs = fleet.ring.recv_nobufs,
                .cq_overflow = fleet.ring.cq_overflow,
                .close_failures = fleet.ring.close_failures,
                .max_cq_ready = fleet.ring.peak_cq_ready,
                .max_cq_entries = fleet.ring.peak_cq_entries,
                .max_recv_bundle_bytes = fleet.ring.max_bundle_bytes,
                .max_recv_bundle_buffers = fleet.ring.max_bundle_buffers,
                // Part of the block `report.writeStats` prints; leaving it out
                // made the overlay and the clipboard copy report whole-buffer
                // retirement on a run whose ring is incremental, contradicting
                // both the diagnostics pane and the stats block itself.
                .incremental_buffers = fleet.ring.incremental_buffers,
                .keep_alive_send_samples = fleet.keep_alive.samples,
                .keep_alive_send_total_ms = fleet.keep_alive.total,
                .keep_alive_send_max_ms = fleet.keep_alive.max,
                .disconnects = .{
                    .transport = fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.transport)],
                    .server = fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.server)],
                    .connect = fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.connect)],
                    .buffer_limit = fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.buffer_limit)],
                    .protocol = fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.protocol)],
                    .resource = fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.resource)],
                    .other = fleet.disconnect_counts[@backingInt(telemetry.DisconnectCategory.other)],
                },
            };
        }
        return stats;
    }

    fn render(app: *App, now_ms: u64) !void {
        const previous_size = app.term.size;
        app.term.refreshSize();
        if (!previous_size.eql(app.term.size)) app.screen.dirty = true;
        try app.screen.resize(app.term.size.cols, app.term.size.rows);
        if (app.screen.cols == 0 or app.screen.rows == 0) return;

        const palette = app.data.palette();
        app.screen.clear(.{ .fg = palette.text, .bg = palette.background });

        const root: Canvas = .{ .screen = &app.screen, .rect = app.screen.bounds() };
        const strip, const body = root.rect.splitTop(1);
        // A column of gutter down each side so nothing runs into the edge of
        // the window.
        app.renderStrip(root.area(gutter(strip)), now_ms);

        const pane_canvas = root.area(gutter(body));
        switch (app.view.pane) {
            .fleet => panes.fleet.render(pane_canvas, &app.data, app.view),
            .shards => panes.shards.render(pane_canvas, &app.data, app.view),
            .traffic => panes.traffic.render(pane_canvas, &app.data, app.view),
            .diagnostics => panes.diagnostics.render(pane_canvas, &app.data, app.view),
            .log => panes.log.render(pane_canvas, &app.data, app.view),
        }

        if (app.view.overlay) panes.overlay.render(root, &app.data, app.statsSnapshot());

        try app.flush();
    }

    /// The pane strip: numbered tabs, the selected one reversed out, plus the
    /// run state and clock on the right.
    fn renderStrip(app: *App, canvas: Canvas, now_ms: u64) void {
        const palette = app.data.palette();
        const faint: Style = .{ .fg = palette.faint };
        const dim: Style = .{ .fg = palette.dim };

        // The run state and clock are drawn first so the tabs know where they
        // have to stop: laid out independently they collided on anything under
        // eighty columns, and the last tab came out with the state written over
        // its own final characters.
        var right: [64]u8 = undefined;
        const state_text = switch (app.data.state) {
            .joining => "◐ joining",
            .running => "● running",
            .degraded => "▲ degraded",
            .stopped => "■ stopped",
        };
        const state_style: Style = .{ .fg = switch (app.data.state) {
            .joining => palette.warn,
            .running => palette.ok,
            .degraded => palette.warn,
            .stopped => palette.dim,
        } };
        const clock_text = std.fmt.bufPrint(&right, " {f}{s}", .{
            widgets.clock(app.data.elapsed_ms),
            if (app.view.paused) " · paused" else "",
        }) catch "";
        const width = screen_module.displayWidth(state_text) + screen_module.displayWidth(clock_text);
        const start = canvas.width() -| width;
        const after_state = canvas.text(start, 0, state_text, state_style);
        _ = canvas.text(after_state, 0, clock_text, dim);

        // A column of clearance so a truncated tab does not read as running
        // into the state beside it.
        const left = canvas.sub(0, 0, start -| 1, canvas.height());

        var x: u16 = 0;
        for (std.enums.values(model.Pane)) |pane| {
            if (!pane.available()) continue;
            x = left.print(x, 0, faint, "{d} ", .{@backingInt(pane) + 1});
            if (pane == app.view.pane) {
                const selected: Style = .{ .fg = palette.background, .bg = palette.text, .bold = true };
                x = left.print(x, 0, selected, " {s} ", .{pane.label()});
                if (app.view.drilled and pane == .shards) {
                    x = left.text(x, 0, " ▸ ", faint);
                    if (app.data.selectedRow(app.view)) |row| {
                        x = left.print(x, 0, .{ .fg = palette.text, .bold = true }, "{d:0>2}", .{row.id});
                    }
                }
            } else {
                x = left.text(x, 0, pane.label(), dim);
            }
            x = left.text(x, 0, "   ", faint);
        }

        // A transient notice takes the middle of the strip, where nothing else
        // competes for space. A live alert outranks it: the run being in
        // trouble is the more important thing to say.
        if (app.data.state == .degraded and !app.view.alerts) {
            const alerts = app.data.degradation.alertCount();
            x = left.print(x, 0, .{ .fg = palette.warn, .bold = true }, "▲ {d} ", .{alerts});
            _ = left.text(x, 0, "space", .{ .fg = palette.warn });
        } else if (app.notice_len > 0 and now_ms < app.notice_until_ms) {
            _ = left.text(x, 0, app.notice[0..app.notice_len], .{ .fg = palette.ok });
        }
    }

    // Drains to the terminal through a buffered file writer rather than one
    // fixed buffer: a first frame on a large terminal repaints every cell, which
    // can exceed any size that is reasonable to put on the stack.
    fn flush(app: *App) !void {
        var buffer: [16 * 1024]u8 = undefined;
        var file_writer: Io.File.Writer = .init(.stdout(), app.io, &buffer);
        try app.screen.flush(&file_writer.interface);
        try file_writer.interface.flush();
    }
};

/// Insets a region by a column on each side, so nothing a pane draws sits
/// flush against either edge of the window.
fn gutter(rect: screen_module.Rect) screen_module.Rect {
    if (rect.w < 3) return rect;
    return .{ .x = rect.x + 1, .y = rect.y, .w = rect.w - 2, .h = rect.h };
}

fn nowMs(io: Io) u64 {
    const ns: u64 = @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
    return ns / std.time.ns_per_ms;
}

/// The peaks block that follows the stats block in scrollback. Says nothing at
/// all when the dashboard never ran.
///
/// Every line is gated on the counters that feed it actually being compiled in.
/// `report.writeStats` prints "disabled at compile time" one block earlier, and
/// a peak of zero printed underneath that would read as a measurement rather
/// than as the absence of one.
pub fn writeSummary(writer: *Io.Writer, summary: Summary) !void {
    if (comptime !enabled) return;
    if (!summary.valid) return;

    const show_traffic = comptime stats_module.stats_enabled;
    const show_busiest = summary.busiest_reconnects > 0;
    const show_events = summary.events_seen > 0;
    if (!show_traffic and !show_busiest and !show_events) return;

    try writer.writeAll("peaks:\n");
    if (comptime stats_module.stats_enabled) {
        try report.writeLabel(writer, "rx");
        try writer.print("{f} at {f}    pkt {f}/s at {f}\n", .{
            report.byteRate(summary.peak_rx_per_sec),
            widgets.clock(summary.peak_rx_at_ms),
            report.grouped(report.rounded(summary.peak_packets_per_sec)),
            widgets.clock(summary.peak_packets_at_ms),
        });
    }
    if (show_busiest) {
        // The keep-alive percentile is only measured with diagnostics on; an
        // empty histogram answers zero, which would read as a fast fleet.
        if (comptime stats_module.diagnostics_enabled) {
            try report.writeLabel(writer, "busiest");
            try writer.print("shard {d:0>2}: {f} reconnects, ka p99 {d}ms\n", .{
                summary.busiest_shard,
                report.grouped(summary.busiest_reconnects),
                summary.busiest_keepalive_p99_ms,
            });
        } else {
            try report.writeLabel(writer, "busiest");
            try writer.print("shard {d:0>2}: {f} reconnects\n", .{
                summary.busiest_shard,
                report.grouped(summary.busiest_reconnects),
            });
        }
    }
    if (show_events) {
        const many = summary.events_seen != 1;
        try writer.print("  {f} event{s} {s} shown live and released with the alternate screen\n", .{
            report.grouped(summary.events_seen),
            if (many) "s" else "",
            if (many) "were" else "was",
        });
    }
}

test {
    if (comptime enabled) {
        _ = @import("tui/term.zig");
        _ = @import("tui/screen.zig");
        _ = @import("tui/model.zig");
        _ = @import("tui/widgets.zig");
        _ = panes.fleet;
        _ = panes.shards;
        _ = panes.traffic;
        _ = panes.diagnostics;
        _ = panes.log;
        _ = panes.overlay;
    }
}

test "writeSummary stays silent when no dashboard ran" {
    if (comptime !enabled) return error.SkipZigTest;
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeSummary(&writer, .{});
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "writeSummary reports the run's peaks" {
    if (comptime !enabled) return error.SkipZigTest;
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeSummary(&writer, .{
        .valid = true,
        .peak_rx_per_sec = 19_300_000,
        .peak_rx_at_ms = 192_000,
        .peak_packets_per_sec = 194_882,
        .peak_packets_at_ms = 192_000,
        .busiest_shard = 2,
        .busiest_reconnects = 21,
        .busiest_keepalive_p99_ms = 19,
    });
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "peaks:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "shard 02: 21 reconnects") != null);
    // The traffic line only exists where the counters behind it do; with them
    // compiled out the block reports what it measured and nothing else.
    if (comptime stats_module.stats_enabled) {
        try std.testing.expect(std.mem.indexOf(u8, output, "at 03:12") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, output, " rx ") == null);
    }
}

test "writeSummary agrees with the number of events it counted" {
    if (comptime !enabled) return error.SkipZigTest;
    var single_buffer: [512]u8 = undefined;
    var single: Io.Writer = .fixed(&single_buffer);
    try writeSummary(&single, .{ .valid = true, .events_seen = 1 });
    try std.testing.expect(std.mem.indexOf(u8, single.buffered(), "1 event was shown") != null);

    var many_buffer: [512]u8 = undefined;
    var many: Io.Writer = .fixed(&many_buffer);
    try writeSummary(&many, .{ .valid = true, .events_seen = 2 });
    try std.testing.expect(std.mem.indexOf(u8, many.buffered(), "2 events were shown") != null);
}

test "writeSummary reports nothing it did not measure" {
    if (comptime !enabled) return error.SkipZigTest;
    if (comptime stats_module.stats_enabled) return error.SkipZigTest;
    // A run with the counters compiled out and no churn has nothing to peak at,
    // so the header is not printed above a block of zeroes.
    var buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeSummary(&writer, .{ .valid = true });
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
