//! The interface to Wayland.

const allocator = @import("main.zig").allocator;
const Buffer = @import("Buffer.zig");
const c = @import("c.zig");
const Config = @import("Config.zig");
const Element = @import("Element.zig");
const Host = @import("SNI/Host.zig");
const Item = @import("SNI/Item.zig");
const IconManager = @import("IconManager.zig");
const PointerManager = @import("PointerManager.zig");
const StatusCommand = @import("StatusCommand.zig");
const std = @import("std");
const Toplevel = @import("Toplevel.zig");
const util = @import("util.zig");
const Watcher = @import("SNI/Watcher.zig");

const Client = @This();
/// The config settings
config: *const Config,
/// Global display object
display: *c.wl_display,
/// Global shared memory object
shm: *c.wl_shm,
/// Global compositor object
compositor: *c.wl_compositor,
/// Global layer shell object
layer_shell: *c.zwlr_layer_shell_v1,
/// Global seat object
seat: *c.wl_seat,
/// Current Wayland surface object
wl_surface: *c.wl_surface,
/// Current layer surface object
layer_surface: *c.zwlr_layer_surface_v1,
/// The current pixel buffer, or bull if not currently allocated.
buffer: ?Buffer = null,
/// The currnt shm pool buffer, or bull if not currently allocated.
pool_buffer: ?*c.wl_buffer = null,
/// When set to true, events stop being dispatched.
should_close: bool = false,
/// The current width of the surface.
width: i32 = 0,
/// The current height of the surface.
height: i32 = 0,
/// A list of toplevel info.
toplevel_list: Toplevel.List = .{},
/// Pointer info.
pointer_manager: PointerManager = .{},
/// The GUI tree.
gui: ?*Element = null,
/// The icon manager.
icons: IconManager,
/// The taskbar SNI watcher.
watcher: Watcher = .{},
/// The taskbar SNI host.
host: Host = .{},
/// The status command handler.
status_command: StatusCommand = .{},

const InterfaceSpec = struct {
    /// The interface to bind to.
    interface: *const c.wl_interface,
    /// The minimum supported version.
    version: u32,
    /// The value of the interface.
    value: ?*anyopaque = null,
};

const InterfaceList = struct {
    specs: [5]InterfaceSpec,

    fn init() InterfaceList {
        return .{
            .specs = .{
                .{
                    .interface = &c.wl_shm_interface,
                    .version = 1,
                },
                .{
                    .interface = &c.wl_compositor_interface,
                    .version = 4,
                },
                .{
                    .interface = &c.zwlr_layer_shell_v1_interface,
                    .version = 4,
                },
                .{
                    .interface = &c.wl_seat_interface,
                    .version = 7,
                },
                .{
                    .interface = &c.zwlr_foreign_toplevel_manager_v1_interface,
                    .version = 3,
                },
            },
        };
    }

    fn deinit(self: InterfaceList) void {
        if (self.specs[0].value) |v|
            c.wl_shm_destroy(@ptrCast(*c.wl_shm, v));
        if (self.specs[1].value) |v|
            c.wl_compositor_destroy(@ptrCast(*c.wl_compositor, v));
        if (self.specs[2].value) |v|
            c.zwlr_layer_shell_v1_destroy(@ptrCast(*c.zwlr_layer_shell_v1, v));
        if (self.specs[3].value) |v|
            c.wl_seat_destroy(@ptrCast(*c.wl_seat, v));
        if (self.specs[4].value) |v|
            c.zwlr_foreign_toplevel_manager_v1_destroy(@ptrCast(*c.zwlr_foreign_toplevel_manager_v1, v));
    }
};

const registry_listener = util.createListener(c.wl_registry_listener, struct {
    pub fn global(specs: *InterfaceList, registry: ?*c.wl_registry, name: u32, interface: ?[*:0]const u8, version: u32) void {
        const interface_name = std.mem.span(interface.?);
        for (specs.specs) |*spec| {
            if (std.mem.eql(u8, interface_name, std.mem.span(spec.interface.name))) {
                if (version >= spec.version) {
                    spec.value = c.wl_registry_bind(registry, name, spec.interface, spec.version);
                } else {
                    util.err(@src(), "interface {s} is available, but too old", .{interface_name});
                }
                return;
            }
        }
    }
});

fn initInterfaces(display: *c.wl_display) !InterfaceList {
    var specs = InterfaceList.init();
    errdefer specs.deinit();

    const registry = c.wl_display_get_registry(display) orelse
        return util.waylandError(@src());
    defer c.wl_registry_destroy(registry);

    _ = c.wl_registry_add_listener(registry, &registry_listener, &specs);
    if (c.wl_display_roundtrip(display) < 0) {
        return util.waylandError(@src());
    }

    var bad_interfaces = false;
    for (specs.specs) |spec| {
        if (spec.value == null) {
            util.err(@src(), "interface {s} is unavailable or not new enough", .{spec.interface.name});
            bad_interfaces = true;
        }
    }
    if (bad_interfaces) {
        return error.MissingInterface;
    }
    return specs;
}

const surface_listener = util.createListener(c.zwlr_layer_surface_v1_listener, struct {
    pub fn configure(client: *Client, surface: ?*c.zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) void {
        if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return;

        c.zwlr_layer_surface_v1_ack_configure(surface, serial);
        if (width * height != client.width * client.height) {
            const new_buffer = Buffer.init(width, height) catch |err| {
                util.err(@src(), "failed to allocate pixel buffer: {}", .{err});
                return;
            };
            if (client.buffer) |old_buffer| old_buffer.deinit();
            client.buffer = new_buffer;
            client.width = @intCast(i32, width);
            client.height = @intCast(i32, height);
        }
        client.updateGui();
    }

    pub fn closed(client: *Client, surface: ?*c.zwlr_layer_surface_v1) void {
        if (surface == client.layer_surface) {
            util.info(@src(), "surface was closed, shutting down", .{});
            client.should_close = true;
        }
    }
});

pub fn init(display_name: ?[*:0]const u8, config: *const Config) !*Client {
    const display = c.wl_display_connect(display_name) orelse
        return util.waylandError(@src());
    errdefer c.wl_display_disconnect(display);

    const specs = try initInterfaces(display);

    const shm = @ptrCast(*c.wl_shm, specs.specs[0].value.?);
    errdefer c.wl_shm_destroy(shm);
    const compositor = @ptrCast(*c.wl_compositor, specs.specs[1].value.?);
    errdefer c.wl_compositor_destroy(compositor);
    const layer_shell = @ptrCast(*c.zwlr_layer_shell_v1, specs.specs[2].value.?);
    errdefer c.zwlr_layer_shell_v1_destroy(layer_shell);
    const seat = @ptrCast(*c.wl_seat, specs.specs[3].value.?);
    errdefer c.wl_seat_destroy(seat);
    const toplevel_manager = @ptrCast(*c.zwlr_foreign_toplevel_manager_v1, specs.specs[4].value.?);
    errdefer c.zwlr_foreign_toplevel_manager_v1_destroy(toplevel_manager);

    const wl_surface = c.wl_compositor_create_surface(compositor) orelse
        return util.waylandError(@src());
    errdefer c.wl_surface_destroy(wl_surface);

    const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
        layer_shell,
        wl_surface,
        null,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        "ilbar",
    ) orelse return util.waylandError(@src());
    errdefer c.zwlr_layer_surface_v1_destroy(layer_surface);

    c.zwlr_layer_surface_v1_set_anchor(
        layer_surface,
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
    );
    c.zwlr_layer_surface_v1_set_size(layer_surface, 0, @intCast(u32, config.height));
    c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, config.height);

    c.wl_surface_commit(wl_surface);

    const icons = try IconManager.init();
    errdefer icons.deinit();

    const self = try allocator.create(Client);
    errdefer allocator.destroy(self);

    self.* = .{
        .config = config,
        .display = display,
        .shm = shm,
        .compositor = compositor,
        .layer_shell = layer_shell,
        .seat = seat,
        .wl_surface = wl_surface,
        .layer_surface = layer_surface,
        .icons = icons,
    };

    self.toplevel_list.init(toplevel_manager);
    self.pointer_manager.init();
    _ = c.zwlr_layer_surface_v1_add_listener(layer_surface, &surface_listener, self);
    self.watcher.init();
    self.host.init();

    return self;
}

pub fn deinit(self: *Client) void {
    self.status_command.deinit();
    self.host.deinit();
    self.watcher.deinit();
    self.icons.deinit();
    if (self.gui) |gui| gui.deinit();
    self.pointer_manager.deinit();
    self.toplevel_list.deinit();
    if (self.pool_buffer) |pool_buffer| c.wl_buffer_destroy(pool_buffer);
    if (self.buffer) |buffer| buffer.deinit();
    c.wl_surface_destroy(self.wl_surface);
    c.wl_seat_destroy(self.seat);
    c.zwlr_layer_shell_v1_destroy(self.layer_shell);
    c.wl_compositor_destroy(self.compositor);
    c.wl_shm_destroy(self.shm);
    c.wl_display_disconnect(self.display);
    allocator.destroy(self);
}

const WaylandSource = struct {
    source: c.GSource,
    pfd: c.GPollFD,
    display: *c.wl_display,

    fn prepare(source: ?*c.GSource, timeout: ?*c.gint) callconv(.C) c.gboolean {
        const self = @fieldParentPtr(WaylandSource, "source", source.?);
        timeout.?.* = -1;
        _ = c.wl_display_flush(self.display);
        _ = c.wl_display_dispatch_pending(self.display);
        return 0;
    }

    fn check(source: ?*c.GSource) callconv(.C) c.gboolean {
        const self = @fieldParentPtr(WaylandSource, "source", source.?);
        return @boolToInt(self.pfd.revents != 0);
    }

    fn dispatch(source: ?*c.GSource, callback: c.GSourceFunc, user_data: c.gpointer) callconv(.C) c.gboolean {
        _ = callback;
        _ = user_data;

        const self = @fieldParentPtr(WaylandSource, "source", source.?);
        if ((self.pfd.revents & c.G_IO_IN) != 0) {
            _ = c.wl_display_dispatch(self.display);
        } else if ((self.pfd.revents & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            return 0;
        }
        self.pfd.revents = 0;
        return 1;
    }

    var funcs = c.GSourceFuncs{
        .prepare = prepare,
        .check = check,
        .dispatch = dispatch,
        .finalize = null,
        .closure_callback = null,
        .closure_marshal = null,
    };
};

pub fn run(self: *Client) !void {
    const ctx = c.g_main_context_default();

    const status_source = try self.status_command.createSource();
    defer c.g_source_unref(status_source);

    _ = c.g_source_attach(status_source, ctx);
    defer c.g_source_destroy(status_source);

    const source = c.g_source_new(&WaylandSource.funcs, @sizeOf(WaylandSource)).?;
    defer c.g_source_unref(source);

    const wayland_source = @fieldParentPtr(WaylandSource, "source", source);
    wayland_source.display = self.display;
    wayland_source.pfd.fd = c.wl_display_get_fd(self.display);
    wayland_source.pfd.events = c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP;
    wayland_source.pfd.revents = 0;
    _ = c.g_source_add_poll(source, &wayland_source.pfd);

    _ = c.g_source_attach(source, ctx);
    defer c.g_source_destroy(source);

    while (!self.should_close) {
        _ = c.g_main_context_iteration(ctx, 1);
    }
}

fn createShortcutButton(self: *Client, shortcut: *const Config.Shortcut, root: *Element, x: i32) !*Element {
    const button = try Element.ShortcutButton.init(root, shortcut.command.ptr);
    errdefer button.element().deinit();

    const text_width = self.config.textWidth(shortcut.text.ptr);
    var text_x = self.config.margin;

    button.element().x = x;
    button.element().y = 4;
    button.element().width = text_width + (2 * self.config.margin);
    button.element().height = self.config.height - 6;

    if (shortcut.icon) |icon_name| {
        const image = try self.icons.getFromIconName(self.config.icon_size, icon_name);
        defer c.cairo_surface_destroy(image);
        const icon = try Element.Image.init(button.element(), image);
        icon.element().x = self.config.margin;
        icon.element().y = @divTrunc(button.element().height - self.config.icon_size, 2);
        icon.element().width = self.config.icon_size;
        icon.element().height = self.config.icon_size;
        button.element().width += self.config.icon_size + self.config.margin;
        text_x += self.config.icon_size + self.config.margin;
    }
    const shortcut_text = try allocator.dupeZ(u8, shortcut.text);
    errdefer allocator.free(shortcut_text);
    const text = try Element.Text.init(button.element(), shortcut_text);
    text.element().x = text_x;
    text.element().y = @divTrunc((button.element().height - self.config.font_height), 2);
    text.element().width = text_width;
    text.element().height = self.config.font_height;

    return button.element();
}

fn createTaskbarButton(self: *Client, toplevel: *Toplevel, root: *Element, x: i32) !*Element {
    const button = try Element.WindowButton.init(root, toplevel.handle, self.seat);
    errdefer button.element().deinit();

    button.element().x = x;
    button.element().y = 4;
    button.element().width = self.config.width;
    button.element().height = self.config.height - 6;

    var text_x = self.config.margin;
    var text_width = self.config.width - (2 * self.config.margin);
    if (toplevel.app_id) |app_id| {
        if (try self.icons.getFromAppId(self.config.icon_size, app_id)) |image| {
            defer c.cairo_surface_destroy(image);
            const icon = try Element.Image.init(button.element(), image);
            icon.element().x = self.config.margin;
            icon.element().y = @divTrunc(button.element().height - self.config.icon_size, 2);
            icon.element().width = self.config.icon_size;
            icon.element().height = self.config.icon_size;
            text_x += self.config.icon_size + self.config.margin;
            text_width -= self.config.icon_size + self.config.margin;
        }
    }
    if (toplevel.title) |title| {
        const title_text = try allocator.dupeZ(u8, title);
        errdefer allocator.free(title_text);
        const text = try Element.Text.init(button.element(), title_text);
        text.element().x = text_x;
        text.element().y = @divTrunc((button.element().height - self.config.font_height), 2);
        text.element().width = text_width;
        text.element().height = self.config.font_height;
    }
    return button.element();
}

fn createGui(self: *Client) !*Element {
    const root = try Element.Root.init();
    errdefer root.element.deinit();
    root.element.width = self.width;
    root.element.height = self.height;
    var x: i32 = self.config.margin;

    for (self.config.shortcuts) |shortcut| {
        const el = try self.createShortcutButton(&shortcut, &root.element, x);
        x += el.width + self.config.margin;
    }

    var it = self.toplevel_list.list.first;
    while (it) |node| {
        const el = try self.createTaskbarButton(&node.data, &root.element, x);
        x += el.width + self.config.margin;
        it = node.next;
    }

    const status_command_text = try allocator.dupeZ(u8, self.status_command.status);
    errdefer allocator.free(status_command_text);
    const status_command_width = self.config.textWidth(status_command_text.ptr);

    const status_tray = try Element.StatusTray.init(&root.element);
    status_tray.element().width = status_command_width + 2 * self.config.margin + (self.config.icon_size + self.config.margin) * @intCast(i32, self.host.items.len);
    status_tray.element().height = self.config.height - 6;
    status_tray.element().x = self.width - self.config.margin - status_tray.element().width;
    status_tray.element().y = 4;

    const status_command = try Element.Text.init(status_tray.element(), status_command_text);
    status_command.element().x = self.config.margin;
    status_command.element().y = @divTrunc((status_tray.element().height - self.config.font_height), 2);
    status_command.element().width = status_command_width;
    status_command.element().height = self.config.font_height;

    x = status_command.element().width + 2 * self.config.margin;
    var it2 = self.host.items.first;
    while (it2) |node| {
        if (node.data.surface) |surface| {
            const icon = try Element.Image.init(status_tray.element(), surface);
            icon.element().x = x;
            icon.element().y = @divTrunc(status_tray.element().height - self.config.icon_size, 2);
            icon.element().width = self.config.icon_size;
            icon.element().height = self.config.icon_size;
        }
        x += self.config.icon_size + self.config.margin;
        it2 = node.next;
    }

    return &root.element;
}

pub fn updateGui(self: *Client) void {
    const new_gui = self.createGui() catch |err| {
        util.err(@src(), "failed to create new GUI: {}", .{err});
        return;
    };
    if (self.gui) |gui| gui.deinit();
    self.gui = new_gui;
    self.rerender();
}

pub fn press(self: *Client) void {
    if (self.gui) |gui| {
        if (!self.pointer_manager.down) {
            _ = gui.press(self.pointer_manager.x, self.pointer_manager.y);
            self.rerender();
        }
    }
    self.pointer_manager.down = true;
}

pub fn motion(self: *Client) void {
    if (self.gui) |gui| {
        if (self.pointer_manager.down) {
            _ = gui.motion(self.pointer_manager.x, self.pointer_manager.y);
            self.rerender();
        }
    }
}

pub fn release(self: *Client) void {
    if (self.gui) |gui| {
        if (self.pointer_manager.down) {
            _ = gui.release();
            self.rerender();
        }
    }
    self.pointer_manager.down = false;
}

const buffer_listener = util.createListener(c.wl_buffer_listener, struct {
    pub fn release(client: *Client, buffer: ?*c.wl_buffer) void {
        if (buffer == client.pool_buffer) {
            c.wl_buffer_destroy(buffer);
            client.pool_buffer = client.refreshPoolBuffer() catch |err| {
                util.err(@src(), "failed to refresh pool buffer: {}", .{err});
                client.pool_buffer = null;
                return;
            };
        }
    }
});

fn refreshPoolBuffer(self: *Client) !*c.wl_buffer {
    const size = self.width * self.height * 4;
    const pool = c.wl_shm_create_pool(self.shm, self.buffer.?.file.handle, size) orelse
        return util.waylandError(@src());
    defer c.wl_shm_pool_destroy(pool);
    const format: u32 = switch (@import("builtin").target.cpu.arch.endian()) {
        .Big => c.WL_SHM_FORMAT_BGRX8888,
        .Little => c.WL_SHM_FORMAT_XRGB8888,
    };
    const pool_buffer = c.wl_shm_pool_create_buffer(pool, 0, self.width, self.height, self.width * 4, format) orelse
        return util.waylandError(@src());
    _ = c.wl_buffer_add_listener(pool_buffer, &buffer_listener, self);
    return pool_buffer;
}

fn rerender(self: *Client) void {
    if (self.buffer != null and self.gui != null) {
        if (self.pool_buffer == null) {
            self.pool_buffer = self.refreshPoolBuffer() catch |err| {
                util.err(@src(), "failed to create pool buffer: {}", .{err});
                return;
            };
        }
        self.gui.?.render(self);
        c.wl_surface_attach(self.wl_surface, self.pool_buffer.?, 0, 0);
        c.wl_surface_commit(self.wl_surface);
        c.wl_surface_damage(self.wl_surface, 0, 0, self.width, self.height);
    }
}
