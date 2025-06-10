const PosixTty = @This();

const std = @import("std");
const Input = @import("input.zig").Input;
const Tty = @import("../Tty.zig");

fd: std.posix.fd_t,
old_termios: std.posix.termios,
write_buffer: [2048]u8 = undefined,
write_buffer_len: usize = 0,

pub const ReadError = std.posix.ReadError;
pub const WriteError = std.posix.WriteError;
pub const Reader = std.io.GenericReader(PosixTty, ReadError, read);
pub const Writer = std.io.GenericWriter(*PosixTty, WriteError, write);

fn write(tty: *PosixTty, bytes: []const u8) WriteError!usize {
    if (tty.write_buffer_len + bytes.len > tty.write_buffer.len) {
        try tty.flush();
        if (bytes.len > tty.write_buffer.len) {
            return tty.directWrite(bytes);
        }
    }

    const new_len = tty.write_buffer_len + bytes.len;
    @memcpy(tty.write_buffer[tty.write_buffer_len..new_len], bytes);
    tty.write_buffer_len = new_len;
    return bytes.len;
}

pub fn flush(tty: *PosixTty) !void {
    try (std.io.GenericWriter(PosixTty, WriteError, directWrite){ .context = tty.* }).writeAll(tty.write_buffer[0..tty.write_buffer_len]);
    tty.write_buffer_len = 0;
}

fn directWrite(tty: PosixTty, bytes: []const u8) WriteError!usize {
    return try std.posix.write(tty.fd, bytes);
}

pub fn writer(tty: *PosixTty) Writer {
    return .{ .context = tty };
}

fn read(tty: PosixTty, buf: []u8) ReadError!usize {
    return try std.posix.read(tty.fd, buf);
}

pub fn reader(tty: PosixTty) Reader {
    return .{ .context = tty };
}

pub fn readInput(tty: PosixTty) !Input {
    const byte = try tty.reader().readByte();
    switch (byte) {
        32...126 => return .{ .printable = @intCast(byte) },
        '\x1b' => {
            var termios = try std.posix.tcgetattr(tty.fd);
            termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;
            termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
            try std.posix.tcsetattr(tty.fd, .NOW, termios);

            var escape_buffer: [8]u8 = undefined;
            const escape_read_len = try tty.reader().read(&escape_buffer);

            termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            try std.posix.tcsetattr(tty.fd, .NOW, termios);

            const escape = escape_buffer[0..escape_read_len];
            if (escape.len == 0) {
                return .escape;
            } else if (std.mem.eql(u8, escape, "[A")) {
                return .{ .arrow = .up };
            } else if (std.mem.eql(u8, escape, "[B")) {
                return .{ .arrow = .down };
            } else if (std.mem.eql(u8, escape, "[C")) {
                return .{ .arrow = .right };
            } else if (std.mem.eql(u8, escape, "[D")) {
                return .{ .arrow = .left };
            } else {
                std.log.err("Unkown escape sequence: {s}", .{escape});
                return .escape;
            }
        },
        '\n', '\r' => return .@"return",
        8, 127 => return .backspace,
        else => return .{ .unknown = byte },
    }
}

fn uncook(tty: *PosixTty) !void {
    tty.old_termios = try std.posix.tcgetattr(tty.fd);
    errdefer tty.cook() catch {};

    var raw = tty.old_termios;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;

    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;

    try std.posix.tcsetattr(tty.fd, .FLUSH, raw);

    try tty.writer().writeAll("\x1b[?25l");
    try tty.writer().writeAll("\x1b[?1049h");
    try tty.flush();
}

fn cook(tty: *PosixTty) !void {
    try tty.writer().writeAll("\x1b[?1049l");
    try tty.writer().writeAll("\x1b[?25h");
    try tty.flush();

    try std.posix.tcsetattr(tty.fd, .FLUSH, tty.old_termios);
}

pub fn getSize(tty: PosixTty) !Tty.Size {
    var size = std.mem.zeroes(std.posix.winsize);
    const err = std.posix.system.ioctl(tty.fd, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.posix.errno(err) != .SUCCESS) {
        return std.posix.unexpectedErrno(@enumFromInt(err));
    }

    return .{ .width = size.col, .height = size.row };
}

fn ansiColorNumber(color: Tty.Color, bg: bool) usize {
    const base: usize = switch (color) {
        .black => 30,
        .red => 31,
        .green => 32,
        .yellow => 33,
        .blue => 34,
        .magenta => 35,
        .cyan => 36,
        .white => 37,
        .bright_black => 90,
        .bright_red => 91,
        .bright_green => 92,
        .bright_yellow => 93,
        .bright_blue => 94,
        .bright_magenta => 95,
        .bright_cyan => 96,
        .bright_white => 97,
    };

    if (bg) {
        return base + 10;
    } else {
        return base;
    }
}

pub fn setAttributes(tty: *PosixTty, attributes: Tty.Attributes) !void {
    try tty.writer().writeAll("\x1b[0m");
    if (attributes.fg) |fg| {
        try tty.writer().print("\x1b[{}m", .{ansiColorNumber(fg, false)});
    }
    if (attributes.bg) |bg| {
        try tty.writer().print("\x1b[{}m", .{ansiColorNumber(bg, true)});
    }
}

pub fn moveCursor(tty: *PosixTty, pos: Tty.Position) !void {
    try tty.writer().print("\x1b[{};{}H", .{ pos.y + 1, pos.x + 1 });
}

pub fn showCursor(tty: *PosixTty) !void {
    try tty.writer().writeAll("\x1b[?25h");
}

pub fn hideCursor(tty: *PosixTty) !void {
    try tty.writer().writeAll("\x1b[?25l");
}

pub fn setCursorShape(tty: *PosixTty, shape: Tty.CursorShape) !void {
    try tty.writer().print("\x1b[{} q", .{@as(usize, switch (shape) {
        .block => 2,
        .bar => 6,
    })});
}

pub fn init() !PosixTty {
    const fd = try std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);
    errdefer std.posix.close(fd);

    var tty: PosixTty = .{
        .fd = fd,
        .old_termios = undefined,
    };
    try tty.uncook();
    errdefer tty.cook() catch {};

    return tty;
}

pub fn deinit(tty: *PosixTty) void {
    tty.cook() catch {};
    std.posix.close(tty.fd);
}
