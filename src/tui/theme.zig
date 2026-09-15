//! The dashboard palette.
//!
//! A terminal is a fixed character grid, so emphasis comes from weight, color
//! and block glyphs only — there is one cell size everywhere. Severity is
//! always carried by a glyph or a label as well as a hue, never by hue alone.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(color: Rgb, other: Rgb) bool {
        return color.r == other.r and color.g == other.g and color.b == other.b;
    }
};

fn rgb(comptime hex: u24) Rgb {
    return .{
        .r = @intCast((hex >> 16) & 0xff),
        .g = @intCast((hex >> 8) & 0xff),
        .b = @intCast(hex & 0xff),
    };
}

pub const Palette = struct {
    background: Rgb,
    /// Primary text.
    text: Rgb,
    /// Secondary text: labels, units, context.
    dim: Rgb,
    /// Tertiary text: key hints, inactive tabs, footnotes.
    faint: Rgb,
    /// Unfilled portion of a gauge or bar.
    track: Rgb,
    /// Column rules and separators.
    rule: Rgb,
    /// Healthy accent, used for the selected tab background too.
    ok: Rgb,
    /// Chart body and filled bars.
    chart: Rgb,
    /// Older/lower chart rows, so a tall series reads as layered.
    chart_deep: Rgb,
    /// A value worth looking at but not yet failing.
    warn: Rgb,
    /// A failing value.
    bad: Rgb,
    /// The calm field a heatmap's warm cells stand out against.
    ok_track: Rgb,
};

/// The dashboard's only palette. A degraded fleet is called out with markers
/// and labels rather than a second color scheme: recoloring the whole screen
/// while someone is reading it costs more than it communicates, and severity
/// must not depend on hue anyway.
pub const running: Palette = .{
    .background = rgb(0x08090b),
    .text = rgb(0xd5dae0),
    .dim = rgb(0x5d656e),
    .faint = rgb(0x3d444b),
    .track = rgb(0x1b2228),
    .rule = rgb(0x232a31),
    .ok = rgb(0x8fd18a),
    .chart = rgb(0x4a8f5a),
    .chart_deep = rgb(0x357a45),
    .warn = rgb(0xdfb96b),
    .bad = rgb(0xe08a78),
    .ok_track = rgb(0x3f5a45),
};

/// Severity, so a caller picks a color by meaning rather than by hue.
pub const Severity = enum {
    ok,
    watch,
    hot,

    pub fn color(severity: Severity, palette: Palette) Rgb {
        return switch (severity) {
            .ok => palette.ok,
            .watch => palette.warn,
            .hot => palette.bad,
        };
    }

    /// The glyph that carries the same meaning without relying on color.
    /// Hollow escalates to filled, so watch and hot stay apart in a capture,
    /// a colourless terminal, or to a reader who cannot tell the hues apart.
    pub fn marker(severity: Severity) []const u8 {
        return switch (severity) {
            // A calm row earns no mark; only what needs attention is marked.
            .ok => " ",
            .watch => "△",
            .hot => "▲",
        };
    }
};
