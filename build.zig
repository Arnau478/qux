const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = .ReleaseFast,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("tree_sitter", tree_sitter_dep.module("tree-sitter"));

    var tree_sitter_queries_source = std.ArrayList(u8).init(b.allocator);
    const tree_sitter_queries_mod = b.createModule(.{});

    inline for (&.{ "c", "zig" }) |language| {
        const dep = b.dependency(b.fmt("tree-sitter-{s}", .{language}), .{});
        const lib = b.addStaticLibrary(.{ .name = language, .target = target, .optimize = .ReleaseFast });
        lib.linkLibC();
        lib.addCSourceFile(.{ .file = dep.path("src/parser.c") });
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
