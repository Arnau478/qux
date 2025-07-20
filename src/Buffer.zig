const Buffer = @This();

const std = @import("std");
const tree_sitter = @import("tree_sitter");
const Editor = @import("Editor.zig");
const Tty = @import("Tty.zig");
const GapBuffer = @import("buffer/gap_buffer.zig").GapBuffer;

pub const syntax = @import("buffer/syntax.zig");
pub const unicode = @import("buffer/unicode.zig");

allocator: std.mem.Allocator,
bytes: GapBuffer(u8),
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
                buffer.bytes.moveGapTo(insert.position);
                try buffer.bytes.insertSlice(insert.text);

                try buffer.updateCursorFromBytePosition(insert.position + insert.text.len);
            },
            .delete => |delete| {
                buffer.bytes.moveGapTo(delete.position);
                buffer.bytes.deleteForwards(delete.text.len);

                try buffer.updateCursorFromBytePosition(delete.position);
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
                buffer.bytes.moveGapTo(insert.position);
                buffer.bytes.deleteForwards(insert.text.len);

                try buffer.updateCursorFromBytePosition(insert.position);
            },
            .delete => |delete| {
                buffer.bytes.moveGapTo(delete.position);
                try buffer.bytes.insertSlice(delete.text);

                try buffer.updateCursorFromBytePosition(delete.position + delete.text.len);
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
        .bytes = try GapBuffer(u8).init(allocator),
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

    const all_bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(all_bytes);
    var bytes = all_bytes;
    if (bytes[bytes.len - 1] == '\n') {
        bytes = bytes[0 .. bytes.len - 1];
    }

    try buffer.bytes.insertSlice(bytes);
    buffer.dirty = false;

    buffer.filetype = syntax.Filetype.guess(file_path, bytes);

    return buffer;
}

pub fn deinit(buffer: *Buffer) void {
    buffer.bytes.deinit();

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

/// Insert `bytes`. If `combine_action` is `true`, then try to combine it with the latest action in the undo stack.
pub fn insertBytes(buffer: *Buffer, slice: []const u8, combine_action: bool) !void {
    const position = try buffer.getCursorBytePosition();

    try buffer.doAndRecordAction(.{
        .insert = .{
            .position = position,
            .text = try buffer.allocator.dupe(u8, slice),
        },
    }, combine_action);

    buffer.dirty = true;
}

fn deleteBytesForwardsFromBytePosition(buffer: *Buffer, position: usize, byte_count: usize, combine_action: bool) !void {
    const text = try buffer.allocator.alloc(u8, byte_count);
    errdefer buffer.allocator.free(text);
    for (text, 0..) |*char, i| {
        char.* = buffer.bytes.getAt(position + i).?;
    }

    try buffer.doAndRecordAction(.{
        .delete = .{
            .position = position,
            .text = text,
        },
    }, combine_action);

    buffer.dirty = true;
}

/// Delete `count` graphemes forwards. If `combine_action` is `true`, then try to combine it with the latest action in the undo stack.
pub fn deleteForwards(buffer: *Buffer, count: usize, combine_action: bool) !void {
    const byte_position = try buffer.getCursorBytePosition();
    // TODO: Bound checks

    const bytes = buffer.getAllBytes(buffer.allocator);
    defer buffer.allocator.free(bytes);

    const graphemes = try unicode.Graphemes.init(buffer.allocator);
    defer graphemes.deinit(buffer.allocator);
    var iter = graphemes.iterator(bytes[byte_position..]);
    var byte_count: usize = 0;
    for (0..count) |_| {
        byte_count += iter.next().?.len;
    }

    try buffer.deleteBytesForwardsFromBytePosition(byte_position, byte_count, combine_action);
}

/// Delete `count` graphemes backwards (backspace-like). If `combine_action` is `true`, then try to combine it with the latest action in the undo stack.
pub fn deleteBackwards(buffer: *Buffer, count: usize, combine_action: bool) !void {
    const byte_position = try buffer.getCursorBytePosition();
    // TODO: Bound checks

    const bytes = try buffer.getAllBytes(buffer.allocator);
    defer buffer.allocator.free(bytes);

    const graphemes = try unicode.Graphemes.init(buffer.allocator);
    defer graphemes.deinit(buffer.allocator);
    var iter = graphemes.reverseIterator(bytes[0..byte_position]);
    var byte_count: usize = 0;
    for (0..count) |_| {
        byte_count += iter.prev().?.len;
    }

    try buffer.deleteBytesForwardsFromBytePosition(byte_position - byte_count, byte_count, combine_action);
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

pub fn moveCursor(buffer: *Buffer, direction: Editor.Direction) !void {
    switch (direction) {
        .left => {
            if (buffer.cursor_col > 0) {
                buffer.cursor_col -= 1;
            } else if (buffer.cursor_line > 0) {
                buffer.cursor_line -= 1;
                buffer.cursor_col = try buffer.getLineGraphemeLength(buffer.cursor_line);
            }
            buffer.preferred_col = buffer.cursor_col;
        },
        .right => {
            if (buffer.cursor_col < try buffer.getLineGraphemeLength(buffer.cursor_line)) {
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
                buffer.cursor_col = @min(buffer.preferred_col, try buffer.getLineGraphemeLength(buffer.cursor_line));
            } else {
                buffer.cursor_col = 0;
                buffer.preferred_col = buffer.cursor_col;
            }
        },
        .down => {
            if (buffer.cursor_line < buffer.getLineCount() - 1) {
                buffer.cursor_line += 1;
                buffer.cursor_col = @min(buffer.preferred_col, try buffer.getLineGraphemeLength(buffer.cursor_line));
            } else {
                buffer.cursor_col = try buffer.getLineGraphemeLength(buffer.cursor_line);
                buffer.preferred_col = buffer.cursor_col;
            }
        },
    }
}

pub fn moveCursorToLine(buffer: *Buffer, line: usize) !void {
    buffer.cursor_line = line;
    buffer.cursor_col = @min(buffer.preferred_col, try buffer.getLineGraphemeLength(buffer.cursor_line));
}

pub fn moveCursorToLineStart(buffer: *Buffer) void {
    buffer.cursor_col = 0;
    buffer.preferred_col = buffer.cursor_col;
}

pub fn moveCursorToLineEnd(buffer: *Buffer) !void {
    buffer.cursor_col = try buffer.getLineGraphemeLength(buffer.cursor_line);
    buffer.preferred_col = buffer.cursor_col;
}

pub fn getCursorBytePosition(buffer: *Buffer) !usize {
    var position: usize = 0;
    var current_line: usize = 0;

    // Whole lines
    while (current_line < buffer.cursor_line) {
        position += buffer.getLineByteLength(current_line);

        if (current_line < buffer.getLineCount() - 1) {
            position += 1;
        }

        current_line += 1;
    }

    // Current line
    const line_bytes = try buffer.getLineBytes(buffer.cursor_line, buffer.allocator);
    defer buffer.allocator.free(line_bytes);

    const graphemes = try unicode.Graphemes.init(buffer.allocator);
    defer graphemes.deinit(buffer.allocator);
    var iter = graphemes.iterator(line_bytes);
    for (0..buffer.cursor_col) |_| {
        const g = iter.next();
        position += g.?.len;
    }

    return position;
}

pub fn getLineCount(buffer: *Buffer) usize {
    var count: usize = 1;

    for (0..buffer.bytes.getLen()) |i| {
        if (buffer.bytes.getAt(i) == '\n') {
            count += 1;
        }
    }

    return count;
}

pub fn getLineStartBytePosition(buffer: *Buffer, line: usize) usize {
    var current_line: usize = 0;
    var line_start: usize = 0;

    {
        var i: usize = 0;
        while (i < buffer.bytes.getLen() and current_line < line) : (i += 1) {
            if (buffer.bytes.getAt(i) == '\n') {
                current_line += 1;
                line_start = i + 1;
            }
        }
    }

    return line_start;
}

pub fn getLineGraphemeLength(buffer: *Buffer, line: usize) !usize {
    const graphemes = try unicode.Graphemes.init(buffer.allocator);
    defer graphemes.deinit(buffer.allocator);

    const bytes = try buffer.getLineBytes(line, buffer.allocator);
    defer buffer.allocator.free(bytes);

    var iter = graphemes.iterator(bytes);

    var len: usize = 0;
    while (iter.next()) |_| {
        len += 1;
    }

    return len;
}

pub fn getLineByteLength(buffer: *Buffer, line: usize) usize {
    var len: usize = 0;
    for (buffer.getLineStartBytePosition(line)..buffer.bytes.getLen()) |i| {
        const char = buffer.bytes.getAt(i) orelse break;
        if (char == '\n') break;
        len += 1;
    }

    return len;
}

pub fn getLineBytes(buffer: *Buffer, line: usize, allocator: std.mem.Allocator) ![]u8 {
    var line_content: std.ArrayList(u8) = .init(allocator);
    for (buffer.getLineStartBytePosition(line)..buffer.bytes.getLen()) |i| {
        const char = buffer.bytes.getAt(i) orelse break;
        if (char == '\n') break;
        try line_content.append(char);
    }

    return line_content.toOwnedSlice();
}

pub fn getAllBytes(buffer: *Buffer, allocator: std.mem.Allocator) ![]u8 {
    var content = std.ArrayList(u8).init(allocator);
    for (0..buffer.bytes.getLen()) |i| {
        const char = buffer.bytes.getAt(i) orelse break;
        try content.append(char);
    }

    return content.toOwnedSlice();
}

fn updateCursorFromBytePosition(buffer: *Buffer, position: usize) !void {
    var line: usize = 0;
    var col: usize = 0;

    const bytes = try buffer.getAllBytes(buffer.allocator);
    defer buffer.allocator.free(bytes);

    const graphemes = try unicode.Graphemes.init(buffer.allocator);
    defer graphemes.deinit(buffer.allocator);

    var iter = graphemes.iterator(bytes);

    var current_position: usize = 0;

    while (iter.next()) |g| {
        std.debug.assert(current_position <= position);
        if (current_position == position) {
            break;
        }

        if (g.len == 1 and bytes[g.offset] == '\n') {
            line += 1;
            col = 0;
        } else {
            col += 1;
        }

        current_position += g.len;
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

    const bytes = try buffer.getAllBytes(arena.allocator());

    // Syntax highlighting
    if (buffer.tree_sitter_filetype != buffer.filetype) {
        buffer.tree_sitter_filetype = buffer.filetype;
        if (buffer.filetype) |filetype| {
            buffer.tree_sitter_parser.setLanguage(filetype.treeSitterGrammar()()) catch @panic("TODO");
        } else {
            buffer.tree_sitter_parser.setLanguage(null) catch unreachable;
        }
    }

    buffer.tree_sitter_tree = buffer.tree_sitter_parser.parseString(bytes, null); // TODO: Incremental parsing

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
            display_offset += std.math.divCeil(usize, @max(try buffer.getLineGraphemeLength(line_number), 1), viewport.width - number_col_size) catch @panic("TODO");
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

    const line_start_byte_position = buffer.getLineStartBytePosition(line_number);
    const line_bytes = try buffer.getLineBytes(line_number, arena.allocator());

    // Syntax highlighting
    const line_highlight_byte_types = try arena.allocator().alloc(?syntax.HighlightType, line_bytes.len);
    @memset(line_highlight_byte_types, null);
    for (tree_sitter_captures) |capture| {
        const name = buffer.filetype.?.treeSitterQuery().captureNameForId(capture.index).?;
        if (capture.node.endByte() <= line_start_byte_position) continue;
        if (capture.node.startByte() >= line_start_byte_position + line_bytes.len) continue;

        const start = @max(capture.node.startByte(), line_start_byte_position);
        const end = @min(capture.node.endByte(), line_start_byte_position + line_bytes.len);

        for (line_highlight_byte_types[start - line_start_byte_position .. end - line_start_byte_position]) |*t| {
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
    const graphemes = try unicode.Graphemes.init(arena.allocator());

    var grapheme_iter = graphemes.iterator(line_bytes);
    var line_graphemes_list: std.ArrayListUnmanaged(unicode.Graphemes.Grapheme) = .{};
    while (grapheme_iter.next()) |g| {
        try line_graphemes_list.append(arena.allocator(), g);
    }
    const line_graphemes = try line_graphemes_list.toOwnedSlice(arena.allocator());

    var visual_line_idx: usize = 0;
    var visual_line_iter = std.mem.window(unicode.Graphemes.Grapheme, line_graphemes, viewport.width - number_col_size, viewport.width - number_col_size);
    while (visual_line_iter.next()) |visual_line| : (visual_line_idx += 1) {
        std.debug.assert(visual_line.len >= 0);

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

        for (visual_line, 0..) |grapheme, col| {
            const highlight_type = line_highlight_byte_types[grapheme.offset];
            var code_attributes: Tty.Attributes = if (highlight_type) |t| t.getAttributes(theme) else .{};
            if (code_attributes.bg == null) code_attributes.bg = theme.background;
            try tty.moveCursor(.{ .x = viewport.x + number_col_size + col, .y = viewport.y + display_offset });
            try tty.setAttributes(code_attributes);
            try tty.writer().writeAll(grapheme.bytes(line_bytes));
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

        const bytes = try buffer.getAllBytes(buffer.allocator);
        defer buffer.allocator.free(bytes);

        file.writeAll(bytes) catch return error.FileWriteError;
        file.writer().writeByte('\n') catch return error.FileWriteError;

        buffer.dirty = false;

        return is_new;
    } else {
        return error.NoDestination;
    }
}
