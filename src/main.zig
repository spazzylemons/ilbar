const IconManager = @import("IconManager.zig");
const std = @import("std");

comptime {
    _ = @import("client.zig");
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

extern fn ilbar_c_main(argc: c_int, argv: [*][*:0]u8) c_int;

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

export fn icons_get(icons: *IconManager, name: [*:0]const u8) ?*anyopaque {
    return icons.get(std.mem.span(name)) catch |err| {
        std.log.err("icons_init(): {}", .{err});
        return null;
    };
}

pub fn main() u8 {
    defer _ = gpa.deinit();
    return @intCast(u8, ilbar_c_main(@intCast(c_int, std.os.argv.len), std.os.argv.ptr));
}
