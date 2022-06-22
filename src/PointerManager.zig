const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");
const util = @import("util.zig");

const PointerManager = @This();

pointer: ?*c.wl_pointer = null,
touch: ?*c.wl_touch = null,

x: c_int = 0,
y: c_int = 0,
down: bool = false,

const pointer_listener = util.createListener(c.wl_pointer_listener, struct {
    pub fn enter(
        manager: *PointerManager,
        ptr: ?*c.wl_pointer,
        serial: u32,
        surface: ?*c.wl_surface,
        x: c.wl_fixed_t,
        y: c.wl_fixed_t,
    ) void {
        _ = ptr;
        _ = serial;
        _ = surface;
        manager.x = c.wl_fixed_to_int(x);
        manager.y = c.wl_fixed_to_int(y);
        manager.client().motion();
    }

    pub fn motion(
        manager: *PointerManager,
        ptr: ?*c.wl_pointer,
        time: u32,
        x: c.wl_fixed_t,
        y: c.wl_fixed_t,
    ) void {
        _ = ptr;
        _ = time;
        manager.x = c.wl_fixed_to_int(x);
        manager.y = c.wl_fixed_to_int(y);
        manager.client().motion();
    }

    pub fn button(
        manager: *PointerManager,
        ptr: ?*c.wl_pointer,
        serial: u32,
        time: u32,
        btn: u32,
        state: u32,
    ) void {
        _ = ptr;
        _ = serial;
        _ = time;
        if (btn == c.BTN_LEFT) {
            if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
                manager.client().press();
            } else {
                manager.client().release();
            }
        }
    }
});

const touch_listener = util.createListener(c.wl_touch_listener, struct {
    pub fn down(
        manager: *PointerManager,
        touch: ?*c.wl_touch,
        serial: u32,
        time: u32,
        surface: ?*c.wl_surface,
        id: i32,
        x: c.wl_fixed_t,
        y: c.wl_fixed_t,
    ) void {
        _ = touch;
        _ = serial;
        _ = time;
        _ = surface;
        _ = id;
        manager.x = c.wl_fixed_to_int(x);
        manager.y = c.wl_fixed_to_int(y);
        manager.client().press();
    }

    pub fn up(
        manager: *PointerManager,
        touch: ?*c.wl_touch,
        serial: u32,
        time: u32,
        id: i32,
    ) void {
        _ = touch;
        _ = serial;
        _ = time;
        _ = id;
        manager.client().release();
    }

    pub fn motion(
        manager: *PointerManager,
        touch: ?*c.wl_touch,
        time: u32,
        id: i32,
        x: c.wl_fixed_t,
        y: c.wl_fixed_t,
    ) void {
        _ = touch;
        _ = time;
        _ = id;
        manager.x = c.wl_fixed_to_int(x);
        manager.y = c.wl_fixed_to_int(y);
        manager.client().motion();
    }
});

const seat_listener = util.createListener(c.wl_seat_listener, struct {
    pub fn capabilities(manager: *PointerManager, seat: ?*c.wl_seat, caps: u32) void {
        if ((caps & c.WL_SEAT_CAPABILITY_POINTER) != 0) {
            if (c.wl_seat_get_pointer(seat)) |new| {
                if (manager.pointer) |old| c.wl_pointer_destroy(old);
                manager.pointer = new;
                _ = c.wl_pointer_add_listener(new, &pointer_listener, manager);
            } else {
                std.log.warn("failed to obtain the pointer", .{});
            }
        }
        if ((caps & c.WL_SEAT_CAPABILITY_TOUCH) != 0) {
            if (c.wl_seat_get_touch(seat)) |new| {
                if (manager.touch) |old| c.wl_touch_destroy(old);
                manager.touch = new;
                _ = c.wl_touch_add_listener(new, &touch_listener, manager);
            } else {
                std.log.warn("failed to obtain the touch", .{});
            }
        }
    }
});

pub fn init(self: *PointerManager) void {
    _ = c.wl_seat_add_listener(self.client().seat, &seat_listener, self);
}

pub fn deinit(self: *PointerManager) void {
    if (self.pointer) |pointer| {
        c.wl_pointer_destroy(pointer);
    }
    if (self.touch) |touch| {
        c.wl_touch_destroy(touch);
    }
}

inline fn client(self: *PointerManager) *Client {
    return @fieldParentPtr(Client, "pointer_manager", self);
}
