const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the test application");
    const test_step = b.step("test", "test the library");

    const sqlite3_module = b.addModule("sqlite3", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    sqlite3_module.link_libc = true;
    sqlite3_module.addIncludePath(b.path("sqlite-src"));
    sqlite3_module.addCSourceFile(.{ .file = b.path("sqlite-src/sqlite3.c") });

    const test_lib = b.addTest(.{
        .root_module = sqlite3_module,
        .optimize = optimize,
        .target = target,
    });
    const test_lib_run = b.addRunArtifact(test_lib);
    test_step.dependOn(&test_lib_run.step);

    const exe = b.addExecutable(.{
        .name = "sqlite-test",
        .root_source_file = b.path("src/example.zig"),
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("sqlite3-zig", sqlite3_module);

    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);
}
