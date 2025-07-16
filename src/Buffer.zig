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
undo_stack: std.ArrayListUnmanaged(Action),
redo_stack: std.ArrayListUnmanaged(Action),
filetype: ?syntax.Filetype,
tree_sitter_filetype: ?syntax.Filetype,
tree_sitter_parser: *tree_sitter.Parser,
tree_sitter_tree: ?*tree_sitter.Tree,

pub const Action = union(enum) {
    insert: struct {
        position: usize,
        text: []const u8,
    },
    delete: struct {
        position: usize,
        text: []const u8,
    },
    composite: []Action,

    pub fn deinit(action: Action, allocator: std.mem.Allocator) void {
        switch (action) {
            .insert => |insert| allocator.free(insert.text),
            .delete => |delete| allocator.free(delete.text),
            .composite => |composite| {
                for (composite) |a| {
                    a.deinit(allocator);
                }
                allocator.free(composite);
            },
        }
    }

    // Apply `action` to `buffer`
    pub fn do(action: Action, buffer: *Buffer) !void {
        switch (action) {
            .insert => |insert| {
                buffer.content.moveGapTo(insert.position);
                try buffer.content.insertSlice(insert.text);

                try buffer.updateCursorFromPosition(insert.position + insert.text.len);
            },
            .delete => |delete| {
                buffer.content.moveGapTo(delete.position);
                buffer.content.deleteForwards(delete.text.len);

                try buffer.updateCursorFromPosition(delete.position);
            },
            .composite => |composite| {
                for (composite) |a| {
                    try a.do(buffer);
                }
            },
        }
    }

    // Undo `action` from `buffer` (i.e. apply in reverse)
    pub fn undo(action: Action, buffer: *Buffer) !void {
        switch (action) {
            .insert => |insert| {
                buffer.content.moveGapTo(insert.position);
                buffer.content.deleteForwards(insert.text.len);

                try buffer.updateCursorFromPosition(insert.position);
            },
            .delete => |delete| {
                buffer.content.moveGapTo(delete.position);
                try buffer.content.insertSlice(delete.text);

                try buffer.updateCursorFromPosition(delete.position + delete.text.len);
            },
            .composite => |composite| {
                var iter = std.mem.reverseIterator(composite);
                while (iter.next()) |a| {
                    try a.undo(buffer);
                }
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

/// Insert a character `char`. If `combine_action` is `true`, then try to combine it with the latest action in the undo stack.
pub fn insertCharacter(buffer: *Buffer, char: u8, combine_action: bool) !void {
    try buffer.insertSlice(&.{char}, combine_action);
}

/// Insert a slice `slice`. If `combine_action` is `true`, then try to combine it with the latest action in the undo stack.
pub fn insertSlice(buffer: *Buffer, slice: []const u8, combine_action: bool) !void {
    const position = try buffer.getCursorPosition();

    try buffer.doAndRecordAction(.{
        .insert = .{
            .position = position,
            .text = try buffer.allocator.dupe(u8, slice),
        },
    }, combine_action);

    buffer.dirty = true;
}

fn deleteForwardsFromPosition(buffer: *Buffer, position: usize, count: usize, combine_action: bool) !void {
    const text = try buffer.allocator.alloc(u8, count);
    errdefer buffer.allocator.free(text);
    for (text, 0..) |*char, i| {
        char.* = buffer.content.getAt(position + i).?;
    }

    try buffer.doAndRecordAction(.{
        .delete = .{
            .position = position,
            .text = text,
        },
    }, combine_action);

    buffer.dirty = true;
}

/// Delete `count` characters forwards. If `combine_action` is `true`, then try to combine it with the latest action in the undo stack.
pub fn deleteForwards(buffer: *Buffer, count: usize, combine_action: bool) !void {
    const position = try buffer.getCursorPosition();
    if (position > buffer.content.getLen() - count) return;

    try buffer.deleteForwardsFromPosition(position, count, combine_action);
}

/// Delete `count` characters backwards (backspace-like). If `combine_action` is `true`, then try to combine it with the latest action in the undo stack.
pub fn deleteBackwards(buffer: *Buffer, count: usize, combine_action: bool) !void {
    const position = try buffer.getCursorPosition();
    if (position < count) return;

    try buffer.deleteForwardsFromPosition(position - count, count, combine_action);
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

    try action.undo(buffer);

    try buffer.redo_stack.append(buffer.allocator, action);
}

pub fn redo(buffer: *Buffer) !void {
    if (buffer.redo_stack.items.len == 0) return;

    const action = buffer.redo_stack.pop().?;

    try action.do(buffer);

    try buffer.undo_stack.append(buffer.allocator, action);
}

fn doAndRecordAction(buffer: *Buffer, action: Action, combine_action: bool) !void {
    try action.do(buffer);

    if (combine_action and buffer.undo_stack.items.len != 0) {
        // TODO: Optimize this
        buffer.undo_stack.items[buffer.undo_stack.items.len - 1] = .{
            .composite = try buffer.allocator.dupe(Action, &.{
                buffer.undo_stack.getLast(),
                action,
            }),
        };
    } else {
        try buffer.undo_stack.append(buffer.allocator, action);
    }

    // Clear redo stack
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

pub fn render(buffer: *Buffer, tty: *Tty, viewport: Editor.Viewport, theme: Editor.Theme) !Tty.Position {
    var arena = std.heap.ArenaAllocator.init(buffer.allocator);
    defer arena.deinit();

    const content = try buffer.getAllContent(arena.allocator());

    // Syntax highlighting
    if (buffer.tree_sitter_filetype != buffer.filetype) {
        buffer.tree_sitter_filetype = buffer.filetype;
        if (buffer.filetype) |filetype| {
            buffer.tree_sitter_parser.setLanguage(filetype.treeSitterGrammar()()) catch @panic("TODO");
        } else {
            buffer.tree_sitter_parser.setLanguage(null) catch unreachable;
        }
    }

    buffer.tree_sitter_tree = buffer.tree_sitter_parser.parseString(content, null); // TODO: Incremental parsing

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
            if (buffer.filetype.?.treeSitterQuery().predicatesForPattern(next_capture[1].pattern_index).len > 0) continue; // TODO
            const capture = next_capture[1].captures[next_capture[0]];
            try tree_sitter_captures.append(capture);
        }
    }

    // Render lines
    const number_col_size = @max(std.math.log10(buffer.getLineCount() + 1) + 1, 3) + 1;

    const fully_visible_line_count = count: {
        var display_offset: usize = 0;
        var line_number: usize = buffer.scroll;
        while (display_offset < viewport.height) : (line_number += 1) {
            display_offset += std.math.divCeil(usize, @max(buffer.getLineLength(line_number), 1), viewport.width - number_col_size) catch @panic("TODO");
        }
        if (display_offset > viewport.height) {
            line_number -= 1;
        }
        break :count line_number - buffer.scroll;
    };

    buffer.scrollToLine(buffer.cursor_line, fully_visible_line_count);

    var current_line_display_offset: usize = 0;
    var current_line_number = buffer.scroll;
    var cursor_display_pos: ?Tty.Position = null;
    while (current_line_display_offset < viewport.height) : (current_line_number += 1) {
        if (current_line_number < buffer.getLineCount()) {
            if (current_line_number == buffer.cursor_line) {
                std.debug.assert(cursor_display_pos == null);
                cursor_display_pos = .{
                    .x = viewport.x + number_col_size + buffer.cursor_col % (viewport.width - number_col_size),
                    .y = viewport.y + current_line_display_offset + buffer.cursor_col / (viewport.width - number_col_size),
                };
            }
            const line_height_limit = viewport.height - current_line_display_offset;
            const line_height = try buffer.renderLine(&arena, tty, viewport, theme, current_line_number, current_line_display_offset, tree_sitter_captures.items, number_col_size, line_height_limit);
            std.debug.assert(line_height >= 1);
            current_line_display_offset += line_height;
        } else {
            try tty.setAttributes(theme.number_column);
            try tty.writer().writeByteNTimes(' ', number_col_size);
            try tty.setAttributes(.{ .bg = theme.background, .fg = theme.line_placeholder });
            try tty.writer().writeByte('~');
            try tty.setAttributes(.{ .bg = theme.background });
            try tty.writer().writeByteNTimes(' ', viewport.width - number_col_size - 1);
            current_line_display_offset += 1;
        }
    }

    return cursor_display_pos.?;
}

fn renderLine(buffer: *Buffer, arena: *std.heap.ArenaAllocator, tty: *Tty, viewport: Editor.Viewport, theme: Editor.Theme, line_number: usize, line_display_offset: usize, tree_sitter_captures: []const tree_sitter.Query.Capture, number_col_size: usize, line_height_limit: usize) !usize {
    std.debug.assert(line_height_limit >= 1);

    const line_start_pos = buffer.getLineStartPos(line_number);
    const line_content = try buffer.getLine(line_number, arena.allocator());

    // Syntax highlighting
    const line_highlight_types = try arena.allocator().alloc(?syntax.HighlightType, line_content.len);
    @memset(line_highlight_types, null);
    for (tree_sitter_captures) |capture| {
        const name = buffer.filetype.?.treeSitterQuery().captureNameForId(capture.index).?;
        if (capture.node.endByte() <= line_start_pos) continue;
        if (capture.node.startByte() >= line_start_pos + line_content.len) continue;

        const start = @max(capture.node.startByte(), line_start_pos);
        const end = @min(capture.node.endByte(), line_start_pos + line_content.len);

        for (line_highlight_types[start - line_start_pos .. end - line_start_pos]) |*t| {
            if (syntax.HighlightType.fromTreeSitterCapture(name)) |highlight_type| {
                if (t.* == null or t.*.?.compareSpecificity(highlight_type) == .lt) {
                    t.* = syntax.HighlightType.fromTreeSitterCapture(name);
                }
            } else {
                std.log.warn("Unknown tree sitter capture: @{s}", .{name});
                break;
            }
        }
    }

    // Render the line
    var visual_line_idx: usize = 0;
    var window_iter = std.mem.window(u8, line_content, viewport.width - number_col_size, viewport.width - number_col_size);
    var highlight_types_window_iter = std.mem.window(?syntax.HighlightType, line_highlight_types, viewport.width - number_col_size, viewport.width - number_col_size);
    while (window_iter.next()) |visual_line| : (visual_line_idx += 1) {
        std.debug.assert(visual_line_idx <= line_height_limit);
        if (visual_line_idx == line_height_limit) {
            const continue_indicator = ">";
            try tty.moveCursor(.{
                .x = viewport.x + viewport.width - continue_indicator.len,
                .y = viewport.y + line_display_offset + (visual_line_idx - 1),
            });
            try tty.setAttributes(theme.line_continue_indicator);
            try tty.writer().writeAll(continue_indicator);
            break;
        }

        const visual_line_highlight_types = highlight_types_window_iter.next().?;
        const display_offset = line_display_offset + visual_line_idx;

        try tty.moveCursor(.{ .x = viewport.x, .y = viewport.y + display_offset });

        if (line_number == buffer.cursor_line and visual_line_idx == 0) {
            try tty.setAttributes(theme.number_column_current);
        } else {
            try tty.setAttributes(theme.number_column);
        }

        if (visual_line_idx == 0) {
            try tty.writer().print("{d:>[1]} ", .{ line_number + 1, number_col_size - 1 });
        } else {
            const digit_len = std.math.log10(line_number + 1) + 1;
            try tty.writer().writeByteNTimes(' ', number_col_size - digit_len - 1);
            try tty.writer().writeByteNTimes('>', digit_len);
            try tty.writer().writeByte(' ');
        }

        for (visual_line, visual_line_highlight_types) |char, highlight_type| {
            var code_attributes: Tty.Attributes = if (highlight_type) |t| t.getAttributes(theme) else .{};
            if (code_attributes.bg == null) code_attributes.bg = theme.background;
            try tty.setAttributes(code_attributes);
            try tty.writer().writeByte(char);
        }

        try tty.setAttributes(.{ .bg = theme.background });
        try tty.writer().writeByteNTimes(' ', viewport.width - number_col_size - visual_line.len);
    }

    return visual_line_idx;
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
