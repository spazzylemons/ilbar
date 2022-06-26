const allocator = @import("../main.zig").allocator;
const c = @import("../c.zig");
const Client = @import("../Client.zig");
const g = @import("g_util.zig");
const Item = @import("Item.zig");
const std = @import("std");

const Host = @This();

name: [:0]const u8,
path: [:0]const u8,

host_id: c.guint,
watcher_id: c.guint,

cancellable: ?*c.GCancellable,
watcher: ?*c.OrgKdeStatusNotifierWatcher,

items: std.TailQueue(Item),

client: ?*Client,

pub fn init() !*Host {
    const self = try allocator.create(Host);
    errdefer allocator.destroy(self);

    self.name = try std.fmt.allocPrintZ(allocator, "org.kde.StatusNotifierHost-{}", .{std.os.linux.getpid()});
    errdefer allocator.free(self.name);

    self.host_id = c.g_bus_own_name(
        c.G_BUS_TYPE_SESSION,
        self.name.ptr,
        c.G_BUS_NAME_OWNER_FLAGS_NONE,
        onBusAcquired,
        null,
        null,
        self,
        null,
    );
    errdefer c.g_bus_unown_name(self.host_id);

    self.path = try std.fmt.allocPrintZ(allocator, "/StatusNotifierHost/{}", .{self.host_id});
    errdefer allocator.free(self.path);

    self.watcher_id = 0;
    self.cancellable = null;
    self.watcher = null;

    self.items = .{};

    self.client = null;

    return self;
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
    allocator.free(self.name);
    allocator.free(self.path);
    allocator.destroy(self);
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
        std.log.warn("failed to create a new StatusNotifierWatcher: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }

    self.watcher = watcher;

    c.org_kde_status_notifier_watcher_call_register_status_notifier_host(
        watcher,
        self.path.ptr,
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
        std.log.warn("failed to register host: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }

    _ = g.signalConnect(self.watcher, "status-notifier-item-registered", g.callback(onItemRegistered), self);
    _ = g.signalConnect(self.watcher, "status-notifier-item-unregistered", g.callback(onItemUnregistered), self);

    var items = c.org_kde_status_notifier_watcher_get_registered_status_notifier_items(self.watcher) orelse return;
    while (items[0]) |item| {
        std.log.info("item! {s}", .{item});
        self.addItem(item) catch {
            std.log.warn("failed to add item {s} on initialization", .{item});
        };
        items += 1;
    }
    if (self.client) |cl| {
        cl.updateGui();
    }
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
    if (self.client) |cl| {
        cl.updateGui();
    }
}

fn onItemRegistered(watcher: *c.OrgKdeStatusNotifierWatcher, service: [*:0]const u8, self: *Host) callconv(.C) void {
    _ = watcher;
    self.addItem(service) catch {
        std.log.warn("failed to add new item {s}", .{service});
    };
    if (self.client) |cl| {
        cl.updateGui();
    }
}

fn onItemUnregistered(watcher: *c.OrgKdeStatusNotifierWatcher, service: [*:0]const u8, self: *Host) callconv(.C) void {
    _ = watcher;
    if (self.findItem(service)) |node| {
        node.data.deinit();
        self.items.remove(node);
        allocator.destroy(node);
        std.log.info("removed item {s}", .{service});
        if (self.client) |cl| {
            cl.updateGui();
        }
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
        std.log.warn("duplicate item", .{});
        return;
    }

    const node = try allocator.create(std.TailQueue(Item).Node);
    errdefer allocator.destroy(node);

    try node.data.init(self.client.?, service);
    errdefer node.data.deinit();

    self.items.append(node);
}
