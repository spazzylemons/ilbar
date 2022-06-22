const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Element = @import("Element.zig");
const IconManager = @import("IconManager.zig");
const PointerManager = @import("PointerManager.zig");
const std = @import("std");
const Toplevel = @import("Toplevel.zig");

extern fn strerror(errnum: c_int) [*:0]u8;
extern fn free_all_toplevels(self: *c.Client) void;
extern fn icons_deinit(icons: *c.IconManager) void;
extern fn toplevel_list_deinit(list: *c.ToplevelList) void;

fn refreshPoolBuffer(self: *c.Client) !*c.wl_buffer {
    const size = self.width * self.height * 4;
    const pool = c.wl_shm_create_pool(self.shm, self.buffer_fd, @intCast(i32, size))
        orelse return error.WaylandError;
    defer c.wl_shm_pool_destroy(pool);
    const format: u32 = switch (@import("builtin").target.cpu.arch.endian()) {
        .Big => c.WL_SHM_FORMAT_BGRX8888,
        .Little => c.WL_SHM_FORMAT_XRGB8888,
    };
    const pool_buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(i32, self.width),
        @intCast(i32, self.height),
        @intCast(i32, self.width * 4),
        format,
    ) orelse return error.WaylandError;
    _ = c.wl_buffer_add_listener(pool_buffer, &buffer_listener, self);
    return pool_buffer;
}

export fn refresh_pool_buffer(client: *c.Client) ?*c.wl_buffer {
    return refreshPoolBuffer(client) catch null;
}

fn onBufferRelease(
    data:   ?*anyopaque,
    buffer: ?*c.wl_buffer,
) callconv(.C) void {
    const client = @ptrCast(*c.Client, @alignCast(@alignOf(c.Client), data.?));
    if (buffer == client.pool_buffer) {
        c.wl_buffer_destroy(buffer);
        client.pool_buffer = refreshPoolBuffer(client) catch null;
    }
}

const buffer_listener = c.wl_buffer_listener{
    .release = onBufferRelease,
};

fn getGui(self: *c.Client) ?*Element {
    return @ptrCast(*Element, @alignCast(@alignOf(Element), self.gui orelse return null));
}

fn getPtrManager(self: *c.Client) ?*PointerManager {
    return @ptrCast(*PointerManager, @alignCast(@alignOf(PointerManager), self.pointer_manager orelse return null));
}

export fn pointer_manager_init(self: *c.Client) ?*PointerManager {
    return PointerManager.init(self) catch return null;
}

export fn client_rerender(self: *c.Client) void {
    if (self.buffer != null and self.buffer_fd >= 0 and self.gui != null) {
        if (self.pool_buffer == null) {
            self.pool_buffer = refreshPoolBuffer(self) catch null;
        }
        if (self.pool_buffer) |pool_buffer| {
            getGui(self).?.render(self);
            c.wl_surface_attach(self.wl_surface, pool_buffer, 0, 0);
            c.wl_surface_commit(self.wl_surface);
            c.wl_surface_damage(self.wl_surface, 0, 0, @intCast(i32, self.width), @intCast(i32, self.height));
        }
    }
}

fn createTaskbarButton(self: *c.Client, toplevel: *Toplevel, root: *Element, x: c_int) !void {
    const button = try root.initChild(&Element.window_button_class);
    errdefer button.deinit();

    button.x = x;
    button.y = 4;
    button.width = self.config.*.width;
    button.height = self.config.*.height - 6;
    button.data = .{ .window_button = .{
        .handle = toplevel.handle,
        .seat = self.seat.?,
    } };

    var text_x = self.config.*.margin;
    var text_width = self.config.*.width - (2 * self.config.*.margin);
    if (self.icons) |icons_ptr| {
        const icons = @ptrCast(*IconManager, @alignCast(@alignOf(IconManager), icons_ptr));
        if (toplevel.app_id) |app_id| {
            if (icons.get(app_id) catch null) |image| {
                errdefer c.cairo_surface_destroy(image);
                const icon = try button.initChild(&Element.image_class);
                icon.x = self.config.*.margin;
                icon.y = @divTrunc(button.height - 16, 2);
                icon.data = .{ .image = image };
                text_x += 16 + self.config.*.margin;
                text_width -= 16 + self.config.*.margin;
            }
        }
    }
    const text = try button.initChild(&Element.text_class);
    text.x = text_x;
    text.y = @floatToInt(c_int, (@intToFloat(f64, button.height) - self.config.*.font_height) / 2);
    text.width = text_width;
    text.height = @floatToInt(c_int, self.config.*.font_height);
    if (toplevel.title) |title| {
        text.data = .{ .text = try allocator.dupeZ(u8, title) };
    } else {
        text.data = .{ .text = null };
    }
}

fn createGui(self: *c.Client) !*Element {
    const root = try Element.init();
    root.width = @intCast(c_int, self.width);
    root.height = @intCast(c_int, self.height);
    var x = self.config.*.margin;

    var list = @ptrCast(*Toplevel.List, @alignCast(@alignOf(Toplevel), self.toplevel_list.?));
    var it = list.list.first;
    while (it) |node| {
        if (createTaskbarButton(self, &node.data, root, x)) |_| {
            x += self.config.*.width + self.config.*.margin;
        } else |err| {
            std.log.warn("failed to create a taskbar button: {}", .{err});
        }
        it = node.next;
    }

    return root;
}

export fn destroy_client_gui(self: *c.Client) void {
    if (getGui(self)) |g| {
        g.deinit();
        self.gui = null;
    }
}

export fn update_gui(self: *c.Client) void {
    const new_gui = createGui(self) catch return;
    if (getGui(self)) |g| {
        g.deinit();
    }
    self.gui = @ptrCast(*c.Element, new_gui);
    client_rerender(self);
}

export fn client_deinit(self: *c.Client) void {
    if (self.toplevel_list) |x| toplevel_list_deinit(x);

    if (self.icons) |x| icons_deinit(x);

    if (getGui(self)) |x| x.deinit();

    if (self.pool_buffer) |x| c.wl_buffer_destroy(x);
    if (self.buffer) |x| _ = std.c.munmap(@alignCast(4096, x), @intCast(usize, self.width * self.height * 4));
    if (self.buffer_fd >= 0) _ = std.c.close(self.buffer_fd);

    if (self.pointer) |x| c.wl_pointer_destroy(x);
    if (self.touch) |x| c.wl_touch_destroy(x);

    if (self.layer_surface) |x| c.zwlr_layer_surface_v1_destroy(x);
    if (self.wl_surface) |x| c.wl_surface_destroy(x);

    if (getPtrManager(self)) |x| {
        allocator.destroy(x);
    }

    if (self.shm) |x| c.wl_shm_destroy(x);
    if (self.compositor) |x| c.wl_compositor_destroy(x);
    if (self.layer_shell) |x| c.zwlr_layer_shell_v1_destroy(x);
    if (self.seat) |x| c.wl_seat_destroy(x);
    if (self.toplevel_manager) |x|
        c.zwlr_foreign_toplevel_manager_v1_destroy(x);

    if (self.display) |x| c.wl_display_disconnect(x);

    std.c.free(self);
}

export fn client_run(self: *c.Client) void {
    while (!self.should_close and c.wl_display_dispatch(self.display) >= 0) {
        // nothing to do
    }

    const err = c.wl_display_get_error(self.display);
    if (err != 0) {
        std.log.err("disconnected: {s}", .{std.mem.span(strerror(err))});
    }
}

export fn client_press(self: *c.Client) void {
    if (getGui(self)) |g| {
        if (!getPtrManager(self).?.down) {
            _ = g.press(
                getPtrManager(self).?.x,
                getPtrManager(self).?.y,
            );
            client_rerender(self);
        }
    }
    getPtrManager(self).?.down = true;
}

export fn client_motion(self: *c.Client) void {
    if (getGui(self)) |g| {
        if (getPtrManager(self).?.down) {
            _ = g.motion(
                getPtrManager(self).?.x,
                getPtrManager(self).?.y,
            );
            client_rerender(self);
        }
    }
}

export fn client_release(self: *c.Client) void {
    if (getGui(self)) |g| {
        if (getPtrManager(self).?.down) {
            _ = g.release();
            client_rerender(self);
        }
    }
    getPtrManager(self).?.down = false;
}
