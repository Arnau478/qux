const std = @import("std");
const Tty = @import("Tty.zig");
const Editor = @import("Editor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tty: Tty = try .init();
    defer tty.deinit();

    var editor: Editor = try .init(allocator, &tty);
    defer editor.deinit();

    try editor.run();
}
