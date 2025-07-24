const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pennant_dep = b.dependency("pennant", .{
        .target = target,
        .optimize = optimize,
    });

    const zg_dep = b.dependency("zg", .{
        .target = target,
        .optimize = optimize,
    });

    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const known_folders_dep = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });

    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("pennant", pennant_dep.module("pennant"));
    exe_mod.addImport("zg-code_point", zg_dep.module("code_point"));
    exe_mod.addImport("zg-Graphemes", zg_dep.module("Graphemes"));
    exe_mod.addImport("toml", toml_dep.module("toml"));
    exe_mod.addImport("known_folders", known_folders_dep.module("known-folders"));
    exe_mod.addImport("tree_sitter", tree_sitter_dep.module("tree-sitter"));

    var tree_sitter_queries_source = std.ArrayList(u8).init(b.allocator);
    const tree_sitter_queries_mod = b.createModule(.{});

    inline for (&.{ "c", "toml", "zig" }) |language| {
        const dep = b.dependency(b.fmt("tree-sitter-{s}", .{language}), .{});
        const lib = b.addStaticLibrary(.{ .name = language, .target = target, .optimize = .ReleaseFast });
        lib.linkLibC();
        lib.addCSourceFile(.{ .file = dep.path("src/parser.c") });
        if (!std.meta.isError(dep.path("src").getPath3(b, null).access("scanner.c", .{}))) {
            lib.addCSourceFile(.{ .file = dep.path("src/scanner.c") });
        }
        exe_mod.linkLibrary(lib);

        tree_sitter_queries_mod.addAnonymousImport(language, .{ .root_source_file = dep.path("queries/highlights.scm") });
        tree_sitter_queries_source.appendSlice(b.fmt(
            \\pub const {s} = @embedFile("{s}");
            \\
        , .{ language, language })) catch @panic("Out of memory");
    }

    const tree_sitter_queries_wf = b.addWriteFiles();
    tree_sitter_queries_mod.root_source_file = tree_sitter_queries_wf.add("tree_sitter_queries.zig", tree_sitter_queries_source.items);
    exe_mod.addImport("tree_sitter_query_sources", tree_sitter_queries_mod);

    const exe = b.addExecutable(.{
        .name = "qux",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
