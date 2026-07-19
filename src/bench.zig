const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const TimerWheel = @import("scheduler.zig").TimerWheel;
const client = @import("client.zig");
const features = @import("features.zig");

const Benchmark = enum {
    scheduler,
    timer_idle,
    timer_rotate,
    timer_walk,

    fn name(benchmark: Benchmark) []const u8 {
        return switch (benchmark) {
            .scheduler => "scheduler",
            .timer_idle => "timer-idle",
            .timer_rotate => "timer-rotate",
            .timer_walk => "timer-walk",
        };
    }
};

const Config = struct {
    benchmark: Benchmark = .scheduler,
    clients: usize = 50_000,
    min_actions: usize = 1_000_000,
    interval_ms: u64 = 50,
    warmups: usize = 2,
    samples: usize = 10,
    json: bool = false,
};

const Action = union(enum) {
    help,
    run: Config,
};

const Sample = struct {
    elapsed_ns: u64,
    actions: usize,
    checksum: u64,

    fn actionsPerSecond(sample: Sample) f64 {
        return @as(f64, @floatFromInt(sample.actions)) * std.time.ns_per_s / @as(f64, @floatFromInt(sample.elapsed_ns));
    }
};

const Summary = struct {
    min_ns: u64,
    median_ns: u64,
    max_ns: u64,
    mean_ns: f64,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.skip();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const action = parseArgs(&args) catch |err| {
        try stderr.print("error: invalid benchmark arguments ({t})\n\n", .{err});
        try writeUsage(stderr);
        try stderr.flush();
        std.process.exit(2);
    };
    const config = switch (action) {
        .help => return writeUsage(stdout),
        .run => |run| run,
    };

    for (0..config.warmups) |_| _ = try runSample(init.io, init.gpa, config);

    const samples = try init.gpa.alloc(Sample, config.samples);
    defer init.gpa.free(samples);
    for (samples) |*sample| sample.* = try runSample(init.io, init.gpa, config);

    const expected_actions = samples[0].actions;
    const expected_checksum = samples[0].checksum;
    for (samples[1..]) |sample| {
        if (sample.actions != expected_actions or sample.checksum != expected_checksum)
            return error.NonDeterministicWorkload;
    }

    const elapsed_scratch = try init.gpa.alloc(u64, samples.len);
    defer init.gpa.free(elapsed_scratch);
    const summary = summarize(samples, elapsed_scratch);
    if (config.json) {
        try writeJson(stdout, config, samples, summary);
    } else {
        try writeText(stdout, config, samples, summary);
    }
}

fn parseArgs(args: *std.process.Args.Iterator) !Action {
    var config: Config = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--benchmark")) {
            const value = try nextValue(args);
            config.benchmark = if (std.mem.eql(u8, value, "scheduler"))
                .scheduler
            else if (std.mem.eql(u8, value, "timer-idle"))
                .timer_idle
            else if (std.mem.eql(u8, value, "timer-rotate"))
                .timer_rotate
            else if (std.mem.eql(u8, value, "timer-walk"))
                .timer_walk
            else
                return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--clients")) {
            config.clients = try parseInt(usize, try nextValue(args));
        } else if (std.mem.eql(u8, arg, "--actions")) {
            config.min_actions = try parseInt(usize, try nextValue(args));
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            config.interval_ms = try parseInt(u64, try nextValue(args));
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            config.warmups = try parseInt(usize, try nextValue(args));
        } else if (std.mem.eql(u8, arg, "--samples")) {
            config.samples = try parseInt(usize, try nextValue(args));
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else {
            return error.InvalidArgs;
        }
    }
    if (config.clients == 0 or config.clients > std.math.maxInt(u32)) return error.InvalidArgs;
    if (config.min_actions == 0) return error.InvalidArgs;
    if (config.interval_ms == 0 or config.interval_ms > 60_000) return error.InvalidArgs;
    if (config.samples == 0 or config.samples > 1_000) return error.InvalidArgs;
    if (config.warmups > 1_000) return error.InvalidArgs;
    if (comptime !features.movement) {
        if (config.benchmark != .scheduler) return error.FeatureDisabled;
    }
    return .{ .run = config };
}

fn nextValue(args: *std.process.Args.Iterator) ![]const u8 {
    const value = args.next() orelse return error.InvalidArgs;
    if (std.mem.startsWith(u8, value, "--")) return error.InvalidArgs;
    return value;
}

fn parseInt(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidArgs;
}

fn runSample(io: Io, allocator: std.mem.Allocator, config: Config) !Sample {
    return switch (config.benchmark) {
        .scheduler => runSchedulerSample(io, allocator, config),
        .timer_idle => if (comptime features.movement) runTimerSample(io, allocator, config, .idle) else error.FeatureDisabled,
        .timer_rotate => if (comptime features.movement) runTimerSample(io, allocator, config, .rotate) else error.FeatureDisabled,
        .timer_walk => if (comptime features.movement) runTimerSample(io, allocator, config, .walk) else error.FeatureDisabled,
    };
}

fn runSchedulerSample(io: Io, allocator: std.mem.Allocator, config: Config) !Sample {
    var wheel = try TimerWheel.init(allocator, config.clients, 0);
    defer wheel.deinit();
    const due = try allocator.alloc(u32, config.clients);
    defer allocator.free(due);

    for (0..config.clients) |index| {
        wheel.schedule(index, @as(u64, @intCast(index)) % config.interval_ms);
    }

    const started = Io.Timestamp.now(io, .awake).toNanoseconds();
    var actions: usize = 0;
    var checksum: u64 = 0;
    var now_ms: u64 = 0;
    while (actions < config.min_actions) : (now_ms += 1) {
        const count = wheel.takeDue(now_ms, due);
        actions += count;
        for (due[0..count]) |index| {
            checksum = (checksum *% 0x9e3779b185ebca87) ^ index ^ now_ms;
            wheel.schedule(index, now_ms + config.interval_ms);
        }
    }
    const stopped = Io.Timestamp.now(io, .awake).toNanoseconds();
    return .{
        .elapsed_ns = @intCast(@max(stopped - started, 1)),
        .actions = actions,
        .checksum = checksum,
    };
}

fn runTimerSample(
    io: Io,
    allocator: std.mem.Allocator,
    config: Config,
    comptime profile: if (features.movement) client.MovementProfile else void,
) !Sample {
    if (comptime !features.movement) return error.FeatureDisabled;

    var clients: client.ClientTable = .{
        .allocator = allocator,
        .io = io,
        .total_client_count = config.clients,
        .movement = .{
            .profile = profile,
            .interval_ms = config.interval_ms,
        },
    };
    defer clients.deinit(allocator);
    try clients.ensureTotalCapacity(allocator, config.clients);
    for (0..config.clients) |index| {
        clients.appendAssumeCapacity(@intCast(index), 0);
        clients.phases.items[index] = .play;
        client.timerState(&clients, index).next_movement_ms = 0;
        if (comptime profile != .idle) client.motionState(&clients, index).initialized = true;

        // Remove first-use allocation from the timed region while retaining
        // the exact owned-buffer path exercised by movement packets.
        try client.writeState(&clients, index).enqueueOwned(allocator, &.{0});
        client.writeState(&clients, index).clearRetainingCapacity();
    }

    var packet_builder_buf: Io.Writer.Allocating = .init(allocator);
    defer packet_builder_buf.deinit();
    try packet_builder_buf.ensureTotalCapacity(64);
    var write_temp_buf: Io.Writer.Allocating = .init(allocator);
    defer write_temp_buf.deinit();
    try write_temp_buf.ensureTotalCapacity(128);

    // Hoist the SoA column pointers out of the timed loop so the benchmark
    // measures the timer/movement work rather than MultiArrayList index math.
    // Capacity was reserved and the per-client write buffers pre-grown above, so
    // no column reallocates during the loop and these slices stay valid.
    const sessions = clients.sessions.slice();
    const timers = sessions.items(.timers);
    const writes = sessions.items(.write);
    const phases = clients.phases.items;
    const motions = if (comptime profile != .idle) clients.motion_states.items else {};

    const started = Io.Timestamp.now(io, .awake).toNanoseconds();
    var checksum: u64 = 0;
    var index: usize = 0;
    var now_ms = config.interval_ms;
    for (0..config.min_actions) |_| {
        timers[index].next_movement_ms = now_ms;
        const wrote = try client.onTimerFor(
            profile,
            &clients,
            index,
            &phases[index],
            now_ms,
            &packet_builder_buf,
            &write_temp_buf,
        );
        if (!wrote) return error.TimerDidNotWrite;
        const byte_count = writes[index].byteCount();
        checksum = (checksum *% 0x9e3779b185ebca87) ^ byte_count ^ index;
        if (comptime profile != .idle) {
            const motion = &motions[index];
            const yaw_bits: u32 = @bitCast(motion.yaw);
            checksum ^= yaw_bits;
            if (comptime profile == .walk) checksum ^= @as(u64, @bitCast(motion.x));
        }
        writes[index].clearRetainingCapacity();

        index += 1;
        if (index == config.clients) {
            index = 0;
            now_ms +|= config.interval_ms;
        }
    }
    const stopped = Io.Timestamp.now(io, .awake).toNanoseconds();
    return .{
        .elapsed_ns = @intCast(@max(stopped - started, 1)),
        .actions = config.min_actions,
        .checksum = checksum,
    };
}

fn summarize(samples: []const Sample, scratch: []u64) Summary {
    std.debug.assert(samples.len > 0);
    std.debug.assert(samples.len == scratch.len);
    var total: f64 = 0;
    for (samples, scratch) |sample, *elapsed| {
        elapsed.* = sample.elapsed_ns;
        total += @floatFromInt(sample.elapsed_ns);
    }
    std.mem.sortUnstable(u64, scratch, {}, std.sort.asc(u64));
    const middle = scratch.len / 2;
    const median = if (scratch.len % 2 == 1)
        scratch[middle]
    else
        scratch[middle - 1] + (scratch[middle] - scratch[middle - 1]) / 2;
    return .{
        .min_ns = scratch[0],
        .median_ns = median,
        .max_ns = scratch[scratch.len - 1],
        .mean_ns = total / @as(f64, @floatFromInt(samples.len)),
    };
}

fn medianRate(actions: usize, median_ns: u64) f64 {
    return @as(f64, @floatFromInt(actions)) * std.time.ns_per_s / @as(f64, @floatFromInt(median_ns));
}

fn writeText(writer: *Io.Writer, config: Config, samples: []const Sample, summary: Summary) !void {
    try writer.print("{s} benchmark: zig={s} mode={s} clients={d} min_actions={d} interval_ms={d} warmups={d} samples={d}\n", .{
        config.benchmark.name(),
        builtin.zig_version_string,
        @tagName(builtin.mode),
        config.clients,
        config.min_actions,
        config.interval_ms,
        config.warmups,
        config.samples,
    });
    for (samples, 1..) |sample, index| {
        try writer.print("sample {d}: elapsed_ns={d} actions={d} rate={d:.0}/s checksum={x}\n", .{
            index,
            sample.elapsed_ns,
            sample.actions,
            sample.actionsPerSecond(),
            sample.checksum,
        });
    }
    try writer.print("summary: min_ns={d} median_ns={d} max_ns={d} mean_ns={d:.1} median_rate={d:.0}/s\n", .{
        summary.min_ns,
        summary.median_ns,
        summary.max_ns,
        summary.mean_ns,
        medianRate(samples[0].actions, summary.median_ns),
    });
}

fn writeJson(writer: *Io.Writer, config: Config, samples: []const Sample, summary: Summary) !void {
    try writer.print("{{\"benchmark\":\"{s}\",\"zig\":\"{s}\",\"mode\":\"{s}\",\"clients\":{d},\"min_actions\":{d},\"interval_ms\":{d},\"warmups\":{d},\"sample_count\":{d},\"actions\":{d},\"checksum\":\"{x}\",\"samples\":[", .{
        config.benchmark.name(),
        builtin.zig_version_string,
        @tagName(builtin.mode),
        config.clients,
        config.min_actions,
        config.interval_ms,
        config.warmups,
        config.samples,
        samples[0].actions,
        samples[0].checksum,
    });
    for (samples, 0..) |sample, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"elapsed_ns\":{d},\"actions_per_second\":{d:.3}}}", .{ sample.elapsed_ns, sample.actionsPerSecond() });
    }
    try writer.print("],\"summary\":{{\"min_ns\":{d},\"median_ns\":{d},\"max_ns\":{d},\"mean_ns\":{d:.3},\"median_actions_per_second\":{d:.3}}}}}\n", .{
        summary.min_ns,
        summary.median_ns,
        summary.max_ns,
        summary.mean_ns,
        medianRate(samples[0].actions, summary.median_ns),
    });
}

fn writeUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zig build bench -- [options]
        \\
        \\Options:
        \\  --benchmark <name>      scheduler, timer-idle, timer-rotate, or timer-walk
        \\  --clients <count>       Scheduled clients (default: 50000)
        \\  --actions <count>       Minimum timed actions per sample (default: 1000000)
        \\  --interval-ms <ms>      Reschedule interval (default: 50)
        \\  --warmups <count>       Untimed warmup samples (default: 2)
        \\  --samples <count>       Timed samples (default: 10)
        \\  --json                  Emit one machine-readable JSON object
        \\  -h, --help              Show this help
        \\
    );
}

test "benchmark summary uses a conventional even-sample median" {
    const samples = [_]Sample{
        .{ .elapsed_ns = 40, .actions = 1, .checksum = 1 },
        .{ .elapsed_ns = 10, .actions = 1, .checksum = 1 },
        .{ .elapsed_ns = 30, .actions = 1, .checksum = 1 },
        .{ .elapsed_ns = 20, .actions = 1, .checksum = 1 },
    };
    var scratch: [samples.len]u64 = undefined;
    const summary = summarize(&samples, &scratch);
    try std.testing.expectEqual(@as(u64, 10), summary.min_ns);
    try std.testing.expectEqual(@as(u64, 25), summary.median_ns);
    try std.testing.expectEqual(@as(u64, 40), summary.max_ns);
    try std.testing.expectEqual(@as(f64, 25), summary.mean_ns);
}
