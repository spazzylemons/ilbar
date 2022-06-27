const std = @import("std");

fn runCommand(b: *std.build.Builder, argv: []const []const u8) []u8 {
    const result = std.ChildProcess.exec(.{
        .allocator = b.allocator,
        .argv = argv,
    }) catch unreachable;
    // print stderr for error diagnosis
    std.io.getStdErr().writeAll(result.stderr) catch {};
    b.allocator.free(result.stderr);
    // must exit with code 0
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.panic("failed to execute {s}", .{argv[0]});
    }

    return result.stdout;
}

fn pkgConfig(b: *std.build.Builder, obj: *std.build.LibExeObjStep, name: []const u8) void {
    const result = runCommand(b, &.{ "pkg-config", "--cflags", "--libs", name });
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

const WaylandScannerStep = struct {
    step: std.build.Step,
    b: *std.build.Builder,
    src: []const u8,
    dst_c_file: std.build.GeneratedFile,
    dst_h_file: std.build.GeneratedFile,

    fn create(b: *std.build.Builder, src: []const u8) *WaylandScannerStep {
        const self = b.allocator.create(WaylandScannerStep) catch unreachable;
        self.* = .{
            .step = std.build.Step.init(.custom, "parse protocol", b.allocator, make),
            .b = b,
            .src = src,
            .dst_c_file = .{ .step = &self.step },
            .dst_h_file = .{ .step = &self.step },
        };
        return self;
    }

    fn make(step: *std.build.Step) anyerror!void {
        const self = @fieldParentPtr(WaylandScannerStep, "step", step);
        const xml = self.b.fmt("{s}.xml", .{self.src});
        const c_file = self.b.fmt("build/{s}-protocol.c", .{std.fs.path.basename(self.src)});
        const h_file = self.b.fmt("build/{s}-protocol.h", .{std.fs.path.basename(self.src)});
        const wayland_scanner_full = runCommand(
            self.b,
            &.{
                "pkg-config",
                "--variable=wayland_scanner",
                "wayland-scanner",
            },
        );
        defer self.b.allocator.free(wayland_scanner_full);
        const wayland_scanner = wayland_scanner_full[0 .. wayland_scanner_full.len - 1];
        if (std.fs.cwd().statFile(c_file)) |_| {
            // file exists, nothing to do
        } else |_| {
            self.b.allocator.free(runCommand(
                self.b,
                &.{
                    wayland_scanner,
                    "private-code",
                    xml,
                    c_file,
                },
            ));
        }
        self.dst_c_file.path = c_file;
        if (std.fs.cwd().statFile(h_file)) |_| {
            // file exists, nothing to do
        } else |_| {
            self.b.allocator.free(runCommand(
                self.b,
                &.{
                    wayland_scanner,
                    "client-header",
                    xml,
                    h_file,
                },
            ));
        }
        self.dst_h_file.path = h_file;
    }
};

const GdbusCodegenStep = struct {
    step: std.build.Step,
    b: *std.build.Builder,
    src: []const u8,
    dst_c_file: std.build.GeneratedFile,
    dst_h_file: std.build.GeneratedFile,

    fn create(b: *std.build.Builder, src: []const u8) *GdbusCodegenStep {
        const self = b.allocator.create(GdbusCodegenStep) catch unreachable;
        self.* = .{
            .step = std.build.Step.init(.custom, "parse protocol", b.allocator, make),
            .b = b,
            .src = src,
            .dst_c_file = .{ .step = &self.step },
            .dst_h_file = .{ .step = &self.step },
        };
        return self;
    }

    fn make(step: *std.build.Step) anyerror!void {
        const self = @fieldParentPtr(WaylandScannerStep, "step", step);
        const xml = self.b.fmt("{s}.xml", .{self.src});
        const c_file = self.b.fmt("build/{s}.c", .{std.fs.path.basename(self.src)});
        const h_file = self.b.fmt("build/{s}.h", .{std.fs.path.basename(self.src)});
        var needs_generation = false;
        _ = std.fs.cwd().statFile(c_file) catch {
            needs_generation = true;
        };
        _ = std.fs.cwd().statFile(h_file) catch {
            needs_generation = true;
        };
        if (needs_generation) {
            self.b.allocator.free(runCommand(
                self.b,
                &.{
                    "gdbus-codegen",
                    "--generate-c-code",
                    std.fs.path.basename(self.src),
                    "--output-dir",
                    "build",
                    xml,
                },
            ));
        }
        self.dst_c_file.path = c_file;
        self.dst_h_file.path = h_file;
    }
};

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("ilbar", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.single_threaded = true;

    exe.linkLibC();
    exe.addIncludePath("build");
    exe.addIncludePath("cj");
    exe.addCSourceFile("cj/cj.c", &.{});
    exe.defineCMacro("_POSIX_C_SOURCE", "200809L");

    pkgConfig(b, exe, "wayland-client");
    pkgConfig(b, exe, "cairo");
    pkgConfig(b, exe, "gtk+-3.0");
    pkgConfig(b, exe, "pangocairo");

    std.fs.cwd().makeDir("build") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const pkgdatadir_full = runCommand(
        b,
        &.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" },
    );
    defer b.allocator.free(pkgdatadir_full);
    const pkgdatadir = pkgdatadir_full[0 .. pkgdatadir_full.len - 1];

    const protocol_xml = [_][]const u8{
        b.pathJoin(&.{ pkgdatadir, "stable/xdg-shell/xdg-shell" }),
        "lib/wlr-foreign-toplevel-management-unstable-v1",
        "lib/wlr-layer-shell-unstable-v1",
    };

    for (protocol_xml) |protocol| {
        const scanner = WaylandScannerStep.create(b, protocol);
        exe.addCSourceFileSource(.{
            .source = .{ .generated = &scanner.dst_c_file },
            .args = &.{},
        });
    }

    const codegen = GdbusCodegenStep.create(b, "lib/SNI");
    exe.addCSourceFileSource(.{
        .source = .{ .generated = &codegen.dst_c_file },
        .args = &.{},
    });

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
