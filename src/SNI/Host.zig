const allocator = @import("../main.zig").allocator;
const c = @import("../c.zig");
const Client = @import("../Client.zig");
const g = @import("g_util.zig");
const Item = @import("Item.zig");
const std = @import("std");
const util = @import("../util.zig");

const Host = @This();

host_id: c.guint = undefined,
watcher_id: c.guint = 0,

cancellable: ?*c.GCancellable = null,
watcher: ?*c.OrgKdeStatusNotifierWatcher = null,

items: std.TailQueue(Item) = .{},

pub fn init(self: *Host) void {
    var name_buf: [std.fmt.count("org.kde.StatusNotifierHost-{}", .{std.math.maxInt(std.os.pid_t)}) + 1]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "org.kde.StatusNotifierHost-{}", .{std.os.linux.getpid()}) catch unreachable;

    self.host_id = c.g_bus_own_name(
        c.G_BUS_TYPE_SESSION,
        name.ptr,
        c.G_BUS_NAME_OWNER_FLAGS_NONE,
        onBusAcquired,
        null,
        null,
        self,
        null,
    );
    errdefer c.g_bus_unown_name(self.host_id);
}

pub fn deinit(self: *Host) void {
    c.g_bus_unown_name(self.host_id);
    if (self.watcher_id != 0) {
        c.g_bus_unwatch_name(self.watcher_id);
    }
    if (self.cancellable) |cancellable| {
        c.g_cancellable_cancel(cancellable);
        c.g_object_unref(cancellable);
    }
    if (self.watcher) |watcher| {
        c.g_object_unref(watcher);
    }
    while (self.items.pop()) |node| {
        node.data.deinit();
        allocator.destroy(node);
    }
}

inline fn client(self: *Host) *Client {
    return @fieldParentPtr(Client, "host", self);
}

fn onBusAcquired(conn: ?*c.GDBusConnection, name: ?[*:0]const u8, user_data: c.gpointer) callconv(.C) void {
    _ = conn;
    _ = name;
    const self = @ptrCast(*Host, @alignCast(@alignOf(Host), user_data.?));

    self.watcher_id = c.g_bus_watch_name(
        c.G_BUS_TYPE_SESSION,
        "org.kde.StatusNotifierWatcher",
        c.G_BUS_NAME_WATCHER_FLAGS_NONE,
        onNameAppeared,
        onNameVanished,
        self,
        null,
    );
}

fn onNameAppeared(conn: ?*c.GDBusConnection, name: ?[*:0]const u8, owner: ?[*:0]const u8, user_data: c.gpointer) callconv(.C) void {
    _ = name;
    _ = owner;
    const self = @ptrCast(*Host, @alignCast(@alignOf(Host), user_data.?));

    self.cancellable = c.g_cancellable_new();

    c.org_kde_status_notifier_watcher_proxy_new(
        conn,
        c.G_DBUS_PROXY_FLAGS_NONE,
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        self.cancellable,
        onNewProxy,
        self,
    );
}

fn onNewProxy(src: ?*c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.C) void {
    _ = src;
    const self = @ptrCast(*Host, @alignCast(@alignOf(Host), user_data.?));

    var err: ?*c.GError = null;
    const watcher = c.org_kde_status_notifier_watcher_proxy_new_finish(res, &err);
    if (err) |e| {
        util.warn(@src(), "failed to create a new StatusNotifierWatcher: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }

    self.watcher = watcher;

    var path_buf: [std.fmt.count("/StatusNotifierHost/{}", .{std.math.maxInt(c.guint)}) + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/StatusNotifierHost/{}", .{self.host_id}) catch unreachable;

    c.org_kde_status_notifier_watcher_call_register_status_notifier_host(
        watcher,
        path.ptr,
        self.cancellable,
        onRegisterHost,
        self,
    );
}

fn onRegisterHost(src: ?*c.GObject, res: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.C) void {
    _ = src;
    const self = @ptrCast(*Host, @alignCast(@alignOf(Host), user_data.?));

    var err: ?*c.GError = null;
    _ = c.org_kde_status_notifier_watcher_call_register_status_notifier_host_finish(
        self.watcher,
        res,
        &err,
    );
    if (err) |e| {
        util.warn(@src(), "failed to register host: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }

    _ = g.signalConnect(self.watcher, "status-notifier-item-registered", g.callback(onItemRegistered), self);
    _ = g.signalConnect(self.watcher, "status-notifier-item-unregistered", g.callback(onItemUnregistered), self);

    var items = c.org_kde_status_notifier_watcher_get_registered_status_notifier_items(self.watcher) orelse return;
    while (items[0]) |item| {
        self.addItem(item) catch {
            util.warn(@src(), "failed to add item {s} on initialization", .{item});
        };
        items += 1;
    }
    self.client().updateGui();
}

fn onNameVanished(conn: ?*c.GDBusConnection, name: ?[*:0]const u8, user_data: c.gpointer) callconv(.C) void {
    _ = conn;
    _ = name;
    const self = @ptrCast(*Host, @alignCast(@alignOf(Host), user_data.?));
    if (self.cancellable) |cancellable| {
        c.g_cancellable_cancel(cancellable);
        c.g_object_unref(cancellable);
    }
    if (self.watcher) |watcher| {
        c.g_object_unref(watcher);
    }
    while (self.items.pop()) |node| {
        node.data.deinit();
        allocator.destroy(node);
    }
    self.client().updateGui();
}

fn onItemRegistered(watcher: *c.OrgKdeStatusNotifierWatcher, service: [*:0]const u8, self: *Host) callconv(.C) void {
    _ = watcher;
    self.addItem(service) catch {
        util.warn(@src(), "failed to add new item {s}", .{service});
    };
    self.client().updateGui();
}

fn onItemUnregistered(watcher: *c.OrgKdeStatusNotifierWatcher, service: [*:0]const u8, self: *Host) callconv(.C) void {
    _ = watcher;
    if (self.findItem(service)) |node| {
        node.data.deinit();
        self.items.remove(node);
        allocator.destroy(node);
        self.client().updateGui();
    }
}

fn findItem(self: *Host, service: [*:0]const u8) ?*std.TailQueue(Item).Node {
    const span = std.mem.span(service);
    var it = self.items.first;
    while (it) |node| {
        if (std.mem.eql(u8, node.data.service, span)) {
            return node;
        }
        it = node.next;
    }
    return null;
}

fn addItem(self: *Host, service: [*:0]const u8) !void {
    if (self.findItem(service) != null) {
        util.warn(@src(), "duplicate item", .{});
        return;
    }

    const node = try allocator.create(std.TailQueue(Item).Node);
    errdefer allocator.destroy(node);

    try node.data.init(self.client(), service);
    errdefer node.data.deinit();

    self.items.append(node);
}
