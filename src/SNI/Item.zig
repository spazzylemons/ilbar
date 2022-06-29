const allocator = @import("../main.zig").allocator;
const c = @import("../c.zig");
const Client = @import("../Client.zig");
const g = @import("../glib_util.zig");
const IconManager = @import("../IconManager.zig");
const std = @import("std");
const util = @import("../util.zig");

const Item = @This();

client: *Client,

service: []const u8,
name: []const u8,
path: []const u8,

cancellable: *c.GCancellable,
item: ?*c.OrgKdeStatusNotifierItem = null,
surface: ?*c.cairo_surface_t = null,

pending_icon_change: bool = true,

icon_name: ?[:0]u8 = null,
icon_pixmap: ?*c.GVariant = null,
icon_theme_path: ?[*:0]u8 = null,
item_is_menu: bool = true,
menu_path: ?[*:0]u8 = null,

menu: ?*c.GtkMenu = null,

pub fn init(self: *Item, client: *Client, service: [*:0]const u8) !void {
    const service_copy = try allocator.dupe(u8, std.mem.span(service));
    errdefer allocator.free(service_copy);

    var name: []const u8 = undefined;
    var path: []const u8 = undefined;

    if (std.mem.indexOfScalar(u8, service_copy, '/')) |path_start| {
        name = service_copy[0..path_start];
        path = service_copy[path_start..];
    } else {
        name = service_copy;
        path = "/StatusNotifierItem";
    }

    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    self.* = .{
        .client = client,
        .service = service_copy,
        .name = name,
        .path = path,
        .cancellable = c.g_cancellable_new(),
    };

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
    if (self.icon_name) |icon_name| {
        c.g_free(icon_name.ptr);
    }
    if (self.icon_pixmap) |icon_pixmap| {
        c.g_variant_unref(icon_pixmap);
    }
    if (self.icon_theme_path) |icon_theme_path| {
        c.g_free(icon_theme_path);
    }
    if (self.menu_path) |menu_path| {
        c.g_free(menu_path);
    }
    if (self.menu) |menu| {
        c.g_object_unref(menu);
    }
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

    _ = g.signalConnect(item, "new-icon", onNewIcon, self);

    self.updateProperties();
}

fn getIconFromIconName(self: *Item) !?*c.cairo_surface_t {
    // get the icon name, if it exists
    const icon_name = self.icon_name orelse return null;
    // if the item uses a custom path, search the theme for the icon there
    if (self.icon_theme_path) |icon_theme_path| {
        const theme = c.gtk_icon_theme_new().?;
        defer c.g_object_unref(theme);
        c.gtk_icon_theme_append_search_path(theme, icon_theme_path);
        return try IconManager.getIconFromTheme(theme, self.client.config.icon_size, icon_name);
    }
    // otherwise, use the default theme
    return try self.client.icons.getFromIconName(self.client.config.icon_size, icon_name);
}

fn getIconFromPixmap(self: *Item) !?*c.cairo_surface_t {
    const variant = self.icon_pixmap orelse return null;
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
        const is_exact = width == self.client.config.icon_size and height == self.client.config.icon_size;
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
    self.updateProperties();
}

fn updateMenu(self: *Item) void {
    const name = allocator.dupeZ(u8, self.name) catch {
        util.warn(@src(), "failed to allocate to update menu", .{});
        return;
    };
    defer allocator.free(name);

    if (self.menu == null and self.menu_path != null) {
        const dbus_menu = c.dbusmenu_gtkmenu_new(name, self.menu_path);
        defer c.g_object_unref(dbus_menu);
        _ = c.g_object_ref_sink(dbus_menu);

        self.menu = g.cast(c.GtkMenu, dbus_menu, c.gtk_menu_get_type());

        const window = g.cast(c.GtkWidget, self.client.window, c.gtk_widget_get_type());
        c.gtk_menu_attach_to_widget(self.menu, window, null);
    }
}

// GdkEvent cannot be parsed by zig, need to redefine the function
extern fn gtk_menu_popup_at_pointer(menu: *c.GtkMenu, event: *const anyopaque) void;

pub fn click(self: *Item, event: *const c.GdkEventButton) void {
    if (self.item_is_menu) {
        self.updateMenu();
        if (self.menu) |menu| {
            gtk_menu_popup_at_pointer(menu, event);
        }
    } else {
        c.org_kde_status_notifier_item_call_activate(
            self.item,
            @floatToInt(i32, event.x),
            @floatToInt(i32, event.y),
            self.cancellable,
            onActivateComplete,
            self,
        );
    }
}

fn onActivateComplete(src: ?*c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.C) void {
    _ = src;
    const self = @ptrCast(*Item, @alignCast(@alignOf(Item), user_data.?));

    var err: ?*c.GError = null;
    _ = c.org_kde_status_notifier_item_call_activate_finish(self.item, res, &err);
    if (err) |e| {
        util.warn(@src(), "failed to activate the item: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }
}

fn updateProperties(self: *Item) void {
    c.g_dbus_proxy_call(
        g.cast(c.GDBusProxy, self.item, c.g_dbus_proxy_get_type()),
        "org.freedesktop.DBus.Properties.GetAll",
        c.g_variant_new("(s)", "org.kde.StatusNotifierItem"),
        c.G_DBUS_CALL_FLAGS_NONE,
        -1,
        self.cancellable,
        onPropertiesGet,
        self,
    );
}

fn onPropertiesGet(src: ?*c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.C) void {
    const self = @ptrCast(*Item, @alignCast(@alignOf(Item), user_data.?));
    _ = self;

    const proxy = g.cast(c.GDBusProxy, src, c.g_dbus_proxy_get_type());

    var err: ?*c.GError = null;
    const variant = c.g_dbus_proxy_call_finish(proxy, res, &err);
    if (err) |e| {
        util.warn(@src(), "failed to get properties: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }
    defer c.g_variant_unref(variant);

    var it: ?*c.GVariantIter = undefined;
    c.g_variant_get(variant, "(a{sv})", &it);
    defer c.g_variant_iter_free(it);

    var key: [*:0]u8 = undefined;
    var value: *c.GVariant = undefined;
    while (c.g_variant_iter_next(it, "{sv}", &key, &value) != 0) {
        defer c.g_free(key);
        defer c.g_variant_unref(value);

        const key_span = std.mem.span(key);

        if (std.mem.eql(u8, key_span, "IconName")) {
            if (self.icon_name) |icon_name| {
                c.g_free(icon_name.ptr);
            }
            var icon_name: ?[*:0]u8 = null;
            c.g_variant_get(value, "s", &icon_name);
            self.icon_name = std.mem.span(icon_name);
        } else if (std.mem.eql(u8, key_span, "IconPixmap")) {
            if (self.icon_pixmap) |icon_pixmap| {
                c.g_variant_unref(icon_pixmap);
            }
            self.icon_pixmap = value;
            _ = c.g_variant_ref(value);
        } else if (std.mem.eql(u8, key_span, "IconThemePath")) {
            if (self.icon_theme_path) |icon_theme_path| {
                c.g_free(icon_theme_path);
            }
            c.g_variant_get(value, "s", &self.icon_theme_path);
        } else if (std.mem.eql(u8, key_span, "Menu")) {
            if (self.menu_path) |menu_path| {
                c.g_free(menu_path);
            }
            c.g_variant_get(value, "o", &self.menu_path);
            self.updateMenu();
        } else if (std.mem.eql(u8, key_span, "ItemIsMenu")) {
            var item_is_menu: c.gboolean = @boolToInt(self.item_is_menu);
            c.g_variant_get(value, "b", &item_is_menu);
            self.item_is_menu = item_is_menu != 0;
        }
    }

    if (self.pending_icon_change) {
        self.pending_icon_change = false;
        self.updateIcon() catch |e| {
            util.warn(@src(), "failed to update icon: {}", .{e});
        };
    }
}
