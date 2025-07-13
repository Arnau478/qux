const Buffer = @This();

const std = @import("std");
const tree_sitter = @import("tree_sitter");
const Editor = @import("Editor.zig");
const Tty = @import("Tty.zig");
const GapBuffer = @import("buffer/gap_buffer.zig").GapBuffer;

pub const syntax = @import("buffer/syntax.zig");

allocator: std.mem.Allocator,
content: GapBuffer(u8),
destination: ?[]const u8,
dirty: bool,
read_only: bool,
cursor_line: usize,
cursor_col: usize,
preferred_col: usize,
scroll: usize,
undo_stack: std.ArrayListUnmanaged(UndoAction),
redo_stack: std.ArrayListUnmanaged(UndoAction),
filetype: ?syntax.Filetype,
tree_sitter_filetype: ?syntax.Filetype,
tree_sitter_parser: *tree_sitter.Parser,
tree_sitter_tree: ?*tree_sitter.Tree,

pub const UndoAction = union(enum) {
    insert: struct {
        position: usize,
        text: []const u8,
    },
    delete: struct {
        position: usize,
        text: []const u8,
    },
    replace: struct {
        position: usize,
        old_text: []const u8,
        new_text: []const u8,
    },

    pub fn deinit(action: UndoAction, allocator: std.mem.Allocator) void {
        switch (action) {
            .insert => |insert| allocator.free(insert.text),
            .delete => |delete| allocator.free(delete.text),
            .replace => |replace| {
                allocator.free(replace.old_text);
                allocator.free(replace.new_text);
            },
        }
    }
};

pub fn init(allocator: std.mem.Allocator) !Buffer {
    return .{
        .allocator = allocator,
        .content = try GapBuffer(u8).init(allocator),
        .destination = null,
        .dirty = false,
        .read_only = false,
        .cursor_line = 0,
        .cursor_col = 0,
        .preferred_col = 0,
        .scroll = 0,
        .undo_stack = .{},
        .redo_stack = .{},
        .filetype = null,
        .tree_sitter_filetype = null,
        .tree_sitter_parser = tree_sitter.Parser.create(),
        .tree_sitter_tree = null,
    };
}

pub fn initFromFile(allocator: std.mem.Allocator, file_path: []const u8) !Buffer {
    var buffer = try Buffer.init(allocator);
    buffer.destination = try allocator.dupe(u8, file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            buffer.filetype = syntax.Filetype.guess(file_path, null);

            return buffer;
        },
        else => @panic("TODO"),
    };
    defer file.close();

    if (std.meta.isError(std.fs.cwd().access(file_path, .{ .mode = .read_write }))) {
        buffer.read_only = true;
    }

    const raw_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(raw_content);
    var content = raw_content;
    if (content[content.len - 1] == '\n') {
        content = content[0 .. content.len - 1];
    }

    try buffer.content.insertSlice(content);
    buffer.dirty = false;

    buffer.filetype = syntax.Filetype.guess(file_path, content);

    return buffer;
}

pub fn deinit(buffer: *Buffer) void {
    buffer.content.deinit();

    if (buffer.destination) |destination| buffer.allocator.free(destination);

    for (buffer.undo_stack.items) |action| {
        action.deinit(buffer.allocator);
    }
    buffer.undo_stack.deinit(buffer.allocator);

    for (buffer.redo_stack.items) |action| {
        action.deinit(buffer.allocator);
    }
    buffer.redo_stack.deinit(buffer.allocator);

    buffer.tree_sitter_parser.destroy();
}

pub fn insertCharacter(buffer: *Buffer, char: u8) !void {
    const position = try buffer.getCursorPosition();

    buffer.content.moveGapTo(position);
    try buffer.content.insert(char);

    try buffer.recordUndoAction(.{
        .insert = .{
            .position = position,
            .text = try buffer.allocator.dupe(u8, &[_]u8{char}),
        },
    });

    if (char == '\n') {
        buffer.cursor_line += 1;
        buffer.cursor_col = 0;
    } else {
        buffer.cursor_col += 1;
    }
    buffer.preferred_col = buffer.cursor_col;

    buffer.dirty = true;
}

pub fn insertSlice(buffer: *Buffer, slice: []const u8) !void {
    const position = try buffer.getCursorPosition();

    buffer.content.moveGapTo(position);
    buffer.content.insertSlice(slice);

    try buffer.recordUndoAction(.{
        .insert = .{
            .position = position,
            .text = try buffer.allocator.dupe(u8, slice),
        },
    });

    for (slice) |char| {
        if (char == '\n') {
            buffer.cursor_line += 1;
            buffer.cursor_col = 0;
        } else {
            buffer.cursor_col += 1;
        }
    }
    buffer.preferred_col = buffer.cursor_col;

    buffer.dirty = true;
}

pub fn deleteCharacter(buffer: *Buffer) !void {
    const position = try buffer.getCursorPosition();
    if (position >= buffer.content.getLen()) return;

    const char = buffer.content.getAt(position);

    buffer.content.moveGapTo(position);
    buffer.content.deleteForwards();

    try buffer.recordUndoAction(.{
        .delete = .{
            .position = position,
            .text = try buffer.allocator.dupe(u8, &[_]u8{char}),
        },
    });

    buffer.dirty = true;
}

pub fn backspace(buffer: *Buffer) !void {
    if (buffer.cursor_line == 0 and buffer.cursor_col == 0) return;

    const position = try buffer.getCursorPosition();
    if (position == 0) return;

    const char = buffer.content.getAt(position - 1) orelse return;

    buffer.content.moveGapTo(position);
    buffer.content.deleteBackwards();

    try buffer.recordUndoAction(.{
        .delete = .{
            .position = position - 1,
            .text = try buffer.allocator.dupe(u8, &[_]u8{char}),
        },
    });

    if (char == '\n') {
        buffer.cursor_line -= 1;
        buffer.cursor_col = buffer.getLineLength(buffer.cursor_line);
    } else {
        buffer.cursor_col -= 1;
    }
    buffer.preferred_col = buffer.cursor_col;

    buffer.dirty = true;
}

pub fn moveCursor(buffer: *Buffer, direction: Editor.Direction) void {
    switch (direction) {
        .left => {
            if (buffer.cursor_col > 0) {
                buffer.cursor_col -= 1;
            } else if (buffer.cursor_line > 0) {
                buffer.cursor_line -= 1;
                buffer.cursor_col = buffer.getLineLength(buffer.cursor_line);
            }
            buffer.preferred_col = buffer.cursor_col;
        },
        .right => {
            if (buffer.cursor_col < buffer.getLineLength(buffer.cursor_line)) {
                buffer.cursor_col += 1;
            } else if (buffer.cursor_line < buffer.getLineCount() - 1) {
                buffer.cursor_line += 1;
                buffer.cursor_col = 0;
            }
            buffer.preferred_col = buffer.cursor_col;
        },
        .up => {
            if (buffer.cursor_line > 0) {
                buffer.cursor_line -= 1;
                buffer.cursor_col = @min(buffer.preferred_col, buffer.getLineLength(buffer.cursor_line));
            } else {
                // TODO: Go to the beginning
            }
        },
        .down => {
            if (buffer.cursor_line < buffer.getLineCount() - 1) {
                buffer.cursor_line += 1;
                buffer.cursor_col = @min(buffer.preferred_col, buffer.getLineLength(buffer.cursor_line));
            } else {
                // TODO: Go to the end
            }
        },
    }
}

pub fn moveCursorToLine(buffer: *Buffer, line: usize) void {
    buffer.cursor_line = line;
    buffer.cursor_col = @min(buffer.preferred_col, buffer.getLineLength(buffer.cursor_line));
}

pub fn moveCursorToLineStart(buffer: *Buffer) void {
    buffer.cursor_col = 0;
    buffer.preferred_col = buffer.cursor_col;
}

pub fn moveCursorToLineEnd(buffer: *Buffer) void {
    buffer.cursor_col = buffer.getLineLength(buffer.cursor_line);
    buffer.preferred_col = buffer.cursor_col;
}

pub fn getCursorPosition(buffer: *Buffer) !usize {
    var position: usize = 0;
    var current_line: usize = 0;

    while (current_line < buffer.cursor_line) {
        position += buffer.getLineLength(current_line);

        if (current_line < buffer.getLineCount() - 1) {
            position += 1;
        }

        current_line += 1;
    }

    position += buffer.cursor_col;

    return position;
}

pub fn getLineCount(buffer: *Buffer) usize {
    var count: usize = 1;

    for (0..buffer.content.getLen()) |i| {
        if (buffer.content.getAt(i) == '\n') {
            count += 1;
        }
    }

    return count;
}

pub fn getLineStartPos(buffer: *Buffer, line: usize) usize {
    var current_line: usize = 0;
    var line_start: usize = 0;

    {
        var i: usize = 0;
        while (i < buffer.content.getLen() and current_line < line) : (i += 1) {
            if (buffer.content.getAt(i) == '\n') {
                current_line += 1;
                line_start = i + 1;
            }
        }
    }

    return line_start;
}

pub fn getLineLength(buffer: *Buffer, line: usize) usize {
    var len: usize = 0;
    for (buffer.getLineStartPos(line)..buffer.content.getLen()) |i| {
        const char = buffer.content.getAt(i) orelse break;
        if (char == '\n') break;
        len += 1;
    }

    return len;
}

pub fn getLine(buffer: *Buffer, line: usize, allocator: std.mem.Allocator) ![]u8 {
    var line_content: std.ArrayList(u8) = .init(allocator);
    for (buffer.getLineStartPos(line)..buffer.content.getLen()) |i| {
        const char = buffer.content.getAt(i) orelse break;
        if (char == '\n') break;
        try line_content.append(char);
    }

    return line_content.toOwnedSlice();
}

pub fn getAllContent(buffer: *Buffer, allocator: std.mem.Allocator) ![]u8 {
    var content = std.ArrayList(u8).init(allocator);
    for (0..buffer.content.getLen()) |i| {
        const char = buffer.content.getAt(i) orelse break;
        try content.append(char);
    }

    return content.toOwnedSlice();
}

pub fn undo(buffer: *Buffer) !void {
    if (buffer.undo_stack.items.len == 0) return;

    const action = buffer.undo_stack.pop().?;

    switch (action) {
        .insert => |insert| {
            buffer.content.moveGapTo(insert.position);

            for (0..insert.text.len) |_| {
                buffer.content.deleteForwards();
            }
        },
        .delete => |delete| {
            buffer.content.moveGapTo(delete.position);
            try buffer.content.insertSlice(delete.text);
        },
        .replace => |replace| {
            buffer.content.moveGapTo(replace.position);
            for (0..replace.new_text.len) |_| {
                buffer.content.deleteForwards();
            }

            try buffer.content.insertSlice(replace.old_text);
        },
    }

    try buffer.redo_stack.append(buffer.allocator, action);

    try buffer.updateCursorFromPosition(switch (action) {
        inline else => |a| @field(a, "position"),
    });
}

pub fn redo(buffer: *Buffer) !void {
    if (buffer.redo_stack.items.len == 0) return;

    const action = buffer.redo_stack.pop().?;

    switch (action) {
        .insert => |insert| {
            buffer.content.moveGapTo(insert.position);
            try buffer.content.insertSlice(insert.text);
        },
        .delete => |delete| {
            buffer.content.moveGapTo(delete.position);

            for (0..delete.text.len) |_| {
                buffer.content.deleteForwards();
            }
        },
        .replace => |replace| {
            buffer.content.moveGapTo(replace.position);
            for (0..replace.old_text.len) |_| {
                buffer.content.deleteForwards();
            }

            try buffer.content.insertSlice(replace.new_text);
        },
    }

    try buffer.undo_stack.append(buffer.allocator, action);

    try buffer.updateCursorFromPosition(switch (action) {
        .insert => |insert| insert.position + insert.text.len,
        .delete => |delete| delete.position,
        .replace => |replace| replace.position + replace.new_text.len,
    });
}

fn recordUndoAction(buffer: *Buffer, action: UndoAction) !void {
    try buffer.undo_stack.append(buffer.allocator, action);

    for (buffer.redo_stack.items) |redo_action| {
        redo_action.deinit(buffer.allocator);
    }

    buffer.redo_stack.clearRetainingCapacity();
}

fn updateCursorFromPosition(buffer: *Buffer, position: usize) !void {
    var line: usize = 0;
    var col: usize = 0;

    for (0..@min(position, buffer.content.getLen())) |i| {
        const char = buffer.content.getAt(i) orelse break;
        if (char == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }
    }

    buffer.cursor_line = line;
    buffer.cursor_col = col;
    buffer.preferred_col = col;
}

fn scrollToLine(buffer: *Buffer, line: usize, height: usize) void {
    buffer.scroll = @min(buffer.scroll, line);
    buffer.scroll = @max(buffer.scroll + (height - 1), line) - (height - 1);
}

pub const HighlightType = enum {
    comment,
    string,

    pub fn getAttributes(highlight_type: HighlightType, theme: Editor.Theme) Tty.Attributes {
        return switch (highlight_type) {
            .comment => theme.syntax.comment,
            .string => theme.syntax.string,
        };
    }
};

pub fn render(buffer: *Buffer, tty: *Tty, viewport: Editor.Viewport, theme: Editor.Theme) !Tty.Position {
    var arena = std.heap.ArenaAllocator.init(buffer.allocator);
    defer arena.deinit();

    if (buffer.tree_sitter_filetype != buffer.filetype) {
        buffer.tree_sitter_filetype = buffer.filetype;
        if (buffer.filetype) |filetype| {
            buffer.tree_sitter_parser.setLanguage(filetype.treeSitterGrammar()()) catch @panic("TODO");
        } else {
            buffer.tree_sitter_parser.setLanguage(null) catch unreachable;
        }
    }

    const content = try buffer.getAllContent(arena.allocator());
    buffer.tree_sitter_tree = buffer.tree_sitter_parser.parseString(content, null).?; // TODO: Incremental parsing

    const tree_sitter_query_cursor = cursor: {
        if (buffer.filetype) |filetype| {
            const query = filetype.treeSitterQuery();
            const cursor = tree_sitter.QueryCursor.create();
            cursor.exec(query, buffer.tree_sitter_tree.?.rootNode());

            break :cursor cursor;
        } else {
            break :cursor null;
        }
    };

    defer if (tree_sitter_query_cursor) |cursor| cursor.destroy();

    var tree_sitter_captures = std.ArrayList(tree_sitter.Query.Capture).init(arena.allocator());
    if (tree_sitter_query_cursor) |cursor| {
        while (cursor.nextCapture()) |next_capture| {
            const capture = next_capture[1].captures[next_capture[0]];
            try tree_sitter_captures.append(capture);
        }
    }

    buffer.scrollToLine(buffer.cursor_line, viewport.height);

    const number_col_size = @max(std.math.log10(buffer.getLineCount()) + 1, 3) + 1;

    for (0..viewport.height) |i| {
        const line_number = i + buffer.scroll;
        const line_content = try buffer.getLine(line_number, arena.allocator());

        try tty.moveCursor(.{ .x = viewport.x, .y = viewport.y + i });
        if (line_number < buffer.getLineCount()) {
            const line_start_pos = buffer.getLineStartPos(line_number);

            const line_highlight_types = try arena.allocator().alloc(?HighlightType, line_content.len);
            @memset(line_highlight_types, null);
            for (tree_sitter_captures.items) |capture| {
                const name = buffer.filetype.?.treeSitterQuery().captureNameForId(capture.index).?;
                if (capture.node.endByte() <= line_start_pos) continue;
                if (capture.node.startByte() >= line_start_pos + line_content.len) continue;

                const start = @max(capture.node.startByte(), line_start_pos);
                const end = @min(capture.node.endByte(), line_start_pos + line_content.len);

                for (line_highlight_types[start - line_start_pos .. end - line_start_pos]) |*t| {
                    if (t.* == null) {
                        const highlight_type: ?HighlightType = if (std.mem.eql(u8, name, "comment"))
                            .comment
                        else if (std.mem.eql(u8, name, "string"))
                            .string
                        else blk: {
                            std.log.warn("Unknown tree sitter capture: @{s}", .{name});
                            break :blk null;
                        };
                        t.* = highlight_type;
                    }
                }
            }

            if (line_number == buffer.cursor_line) {
                try tty.setAttributes(theme.number_column_current);
            } else {
                try tty.setAttributes(theme.number_column);
            }
            try tty.writer().print("{d:>[1]} ", .{ line_number + 1, number_col_size - 1 });
            for (line_content, line_highlight_types) |char, line_highlight_type| {
                var code_attributes: Tty.Attributes = if (line_highlight_type) |t| t.getAttributes(theme) else .{};
                if (code_attributes.bg == null) code_attributes.bg = theme.background;
                try tty.setAttributes(code_attributes);
                try tty.writer().writeByte(char);
            }
            try tty.setAttributes(.{ .bg = theme.background });
            try tty.writer().writeByteNTimes(' ', viewport.width - number_col_size - line_content.len);
        } else {
            try tty.setAttributes(theme.number_column);
            try tty.writer().writeByteNTimes(' ', number_col_size);
            try tty.setAttributes(.{ .bg = theme.background, .fg = theme.line_placeholder });
            try tty.writer().writeByte('~');
            try tty.setAttributes(.{ .bg = theme.background });
            try tty.writer().writeByteNTimes(' ', viewport.width - number_col_size - 1);
        }
    }

    return .{
        .x = viewport.x + number_col_size + buffer.cursor_col,
        .y = viewport.y + buffer.cursor_line - buffer.scroll,
    };
}

pub fn save(buffer: *Buffer) !bool {
    if (buffer.destination) |destination| {
        const is_new = std.meta.isError(std.fs.cwd().access(destination, .{}));

        if (!is_new and std.meta.isError(std.fs.cwd().access(destination, .{ .mode = .read_write }))) {
            buffer.read_only = true;
        }

        const file = std.fs.cwd().createFile(destination, .{}) catch return error.FileOpenError;
        defer file.close();

        const content = try buffer.getAllContent(buffer.allocator);
        defer buffer.allocator.free(content);

        file.writeAll(content) catch return error.FileWriteError;
        file.writer().writeByte('\n') catch return error.FileWriteError;

        buffer.dirty = false;

        return is_new;
    } else {
        return error.NoDestination;
    }
}
