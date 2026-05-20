const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the example application");
    const test_step = b.step("test", "Test the library");

    const sqlite3_module = b.addModule("sqlite3", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    sqlite3_module.link_libc = true;
    sqlite3_module.addIncludePath(b.path("sqlite-src"));
    sqlite3_module.addCSourceFile(.{ .file = b.path("sqlite-src/sqlite3.c") });
    sqlite3_module.addCSourceFile(.{ .file = b.path("src/sqlite_bridge.c") });

    const test_lib = b.addTest(.{ .root_module = sqlite3_module });
    const test_lib_run = b.addRunArtifact(test_lib);
    test_step.dependOn(&test_lib_run.step);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("sqlite3", sqlite3_module);
    const exe = b.addExecutable(.{
        .name = "sqlite-example",
        .root_module = exe_module,
    });

    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);
}
