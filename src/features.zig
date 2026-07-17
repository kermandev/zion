const build_options = @import("build_options");

pub const stats = build_options.enable_stats;
pub const compression = build_options.enable_compression;
pub const movement = build_options.enable_movement;
pub const broadcast = build_options.enable_broadcast;
pub const client_tick = build_options.enable_client_tick;
pub const diagnostics = build_options.enable_diagnostics;
