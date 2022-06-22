const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");

const PointerManager = @This();

pointer: ?*c.wl_pointer = null,
touch: ?*c.wl_touch = null,

x: c_int = 0,
y: c_int = 0,
down: bool = false,

fn onPointerEnter(
    data: ?*anyopaque,
    ptr: ?*c.wl_pointer,
    serial: u32,
    surface: ?*c.wl_surface,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.C) void {
    _ = ptr;
    _ = serial;
    _ = surface;
    const manager = unwrap(data);
    manager.x = c.wl_fixed_to_int(x);
    manager.y = c.wl_fixed_to_int(y);
    manager.client().motion();
}

fn onPointerLeave(
    data: ?*anyopaque,
    ptr: ?*c.wl_pointer,
    serial: u32,
    surface: ?*c.wl_surface,
) callconv(.C) void {
    _ = data;
    _ = ptr;
    _ = serial;
    _ = surface;
}

fn onPointerMotion(
    data: ?*anyopaque,
    ptr: ?*c.wl_pointer,
    time: u32,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.C) void {
    _ = ptr;
    _ = time;
    const manager = unwrap(data);
    manager.x = c.wl_fixed_to_int(x);
    manager.y = c.wl_fixed_to_int(y);
    manager.client().motion();
}

fn onPointerButton(
    data: ?*anyopaque,
    ptr: ?*c.wl_pointer,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.C) void {
    _ = ptr;
    _ = serial;
    _ = time;
    const manager = unwrap(data);
    if (button == c.BTN_LEFT) {
        if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            manager.client().press();
        } else {
            manager.client().release();
        }
    }
}

fn onPointerAxis(
    data: ?*anyopaque,
    ptr: ?*c.wl_pointer,
    time: u32,
    axis: u32,
    value: c.wl_fixed_t,
) callconv(.C) void {
    _ = data;
    _ = ptr;
    _ = time;
    _ = axis;
    _ = value;
}

fn onPointerFrame(data: ?*anyopaque, ptr: ?*c.wl_pointer) callconv(.C) void {
    _ = data;
    _ = ptr;
}

fn onPointerAxisSource(data: ?*anyopaque, ptr: ?*c.wl_pointer, src: u32) callconv(.C) void {
    _ = data;
    _ = ptr;
    _ = src;
}

fn onPointerAxisStop(
    data: ?*anyopaque,
    ptr: ?*c.wl_pointer,
    time: u32,
    axis: u32,
) callconv(.C) void {
    _ = data;
    _ = ptr;
    _ = time;
    _ = axis;
}

fn onPointerAxisDiscrete(
    data: ?*anyopaque,
    ptr: ?*c.wl_pointer,
    axis: u32,
    discrete: i32,
) callconv(.C) void {
    _ = data;
    _ = ptr;
    _ = axis;
    _ = discrete;
}

const pointer_listener = c.wl_pointer_listener{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
    .frame = onPointerFrame,
    .axis_source = onPointerAxisSource,
    .axis_stop = onPointerAxisStop,
    .axis_discrete = onPointerAxisDiscrete,
};

fn onTouchDown(
    data: ?*anyopaque,
    touch: ?*c.wl_touch,
    serial: u32,
    time: u32,
    surface: ?*c.wl_surface,
    id: i32,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.C) void {
    _ = touch;
    _ = serial;
    _ = time;
    _ = surface;
    _ = id;
    const manager = unwrap(data);
    manager.x = c.wl_fixed_to_int(x);
    manager.y = c.wl_fixed_to_int(y);
    manager.client().press();
}

fn onTouchUp(
    data: ?*anyopaque,
    touch: ?*c.wl_touch,
    serial: u32,
    time: u32,
    id: i32,
) callconv(.C) void {
    _ = touch;
    _ = serial;
    _ = time;
    _ = id;
    const manager = unwrap(data);
    manager.client().release();
}

fn onTouchMotion(
    data: ?*anyopaque,
    touch: ?*c.wl_touch,
    time: u32,
    id: i32,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.C) void {
    _ = touch;
    _ = time;
    _ = id;
    const manager = unwrap(data);
    manager.x = c.wl_fixed_to_int(x);
    manager.y = c.wl_fixed_to_int(y);
    manager.client().motion();
}

fn onTouchFrameOrCancel(data: ?*anyopaque, touch: ?*c.wl_touch) callconv(.C) void {
    _ = data;
    _ = touch;
}

fn onTouchShape(
    data: ?*anyopaque,
    touch: ?*c.wl_touch,
    id: i32,
    major: c.wl_fixed_t,
    minor: c.wl_fixed_t,
) callconv(.C) void {
    _ = data;
    _ = touch;
    _ = id;
    _ = major;
    _ = minor;
}

fn onTouchOrientation(
    data: ?*anyopaque,
    touch: ?*c.wl_touch,
    id: i32,
    orientation: c.wl_fixed_t,
) callconv(.C) void {
    _ = data;
    _ = touch;
    _ = id;
    _ = orientation;
}

const touch_listener = c.wl_touch_listener{
    .down = onTouchDown,
    .up = onTouchUp,
    .motion = onTouchMotion,
    .frame = onTouchFrameOrCancel,
    .cancel = onTouchFrameOrCancel,
    .shape = onTouchShape,
    .orientation = onTouchOrientation,
};

inline fn unwrap(data: ?*anyopaque) *PointerManager {
    return @ptrCast(*PointerManager, @alignCast(@alignOf(PointerManager), data.?));
}

fn onCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.C) void {
    const manager = unwrap(data);
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

fn onName(data: ?*anyopaque, seat: ?*c.wl_seat, name: ?[*:0]const u8) callconv(.C) void {
    _ = data;
    _ = seat;
    _ = name;
}

const seat_listener = c.wl_seat_listener{
    .capabilities = onCapabilities,
    .name = onName,
};

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
