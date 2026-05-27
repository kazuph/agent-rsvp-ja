const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const exe = b.addExecutable(.{
        .name = "agent-rsvp-native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.addCSourceFile(.{
        .file = b.path("native/macos_app.m"),
        .flags = &.{ "-fobjc-arc" },
    });
    exe.linkFramework("Cocoa");
    exe.linkFramework("NaturalLanguage");
    exe.linkLibC();

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the native RSVP app");
    run_step.dependOn(&run.step);
}
