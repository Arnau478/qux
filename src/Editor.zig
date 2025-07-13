const Editor = @This();

const std = @import("std");
const Tty = @import("Tty.zig");
const Buffer = @import("Buffer.zig");

pub const Theme = @import("editor/Theme.zig");

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

    pub fn displayColor(mode: Mode, theme: Theme) Tty.Color {
        return switch (mode) {
            inline else => |_, m| @field(theme.mode, @tagName(m)),
        };
    }
};

allocator: std.mem.Allocator,
tty: *Tty,
mode: Mode,
buffers: std.ArrayListUnmanaged(Buffer),
current_buffer_idx: usize,
notice: ?[]const u8,
notice_is_error: bool,
theme: Theme,

pub fn init(allocator: std.mem.Allocator, tty: *Tty, initial_buffer_destinations: []const []const u8) !Editor {
    var editor: Editor = .{
        .allocator = allocator,
        .tty = tty,
        .mode = .normal,
        .buffers = .{},
        .current_buffer_idx = 0,
        .notice = null,
        .notice_is_error = false,
        .theme = Theme.default,
    };

    if (initial_buffer_destinations.len == 0) {
        try editor.buffers.append(allocator, try .init(allocator));
    } else {
        for (initial_buffer_destinations) |dest| {
            try editor.buffers.append(allocator, try .initFromFile(allocator, dest));
        }
    }

    return editor;
}

pub fn deinit(editor: *Editor) void {
    editor.unsetNotice();
    editor.buffers.deinit(editor.allocator);
}

fn unsetNotice(editor: *Editor) void {
    if (editor.notice) |old| editor.allocator.free(old);
    editor.notice = null;
    editor.notice_is_error = false;
}

fn setNotice(editor: *Editor, is_error: bool, comptime fmt: []const u8, args: anytype) !void {
    editor.unsetNotice();
    editor.notice_is_error = is_error;
    editor.notice = try std.fmt.allocPrint(editor.allocator, fmt, args);
}

fn currentBuffer(editor: Editor) *Buffer {
    return &editor.buffers.items[editor.current_buffer_idx];
}

fn quitCurrentBuffer(editor: *Editor) void {
    editor.currentBuffer().deinit();
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
        var cursor_pos = try editor.currentBuffer().render(editor.tty, buffer_viewport, editor.theme);

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
        editor.unsetNotice();
        switch (editor.mode) {
            .normal => switch (input) {
                .printable => |printable| switch (printable) {
                    0...31 => unreachable,
                    'i' => editor.mode = .insert,
                    ':' => editor.mode = .{ .command = .{} },
                    else => {},
                },
                .arrow => |arrow| switch (arrow) {
                    inline else => |a| editor.currentBuffer().moveCursor(@field(Direction, @tagName(a))),
                },
                else => {},
            },
            .insert => switch (input) {
                .printable => |printable| try editor.currentBuffer().insertCharacter(printable),
                .@"return" => try editor.currentBuffer().insertCharacter('\n'),
                .backspace => try editor.currentBuffer().backspace(),
                .escape => editor.mode = .normal,
                .arrow => |arrow| switch (arrow) {
                    inline else => |a| editor.currentBuffer().moveCursor(@field(Direction, @tagName(a))),
                },
                else => {},
            },
            .command => |*command| switch (input) {
                .printable => |printable| try command.append(editor.allocator, printable),
                .backspace => _ = command.pop(),
                .escape, .@"return" => {
                    if (input == .@"return") try runCommand(editor, command.items);

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
    try editor.tty.setAttributes(.{ .bg = editor.theme.main_bar_background });
    try editor.tty.writer().writeByteNTimes(' ', tty_size.width);

    try editor.tty.moveCursor(.{ .x = 0, .y = tty_size.height - 2 });
    try editor.tty.setAttributes(.{ .bg = editor.mode.displayColor(editor.theme), .fg = editor.theme.main_bar_background, .bold = true });
    try editor.tty.writer().print(" {s} ", .{editor.mode.displayName()});
    try editor.tty.setAttributes(.{ .fg = editor.mode.displayColor(editor.theme), .bg = editor.theme.main_bar_background });
    if (editor.currentBuffer().destination) |destination| {
        try editor.tty.writer().print(" {s}", .{destination});
        if (editor.currentBuffer().dirty) {
            try editor.tty.writer().writeAll(" [+]");
        }
        if (editor.currentBuffer().read_only) {
            try editor.tty.writer().writeAll(" [RO]");
        }
    } else {
        try editor.tty.writer().writeAll(" [scratch]");
    }
    try editor.tty.setAttributes(.{ .bg = editor.theme.main_bar_background });
    try editor.tty.writer().print(" ({}, {})", .{ editor.currentBuffer().cursor_line + 1, editor.currentBuffer().cursor_col + 1 });

    try editor.tty.moveCursor(.{ .x = 0, .y = tty_size.height - 1 });
    try editor.tty.setAttributes(.{ .bg = editor.theme.background });
    try editor.tty.writer().writeByteNTimes(' ', tty_size.width);

    try editor.tty.moveCursor(.{ .x = 0, .y = tty_size.height - 1 });
    try editor.tty.setAttributes(.{ .bg = editor.theme.background });
    if (editor.mode == .command) {
        try editor.tty.writer().print(":{s}", .{editor.mode.command.items});
    } else {
        if (editor.notice) |notice| {
            try editor.tty.setAttributes(.{ .fg = if (editor.notice_is_error) editor.theme.notice_error else editor.theme.notice_info, .bg = editor.theme.background });
            try editor.tty.writer().writeAll(notice);
        }
    }
}

fn runCommand(editor: *Editor, command: []const u8) !void {
    var iter = std.mem.splitScalar(u8, command, ' ');
    var name = iter.next() orelse return;
    while (name.len == 0) {
        name = iter.next() orelse return;
    }

    if (std.mem.eql(u8, name, "q")) {
        if (iter.peek() != null) return; // TODO
        editor.quitCurrentBuffer();
    } else if (std.mem.eql(u8, name, "w")) {
        if (iter.peek() != null) return; // TODO
        const is_new = editor.currentBuffer().save() catch |err| blk: {
            switch (err) {
                error.NoDestination => try editor.setNotice(true, "No destination assigned to buffer", .{}),
                error.FileOpenError => try editor.setNotice(true, "Error opening file \"{s}\"", .{editor.currentBuffer().destination.?}),
                error.FileWriteError => try editor.setNotice(true, "Error writing file \"{s}\"", .{editor.currentBuffer().destination.?}),
                error.OutOfMemory => return err,
            }

            break :blk false;
        };

        if (is_new) try editor.setNotice(false, "Created file \"{s}\"", .{editor.currentBuffer().destination.?});
    } else if (std.mem.eql(u8, name, "theme")) {
        const theme_name = iter.next() orelse return; // TODO
        if (iter.peek() != null) return; // TODO

        if (std.mem.eql(u8, theme_name, "default")) {
            editor.theme = .default;
        } else if (std.mem.eql(u8, theme_name, "kanagawa")) {
            editor.theme = .kanagawa;
        } else {
            try editor.setNotice(true, "No theme named \"{s}\"", .{theme_name});
        }
    } else if (std.mem.eql(u8, name, "filetype")) {
        if (iter.next()) |filetype_str| {
            if (iter.peek() != null) return; // TODO
            if (std.meta.stringToEnum(Buffer.syntax.Filetype, filetype_str)) |filetype| {
                editor.currentBuffer().filetype = filetype;
            } else {
                try editor.setNotice(true, "Unknown filetype: {s}", .{filetype_str});
            }
        } else {
            try editor.setNotice(false, "filetype={s}", .{if (editor.currentBuffer().filetype) |filetype| @tagName(filetype) else "(none)"});
        }
    } else {
        if (std.mem.indexOfNone(u8, name, "0123456789") == null) {
            if (iter.peek() != null) return; // TODO
            editor.currentBuffer().moveCursorToLine((std.fmt.parseInt(usize, name, 10) catch return) - 1);
        } else {
            try editor.setNotice(true, "Unknown command: \":{s}\"", .{name});
        }
    }
}
