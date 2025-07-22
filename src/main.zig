const std = @import("std");
const toml = @import("toml");
const known_folders = @import("known_folders");
const Tty = @import("Tty.zig");
const Editor = @import("Editor.zig");
const Config = @import("Config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_parser = toml.Parser(Config).init(allocator);
    defer config_parser.deinit();

    const config_content = try getConfig(allocator);
    defer if (config_content) |content| allocator.free(content);

    const config_parse_res = try config_parser.parseString(config_content orelse "");
    defer config_parse_res.deinit();

    const config = config_parse_res.value;

    var tty: Tty = try .init();
    defer tty.deinit();

    var editor: Editor = try .init(allocator, &config, &tty, args[1..]);
    defer editor.deinit();

    try editor.run();
}

pub fn getConfig(allocator: std.mem.Allocator) !?[]const u8 {
    if (try known_folders.open(allocator, .roaming_configuration, .{})) |config_dir| {
        const file = config_dir.openFile("qux/config.toml", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const config = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

        return config;
    } else return null;
}
