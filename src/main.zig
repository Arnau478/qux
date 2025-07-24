const std = @import("std");
const pennant = @import("pennant");
const toml = @import("toml");
const known_folders = @import("known_folders");
const Tty = @import("Tty.zig");
const Editor = @import("Editor.zig");
const Config = @import("Config.zig");

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_file: ?std.fs.File = null;

pub fn log(comptime level: std.log.Level, comptime _: @Type(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    if (log_file) |file| {
        file.writer().print(level.asText() ++ ": " ++ fmt ++ "\n", args) catch {};
    }
}

const Options = struct {
    help: bool = false,
    version: bool = false,
};

pub fn main() !void {
    log_file = std.io.getStdErr();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args_res = try pennant.parseForProcess(Options, allocator);
    defer args_res.deinit(allocator);

    switch (args_res) {
        .valid => |args| {
            if (args.options.help) {
                pennant.printHelp(Options, .{});
            } else if (args.options.version) {
                try std.io.getStdOut().writeAll("TODO\n");
            } else {
                log_file = try getLogFile(allocator);

                var config_parser = toml.Parser(Config).init(allocator);
                defer config_parser.deinit();

                const config_content = try getConfig(allocator);
                defer if (config_content) |content| allocator.free(content);

                const config_parse_res = try config_parser.parseString(config_content orelse "");
                defer config_parse_res.deinit();

                const config = config_parse_res.value;

                var tty: Tty = try .init();
                defer tty.deinit();

                var editor: Editor = try .init(allocator, &config, &tty, args.positionals);
                defer editor.deinit();

                try editor.run();
            }
        },
        .err => |err| {
            std.log.err("{}", .{err});
        },
    }
}

pub fn getLogFile(allocator: std.mem.Allocator) !?std.fs.File {
    if (try known_folders.open(allocator, .cache, .{})) |cache_dir| {
        cache_dir.makeDir("qux") catch {};
        return cache_dir.createFile("qux/qux.log", .{}) catch null;
    } else return null;
}

pub fn getConfig(allocator: std.mem.Allocator) !?[]const u8 {
    if (try known_folders.open(allocator, .roaming_configuration, .{})) |config_dir| {
        const file = config_dir.openFile("qux/config.toml", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const config = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

        return config;
    } else return null;
}
