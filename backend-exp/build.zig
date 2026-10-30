const std = @import("std");
const anole = @import("anole");

pub fn build(b: *std.Build) void {
    const app = anole.addApp(b, .{
        .name = "everyai-backend-exp",
        .root_source_file = b.path("src/main.zig"),
        .profile = .full,
    });

    // `zig build test`: unit tests plus the routes served in memory.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = app.exe.root_module.resolved_target,
        .optimize = app.exe.root_module.optimize,
        .imports = &.{
            .{ .name = "anole", .module = app.anole.module("anole") },
            .{ .name = "app", .module = app.exe.root_module },
        },
    }) });
    // Unit tests live in the app module itself.
    const unit = b.addTest(.{ .root_module = app.exe.root_module });
    const step = b.step("test", "Run the tests");
    step.dependOn(&b.addRunArtifact(tests).step);
    step.dependOn(&b.addRunArtifact(unit).step);
}
