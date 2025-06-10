const Buffer = @This();

const std = @import("std");
const Editor = @import("Editor.zig");
const Tty = @import("Tty.zig");

pub const TextPosition = struct {
    line: usize,
    column: usize,
};

lines: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)),
real_cursor: TextPosition,

pub fn init(allocator: std.mem.Allocator) !Buffer {
    var buffer: Buffer = .{
        .lines = .{},
        .real_cursor = .{
            .line = 1,
            .column = 1,
        },
    };

    try buffer.lines.append(allocator, .{});

    return buffer;
}

pub fn deinit(buffer: *Buffer, allocator: std.mem.Allocator) void {
    for (buffer.lines.items) |*line| {
        line.deinit(allocator);
    }
    buffer.lines.deinit(allocator);
}

pub fn visualCursor(buffer: Buffer) TextPosition {
    return .{
        .column = @min(buffer.real_cursor.column, buffer.lines.items[buffer.real_cursor.line - 1].items.len + 1),
        .line = buffer.real_cursor.line,
    };
}

pub fn getTitle(buffer: Buffer) []const u8 {
    _ = buffer;
    return "<scratch>";
}

pub fn insertReturn(buffer: *Buffer, allocator: std.mem.Allocator) !void {
    const slice = buffer.lines.items[buffer.real_cursor.line - 1].items[buffer.visualCursor().column - 1 ..];
    try buffer.lines.insert(allocator, buffer.real_cursor.line, .{});
    try buffer.lines.items[buffer.real_cursor.line].appendSlice(allocator, slice);
    for (0..slice.len) |_| _ = buffer.lines.items[buffer.real_cursor.line - 1].pop().?;
    buffer.real_cursor = .{
        .column = 1,
        .line = buffer.real_cursor.line + 1,
    };
}

pub fn insertBackspace(buffer: *Buffer) !void {
    if (buffer.visualCursor().column > 1) {
        buffer.real_cursor.column = buffer.visualCursor().column - 1;
        _ = buffer.lines.items[buffer.real_cursor.line - 1].orderedRemove(buffer.visualCursor().column - 1);
    }
}

pub fn insertCharacter(buffer: *Buffer, allocator: std.mem.Allocator, char: u8) !void {
    buffer.real_cursor = buffer.visualCursor();
    try buffer.lines.items[buffer.real_cursor.line - 1].insert(allocator, buffer.real_cursor.column - 1, char);
    buffer.real_cursor.column += 1;
}

pub fn shiftCursor(buffer: *Buffer, direction: Editor.Direction) void {
    switch (direction) {
        .up => if (buffer.real_cursor.line > 1) {
            buffer.real_cursor.line -= 1;
        } else {
            // TODO: Go to the start
        },
        .down => if (buffer.real_cursor.line < buffer.lines.items.len) {
            buffer.real_cursor.line += 1;
        } else {
            // TODO: Go to the end
        },
        .left => if (buffer.real_cursor.column > 1) {
            buffer.real_cursor.column = @min(buffer.real_cursor.column - 1, buffer.lines.items[buffer.real_cursor.line - 1].items.len + 1);
        } else {},
        .right => {
            buffer.real_cursor.column = @min(buffer.real_cursor.column + 1, buffer.lines.items[buffer.real_cursor.line - 1].items.len + 1);
        },
    }
}

pub fn goToLine(buffer: *Buffer, line: usize) void {
    buffer.real_cursor.line = @min(@max(line, 1), buffer.lines.items.len);
}

pub fn render(buffer: Buffer, tty: *Tty, viewport: Editor.Viewport) !Tty.Position {
    // TODO: Adjust scroll

    const num_size = @max(std.math.log10(buffer.lines.items.len) + 2, 6);
    for (0..viewport.height) |i| {
        const line_number = i + 1; // TODO: Scroll
        if (line_number <= buffer.lines.items.len) {
            try tty.moveCursor(.{ .x = viewport.x, .y = viewport.y + i });
            try tty.writer().print("{d:>[1]} ", .{ line_number, num_size - 1 });
            try tty.writer().writeAll(buffer.lines.items[line_number - 1].items);
            try tty.writer().writeByteNTimes(' ', viewport.width - num_size - buffer.lines.items[line_number - 1].items.len);
        } else {
            try tty.writer().writeByteNTimes(' ', viewport.width);
        }
    }

    return .{ .x = viewport.x + num_size + buffer.visualCursor().column - 1, .y = viewport.y + buffer.visualCursor().line - 1 }; // TODO: Scroll
}
