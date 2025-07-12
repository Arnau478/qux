const Tty = @This();

const std = @import("std");
const builtin = @import("builtin");

pub const Input = @import("tty/input.zig").Input;

impl: Impl,

const Impl = switch (builtin.os.tag) {
    .linux,
    .macos,
    .watchos,
    .visionos,
    .tvos,
    .ios,
    .freebsd,
    .netbsd,
    .openbsd,
    .haiku,
    .solaris,
    .illumos,
    .serenity,
    => @import("tty/PosixTty.zig"),
    else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
};

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const Position = struct {
    x: usize,
    y: usize,
};

pub const ReadError = Impl.ReadError;
pub const WriteError = Impl.WriteError;
pub const Reader = Impl.Reader;
pub const Writer = Impl.Writer;

pub const Color = union(enum) {
    standard: Standard,
    rgb: Rgb,

    pub const Standard = enum {
        black,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,
        bright_black,
        bright_red,
        bright_green,
        bright_yellow,
        bright_blue,
        bright_magenta,
        bright_cyan,
        bright_white,
    };

    pub const Rgb = struct {
        r: u8,
        g: u8,
        b: u8,
    };
};

pub const Attributes = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
};

pub const CursorShape = enum {
    block,
    bar,
};

pub fn flush(tty: *Tty) !void {
    return tty.impl.flush();
}

pub fn writer(tty: *Tty) Writer {
    return tty.impl.writer();
}

pub fn reader(tty: Tty) Reader {
    return tty.impl.reader();
}

pub fn readInput(tty: Tty) !Input {
    return tty.impl.readInput();
}

pub fn getSize(tty: Tty) !Size {
    return tty.impl.getSize();
}

pub fn moveCursor(tty: *Tty, pos: Position) !void {
    return tty.impl.moveCursor(pos);
}

pub fn setAttributes(tty: *Tty, attributes: Attributes) !void {
    return tty.impl.setAttributes(attributes);
}

pub fn showCursor(tty: *Tty) !void {
    return tty.impl.showCursor();
}

pub fn hideCursor(tty: *Tty) !void {
    return tty.impl.hideCursor();
}

pub fn setCursorShape(tty: *Tty, shape: CursorShape) !void {
    return tty.impl.setCursorShape(shape);
}

pub fn init() !Tty {
    return .{ .impl = try .init() };
}

pub fn deinit(tty: *Tty) void {
    return tty.impl.deinit();
}

pub fn clearLine(tty: *Tty, line: usize) !void {
    try tty.moveCursor(.{ .x = 0, .y = line });
    try tty.writer().writeByteNTimes(' ', (try tty.getSize()).width);
}

pub fn resetAttributes(tty: *Tty) !void {
    return tty.setAttributes(.{});
}
