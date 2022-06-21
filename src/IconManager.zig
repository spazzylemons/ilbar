//! Fetches icons using GTK.

const c = @import("c.zig");
const std = @import("std");

const IconManager = @This();

const ICON_CACHE_SIZE = 29;

/// A reference to the default theme.
theme: *c.GtkIconTheme,
/// A cache of recently used icons.
cache: *c.Cache,

fn iconCacheHash(key: ?*const anyopaque) callconv(.C) usize {
    const str = std.mem.span(@ptrCast([*:0]const u8, key.?));
    return @truncate(usize, std.hash.Wyhash.hash(1, str));
}

fn iconCacheEqual(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.C) bool {
    const str_a = std.mem.span(@ptrCast([*:0]const u8, a.?));
    const str_b = std.mem.span(@ptrCast([*:0]const u8, b.?));
    return std.mem.eql(u8, str_a, str_b);
}

fn iconCacheFree(entry: ?*const c.CacheEntry) callconv(.C) void {
    std.heap.c_allocator.free(std.mem.span(@ptrCast([*:0]u8, entry.?.key.?)));
    c.cairo_surface_destroy(@ptrCast(*c.cairo_surface_t, entry.?.value.?));
}

const icon_cache_callbacks = c.CacheCallbacks{
    .hash = iconCacheHash,
    .equal = iconCacheEqual,
    .free = iconCacheFree,
};

/// Construct a new icon manager.
pub fn init() !IconManager {
    const cache = c.cache_init(ICON_CACHE_SIZE, &icon_cache_callbacks)
        orelse return error.OutOfMemory;
    errdefer c.cache_deinit(cache);

    const theme = c.gtk_icon_theme_get_default()
        orelse return error.GtkError;
    // the theme is not automatically ref'd
    _ = c.g_object_ref(theme);

    return IconManager{
        .cache = cache,
        .theme = theme,
    };
}

/// Destroy an icon manager and related resources.
pub fn deinit(self: IconManager) void {
    c.cache_deinit(self.cache);
    c.g_object_unref(self.theme);
}

fn searchFileForIcon(file: std.fs.File) !?[:0]u8 {
    defer file.close();

    var line_buffer = std.ArrayList(u8).init(std.heap.c_allocator);
    defer line_buffer.deinit();

    var buf: [64]u8 = undefined;
    while (true) {
        const amt = try file.read(&buf);
        if (amt == 0) return null;

        for (buf[0..amt]) |b| {
            if (b != '\n') {
                try line_buffer.append(b);
            } else if (std.mem.startsWith(u8, line_buffer.items, "Icon=")) {
                return try std.heap.c_allocator.dupeZ(u8, line_buffer.items[5..]);
            } else {
                line_buffer.clearRetainingCapacity();
            }
        }
    }
}

fn searchApplications(comptime fmt: []const u8, args: anytype) !?[:0]u8 {
    const file = blk: {
        const filename = try std.fmt.allocPrint(std.heap.c_allocator, fmt, args);
        defer std.heap.c_allocator.free(filename);
        break :blk std.fs.cwd().openFile(filename, .{}) catch return null;
    };
    return searchFileForIcon(file);
}

fn getIconNameFromDesktop(name: []const u8) !?[:0]u8 {
    // remove possible trailing .desktop
    var desktop_name = if (std.mem.endsWith(u8, name, ".desktop"))
        try std.heap.c_allocator.dupe(u8, name)
    else
        try std.fmt.allocPrint(std.heap.c_allocator, "{s}.desktop", .{name});
    defer std.heap.c_allocator.free(desktop_name);
    // try local directory first
    if (std.c.getenv("XDG_DATA_HOME")) |v| {
        if (try searchApplications("{s}/applications/{s}", .{v, desktop_name})) |result| {
            return result;
        }
    } else if (std.c.getenv("HOME")) |v| {
        if (try searchApplications("{s}/.local/share/applications/{s}", .{v, desktop_name})) |result| {
            return result;
        }
    }
    // try global directories next
    const xdg_data_dirs: [*:0]const u8 = std.c.getenv("XDG_DAtA_DIRS")
        orelse "/usr/local/share:/usr/share";
    var it = std.mem.split(u8, std.mem.span(xdg_data_dirs), ":");
    while (it.next()) |dir| {
        if (try searchApplications("{s}/applications/{s}", .{dir, desktop_name})) |result| {
            return result;
        }
    }
    // nothing found
    return null;
}

fn getIconName(name: [:0]const u8) !?[:0]u8 {
    // try the app ID first
    if (try getIconNameFromDesktop(name)) |result| {
        return result;
    }
    // ask GTK for the icon
    const search = c.g_desktop_app_info_search(name.ptr)
        orelse return error.GtkError;
    defer {
        var strv = search;
        while (strv.* != null) : (strv += 1) {
            c.g_strfreev(strv.*);
        }
        c.g_free(@ptrCast(?*anyopaque, search));
    }
    var strv = search;
    while (strv.* != null) : (strv += 1) {
        var apps = strv.*;
        while (apps.* != null) : (apps += 1) {
            if (try getIconNameFromDesktop(std.mem.span(apps.*.?))) |result| {
                return result;
            }
        }
    }
    return null;
}

/// Get an icon as a surface.
pub fn get(self: IconManager, name: [:0]const u8) !?*c.cairo_surface_t {
    if (c.cache_get(self.cache, name.ptr)) |cached| {
        _ = c.cairo_surface_reference(@ptrCast(*c.cairo_surface_t, cached));
        return @ptrCast(*c.cairo_surface_t, cached);
    }
    const icon_name = (try getIconName(name)) orelse return null;
    defer std.heap.c_allocator.free(icon_name);

    const pixbuf = c.gtk_icon_theme_load_icon(self.theme, icon_name, 16, 0, null)
        orelse return error.IconNotFound;
    errdefer c.g_object_unref(pixbuf);

    if (c.gdk_pixbuf_get_colorspace(pixbuf) != c.GDK_COLORSPACE_RGB) {
        return error.UnsupportedIcon;
    } else if (c.gdk_pixbuf_get_bits_per_sample(pixbuf) != 8) {
        return error.UnsupportedIcon;
    } else if (c.gdk_pixbuf_get_has_alpha(pixbuf) == 0) {
        return error.UnsupportedIcon;
    } else if (c.gdk_pixbuf_get_n_channels(pixbuf) != 4) {
        return error.UnsupportedIcon;
    } else {
        const width = c.gdk_pixbuf_get_width(pixbuf);
        const height = c.gdk_pixbuf_get_height(pixbuf);
        var src = c.gdk_pixbuf_get_pixels(pixbuf).?;

        const surface = c.cairo_image_surface_create(
            c.CAIRO_FORMAT_ARGB32,
            width,
            height,
        );
        errdefer c.cairo_surface_destroy(surface);
        c.cairo_surface_flush(surface);
        var dst = @ptrCast([*]align(1)u32, c.cairo_image_surface_get_data(surface)
            orelse return error.CairoError);
        const size = width * height;
        var i: c_int = 0;
        while (i < size) : (i += 1) {
            const r: u32 = src[0];
            const g: u32 = src[1];
            const b: u32 = src[2];
            const a: u32 = src[3];
            src += 4;
            dst[0] = (a << 24) | (r << 16) | (g << 8) | b;
            dst += 1;
        }
        c.cairo_surface_mark_dirty(surface);
        const key = try std.heap.c_allocator.dupeZ(u8, name);
        _ = c.cairo_surface_reference(surface);
        c.cache_put(self.cache, key.ptr, surface);
        return surface;
    }
}
