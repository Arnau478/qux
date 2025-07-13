const std = @import("std");
const toml = @import("toml");
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

    const config_parse_res = try config_parser.parseString(""); // TODO
    defer config_parse_res.deinit();

    const config = config_parse_res.value;

    var tty: Tty = try .init();
    defer tty.deinit();

    var editor: Editor = try .init(allocator, config.editor, &tty, args[1..]);
    defer editor.deinit();

    try editor.run();
}
