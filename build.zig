const std = @import("std");
pub fn build(b: *std.Build) void {
    // this is written in zig 0.13!
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // this is optional and builds a static sqlite library one could use i.e. with c
    const static_lib = b.addStaticLibrary(.{
        .name = "sqlite3",
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    static_lib.linkLibC();
    static_lib.addIncludePath(b.path("sqlite-src"));
    // this copies the sqlite3 headers sqlite3.h and sqlite3ext.h to the output directory for further use
    static_lib.installHeadersDirectory(b.path("sqlite-src"), "sqlite3-headers", .{ .include_extensions = &.{ "sqlite3.h", "sqlite3ext.h" } });
    static_lib.addCSourceFile(.{ .file = b.path("sqlite-src/sqlite3.c") });
    b.installArtifact(static_lib);

    // ----------------------------------------------------------

    // this makes a zig module which can be included as follows:
    // usually you add this package to the package manager:
    // .dependencies = .{
    //     .@"sqlite3-zig" = .{
    //         .url = "https://github.com/....tar.gz",
    //         .hash = "1220450bb9feb21c29018e21a8af457859eb2a4607a6017748bb618907b4cf18c67b",
    //     },
    // },
    //
    // then adding this to your build.zig:
    //
    // const sqlite3 = b.dependency("sqlite3-zig", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const sqlite_module = sqlite3.module("sqlite3-zig");
    // exe.root_module.addImport("sqlite3-zig", sqlite_module);
    //
    // then in your main.zig:
    // @import(sqlite3-zig);

    // this will not compile a static lib but your executable will do the compilation if you import this as a module

    const module = b.addModule("sqlite3", .{ .root_source_file = b.path("src/sqlite.zig") });
    module.link_libc = true;
    module.addIncludePath(b.path("sqlite-src"));
    module.addCSourceFile(.{ .file = b.path("sqlite-src/sqlite3.c") });

    // this is an example executable which opens the sqlite3 database in memory and closes it again
    const exe = b.addExecutable(.{
        .name = "sqlite-test",
        .root_source_file = b.path("src/example.zig"),
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("sqlite3-zig", module);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the test application");
    run_step.dependOn(&run_exe.step);
}
