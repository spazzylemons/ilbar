const std = @import("std");

extern fn ilbar_c_main(argc: c_int, argv: [*][*:0]u8) c_int;

pub fn main() u8 {
    return @intCast(u8, ilbar_c_main(@intCast(c_int, std.os.argv.len), std.os.argv.ptr));
}
