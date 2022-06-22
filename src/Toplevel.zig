const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");

const Toplevel = @This();

/// A reference to the node.
node: *std.TailQueue(Toplevel).Node,
/// The window handle.
handle: *c.zwlr_foreign_toplevel_handle_v1,
/// THe last seen title.
title: ?[:0]const u8,
/// The last seen app ID.
app_id: ?[:0]const u8,

inline fn unwrapList(data: ?*anyopaque) *List {
    return @ptrCast(*List, @alignCast(@alignOf(List), data.?));
}

fn onTitle(
    data: ?*anyopaque,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
    title: ?[*:0]const u8,
) callconv(.C) void {
    const list = unwrapList(data);
    const toplevel = list.findOrAdd(handle.?) catch |err| {
        std.log.warn("onTitle: {}", .{err});
        return;
    };
    const copy = allocator.dupeZ(u8, std.mem.span(title.?)) catch |err| {
        std.log.warn("onTitle: {}", .{err});
        return;
    };
    if (toplevel.title) |old_title| allocator.free(old_title);
    toplevel.title = copy;
    list.getClient().updateGui();
}

fn onAppId(
    data: ?*anyopaque,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
    app_id: ?[*:0]const u8,
) callconv(.C) void {
    const list = unwrapList(data);
    const toplevel = list.findOrAdd(handle.?) catch |err| {
        std.log.warn("onAppId: {}", .{err});
        return;
    };
    const copy = allocator.dupeZ(u8, std.mem.span(app_id.?)) catch |err| {
        std.log.warn("onAppId: {}", .{err});
        return;
    };
    if (toplevel.app_id) |old_app_id| allocator.free(old_app_id);
    toplevel.app_id = copy;
    list.getClient().updateGui();
}

fn onOutput(
    data: ?*anyopaque,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
    output: ?*c.wl_output,
) callconv(.C) void {
    _ = data;
    _ = handle;
    _ = output;
}

fn onState(
    data: ?*anyopaque,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
    state: ?*c.wl_array,
) callconv(.C) void {
    _ = data;
    _ = handle;
    _ = state;
}

fn onDone(
    data: ?*anyopaque,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
) callconv(.C) void {
    _ = data;
    _ = handle;
}

fn onClosed(
    data: ?*anyopaque,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
) callconv(.C) void {
    const list = unwrapList(data);
    if (list.getClient().gui) |gui| {
        gui.deinit();
        list.getClient().gui = null;
    }

    if (list.find(handle.?)) |toplevel| {
        list.remove(toplevel);
    } else {
        c.zwlr_foreign_toplevel_handle_v1_destroy(handle);
    }

    list.getClient().updateGui();
}

fn onParent(
    data: ?*anyopaque,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
    parent: ?*c.zwlr_foreign_toplevel_handle_v1,
) callconv(.C) void {
    _ = data;
    _ = handle;
    _ = parent;
}

const handle_listener = c.zwlr_foreign_toplevel_handle_v1_listener{
    .title = onTitle,
    .app_id = onAppId,
    .output_enter = onOutput,
    .output_leave = onOutput,
    .state = onState,
    .done = onDone,
    .closed = onClosed,
    .parent = onParent,
};

fn onToplevel(
    data: ?*anyopaque,
    manager: ?*c.zwlr_foreign_toplevel_manager_v1,
    handle: ?*c.zwlr_foreign_toplevel_handle_v1,
) callconv(.C) void {
    _ = manager;

    const list = unwrapList(data);
    _ = c.zwlr_foreign_toplevel_handle_v1_add_listener(handle, &handle_listener, list);
    _ = list.add(handle.?) catch |err| {
        std.log.warn("onTopLevel: {}", .{err});
    };
}

fn onFinished(
    data: ?*anyopaque,
    manager: ?*c.zwlr_foreign_toplevel_manager_v1,
) callconv(.C) void {
    _ = manager;
    const self = unwrapList(data);
    self.clear();
    std.log.warn("toplevel manager closed early, functionality limited", .{});
}

const toplevel_listener = c.zwlr_foreign_toplevel_manager_v1_listener{
    .toplevel = onToplevel,
    .finished = onFinished,
};

pub const List = struct {
    toplevel_manager: *c.zwlr_foreign_toplevel_manager_v1 = undefined,
    list: std.TailQueue(Toplevel) = .{},

    pub fn init(self: *List, toplevel_manager: *c.zwlr_foreign_toplevel_manager_v1) void {
        self.toplevel_manager = toplevel_manager;
        _ = c.zwlr_foreign_toplevel_manager_v1_add_listener(
            toplevel_manager,
            &toplevel_listener,
            self,
        );
    }

    pub fn deinit(self: *List) void {
        self.clear();
        c.zwlr_foreign_toplevel_manager_v1_destroy(self.toplevel_manager);
    }

    pub fn add(self: *List, handle: *c.zwlr_foreign_toplevel_handle_v1) !*Toplevel {
        const node = try allocator.create(std.TailQueue(Toplevel).Node);
        node.* = .{
            .data = .{
                .node = node,
                .handle = handle,
                .title = null,
              .app_id = null,
            },
        };
        self.list.append(node);
        return &node.data;
    }

    pub fn find(self: List, handle: *c.zwlr_foreign_toplevel_handle_v1) ?*Toplevel {
        var it = self.list.first;
        while (it) |node| {
            if (node.data.handle == handle) return &node.data;
            it = node.next;
        }
        return null;
    }

    pub fn findOrAdd(self: *List, handle: *c.zwlr_foreign_toplevel_handle_v1) !*Toplevel {
        return self.find(handle) orelse try self.add(handle);
    }

    pub fn remove(self: *List, toplevel: *Toplevel) void {
        self.list.remove(toplevel.node);
        c.zwlr_foreign_toplevel_handle_v1_destroy(toplevel.handle);
        if (toplevel.title) |title| allocator.free(title);
        if (toplevel.app_id) |app_id| allocator.free(app_id);
        allocator.destroy(toplevel.node);
    }

    pub fn clear(self: *List) void {
        var it = self.list.first;
        while (it) |node| {
            it = node.next;
            self.remove(&node.data);
        }
    }

    inline fn getClient(self: *List) *Client {
        return @fieldParentPtr(Client, "toplevel_list", self);
    }
};