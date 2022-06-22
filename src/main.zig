const c = @import("c.zig");
const IconManager = @import("IconManager.zig");
const std = @import("std");

comptime {
    _ = @import("client.zig");
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

export fn icons_init() ?*anyopaque {
    const result = std.heap.c_allocator.create(IconManager) catch return null;
    result.* = IconManager.init() catch |err| {
        std.log.err("icons_init(): {}", .{err});
        std.heap.c_allocator.destroy(result);
        return null;
    };
    return result;
}

export fn icons_deinit(icons: *IconManager) void {
    icons.deinit();
    std.heap.c_allocator.destroy(icons);
}

fn openConfigFile(path: ?[*:0]u8) !*std.c.FILE {
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
    return std.c.fopen(config_path, "r") orelse return error.CannotOpenFile;
}

fn readConfigFile(path: ?[*:0]u8, config: *c.Config) !void {
    const file = try openConfigFile(path);
    defer _ = std.c.fclose(file);

    var buf: [64]u8 = undefined;
    var fr: c.CJFileReader = undefined;
    c.cj_init_file_reader(&fr, @ptrCast(*c.FILE, @alignCast(@alignOf(c.FILE), file)), &buf, buf.len);
    var json: c.CJValue = undefined;
    if (c.cj_parse(null, &fr.reader, &json) != c.CJ_SUCCESS) {
        return error.ParseError;
    }
    defer c.cj_free(null, &json);
    c.config_parse(config, &json);
}

pub fn main() u8 {
    defer _ = gpa.deinit();

    var dummy_argc: c.gint = 1;
    var dummy_argv_value = [_:null]?[*:0]u8{ std.os.argv[0] };
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

    var config: c.Config = undefined;
    c.config_defaults(&config);
    defer c.config_deinit(&config);
    readConfigFile(config_path, &config) catch |err| {
        // log error, but proceed with default config
        std.log.err("error reading config file: {}", .{err});
    };
    c.config_process(&config);
    const client = c.client_init(display, &config) orelse {
        return 1;
    };
    defer c.client_deinit(client);
    c.client_run(client);
    return 0;
}
