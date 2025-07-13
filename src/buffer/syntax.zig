const std = @import("std");
const tree_sitter = @import("tree_sitter");
const tree_sitter_query_sources = @import("tree_sitter_query_sources");

const tree_sitter_grammars = struct {
    extern fn tree_sitter_c() callconv(.c) *tree_sitter.Language;
    extern fn tree_sitter_zig() callconv(.c) *tree_sitter.Language;
};

var tree_sitter_query_cache: std.enums.EnumFieldStruct(Filetype, ?*tree_sitter.Query, @as(?*tree_sitter.Query, null)) = .{};

pub const Filetype = enum {
    c,
    zig,

    fn treeSitterName(filetype: Filetype) []const u8 {
        return switch (filetype) {
            .c => "c",
            .zig => "zig",
        };
    }

    pub fn treeSitterGrammar(filetype: Filetype) *const fn () callconv(.c) *tree_sitter.Language {
        switch (filetype) {
            inline else => |t| {
                const name = comptime treeSitterName(t);
                return @field(tree_sitter_grammars, std.fmt.comptimePrint("tree_sitter_{s}", .{name}));
            },
        }
    }

    pub fn treeSitterQuerySource(filetype: Filetype) []const u8 {
        switch (filetype) {
            inline else => |t| {
                const name = comptime treeSitterName(t);
                return @field(tree_sitter_query_sources, name);
            },
        }
    }

    pub fn treeSitterQuery(filetype: Filetype) *tree_sitter.Query {
        switch (filetype) {
            inline else => |t| {
                if (@field(tree_sitter_query_cache, @tagName(t))) |query| {
                    return query;
                } else {
                    var error_offset: u32 = 0;
                    const query = tree_sitter.Query.create(filetype.treeSitterGrammar()(), filetype.treeSitterQuerySource(), &error_offset) catch @panic("TODO");

                    @field(tree_sitter_query_cache, @tagName(t)) = query;

                    return query;
                }
            },
        }
    }

    pub fn guess(file_path: []const u8, content: ?[]const u8) ?Filetype {
        const file_name = std.fs.path.basename(file_path);

        if (std.mem.endsWith(u8, file_name, ".c") or std.mem.endsWith(u8, file_name, ".h")) {
            return .zig;
        }

        if (std.mem.endsWith(u8, file_name, ".zig") or std.mem.endsWith(u8, file_name, ".zon")) {
            return .zig;
        }

        _ = content;

        return null;
    }
};
