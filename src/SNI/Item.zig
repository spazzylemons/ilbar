const allocator = @import("../main.zig").allocator;
const c = @import("../c.zig");
const Client = @import("../Client.zig");
const g = @import("g_util.zig");
const IconManager = @import("../IconManager.zig");
const std = @import("std");
const util = @import("../util.zig");

const Item = @This();

client: *Client,

service: []const u8,
name: []const u8,
path: []const u8,

cancellable: *c.GCancellable,
item: ?*c.OrgKdeStatusNotifierItem,
surface: ?*c.cairo_surface_t,

pending_propertes: usize,
pending_icon_change: bool,

pub fn init(self: *Item, client: *Client, service: [*:0]const u8) !void {
    self.client = client;

    self.service = try allocator.dupe(u8, std.mem.span(service));
    errdefer allocator.free(self.service);

    if (std.mem.indexOfScalar(u8, self.service, '/')) |path_start| {
        self.name = self.service[0..path_start];
        self.path = self.service[path_start..];
    } else {
        self.name = self.service;
        self.path = "/StatusNotifierItem";
    }

    const name_z = try allocator.dupeZ(u8, self.name);
    defer allocator.free(name_z);
    const path_z = try allocator.dupeZ(u8, self.path);
    defer allocator.free(path_z);

    self.cancellable = c.g_cancellable_new();
    self.item = null;
    self.surface = null;
    self.pending_propertes = 0;
    self.pending_icon_change = false;

    c.org_kde_status_notifier_item_proxy_new_for_bus(
        c.G_BUS_TYPE_SESSION,
        c.G_DBUS_PROXY_FLAGS_NONE,
        name_z.ptr,
        path_z.ptr,
        self.cancellable,
        onNewProxy,
        self,
    );
}

pub fn deinit(self: *Item) void {
    if (self.surface) |surface| {
        c.cairo_surface_destroy(surface);
    }
    if (self.item) |item| {
        c.g_object_unref(item);
    }
    c.g_cancellable_cancel(self.cancellable);
    c.g_object_unref(self.cancellable);
    allocator.free(self.service);
}

fn onNewProxy(src: ?*c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.C) void {
    _ = src;
    const self = @ptrCast(*Item, @alignCast(@alignOf(Item), user_data.?));

    var err: ?*c.GError = null;
    const item = c.org_kde_status_notifier_item_proxy_new_for_bus_finish(res, &err);
    if (err) |e| {
        util.warn(@src(), "failed to acquire a StatusNotifierItem: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }

    self.item = item;

    _ = g.signalConnect(
        item,
        "new-icon",
        g.callback(onNewIcon),
        self,
    );

    self.updateIcon() catch |e| {
        util.warn(@src(), "failed to load icon: {}", .{e});
    };
}

fn getIconFromIconName(self: *Item) !?*c.cairo_surface_t {
    // get the icon name, if it exists
    const icon_name = c.org_kde_status_notifier_item_get_icon_name(self.item) orelse
        return null;
    // if the item uses a custom path, search the theme for the icon there
    if (c.org_kde_status_notifier_item_get_icon_theme_path(self.item)) |icon_theme_path| {
        const theme = c.gtk_icon_theme_new().?;
        defer c.g_object_unref(theme);
        c.gtk_icon_theme_append_search_path(theme, icon_theme_path);
        return try IconManager.getIconFromTheme(theme, std.mem.span(icon_name));
    }
    // otherwise, use the default theme
    return try self.client.icons.getFromIconName(std.mem.span(icon_name));
}

fn getIconFromPixmap(self: *Item) !?*c.cairo_surface_t {
    const variant = c.org_kde_status_notifier_item_get_icon_pixmap(self.item) orelse
        return null;
    var it: ?*c.GVariantIter = undefined;
    c.g_variant_get(variant, "a(iiay)", &it);
    defer c.g_variant_iter_free(it);

    var best_width: c.gint = 0;
    var best_height: c.gint = 0;
    var best_pixels: ?[*]const u8 = null;

    var width: c.gint = undefined;
    var height: c.gint = undefined;
    var pixels: *c.GVariant = undefined;

    // find the largest image, or the one with the exact dimensions we want
    while (c.g_variant_iter_next(it, "(ii@ay)", &width, &height, &pixels) != 0) {
        const is_exact = width == 16 and height == 16;
        if (is_exact or (width > best_width and height > best_height)) {
            best_width = width;
            best_height = height;
            best_pixels = @ptrCast([*]const u8, c.g_variant_get_data(pixels).?);
            if (is_exact) break;
        }
    }

    var src = best_pixels orelse return null;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, best_width, best_height).?;
    errdefer c.cairo_surface_destroy(surface);

    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        return error.OutOfMemory;
    }

    c.cairo_surface_flush(surface);
    const size = @intCast(usize, best_width * best_height);
    var dst = @ptrCast([*]align(1) u32, c.cairo_image_surface_get_data(surface));
    for (dst[0..size]) |*pixel| {
        const pa: u32 = src[0];
        const pr: u32 = src[1];
        const pg: u32 = src[2];
        const pb: u32 = src[3];
        pixel.* = (pa << 24) | (pr << 16) | (pg << 8) | pb;
        src += 4;
    }
    c.cairo_surface_mark_dirty(surface);
    return surface;
}

fn updateIcon(self: *Item) !void {
    const new_icon = (self.getIconFromIconName() catch null) orelse
        (try self.getIconFromPixmap()) orelse
        return;
    if (self.surface) |surface| {
        c.cairo_surface_destroy(surface);
    }
    self.surface = new_icon;
    self.client.updateGui();
}

fn onNewIcon(item: *c.OrgKdeStatusNotifierItem, self: *Item) callconv(.C) void {
    _ = item;
    self.pending_icon_change = true;
    self.updateProperty("IconName");
    self.updateProperty("IconPixmap");
}

const ItemAndName = struct {
    item: *Item,
    name: [*:0]const u8,
};

fn updateProperty(self: *Item, name: [:0]const u8) void {
    const data = allocator.create(ItemAndName) catch {
        util.warn(@src(), "failed to allocate to update property {s}", .{name});
        return;
    };
    data.item = self;
    data.name = name;

    self.pending_propertes += 1;
    c.g_dbus_proxy_call(
        g.cast(c.GDBusProxy, self.item, c.g_dbus_proxy_get_type()),
        "org.freedesktop.DBus.Properties.Get",
        c.g_variant_new("(ss)", "org.kde.StatusNotifierItem", name.ptr),
        c.G_DBUS_CALL_FLAGS_NONE,
        -1,
        self.cancellable,
        onPropertyGet,
        data,
    );
}

fn onPropertyGet(src: ?*c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.C) void {
    const data = @ptrCast(*ItemAndName, @alignCast(@alignOf(ItemAndName), user_data.?));
    defer allocator.destroy(data);

    const proxy = g.cast(c.GDBusProxy, src, c.g_dbus_proxy_get_type());

    var err: ?*c.GError = null;
    const variant = c.g_dbus_proxy_call_finish(proxy, res, &err);
    if (err) |e| {
        util.warn(@src(), "failed to get the property: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }
    defer c.g_variant_unref(variant);

    var value: ?*c.GVariant = undefined;
    c.g_variant_get(variant, "(v)", &value);
    defer c.g_variant_unref(value);

    c.g_dbus_proxy_set_cached_property(proxy, data.name, value);

    data.item.pending_propertes -= 1;
    if (data.item.pending_propertes == 0 and data.item.pending_icon_change) {
        data.item.pending_icon_change = false;
        data.item.updateIcon() catch |e| {
            util.warn(@src(), "failed to update icon: {}", .{e});
        };
    }
}
