const std = @import("std");

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) []u8 {
    const result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = argv,
    }) catch unreachable;
    // print stderr for error diagnosis
    std.io.getStdErr().writeAll(result.stderr) catch {};
    allocator.free(result.stderr);
    // must exit with code 0
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.panic("failed to execute {s}", .{argv[0]});
    }

    return result.stdout;
}

fn pkgConfig(b: *std.build.Builder, obj: *std.build.LibExeObjStep, name: []const u8) void {
    const result = runCommand(b.allocator, &.{ "pkg-config", "--cflags", "--libs", name });
    defer b.allocator.free(result);
    var it = std.mem.tokenize(u8, result[0 .. result.len - 1], " ");
    while (it.next()) |slice| {
        if (std.mem.startsWith(u8, slice, "-I")) {
            obj.addIncludePath(b.dupe(slice[2..]));
        } else if (std.mem.startsWith(u8, slice, "-l")) {
            obj.linkSystemLibrary(b.dupe(slice[2..]));
        }
    }
}

fn generateFilesIfNeeded(
    b: *std.build.Builder,
    source: []const u8,
    files: []const []const u8,
    generator: []const []const u8,
) !void {
    const time = (try std.fs.cwd().statFile(source)).mtime;
    // if source file is newer than generated, or if generated does not exist,
    // we nede to re-build
    for (files) |file| {
        if (std.fs.cwd().statFile(file)) |stat| {
            if (stat.mtime < time) break;
        } else |_| break;
    } else return;
    b.allocator.free(runCommand(b.allocator, generator));
}

const WaylandScannerStep = struct {
    step: std.build.Step,
    b: *std.build.Builder,
    src: []const u8,
    dst_c_file: std.build.GeneratedFile,

    fn create(b: *std.build.Builder, src: []const u8) *WaylandScannerStep {
        const self = b.allocator.create(WaylandScannerStep) catch unreachable;
        self.* = .{
            .step = std.build.Step.init(.custom, "parse protocol", b.allocator, make),
            .b = b,
            .src = src,
            .dst_c_file = .{ .step = &self.step },
        };
        return self;
    }

    fn make(step: *std.build.Step) anyerror!void {
        const self = @fieldParentPtr(WaylandScannerStep, "step", step);
        const xml = self.b.fmt("{s}.xml", .{self.src});
        const basename = std.fs.path.basename(self.src);
        const c_file = self.b.fmt("build/{s}-protocol.c", .{basename});
        const h_file = self.b.fmt("build/{s}-protocol.h", .{basename});
        const wayland_scanner_full = runCommand(self.b.allocator, &.{ "pkg-config", "--variable=wayland_scanner", "wayland-scanner" });
        defer self.b.allocator.free(wayland_scanner_full);
        const wayland_scanner = wayland_scanner_full[0 .. wayland_scanner_full.len - 1];
        // generate c file
        try generateFilesIfNeeded(
            self.b,
            xml,
            &.{c_file},
            &.{ wayland_scanner, "private-code", xml, c_file },
        );
        self.dst_c_file.path = c_file;
        // generate h file
        try generateFilesIfNeeded(
            self.b,
            xml,
            &.{h_file},
            &.{ wayland_scanner, "client-header", xml, h_file },
        );
    }
};

const GdbusCodegenStep = struct {
    step: std.build.Step,
    b: *std.build.Builder,
    src: []const u8,
    dst_c_file: std.build.GeneratedFile,

    fn create(b: *std.build.Builder, src: []const u8) *GdbusCodegenStep {
        const self = b.allocator.create(GdbusCodegenStep) catch unreachable;
        self.* = .{
            .step = std.build.Step.init(.custom, "parse protocol", b.allocator, make),
            .b = b,
            .src = src,
            .dst_c_file = .{ .step = &self.step },
        };
        return self;
    }

    fn make(step: *std.build.Step) anyerror!void {
        const self = @fieldParentPtr(WaylandScannerStep, "step", step);
        const xml = self.b.fmt("{s}.xml", .{self.src});
        const basename = std.fs.path.basename(self.src);
        const c_file = self.b.fmt("build/{s}.c", .{basename});
        const h_file = self.b.fmt("build/{s}.h", .{basename});
        try generateFilesIfNeeded(
            self.b,
            xml,
            &.{ c_file, h_file },
            &.{ "gdbus-codegen", "--generate-c-code", basename, "--output-dir", "build", xml },
        );
        self.dst_c_file.path = c_file;
    }
};

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    std.fs.cwd().makeDir("build") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const exe = b.addExecutable("ilbar", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.single_threaded = true;

    exe.linkLibC();
    exe.addIncludePath("build");
    exe.addIncludePath("cj");
    exe.addCSourceFile("cj/cj.c", &.{});
    exe.linkSystemLibrary("dbusmenu-gtk3");
    exe.addIncludePath("/usr/include/libdbusmenu-gtk3-0.4");
    exe.addIncludePath("/usr/include/libdbusmenu-glib-0.4");
    exe.defineCMacro("_POSIX_C_SOURCE", "200809L");

    pkgConfig(b, exe, "wayland-client");
    pkgConfig(b, exe, "gtk+-3.0");
    pkgConfig(b, exe, "gtk-layer-shell-0");

    const scanner = WaylandScannerStep.create(b, "lib/wlr-foreign-toplevel-management-unstable-v1");
    exe.addCSourceFileSource(.{
        .source = .{ .generated = &scanner.dst_c_file },
        .args = &.{},
    });

    const codegen = GdbusCodegenStep.create(b, "lib/SNI");
    exe.addCSourceFileSource(.{
        .source = .{ .generated = &codegen.dst_c_file },
        .args = &.{},
    });

    var hash = runCommand(b.allocator, &.{ "git", "rev-parse", "--short", "HEAD" });
    defer b.allocator.free(hash);
    exe.defineCMacro("ILBAR_COMMIT_HASH", b.fmt("\"{s}\"", .{hash[0 .. hash.len - 1]}));

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
