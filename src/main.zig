const c = @import("c.zig");
const Client = @import("Client.zig");
const Config = @import("Config.zig");
const std = @import("std");
const util = @import("util.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

fn openConfigFile(path: ?[*:0]u8) !std.fs.File {
    var generated: []u8 = &.{};
    const config_path = std.mem.span(path) orelse blk: {
        if (std.os.getenvZ("XDG_CONFIG_HOME")) |config_home| {
            generated = try std.fmt.allocPrint(allocator, "{s}/ilbar/config.json", .{config_home});
        } else if (std.os.getenvZ("HOME")) |home| {
            generated = try std.fmt.allocPrint(allocator, "{s}/.config/ilbar/config.json", .{home});
        } else {
            return error.CannotFindConfigDir;
        }
        break :blk generated;
    };
    defer allocator.free(generated);
    util.info(@src(), "using config file {s}", .{config_path});
    return try std.fs.cwd().openFile(config_path, .{});
}

fn readConfigFile(path: ?[*:0]u8) !Config {
    const file = try openConfigFile(path);
    defer file.close();

    return try Config.parse(file);
}

pub fn main() u8 {
    defer _ = gpa.deinit();

    // force Wayland backend
    if (c.setenv("GDK_BACKEND", "wayland", 1) != 0) {
        util.err(@src(), "failed to set GDK_BACKEND", .{});
        return 1;
    }

    var display: ?[*:0]u8 = null;
    var config_path: ?[*:0]u8 = null;

    var i: usize = 1;
    while (i < std.os.argv.len) : (i += 1) {
        const arg = std.os.argv[i];
        if (arg[0] != '-' or arg[1] == 0 or arg[2] != 0) {
            util.err(@src(), "invalid argument: {s}", .{arg});
            return 1;
        }
        switch (arg[1]) {
            'h' => {
                std.io.getStdOut().writer().print(
                    \\usage: {s} [-h] [-v] [-d display] [-c config]
                    \\  -h          display this help and exit
                    \\  -v          display program information and exit
                    \\  -d display  set Wayland display (default: $WAYLAND_DISPLAY)
                    \\  -c config   change config file path
                    \\
                , .{std.os.argv[0]}) catch return 1;
                return 0;
            },

            'v' => {
                std.io.getStdOut().writer().print(
                    \\ilbar - unversioned build, commit {s}
                    \\copyright (c) 2022 spazzylemons
                    \\license: MIT <https://opensource.org/licenses/MIT>
                    \\
                , .{@cImport({}).ILBAR_COMMIT_HASH}) catch return 1;
                return 0;
            },

            'd' => {
                if (i + 1 >= std.os.argv.len) {
                    util.err(@src(), "missing value for -d", .{});
                    return 1;
                }

                display = std.os.argv[i + 1];
                i += 1;
            },

            'c' => {
                if (i + 1 >= std.os.argv.len) {
                    util.err(@src(), "missing value for -c", .{});
                    return 1;
                }

                config_path = std.os.argv[i + 1];
                i += 1;
            },

            else => {
                util.err(@src(), "invalid argument: {s}", .{arg});
                return 1;
            },
        }
    }

    if (display) |disp| {
        if (c.setenv("WAYLAND_DISPLAY", disp, 1) != 0) {
            util.err(@src(), "failed to set WAYLAND_DISPLAY", .{});
        }
    }

    var dummy_argc: c.gint = 1;
    var dummy_argv_value = [_:null]?[*:0]u8{std.os.argv[0]};
    var dummy_argv: [*c][*c]u8 = &dummy_argv_value;
    c.gtk_init(&dummy_argc, &dummy_argv);

    var config = readConfigFile(config_path) catch |err| blk: {
        util.err(@src(), "error reading config file: {}", .{err});
        break :blk Config.defaults();
    };
    defer config.deinit();
    config.font_height = config.fontHeight();

    var client: Client = undefined;
    client.init(&config) catch |err| {
        util.err(@src(), "failed to create client: {}", .{err});
        return 1;
    };
    defer client.deinit();
    client.run() catch |err| {
        util.err(@src(), "cient closed: {}", .{err});
        return 1;
    };

    return 0;
}
