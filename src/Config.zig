const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const std = @import("std");

const Config = @This();

pub const Shortcut = struct {
    text: [:0]const u8,
    icon: ?[:0]const u8 = null,
    command: [:0]const u8,

    fn deinit(self: Shortcut) void {
        allocator.free(self.text);
        if (self.icon) |v| allocator.free(v);
        allocator.free(self.command);
    }
};

const default_status_command = "while true; do date +%H:%M; sleep 1; done";

/// The font used on the taskbar.
font: *c.PangoFontDescription,
/// The height of the taskbar.
height: u16 = 28,
/// The spacing between various elements.
margin: u16 = 3,
/// The width of each button.
width: u16 = 160,
/// The shortcuts.
shortcuts: []Shortcut = &.{},
/// THe command to run to display a status.
status_command: [:0]const u8 = default_status_command,
/// generated from config, not inputted by user
font_height: i32 = 0,

pub fn defaults() Config {
    return .{ .font = c.pango_font_description_from_string("FreeSans 11px").? };
}

const FileReader = struct {
    reader: c.CJReader = .{ .read = read },
    file: std.fs.File,
    buffer: []u8,
    read_error: std.fs.File.ReadError = undefined,

    fn read(reader: ?*c.CJReader, size: ?*usize) callconv(.C) ?[*]const u8 {
        const self = @fieldParentPtr(FileReader, "reader", reader.?);
        size.?.* = self.file.read(self.buffer) catch |err| {
            self.read_error = err;
            size.?.* = 1;
            return null;
        };
        if (size.?.* == 0) {
            return null;
        }
        return self.buffer.ptr;
    }
};

fn getString(obj: c.CJObject, name: []const u8, nullable: bool) !?[:0]const u8 {
    for (obj.members[0..obj.length]) |member| {
        const key = member.key.chars[0..member.key.length];
        // must be the key we're looking for
        if (!std.mem.eql(u8, key, name)) {
            continue;
        }
        // must be a string, unless nullable
        if (member.value.type != c.CJ_STRING) {
            if (nullable and member.value.type == c.CJ_NULL) {
                return null;
            }
            std.log.err("{s} must be a string", .{name});
            continue;
        }
        // copy the value and return it
        return try allocator.dupeZ(u8, member.value.as.string.chars[0..member.value.as.string.length]);
    }
    return null;
}

fn getNumber(obj: c.CJObject, name: []const u8, min: u16) ?u16 {
    for (obj.members[0..obj.length]) |member| {
        const key = member.key.chars[0..member.key.length];
        // must be the key we're looking for
        if (!std.mem.eql(u8, key, name)) {
            continue;
        }
        // must be a number
        if (member.value.type != c.CJ_NUMBER) {
            std.log.err("{s} must be a number", .{name});
            continue;
        }
        // must be in range
        if (member.value.as.number < @intToFloat(f64, min) or member.value.as.number > std.math.maxInt(u16)) {
            std.log.err("{s} is out of range", .{name});
            continue;
        }
        // cast the value and return it
        return @floatToInt(u16, member.value.as.number);
    }
    return null;
}

fn getFont(obj: c.CJObject, name: []const u8) ?*c.PangoFontDescription {
    for (obj.members[0..obj.length]) |member| {
        const key = member.key.chars[0..member.key.length];
        // must be the key we're looking for
        if (!std.mem.eql(u8, key, name)) {
            continue;
        }
        // must be a string
        if (member.value.type != c.CJ_STRING) {
            std.log.err("{s} must be a string", .{name});
            continue;
        }
        // load the font and return
        return c.pango_font_description_from_string(member.value.as.string.chars);
    }
    return null;
}

fn getShortcuts(obj: c.CJObject, name: []const u8) !?[]Shortcut {
    for (obj.members[0..obj.length]) |member| {
        const key = member.key.chars[0..member.key.length];
        // must be the key we're looking for
        if (!std.mem.eql(u8, key, name)) {
            continue;
        }
        // must be an array
        if (member.value.type != c.CJ_ARRAY) {
            std.log.err("{s} must be an array", .{name});
            continue;
        }
        // load the font and return
        var shortcuts = std.ArrayListUnmanaged(Shortcut){};
        defer shortcuts.deinit(allocator);
        for (member.value.as.array.elements[0..member.value.as.array.length]) |element| {
            const shortcut = parseShortcutConfig(element) catch |err| switch (err) {
                error.InvalidShortcut => continue,
                else => |e| return e,
            };
            try shortcuts.append(allocator, shortcut);
        }
        return shortcuts.toOwnedSlice(allocator);
    }
    return null;
}

fn parseRootConfig(self: *Config, value: c.CJValue) !void {
    if (value.type != c.CJ_OBJECT) {
        std.log.err("config must be an object", .{});
        return;
    }

    if (getFont(value.as.object, "font")) |v| {
        c.pango_font_description_free(self.font);
        self.font = v;
    }

    if (getNumber(value.as.object, "height", 6)) |v| {
        self.height = v;
    }

    if (getNumber(value.as.object, "margin", 0)) |v| {
        self.margin = v;
    }

    if (getNumber(value.as.object, "width", 0)) |v| {
        self.width = v;
    }

    if (try getString(value.as.object, "status_command", false)) |v| {
        self.status_command = v;
    }

    if (try getShortcuts(value.as.object, "shortcuts")) |v| {
        self.shortcuts = v;
    }
}

fn parseShortcutConfig(value: c.CJValue) !Shortcut {
    if (value.type != c.CJ_OBJECT) {
        std.log.err("shortcut must be an object", .{});
        return error.InvalidShortcut;
    }

    const text = (try getString(value.as.object, "text", false)) orelse {
        std.log.err("shortcut text is required", .{});
        return error.InvalidShortcut;
    };
    errdefer allocator.free(text);

    const command = (try getString(value.as.object, "command", false)) orelse {
        std.log.err("shortcut command is required", .{});
        return error.InvalidShortcut;
    };
    errdefer allocator.free(command);

    const icon = try getString(value.as.object, "icon", true);
    errdefer if (icon) |v| allocator.free(v);

    return Shortcut{ .text = text, .command = command, .icon = icon };
}

pub fn parse(file: std.fs.File) !Config {
    var buffer: [64]u8 = undefined;
    var fr = FileReader{ .file = file, .buffer = &buffer };
    var value: c.CJValue = undefined;
    switch (c.cj_parse(null, &fr.reader, &value)) {
        c.CJ_OUT_OF_MEMORY => return error.OutOfMemory,
        c.CJ_SYNTAX_ERROR => return error.SyntaxError,
        c.CJ_TOO_MUCH_NESTING => return error.NestedTooDeeply,
        c.CJ_READ_ERROR => return fr.read_error,
        else => {},
    }
    defer c.cj_free(null, &value);
    var result = defaults();
    errdefer result.deinit();
    try parseRootConfig(&result, value);
    return result;
}

pub fn deinit(self: Config) void {
    c.pango_font_description_free(self.font);
    if (self.status_command.ptr != default_status_command) {
        allocator.free(self.status_command);
    }
    for (self.shortcuts) |shortcut| {
        shortcut.deinit();
    }
    allocator.free(self.shortcuts);
}

fn makeContext() *c.PangoContext {
    return c.pango_font_map_create_context(c.pango_cairo_font_map_get_default()).?;
}

pub fn fontHeight(self: Config) i32 {
    const context = makeContext();
    defer c.g_object_unref(context);

    const font = c.pango_context_load_font(context, self.font);
    defer c.g_object_unref(font);

    const metrics = c.pango_font_get_metrics(font, null);
    defer c.pango_font_metrics_unref(metrics);

    const ascent = c.pango_font_metrics_get_ascent(metrics);
    const descent = c.pango_font_metrics_get_descent(metrics);

    return @divTrunc(ascent + descent, c.PANGO_SCALE);
}

pub fn textWidth(self: Config, text: [*:0]const u8) i32 {
    const context = makeContext();
    defer c.g_object_unref(context);

    const layout = c.pango_layout_new(context);
    defer c.g_object_unref(layout);
    c.pango_layout_set_font_description(layout, self.font);

    c.pango_layout_set_text(layout, text, -1);
    var width: c.gint = undefined;
    c.pango_layout_get_pixel_size(layout, &width, null);

    return width;
}
