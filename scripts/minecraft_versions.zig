const std = @import("std");
const catalog = @import("minecraft_version_catalog");

pub fn main(init: std.process.Init) !void {
    var buffer: [2048]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file_writer.interface;

    inline for (catalog.all) |release| {
        try writer.print("{s}\n", .{release.minecraft_version});
    }
    try writer.flush();
}
