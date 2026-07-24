const std = @import("std");
const manifest = @import("build.zig.zon");
const minecraft_versions = @import("src/protocol/versions/catalog.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information from binaries") orelse false;

    const minimal = b.option(bool, "minimal", "Disable optional features by default; explicit feature options override this preset") orelse false;
    const enable_stats = b.option(bool, "enable-stats", "Compile traffic statistics") orelse !minimal;
    const enable_compression = b.option(bool, "enable-compression", "Compile Minecraft packet compression support") orelse !minimal;
    const enable_movement = b.option(bool, "enable-movement", "Compile rotation and bounded random-walk support") orelse !minimal;
    const enable_broadcast = b.option(bool, "enable-broadcast", "Compile periodic chat broadcast support") orelse !minimal;
    const enable_client_tick = b.option(bool, "enable-client-tick", "Compile 50 ms client-tick traffic support") orelse !minimal;
    const enable_diagnostics = b.option(bool, "enable-diagnostics", "Compile detailed progress and per-client diagnostics") orelse !minimal;
    const enable_reconnect = b.option(bool, "enable-reconnect", "Compile automatic client reconnect on disconnect") orelse !minimal;
    const requested_minecraft_version = b.option([]const u8, "minecraft-version", "Minecraft Java version to target, or latest") orelse "latest";
    const minecraft_version = if (std.mem.eql(u8, requested_minecraft_version, "latest")) minecraft_versions.latest.minecraft_version else requested_minecraft_version;
    const minecraft_release = findMinecraftRelease(minecraft_version) orelse @panic("unsupported -Dminecraft-version");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "zion_version", manifest.version);
    build_options.addOption(bool, "enable_stats", enable_stats);
    build_options.addOption(bool, "enable_compression", enable_compression);
    build_options.addOption(bool, "enable_movement", enable_movement);
    build_options.addOption(bool, "enable_broadcast", enable_broadcast);
    build_options.addOption(bool, "enable_client_tick", enable_client_tick);
    build_options.addOption(bool, "enable_diagnostics", enable_diagnostics);
    build_options.addOption(bool, "enable_reconnect", enable_reconnect);
    build_options.addOption([]const u8, "minecraft_version", minecraft_version);
    build_options.addOption(i32, "minecraft_protocol_version", minecraft_release.protocol_version);

    const minecraft_version_module = b.createModule(.{
        .root_source_file = b.path(b.fmt("src/protocol/versions/{s}.zig", .{minecraft_release.implementation_file})),
    });

    const exe = b.addExecutable(.{
        .name = "zion",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    addZionImports(exe.root_module, build_options, minecraft_version_module);

    exe.lto = if (optimize != .Debug) .full else .none;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.stdio = .inherit;
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // Tests get their own module (same source and options as the executable)
    // so -Dstrip=true never strips debug info out of the test binary.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    addZionImports(test_module, build_options, minecraft_version_module);

    const exe_tests = b.addTest(.{
        .root_module = test_module,
        .use_llvm = true,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Fuzzing reuses the test binary: the build runner's --fuzz flag switches
    // the shared test-runner process into fuzz mode, so this step is the test
    // step under another name for `zig build fuzz --fuzz=<iterations>`.
    const fuzz_step = b.step("fuzz", "Run builtin fuzz targets (pass --fuzz or --fuzz=<iterations>)");
    fuzz_step.dependOn(&run_exe_tests.step);

    const benchmark_optimize = b.option(std.builtin.OptimizeMode, "benchmark-optimize", "Benchmark optimization mode") orelse .ReleaseFast;

    const bench_exe = b.addExecutable(.{
        .name = "zion-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = benchmark_optimize,
        }),
    });
    addZionImports(bench_exe.root_module, build_options, minecraft_version_module);
    bench_exe.lto = if (benchmark_optimize != .Debug) .full else .none;
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.stdio = .inherit;
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run reproducible scheduler and timer benchmarks");
    bench_step.dependOn(&bench_run.step);
}

// Every zion module needs the same generated options, the selected version
// implementation, and libc.
fn addZionImports(
    module: *std.Build.Module,
    build_options: *std.Build.Step.Options,
    minecraft_version_module: *std.Build.Module,
) void {
    module.addOptions("build_options", build_options);
    module.addImport("minecraft_version", minecraft_version_module);
    module.link_libc = true;
}

fn findMinecraftRelease(minecraft_version: []const u8) ?minecraft_versions.Release {
    for (minecraft_versions.all) |release| {
        if (std.mem.eql(u8, minecraft_version, release.minecraft_version)) return release;
    }
    return null;
}
