const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const std = @import("std");

const Config = @This();

font: ?[:0]const u8 = null,
font_size: u16 = 11,
height: u16 = 28,
margin: u16 = 3,
width: u16 = 160,

pub fn fontName(self: Config) [:0]const u8 {
    return self.font orelse "FreeSans";
}

fn readWholeFile(file: std.fs.File) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var buf: [64]u8 = undefined;
    while (true) {
        const amt = try file.read(&buf);
        if (amt == 0) return result.toOwnedSlice();
        try result.appendSlice(buf[0..amt]);
    }
}

pub fn parse(file: std.fs.File) !Config {
    const source = try readWholeFile(file);
    defer allocator.free(source);

    var tokens = std.json.TokenStream.init(source);
    const result = try std.json.parse(Config, &tokens, .{ .allocator = allocator });
    if (result.height < 6) return error.InvalidNumber;
    return result;
}

pub fn deinit(self: Config) void {
    std.json.parseFree(Config, self, .{ .allocator = allocator });
}

pub fn fontHeight(self: Config) f64 {
    // no complete dummy surface available - recording surface is closest
    const target = c.cairo_recording_surface_create(c.CAIRO_CONTENT_COLOR_ALPHA, null);
    defer c.cairo_surface_destroy(target);
    const cr = c.cairo_create(target);
    defer c.cairo_destroy(cr);
    c.cairo_select_font_face(cr, self.fontName(), c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, @intToFloat(f64, self.font_size));
    var fe: c.cairo_font_extents_t = undefined;
    c.cairo_font_extents(cr, &fe);
    return fe.height;
}
