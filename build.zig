const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .pic = true,
    });
    const lib = b.addLibrary(.{ .name = "memalloc", .linkage = .dynamic, .root_module = module });
    b.installArtifact(lib);
    const run = b.addRunArtifact(lib);
    _ = run;

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const heap_test = b.step("test", "runs tests of heap");
    heap_test.dependOn(&run_tests.step);
}
