const allocator = @import("../main.zig").allocator;
const c = @import("../c.zig");
const g = @import("../glib_util.zig");
const std = @import("std");
const util = @import("../util.zig");

const Watcher = @This();

const WatchedObjectKind = enum { host, item };

const WatchedObject = struct {
    kind: WatchedObjectKind,

    watcher: *Watcher,

    id: c.guint,

    name: []const u8,
    path: []const u8,
    full: [:0]const u8,

    pub fn remove(self: *WatchedObject) void {
        const node = @fieldParentPtr(ObjectList.Node, "data", self);
        switch (self.kind) {
            .host => {
                self.watcher.hosts.remove(node);
                if (self.watcher.hosts.len == 0) {
                    c.org_kde_status_notifier_watcher_set_is_status_notifier_host_registered(self.watcher.watcher, 0);
                }
            },

            .item => {
                self.watcher.items.remove(node);
                self.watcher.updateRegisteredItems() catch {
                    util.warn(@src(), "failed to allocate to update RegisteredStatusNotifierItems", .{});
                };
                c.org_kde_status_notifier_watcher_emit_status_notifier_item_unregistered(self.watcher.watcher, self.full.ptr);
                allocator.free(self.full);
            },
        }
        allocator.free(self.name);
        allocator.free(self.path);
        c.g_bus_unwatch_name(self.id);
        allocator.destroy(node);
    }
};

const ObjectList = std.TailQueue(WatchedObject);

fn newObject(self: *Watcher, list: *ObjectList, kind: WatchedObjectKind, name: [:0]const u8, path: []const u8) !*WatchedObject {
    const node = try allocator.create(ObjectList.Node);
    errdefer allocator.destroy(node);
    const obj = &node.data;

    obj.kind = kind;
    obj.watcher = self;

    obj.name = try allocator.dupe(u8, name);
    errdefer allocator.free(obj.name);

    obj.path = try allocator.dupe(u8, path);
    errdefer allocator.free(obj.path);

    obj.full = switch (kind) {
        .host => undefined,
        .item => try std.fmt.allocPrintZ(allocator, "{s}{s}", .{ obj.name, obj.path }),
    };

    obj.id = c.g_bus_watch_name(c.G_BUS_TYPE_SESSION, name.ptr, c.G_BUS_NAME_WATCHER_FLAGS_NONE, null, onNameVanished, obj, null);
    list.append(node);

    return obj;
}

fn onNameVanished(conn: ?*c.GDBusConnection, name: ?[*:0]const u8, user_data: c.gpointer) callconv(.C) void {
    _ = conn;
    _ = name;
    const obj = @ptrCast(*WatchedObject, @alignCast(@alignOf(WatchedObject), user_data.?));
    obj.remove();
}

fn findObject(list: ObjectList, name: []const u8, path: []const u8) ?*ObjectList.Node {
    var it = list.first;
    while (it) |node| {
        if (std.mem.eql(u8, node.data.name, name) and std.mem.eql(u8, node.data.path, path)) {
            return node;
        }
        it = node.next;
    }
    return null;
}

id: c.guint = undefined,
watcher: *c.OrgKdeStatusNotifierWatcher = undefined,

hosts: ObjectList = .{},
items: ObjectList = .{},

pub fn init(self: *Watcher) void {
    self.id = c.g_bus_own_name(
        c.G_BUS_TYPE_SESSION,
        "org.kde.StatusNotifierWatcher",
        c.G_BUS_NAME_OWNER_FLAGS_ALLOW_REPLACEMENT | c.G_BUS_NAME_OWNER_FLAGS_REPLACE,
        onBusAcquired,
        null,
        null,
        self,
        null,
    );

    self.watcher = c.org_kde_status_notifier_watcher_skeleton_new().?;
}

fn watcherSkeleton(self: *Watcher) *c.GDBusInterfaceSkeleton {
    return g.cast(c.GDBusInterfaceSkeleton, self.watcher, c.g_dbus_interface_skeleton_get_type());
}

pub fn deinit(self: *Watcher) void {
    var it = self.hosts.first;
    while (it) |node| {
        it = node.next;
        node.data.remove();
    }
    it = self.items.first;
    while (it) |node| {
        it = node.next;
        node.data.remove();
    }
    c.g_bus_unown_name(self.id);
    c.g_dbus_interface_skeleton_unexport(self.watcherSkeleton());
}

fn onBusAcquired(conn: ?*c.GDBusConnection, name: ?[*:0]const u8, user_data: c.gpointer) callconv(.C) void {
    _ = name;

    const self = @ptrCast(*Watcher, @alignCast(@alignOf(Watcher), user_data.?));

    var err: ?*c.GError = null;
    _ = c.g_dbus_interface_skeleton_export(
        self.watcherSkeleton(),
        conn,
        "/StatusNotifierWatcher",
        &err,
    );
    if (err) |e| {
        util.warn(@src(), "failed to export StatusNotifierWatcher: {s}", .{e.message});
        c.g_error_free(e);
        return;
    }

    _ = g.signalConnect(
        self.watcher,
        "handle-register-status-notifier-host",
        g.callback(onRegisterHost),
        self,
    );

    _ = g.signalConnect(
        self.watcher,
        "handle-register-status-notifier-item",
        g.callback(onRegisterItem),
        self,
    );
}

const NameAndPath = struct { name: [:0]const u8, path: []const u8 };

fn getNameAndPath(service: [*:0]const u8, invocation: *c.GDBusMethodInvocation, default: []const u8) ?NameAndPath {
    const result: NameAndPath = switch (service[0]) {
        '/' => .{
            .name = std.mem.span(c.g_dbus_method_invocation_get_sender(invocation).?),
            .path = std.mem.span(service),
        },
        else => .{
            .name = std.mem.span(service),
            .path = default,
        },
    };

    if (c.g_dbus_is_name(result.name.ptr) == 0) {
        g.dbusError(invocation, c.G_DBUS_ERROR_INVALID_ARGS, "invalid bus name");
        return null;
    }

    return result;
}

fn onRegisterHost(
    watcher: *c.OrgKdeStatusNotifierWatcher,
    invocation: *c.GDBusMethodInvocation,
    service: [*:0]const u8,
    self: *Watcher,
) callconv(.C) c.gboolean {
    const name_path = getNameAndPath(service, invocation, "/StatusNotifierHost") orelse return 1;

    if (findObject(self.hosts, name_path.name, name_path.path) != null) {
        g.dbusError(invocation, c.G_DBUS_ERROR_INVALID_ARGS, "host already registered");
        return 1;
    }

    _ = self.newObject(&self.hosts, .host, name_path.name, name_path.path) catch {
        util.warn(@src(), "failed to allocate for a StatusNotifierHost", .{});
        return 1;
    };

    c.org_kde_status_notifier_watcher_set_is_status_notifier_host_registered(watcher, 1);
    c.org_kde_status_notifier_watcher_emit_status_notifier_host_registered(watcher);
    c.org_kde_status_notifier_watcher_complete_register_status_notifier_host(watcher, invocation);

    return 1;
}

fn onRegisterItem(
    watcher: *c.OrgKdeStatusNotifierWatcher,
    invocation: *c.GDBusMethodInvocation,
    service: [*:0]const u8,
    self: *Watcher,
) callconv(.C) c.gboolean {
    const name_path = getNameAndPath(service, invocation, "/StatusNotifierItem") orelse return 1;

    if (findObject(self.items, name_path.name, name_path.path) != null) {
        g.dbusError(invocation, c.G_DBUS_ERROR_INVALID_ARGS, "item already registered");
        return 1;
    }

    const item = self.newObject(&self.items, .item, name_path.name, name_path.path) catch {
        util.warn(@src(), "failed to allocate for a StatusNotifierItem", .{});
        return 1;
    };

    self.updateRegisteredItems() catch {
        util.warn(@src(), "failed to allocate to update RegisteredStatusNotifierItems", .{});
        return 1;
    };

    c.org_kde_status_notifier_watcher_emit_status_notifier_item_registered(watcher, item.full.ptr);

    return 1;
}

fn updateRegisteredItems(self: *Watcher) !void {
    const strv = try allocator.alloc(?[*:0]const u8, self.items.len + 1);
    defer allocator.free(strv);

    var it = self.items.first;
    var i: usize = 0;
    while (it) |node| {
        strv[i] = node.data.full.ptr;
        i += 1;
        it = node.next;
    }
    strv[i] = null;

    c.org_kde_status_notifier_watcher_set_registered_status_notifier_items(self.watcher, strv.ptr);
}
