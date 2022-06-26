//! Fetches icons using GTK.

const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const std = @import("std");
const util = @import("util.zig");

const IconManager = @This();

const ICON_CACHE_SIZE = 29;

const CacheKind = enum { app_id, icon_name };

const CacheKey = struct {
    string: []const u8,
    kind: CacheKind,
};

const Cache = @import("cache.zig").Cache(CacheKey, ?*c.cairo_surface_t, struct {
    pub fn hash(key: CacheKey) usize {
        return @truncate(usize, std.hash.Wyhash.hash(1, key.string));
    }

    pub fn equal(a: CacheKey, b: CacheKey) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.string, b.string);
    }

    pub fn free(key: CacheKey, value: ?*c.cairo_surface_t) void {
        allocator.free(key.string);
        if (value) |v| {
            c.cairo_surface_destroy(v);
        }
    }
});

/// A reference to the default theme.
theme: *c.GtkIconTheme,
/// A cache of recently used icons.
cache: Cache,

/// Construct a new icon manager.
pub fn init() !IconManager {
    const cache = try Cache.init(ICON_CACHE_SIZE);
    errdefer cache.deinit();

    const theme = c.gtk_icon_theme_get_default().?;

    return IconManager{
        .cache = cache,
        .theme = theme,
    };
}

/// Destroy an icon manager and related resources.
pub fn deinit(self: IconManager) void {
    self.cache.deinit();
}

fn searchFileForIcon(file: std.fs.File) !?[:0]u8 {
    defer file.close();

    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    var buf: [64]u8 = undefined;
    while (true) {
        const amt = try file.read(&buf);
        if (amt == 0) return null;

        for (buf[0..amt]) |b| {
            if (b != '\n') {
                try line_buffer.append(b);
            } else if (std.mem.startsWith(u8, line_buffer.items, "Icon=")) {
                return try allocator.dupeZ(u8, line_buffer.items[5..]);
            } else {
                line_buffer.clearRetainingCapacity();
            }
        }
    }
}

fn searchApplications(comptime fmt: []const u8, args: anytype) !?[:0]u8 {
    const file = blk: {
        const filename = try std.fmt.allocPrintZ(allocator, fmt, args);
        defer allocator.free(filename);
        break :blk std.fs.cwd().openFileZ(filename, .{}) catch return null;
    };
    return searchFileForIcon(file);
}

fn getIconNameFromDesktop(name: []const u8) !?[:0]u8 {
    // remove possible trailing .desktop
    const stripped_name = if (std.mem.endsWith(u8, name, ".desktop"))
        name[0 .. name.len - 8]
    else
        name;
    // try local directory first
    if (std.os.getenvZ("XDG_DATA_HOME")) |v| {
        if (try searchApplications("{s}/applications/{s}.desktop", .{ v, stripped_name })) |result| {
            return result;
        }
    } else if (std.os.getenvZ("HOME")) |v| {
        if (try searchApplications("{s}/.local/share/applications/{s}.desktop", .{ v, stripped_name })) |result| {
            return result;
        }
    }
    // try global directories next
    const xdg_data_dirs = std.os.getenvZ("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.split(u8, xdg_data_dirs, ":");
    while (it.next()) |dir| {
        if (try searchApplications("{s}/applications/{s}.desktop", .{ dir, stripped_name })) |result| {
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
    const search = c.g_desktop_app_info_search(name.ptr).?;
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

fn putCache(
    self: *IconManager,
    name: []const u8,
    kind: CacheKind,
    value: ?*c.cairo_surface_t,
) void {
    // if we can't cache, not an issue
    const data = allocator.dupe(u8, name) catch return;
    const key = CacheKey{ .string = data, .kind = kind };
    self.cache.put(key, value);
    if (value) |v| _ = c.cairo_surface_reference(v);
}

pub fn getIconFromTheme(theme: *c.GtkIconTheme, icon_name: [:0]const u8) !*c.cairo_surface_t {
    var err: ?*c.GError = null;
    const pixbuf = c.gtk_icon_theme_load_icon(theme, icon_name, 16, 0, &err) orelse
        return util.gtkError(err.?);
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

        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, width, height).?;
        errdefer c.cairo_surface_destroy(surface);

        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
            return error.OutOfMemory;
        }

        c.cairo_surface_flush(surface);
        var dst = @ptrCast([*]align(1) u32, c.cairo_image_surface_get_data(surface));
        for (dst[0..@intCast(usize, width * height)]) |*byte| {
            const r: u32 = src[0];
            const g: u32 = src[1];
            const b: u32 = src[2];
            const a: u32 = src[3];
            byte.* = (a << 24) | (r << 16) | (g << 8) | b;
            src += 4;
        }
        c.cairo_surface_mark_dirty(surface);
        return surface;
    }
}

/// Get an icon as a surface directly from the icon name.
pub fn getFromIconName(self: *IconManager, icon_name: [:0]const u8) !*c.cairo_surface_t {
    const result = try getIconFromTheme(self.theme, icon_name);
    self.putCache(icon_name, .icon_name, result);
    return result;
}

/// Get an icon as a surface.
pub fn getFromAppId(self: *IconManager, app_id: [:0]const u8) !?*c.cairo_surface_t {
    if (self.cache.get(.{ .string = app_id, .kind = .app_id })) |cached| {
        if (cached) |surface| {
            _ = c.cairo_surface_reference(surface);
        }
        return cached;
    }

    const icon_name = (try getIconName(app_id)) orelse {
        self.putCache(app_id, .app_id, null);
        return null;
    };
    defer allocator.free(icon_name);

    const surface = try self.getFromIconName(icon_name);
    self.putCache(app_id, .app_id, surface);
    return surface;
}
