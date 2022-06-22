const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Element = @import("Element.zig");
const IconManager = @import("IconManager.zig");
const PointerManager = @import("PointerManager.zig");
const std = @import("std");
const Toplevel = @import("Toplevel.zig");

extern fn strerror(errnum: c_int) [*:0]u8;
extern fn icons_deinit(icons: *c.IconManager) void;
extern fn toplevel_list_init(client: *c.Client) ?*c.ToplevelList;
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

    allocator.destroy(self);
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

var shm_counter: u8 = 0;

fn allocShm(client: *c.Client, size: usize) !std.os.fd_t {
    const pid = std.os.linux.getpid();
    const name = try std.fmt.allocPrintZ(allocator, "/ilbar-shm-{}-{x}-{}", .{
        pid,
        @ptrToInt(client),
        shm_counter,
    });
    std.log.info("opening new shm file: {s}", .{name});
    defer allocator.free(name);
    shm_counter += 1;

    const fd = std.c.shm_open(name, std.os.O.RDWR | std.os.O.CREAT | std.os.O.EXCL, 0o600);
    if (fd < 0) return error.ShmError;
    errdefer std.os.close(fd);
    _ = std.c.shm_unlink(name);

    if (std.c.ftruncate(fd, @intCast(std.c.off_t, size)) < 0) {
        return error.ShmError;
    }

    return fd;
}

fn updateShm(client: *c.Client, width: u32, height: u32) !void {
    const new_size = try std.math.mul(u32, try std.math.mul(u32, width, height), 4);
    const old_size = client.width * client.height * 4;
    if (old_size == new_size) return;
    const fd = try allocShm(client, new_size);
    errdefer std.os.close(fd);
    const buffer = try std.os.mmap(
        null,
        new_size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.SHARED,
        fd,
        0,
    );
    if (client.buffer) |b| {
        std.os.munmap(@alignCast(4096, b)[0..old_size]);
    }
    client.buffer = buffer.ptr;
    if (client.buffer_fd >= 0) {
        std.os.close(client.buffer_fd);
    }
    client.buffer_fd = fd;
    client.width = width;
    client.height = height;
}

fn onConfigure(
    data: ?*anyopaque,
    surface: ?*c.zwlr_layer_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.C) void {
    const client = @ptrCast(*c.Client, @alignCast(@alignOf(c.Client), data.?));
    c.zwlr_layer_surface_v1_ack_configure(surface, serial);
    updateShm(client, width, height) catch {};
    update_gui(client);
}

fn onClosed(data: ?*anyopaque, surface: ?*c.zwlr_layer_surface_v1) callconv(.C) void {
    const client = @ptrCast(*c.Client, @alignCast(@alignOf(c.Client), data.?));
    if (surface == client.layer_surface) {
        std.log.info("surface was closed, shutting down", .{});
        client.should_close = true;
    }
}

const surface_listener = c.zwlr_layer_surface_v1_listener{
    .configure = onConfigure,
    .closed = onClosed,
};

/// Specification for loading an interface from the registry.
const InterfaceSpec = struct {
    /// The interface to bind to.
    interface: *const c.wl_interface,
    /// The minimum supported version.
    version: u32,
    /// The location to store the interface.
    offset: usize,

    pub inline fn get(self: InterfaceSpec, client: *c.Client) *?*anyopaque {
        return @intToPtr(*?*anyopaque, @ptrToInt(client) + self.offset);
    }
};

var initialized_specs = false;
var specs: [5]InterfaceSpec = undefined;

fn initSpecs() void {
    if (initialized_specs) return;
    specs = .{
        .{
            .interface = &c.wl_shm_interface,
            .version = 1,
            .offset = @offsetOf(c.Client, "shm"),
        },
        .{
            .interface = &c.wl_compositor_interface,
            .version = 4,
            .offset = @offsetOf(c.Client, "compositor"),
        },
        .{
            .interface = &c.zwlr_layer_shell_v1_interface,
            .version = 4,
            .offset = @offsetOf(c.Client, "layer_shell"),
        },
        .{
            .interface = &c.wl_seat_interface,
            .version = 7,
            .offset = @offsetOf(c.Client, "seat"),
        },
        .{
            .interface = &c.zwlr_foreign_toplevel_manager_v1_interface,
            .version = 3,
            .offset = @offsetOf(c.Client, "toplevel_manager"),
        },
    };
    initialized_specs = true;
}

fn onRegistryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32
) callconv(.C) void {
    const interface_name = std.mem.span(interface.?);
    const client = @ptrCast(*c.Client, @alignCast(@alignOf(c.Client), data.?));
    for (specs) |spec| {
        if (std.mem.eql(u8, interface_name, std.mem.span(spec.interface.name))) {
            if (version >= spec.version) {
                spec.get(client).* = c.wl_registry_bind(registry, name, spec.interface, spec.version);
            } else {
                std.log.err("interface {s} is available, but too old", .{interface_name});
            }
            return;
        }
    }
}

fn onRegistryGlobalRemove(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
) callconv(.C) void {
    _ = data;
    _ = registry;
    _ = name;
}

const registry_listener = c.wl_registry_listener{
    .global = onRegistryGlobal,
    .global_remove = onRegistryGlobalRemove,
};

fn clientInit(display: ?[*:0]const u8, config: *c.Config) !*c.Client {
    initSpecs();

    const self = try allocator.create(c.Client);
    errdefer client_deinit(self);
    @memset(@ptrCast([*]u8, self), 0, @sizeOf(c.Client));
    self.config = config;
    self.buffer_fd = -1;

    self.display = c.wl_display_connect(display) orelse {
        std.log.err("failed to open the wayland display", .{});
        return error.WaylandError;
    };
    const display_name = display orelse @as(?[*:0]const u8, std.c.getenv("WAYLAND_DISPLAY"));
    std.log.info("connected to display {s}", .{display_name});

    {
        const registry = c.wl_display_get_registry(self.display) orelse {
            std.log.err("failed to get the Wayland registry", .{});
            return error.WaylandError;
        };
        defer c.wl_registry_destroy(registry);

        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        if (c.wl_display_roundtrip(self.display) < 0) {
            std.log.err("failed to perform roundtrip", .{});
            return error.WaylandError;
        }

        var bad_interfaces = false;
        for (specs) |spec| {
            if (spec.get(self).* == null) {
                std.log.err("interface {s} is unavailable or not new enough", .{spec.interface.name});
                bad_interfaces = true;
            }
        }
        if (bad_interfaces) {
            return error.WaylandError;
        }
    }

    self.wl_surface = c.wl_compositor_create_surface(self.compositor) orelse {
        std.log.err("failed to create Wayland surface", .{});
        return error.WaylandError;
    };

    self.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
        self.layer_shell,
        self.wl_surface,
        null,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        "ilbar",
    ) orelse {
        std.log.err("failed to create layer surface", .{});
        return error.WaylandError;
    };

    self.toplevel_list = toplevel_list_init(self) orelse {
        std.log.err("failed to create toplevel list", .{});
        return error.Oops;
    };

    _ = c.zwlr_layer_surface_v1_add_listener(self.layer_surface, &surface_listener, self);

    // anchor to all but top
    c.zwlr_layer_surface_v1_set_anchor(self.layer_surface,
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
    );
    c.zwlr_layer_surface_v1_set_size(self.layer_surface, 0, @intCast(u32, config.height));
    c.zwlr_layer_surface_v1_set_exclusive_zone(self.layer_surface, @intCast(i32, config.height));

    c.wl_surface_commit(self.wl_surface);

    self.icons = c.icons_init() orelse {
        std.log.err("failed to create icon manager", .{});
        return error.Oops;
    };

    const pm = try PointerManager.init(self);
    self.pointer_manager = @ptrCast(*c.PointerManager, pm);

    return self;
}

export fn client_init(display: ?[*:0]const u8, config: *c.Config) ?*c.Client {
    return clientInit(display, config) catch null;
}
