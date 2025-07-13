const Theme = @This();

const std = @import("std");
const Tty = @import("../Tty.zig");

pub const default_builtin = builtin.basic;

pub fn byName(name: []const u8) ?Theme {
    inline for (comptime std.meta.declarations(builtin)) |decl| {
        if (std.mem.eql(u8, name, decl.name)) {
            return @field(builtin, decl.name);
        }
    }

    return null;
}

pub const builtin = struct {
    pub const basic: Theme = .{
        .background = null,
        .number_column = .{},
        .number_column_current = .{},
        .line_placeholder = .{ .standard = .magenta },
        .line_continue_indicator = .{ .fg = .{ .standard = .bright_black } },
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
            .character = .{ .fg = .{ .standard = .green } },
            .string = .{ .fg = .{ .standard = .green } },
            .variable = .{},
            .function = .{ .fg = .{ .standard = .blue } },
            .type = .{ .fg = .{ .standard = .cyan } },
            .number = .{ .fg = .{ .standard = .magenta } },
            .operator = .{},
            .keyword = .{ .fg = .{ .standard = .magenta } },
            .boolean = .{ .fg = .{ .standard = .yellow } },
        },
    };

    // Based on https://github.com/rebelot/kanagawa.nvim
    pub const kanagawa: Theme = .{
        .background = .{ .rgb = .{ .r = 0x1f, .g = 0x1f, .b = 0x28 } },
        .number_column = .{ .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x37 } }, .fg = .{ .rgb = .{ .r = 0x54, .g = 0x54, .b = 0x6d } } },
        .number_column_current = .{ .bg = .{ .rgb = .{ .r = 0x2a, .g = 0x2a, .b = 0x37 } }, .fg = .{ .rgb = .{ .r = 0xff, .g = 0x9e, .b = 0x3b } }, .bold = true },
        .line_placeholder = .{ .rgb = .{ .r = 0x54, .g = 0x54, .b = 0x6d } },
        .line_continue_indicator = .{ .fg = .{ .rgb = .{ .r = 0x54, .g = 0x54, .b = 0x6d } }, .bold = true },
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
            .character = .{ .fg = .{ .rgb = .{ .r = 0x98, .g = 0xbb, .b = 0x6c } } },
            .string = .{ .fg = .{ .rgb = .{ .r = 0x98, .g = 0xbb, .b = 0x6c } } },
            .variable = .{ .fg = .{ .rgb = .{ .r = 0xdc, .g = 0xd7, .b = 0xba } } },
            .function = .{ .fg = .{ .rgb = .{ .r = 0x7e, .g = 0x9c, .b = 0xd8 } } },
            .type = .{ .fg = .{ .rgb = .{ .r = 0x7a, .g = 0xa8, .b = 0x9f } } },
            .number = .{ .fg = .{ .rgb = .{ .r = 0xd2, .g = 0x7e, .b = 0x99 } } },
            .operator = .{ .fg = .{ .rgb = .{ .r = 0xc0, .g = 0xa3, .b = 0x6e } } },
            .keyword = .{ .fg = .{ .rgb = .{ .r = 0x95, .g = 0x7f, .b = 0xb8 } }, .italic = true },
            .boolean = .{ .fg = .{ .rgb = .{ .r = 0xff, .g = 0xa0, .b = 0x66 } }, .bold = true },
        },
    };
};

background: ?Tty.Color,
number_column: Tty.Attributes,
number_column_current: Tty.Attributes,
line_placeholder: ?Tty.Color,
line_continue_indicator: Tty.Attributes,
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
    character: Tty.Attributes,
    string: Tty.Attributes,
    variable: Tty.Attributes,
    function: Tty.Attributes,
    type: Tty.Attributes,
    number: Tty.Attributes,
    operator: Tty.Attributes,
    keyword: Tty.Attributes,
    boolean: Tty.Attributes,
},
