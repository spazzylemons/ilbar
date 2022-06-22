const c = @import("c.zig");
const Client = @import("Client.zig");
const Config = @import("Config.zig");
const IconManager = @import("IconManager.zig");
const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

fn openConfigFile(path: ?[*:0]u8) !std.fs.File {
    var generated: ?[:0]u8 = null;
    const config_path = path orelse blk: {
        if (std.c.getenv("XDG_CONFIG_HOME")) |config_home| {
            generated = try std.fmt.allocPrintZ(allocator, "{s}/ilbar/config.json", .{config_home});
        } else {
            const home = std.c.getenv("HOME").?;
            generated = try std.fmt.allocPrintZ(allocator, "{s}/.config/ilbar/config.json", .{home});
        }
        break :blk generated.?.ptr;
    };
    defer if (generated) |g| allocator.free(g);
    return try std.fs.cwd().openFile(std.mem.span(config_path), .{});
}

fn readConfigFile(path: ?[*:0]u8) !Config {
    const file = try openConfigFile(path);
    defer file.close();

    return try Config.parse(file);
}

pub fn main() u8 {
    defer _ = gpa.deinit();

    var dummy_argc: c.gint = 1;
    var dummy_argv_value = [_:null]?[*:0]u8{std.os.argv[0]};
    var dummy_argv: [*c][*c]u8 = &dummy_argv_value;
    c.gdk_init(&dummy_argc, &dummy_argv);

    var display: ?[*:0]u8 = null;
    var config_path: ?[*:0]u8 = null;

    var i: usize = 1;
    while (i < std.os.argv.len) : (i += 1) {
        const arg = std.os.argv[i];
        if (arg[0] != '-' or arg[2] != 0) {
            std.log.err("invalid argument: {s}", .{arg});
            return 1;
        }
        switch (arg[1]) {
            'h' => {
                std.io.getStdOut().writer().print(
                    \\usage: {s} [-h] [-v] [-d display] [-c config]
                    \\  -h          display this help and exit
                    \\  -v          display program information and exit
                    \\  -d display  set Wayland display (default: $WAYLAND_DISPLAY
                    \\  -c config   change config file path
                    \\
                , .{std.os.argv[0]}) catch return 1;
                return 0;
            },

            'v' => {
                std.io.getStdOut().writeAll(
                    \\ilbar - unversioned build
                    \\copyright (c) 2022 spazzylemons
                    \\license: MIT <https://opensource.org/licenses/MIT>
                    \\
                ) catch return 1;
                return 0;
            },

            'd' => {
                if (i + 1 >= std.os.argv.len) {
                    std.log.err("missing value for -d", .{});
                    return 1;
                }

                display = std.os.argv[i + 1];
                i += 1;
            },

            'c' => {
                if (i + 1 >= std.os.argv.len) {
                    std.log.err("missing value for -c", .{});
                    return 1;
                }

                config_path = std.os.argv[i + 1];
                i += 1;
            },

            else => {
                std.log.err("invalid argument: {s}", .{arg});
                return 1;
            },
        }
    }

    const config = readConfigFile(config_path) catch |err| blk: {
        std.log.err("error reading config file: {}", .{err});
        break :blk Config{};
    };
    defer config.deinit();

    const client = Client.init(display, &config) catch |err| {
        std.log.err("failed to create client: {}", .{err});
        return 1;
    };
    defer client.deinit();
    client.run();

    return 0;
}
