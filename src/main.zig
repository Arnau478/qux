const std = @import("std");
const Tty = @import("Tty.zig");
const Editor = @import("Editor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var tty: Tty = try .init();
    defer tty.deinit();

    var editor: Editor = try .init(allocator, &tty, args[1..]);
    defer editor.deinit();

    try editor.run();
}
