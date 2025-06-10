const Editor = @This();

const std = @import("std");
const Tty = @import("Tty.zig");
const Buffer = @import("Buffer.zig");

pub const Viewport = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

pub const Mode = union(enum) {
    normal,
    insert,
    command: std.ArrayListUnmanaged(u8),

    pub fn displayName(mode: Mode) []const u8 {
        return switch (mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .command => "COMMAND",
        };
    }

    pub fn displayColor(mode: Mode) Tty.Color {
        return switch (mode) {
            .normal => .cyan,
            .insert => .green,
            .command => .yellow,
        };
    }
};

allocator: std.mem.Allocator,
tty: *Tty,
mode: Mode,
buffers: std.ArrayListUnmanaged(Buffer),
current_buffer_idx: usize,

pub fn init(allocator: std.mem.Allocator, tty: *Tty) !Editor {
    var editor: Editor = .{
        .allocator = allocator,
        .tty = tty,
        .mode = .normal,
        .buffers = .{},
        .current_buffer_idx = 0,
    };

    try editor.buffers.append(allocator, try .init(allocator));

    return editor;
}

pub fn deinit(editor: *Editor) void {
    editor.buffers.deinit(editor.allocator);
}

fn currentBuffer(editor: Editor) *Buffer {
    return &editor.buffers.items[editor.current_buffer_idx];
}

fn quitCurrentBuffer(editor: *Editor) void {
    editor.currentBuffer().deinit(editor.allocator);
    _ = editor.buffers.orderedRemove(editor.current_buffer_idx);
    if (editor.current_buffer_idx > 0) editor.current_buffer_idx -= 1;
}

pub fn run(editor: *Editor) !void {
    while (true) {
        if (editor.buffers.items.len == 0) return;

        const tty_size = try editor.tty.getSize();

        try editor.tty.hideCursor();

        try editor.drawBar(tty_size);

        const buffer_viewport: Viewport = .{ .x = 0, .y = 0, .width = tty_size.width, .height = tty_size.height - 2 };
        var cursor_pos = try editor.currentBuffer().render(editor.tty, buffer_viewport);

        switch (editor.mode) {
            .command => |command| cursor_pos = .{ .x = command.items.len + 1, .y = tty_size.height - 1 },
            else => {},
        }

        try editor.tty.moveCursor(cursor_pos);
        try editor.tty.setCursorShape(switch (editor.mode) {
            .normal, .command => .block,
            .insert => .bar,
        });
        try editor.tty.showCursor();
        try editor.tty.flush();

        const input = try editor.tty.readInput();
        switch (editor.mode) {
            .normal => switch (input) {
                .printable => |printable| switch (printable) {
                    0...31 => unreachable,
                    'i' => editor.mode = .insert,
                    ':' => editor.mode = .{ .command = .{} },
                    else => {},
                },
                .escape => {},
                .arrow => |arrow| switch (arrow) {
                    inline else => |a| editor.currentBuffer().shiftCursor(@field(Direction, @tagName(a))),
                },
                else => {},
            },
            .insert => switch (input) {
                .printable => |printable| try editor.currentBuffer().insertCharacter(editor.allocator, printable),
                .@"return" => try editor.currentBuffer().insertReturn(editor.allocator),
                .backspace => try editor.currentBuffer().insertBackspace(),
                .escape => editor.mode = .normal,
                .arrow => |arrow| switch (arrow) {
                    inline else => |a| editor.currentBuffer().shiftCursor(@field(Direction, @tagName(a))),
                },
                else => {},
            },
            .command => |*command| switch (input) {
                .printable => |printable| try command.append(editor.allocator, printable),
                .escape, .@"return" => {
                    if (input == .@"return") runCommand(editor, command.items);

                    command.deinit(editor.allocator);
                    editor.mode = .normal;
                },
                else => {},
            },
        }
    }
}

fn drawBar(editor: Editor, tty_size: Tty.Size) !void {
    try editor.tty.clearLine(tty_size.height - 2);
    try editor.tty.clearLine(tty_size.height - 1);

    try editor.tty.moveCursor(.{ .x = 0, .y = tty_size.height - 2 });
    try editor.tty.setAttributes(.{ .bg = editor.mode.displayColor(), .fg = .black });
    try editor.tty.writer().print(" {s} ", .{editor.mode.displayName()});
    try editor.tty.resetAttributes();
    try editor.tty.setAttributes(.{ .fg = editor.mode.displayColor() });
    try editor.tty.writer().print(" {s}", .{editor.currentBuffer().getTitle()});
    try editor.tty.resetAttributes();
    try editor.tty.writer().print(" ({}, {})", .{ editor.currentBuffer().visualCursor().line, editor.currentBuffer().visualCursor().column });

    if (editor.mode == .command) {
        try editor.tty.moveCursor(.{ .x = 0, .y = tty_size.height - 1 });
        try editor.tty.writer().print(":{s}", .{editor.mode.command.items});
    }
}

fn runCommand(editor: *Editor, command: []const u8) void {
    var iter = std.mem.splitScalar(u8, command, ' ');
    var name = iter.next() orelse return;
    while (name.len == 0) {
        name = iter.next() orelse return;
    }

    if (std.mem.eql(u8, name, "q")) {
        if (iter.peek() != null) return; // TODO
        editor.quitCurrentBuffer();
    } else {
        if (iter.peek() == null and std.mem.indexOfNone(u8, name, "0123456789") == null) {
            editor.currentBuffer().goToLine(std.fmt.parseInt(usize, name, 10) catch return);
        } else {
            // TODO
        }
    }
}
