const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");
const util = @import("util.zig");

const Toplevel = @This();

/// A reference to the node.
node: *std.TailQueue(Toplevel).Node,
/// The window handle.
handle: *c.zwlr_foreign_toplevel_handle_v1,
/// THe last seen title.
title: ?[:0]const u8,
/// The last seen app ID.
app_id: ?[:0]const u8,

const handle_listener = util.createListener(c.zwlr_foreign_toplevel_handle_v1_listener, struct {
    pub fn title(
        list: *List,
        handle: ?*c.zwlr_foreign_toplevel_handle_v1,
        new_title: ?[*:0]const u8,
    ) void {
        if (handle == null or new_title == null) return;
        const toplevel = list.findOrAdd(handle.?) catch {
            std.log.warn("failed to allocate for toplevel", .{});
            return;
        };
        const copy = allocator.dupeZ(u8, std.mem.span(new_title.?)) catch {
            std.log.warn("failed to allocate new title", .{});
            return;
        };
        if (toplevel.title) |old_title| allocator.free(old_title);
        toplevel.title = copy;
        list.client().updateGui();
    }

    pub fn app_id(
        list: *List,
        handle: ?*c.zwlr_foreign_toplevel_handle_v1,
        new_app_id: ?[*:0]const u8,
    ) void {
        if (handle == null or new_app_id == null) return;
        const toplevel = list.findOrAdd(handle.?) catch {
            std.log.warn("failed to allocate for toplevel", .{});
            return;
        };
        const copy = allocator.dupeZ(u8, std.mem.span(new_app_id.?)) catch {
            std.log.warn("failed to allocate new app ID", .{});
            return;
        };
        if (toplevel.app_id) |old_app_id| allocator.free(old_app_id);
        toplevel.app_id = copy;
        list.client().updateGui();
    }

    pub fn closed(
        list: *List,
        handle: ?*c.zwlr_foreign_toplevel_handle_v1,
    ) void {
        if (list.client().gui) |gui| {
            gui.deinit();
            list.client().gui = null;
        }

        if (list.find(handle.?)) |toplevel| {
            list.remove(toplevel);
        } else {
            c.zwlr_foreign_toplevel_handle_v1_destroy(handle);
        }

        list.client().updateGui();
    }
});

const toplevel_listener = util.createListener(c.zwlr_foreign_toplevel_manager_v1_listener, struct {
    pub fn toplevel(list: *List, manager: ?*c.zwlr_foreign_toplevel_manager_v1, handle: ?*c.zwlr_foreign_toplevel_handle_v1) void {
        _ = manager;

        _ = c.zwlr_foreign_toplevel_handle_v1_add_listener(handle, &handle_listener, list);
        _ = list.add(handle.?) catch |err| {
            std.log.warn("onTopLevel: {}", .{err});
        };
    }

    pub fn finished(list: *List, manager: ?*c.zwlr_foreign_toplevel_manager_v1) void {
        _ = manager;
        list.clear();
        std.log.warn("toplevel manager closed early, functionality limited", .{});
    }
});

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

    inline fn client(self: *List) *Client {
        return @fieldParentPtr(Client, "toplevel_list", self);
    }
};
