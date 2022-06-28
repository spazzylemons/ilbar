//! The interface to Wayland.

const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Config = @import("Config.zig");
const Element = @import("Element.zig");
const g = @import("glib_util.zig");
const Host = @import("SNI/Host.zig");
const Item = @import("SNI/Item.zig");
const IconManager = @import("IconManager.zig");
const StatusCommand = @import("StatusCommand.zig");
const std = @import("std");
const Toplevel = @import("Toplevel.zig");
const util = @import("util.zig");
const Watcher = @import("SNI/Watcher.zig");

const Client = @This();
/// The config settings
config: *const Config,
/// Seat provided by GDK
seat: ?*c.wl_seat = null,
/// When set to true, events stop being dispatched.
should_close: bool = false,
/// The current width of the surface.
width: i32 = 0,
/// The current height of the surface.
height: i32 = 0,
/// A list of toplevel info.
toplevel_list: Toplevel.List = .{},
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
/// The GTK application.
application: *c.GtkApplication,
/// THe GTK window.
window: ?*c.GtkWindow = null,
/// If true, the mouse is down.
mouse_down: bool = false,

const registry_listener = util.createListener(c.wl_registry_listener, struct {
    pub fn global(ptr: *?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: ?[*:0]const u8, version: u32) void {
        if (std.mem.eql(u8, std.mem.span(interface.?), "zwlr_foreign_toplevel_manager_v1")) {
            if (version >= 3) {
                ptr.* = c.wl_registry_bind(registry, name, &c.zwlr_foreign_toplevel_manager_v1_interface, version);
            } else {
                util.err(@src(), "foreign toplevel interface is too old", .{});
            }
        }
    }
});

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn init(display_name: ?[*:0]const u8, config: *const Config) !*Client {
    if (display_name) |name| {
        if (setenv("WAYLAND_DISPLAY", name, 1) != 0) return error.OutOfMemory;
    }

    var dummy_argc: c.gint = 1;
    var dummy_argv_value = [_:null]?[*:0]u8{std.os.argv[0]};
    var dummy_argv: [*c][*c]u8 = &dummy_argv_value;
    if (c.gtk_init_check(&dummy_argc, &dummy_argv) == 0) {
        return error.CannotOpenDisplay;
    }

    const application = c.gtk_application_new("spazzylemons.ilbar", c.G_APPLICATION_FLAGS_NONE).?;
    errdefer c.g_object_unref(application);

    const gdk_display = c.gdk_display_get_default() orelse
        return error.NoDefaultDisplay;

    const display = c.gdk_wayland_display_get_wl_display(gdk_display) orelse
        return error.NoWaylandDisplay;

    const toplevel_manager = blk: {
        var toplevel_manager: ?*c.zwlr_foreign_toplevel_manager_v1 = null;

        const registry = c.wl_display_get_registry(display) orelse
            return util.waylandError(@src());
        defer c.wl_registry_destroy(registry);

        _ = c.wl_registry_add_listener(registry, &registry_listener, &toplevel_manager);
        if (c.wl_display_roundtrip(display) < 0) {
            return util.waylandError(@src());
        }

        break :blk toplevel_manager orelse {
            util.err(@src(), "required toplevel manager interface is unavailable", .{});
            return error.MissingInterface;
        };
    };
    errdefer c.zwlr_foreign_toplevel_manager_v1_destroy(toplevel_manager);

    const icons = try IconManager.init();
    errdefer icons.deinit();

    const self = try allocator.create(Client);
    errdefer allocator.destroy(self);

    self.* = .{
        .config = config,
        .icons = icons,
        .application = application,
    };

    self.findSeat(gdk_display);

    self.toplevel_list.init(toplevel_manager);
    self.watcher.init();
    self.host.init();

    _ = g.signalConnect(self.application, "activate", g.callback(onActivate), self);
    _ = g.signalConnect(gdk_display, "seat-added", g.callback(onSeatAdded), self);
    _ = g.signalConnect(gdk_display, "seat-removed", g.callback(onSeatRemoved), self);

    return self;
}

pub fn deinit(self: *Client) void {
    self.status_command.deinit();
    self.host.deinit();
    self.watcher.deinit();
    self.icons.deinit();
    if (self.gui) |gui| gui.deinit();
    self.toplevel_list.deinit();
    c.g_object_unref(self.application);
    allocator.destroy(self);
}

pub fn run(self: *Client) !void {
    const app = g.cast(c.GApplication, self.application, c.g_application_get_type());

    const ctx = c.g_main_context_default();
    if (c.g_main_context_acquire(ctx) == 0) {
        return error.CannotAcquireContext;
    }
    defer c.g_main_context_release(ctx);

    var err: ?*c.GError = null;
    if (c.g_application_register(app, null, &err) == 0) {
        util.err(@src(), "failed to register application: {s}", .{err.?.message});
        c.g_error_free(err);
        return error.FailedToRegister;
    }

    c.g_application_activate(app);

    const status_source = try self.status_command.createSource();
    defer c.g_source_unref(status_source);

    _ = c.g_source_attach(status_source, ctx);
    defer c.g_source_destroy(status_source);

    while (!self.should_close) {
        _ = c.g_main_context_iteration(ctx, 1);
    }
}

fn findSeat(self: *Client, display: *c.GdkDisplay) void {
    const seats = c.gdk_display_list_seats(display);
    defer c.g_list_free(seats);
    var node = seats;
    while (node) |n| {
        const seat = @ptrCast(*c.GdkSeat, @alignCast(@alignOf(c.GdkSeat), n.*.data));
        if (c.gdk_wayland_seat_get_wl_seat(seat)) |s| {
            self.seat = s;
            return;
        }
    }
}

fn onSeatAdded(display: *c.GdkDisplay, seat: *c.GdkSeat, self: *Client) callconv(.C) void {
    _ = display;

    util.info(@src(), "seat added", .{});

    if (self.seat == null) {
        if (c.gdk_wayland_seat_get_wl_seat(seat)) |s| {
            self.seat = s;
        }
    }
}

fn onSeatRemoved(display: *c.GdkDisplay, seat: *c.GdkSeat, self: *Client) callconv(.C) void {
    if (c.gdk_wayland_seat_get_wl_seat(seat) == self.seat) {
        self.seat = null;
        self.findSeat(display);
    }
}

fn onActivate(app: *c.GtkApplication, self: *Client) callconv(.C) void {
    _ = app;
    const window = c.gtk_application_window_new(self.application);
    self.window = g.cast(c.GtkWindow, window, c.gtk_window_get_type());
    c.gtk_layer_init_for_window(self.window);
    c.gtk_layer_set_layer(self.window, c.GTK_LAYER_SHELL_LAYER_BOTTOM);
    c.gtk_layer_set_anchor(self.window, c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
    c.gtk_layer_set_anchor(self.window, c.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
    c.gtk_layer_set_anchor(self.window, c.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
    c.gtk_widget_set_size_request(window, 0, self.config.height);
    c.gtk_layer_auto_exclusive_zone_enable(self.window);
    c.gtk_widget_show_all(window);

    _ = g.signalConnect(self.window, "destroy", g.callback(onWindowDestroy), self);
    _ = g.signalConnect(self.window, "draw", g.callback(onDraw), self);
    _ = g.signalConnect(self.window, "configure-event", g.callback(onConfigure), self);
    _ = g.signalConnect(self.window, "button-press-event", g.callback(onButtonPress), self);
    _ = g.signalConnect(self.window, "button-release-event", g.callback(onButtonRelease), self);
    _ = g.signalConnect(self.window, "motion-notify-event", g.callback(onMotionNotify), self);

    const screen = c.gtk_window_get_screen(self.window);
    _ = g.signalConnect(screen, "size-changed", g.callback(onSizeChanged), self);
}

fn onWindowDestroy(widget: *c.GtkWidget, self: *Client) callconv(.C) void {
    _ = widget;

    c.g_object_unref(self.window);
    self.window = null;
    self.should_close = true;
}

fn onDraw(widget: *c.GtkWidget, cr: *c.cairo_t, self: *Client) callconv(.C) c.gboolean {
    _ = widget;

    if (self.gui) |gui| {
        gui.render(self, cr);
        return 1;
    }

    return 1;
}

fn onConfigure(widget: *c.GtkWidget, event: *const c.GdkEventConfigure, self: *Client) callconv(.C) c.gboolean {
    _ = widget;

    self.width = event.width;
    self.height = event.height;

    self.rerender();
    return 0;
}

fn onButtonPress(widget: *c.GtkWidget, event: *const c.GdkEventButton, self: *Client) callconv(.C) c.gboolean {
    _ = widget;

    if (event.button == 1) {
        if (self.gui) |gui| {
            if (!self.mouse_down) {
                _ = gui.press(@floatToInt(i32, event.x), @floatToInt(i32, event.y));
                self.rerender();
            }
        }
        self.mouse_down = true;
    }

    return 1;
}

fn onButtonRelease(widget: *c.GtkWidget, event: *const c.GdkEventButton, self: *Client) callconv(.C) c.gboolean {
    _ = widget;

    if (event.button == 1) {
        if (self.gui) |gui| {
            if (self.mouse_down) {
                _ = gui.release(event);
                self.rerender();
            }
        }
        self.mouse_down = false;
    }

    return 1;
}

fn onMotionNotify(widget: *c.GtkWidget, event: *const c.GdkEventMotion, self: *Client) callconv(.C) c.gboolean {
    _ = widget;

    if (self.gui) |gui| {
        if (self.mouse_down) {
            _ = gui.motion(@floatToInt(i32, event.x), @floatToInt(i32, event.y));
            self.rerender();
        }
    }

    return 1;
}

fn onSizeChanged(screen: *c.GdkScreen, self: *Client) callconv(.C) void {
    _ = screen;
    self.updateGui();
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

    var command_text_owned = true;

    const status_command_text = try allocator.dupeZ(u8, self.status_command.status);
    errdefer if (command_text_owned) allocator.free(status_command_text);
    const status_command_width = self.config.textWidth(status_command_text.ptr);

    const status_tray = try Element.StatusTray.init(&root.element);
    status_tray.element().width = status_command_width + 2 * self.config.margin + (self.config.icon_size + self.config.margin) * @intCast(i32, self.host.items.len);
    status_tray.element().height = self.config.height - 6;
    status_tray.element().x = self.width - self.config.margin - status_tray.element().width;
    status_tray.element().y = 4;

    const status_command = try Element.Text.init(status_tray.element(), status_command_text);
    command_text_owned = false;
    status_command.element().x = self.config.margin;
    status_command.element().y = @divTrunc((status_tray.element().height - self.config.font_height), 2);
    status_command.element().width = status_command_width;
    status_command.element().height = self.config.font_height;

    x = status_command.element().width + 2 * self.config.margin;
    var it2 = self.host.items.first;
    while (it2) |node| {
        const item = try Element.ItemClick.init(status_tray.element(), &node.data);
        item.element().x = x;
        item.element().y = @divTrunc(status_tray.element().height - self.config.icon_size, 2);
        item.element().width = self.config.icon_size;
        item.element().height = self.config.icon_size;
        if (node.data.surface) |surface| {
            const icon = try Element.Image.init(item.element(), surface);
            icon.element().width = self.config.icon_size;
            icon.element().height = self.config.icon_size;
        }
        x += self.config.icon_size + self.config.margin;
        it2 = node.next;
    }

    return &root.element;
}

pub fn updateGui(self: *Client) void {
    const new_gui = self.createGui() catch |err| blk: {
        util.err(@src(), "failed to create new GUI: {}", .{err});
        // since an update was required, the old gui may have invalid references and cannot be kept
        break :blk null;
    };
    if (self.gui) |gui| gui.deinit();
    self.gui = new_gui;
    self.rerender();
}

fn rerender(self: *Client) void {
    // force a redraw
    const widget = g.cast(c.GtkWidget, self.window, c.gtk_widget_get_type());
    c.gtk_widget_queue_draw_area(widget, 0, 0, self.width, self.height);
}
