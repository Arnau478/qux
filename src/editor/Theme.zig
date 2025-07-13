const Theme = @This();
const Tty = @import("../Tty.zig");

pub const default: Theme = .{
    .background = null,
    .number_column = .{},
    .number_column_current = .{},
    .line_placeholder = .{ .standard = .magenta },
    .notice_info = null,
    .notice_error = .{ .standard = .red },
    .main_bar_background = .{ .standard = .black },
    .mode = .{
        .normal = .{ .standard = .cyan },
        .insert = .{ .standard = .green },
        .command = .{ .standard = .yellow },
    },
    .syntax = .{
        .comment = .{ .fg = .{ .standard = .bright_black } },
        .string = .{ .fg = .{ .standard = .green } },
        .variable = .{},
        .function = .{ .fg = .{ .standard = .blue } },
        .type = .{ .fg = .{ .standard = .cyan } },
        .keyword = .{ .fg = .{ .standard = .magenta } },
    },
};

// Based on https://github.com/rebelot/kanagawa.nvim
pub const kanagawa: Theme = .{
    .background = .{ .rgb = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 } },
    .number_column = .{ .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x37 } }, .fg = .{ .rgb = .{ .r = 0x54, .g = 0x54, .b = 0x6d } } },
    .number_column_current = .{ .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x37 } }, .fg = .{ .rgb = .{ .r = 0xff, .g = 0x9e, .b = 0x3b } }, .bold = true },
    .line_placeholder = .{ .rgb = .{ .r = 0x54, .g = 0x54, .b = 0x6d } },
    .notice_info = .{ .rgb = .{ .r = 0xdc, .g = 0xd7, .b = 0xba } },
    .notice_error = .{ .rgb = .{ .r = 0xe8, .g = 0x24, .b = 0x24 } },
    .main_bar_background = .{ .rgb = .{ .r = 0x16, .g = 0x16, .b = 0x1d } },
    .mode = .{
        .normal = .{ .rgb = .{ .r = 0x7e, .g = 0x9c, .b = 0xd8 } },
        .insert = .{ .rgb = .{ .r = 0x98, .g = 0xbb, .b = 0x6c } },
        .command = .{ .rgb = .{ .r = 0xc0, .g = 0xa3, .b = 0x6e } },
    },
    .syntax = .{
        .comment = .{ .fg = .{ .rgb = .{ .r = 0x72, .g = 0x71, .b = 0x69 } }, .italic = true },
        .string = .{ .fg = .{ .rgb = .{ .r = 0x98, .g = 0xbb, .b = 0x6c } } },
        .variable = .{ .fg = .{ .rgb = .{ .r = 0xdc, .g = 0xd7, .b = 0xba } } },
        .function = .{ .fg = .{ .rgb = .{ .r = 0x7e, .g = 0x9c, .b = 0xd8 } } },
        .type = .{ .fg = .{ .rgb = .{ .r = 0x7a, .g = 0xa8, .b = 0x9f } } },
        .keyword = .{ .fg = .{ .rgb = .{ .r = 0x95, .g = 0x7f, .b = 0xb8 } }, .italic = true },
    },
};

background: ?Tty.Color,
number_column: Tty.Attributes,
number_column_current: Tty.Attributes,
line_placeholder: ?Tty.Color,
notice_info: ?Tty.Color,
notice_error: Tty.Color,
main_bar_background: Tty.Color,
mode: struct {
    normal: Tty.Color,
    insert: Tty.Color,
    command: Tty.Color,
},
syntax: struct {
    comment: Tty.Attributes,
    string: Tty.Attributes,
    variable: Tty.Attributes,
    function: Tty.Attributes,
    type: Tty.Attributes,
    keyword: Tty.Attributes,
},
