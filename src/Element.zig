const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");

const Element = @This();

const Class = struct {
    destroy: fn (self: *Element) void,
    release: ?fn (self: *Element) void,
    render: ?fn (self: *Element, cr: *c.cairo_t) void,
};

fn makeClass(comptime T: type) Class {
    var result: Class = undefined;
    inline for (@typeInfo(Class).Struct.fields) |field| {
        if (@hasDecl(T, field.name)) {
            @field(result, field.name) = @field(T, field.name);
        } else {
            @field(result, field.name) = null;
        }
    }
    return result;
}

pub const Root = struct {
    const class = makeClass(struct {
        pub fn destroy(self: *Element) void {
            allocator.destroy(self);
        }

        pub fn render(self: *Element, cr: *c.cairo_t) void {
            c.cairo_set_source_rgb(cr, 0.75, 0.75, 0.75);
            c.cairo_rectangle(cr, 0, 0, @intToFloat(f64, self.width), @intToFloat(f64, self.height));
            c.cairo_fill(cr);

            c.cairo_set_source_rgb(cr, 1, 1, 1);
            c.cairo_move_to(cr, 0, 1.5);
            c.cairo_rel_line_to(cr, @intToFloat(f64, self.width), 0);
            c.cairo_stroke(cr);
        }
    });

    element: Element,

    pub fn init() !*Root {
        const self = try allocator.create(Root);
        self.element = .{ .class = &class };
        return self;
    }
};

fn renderButton(self: *Element, cr: *c.cairo_t) void {
    const left: f64 = 0.5;
    const right = left + @intToFloat(f64, self.width) - 1;
    const top: f64 = 0.5;
    const bottom = top + @intToFloat(f64, self.height) - 1;

    if (self.pressed_hover) {
        // inset button
        c.cairo_translate(cr, @intToFloat(f64, self.width), @intToFloat(f64, self.height));
        c.cairo_rotate(cr, std.math.pi);
    }

    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_move_to(cr, left, bottom);
    c.cairo_line_to(cr, left, top);
    c.cairo_line_to(cr, right, top);
    c.cairo_stroke(cr);

    c.cairo_set_source_rgb(cr, 0.5, 0.5, 0.5);
    c.cairo_move_to(cr, right - 1, top + 1);
    c.cairo_line_to(cr, right - 1, bottom - 1);
    c.cairo_line_to(cr, left + 1, bottom - 1);
    c.cairo_stroke(cr);

    c.cairo_set_source_rgb(cr, 0, 0, 0);
    c.cairo_move_to(cr, right, top);
    c.cairo_line_to(cr, right, bottom);
    c.cairo_line_to(cr, left, bottom);
    c.cairo_stroke(cr);
}

pub const WindowButton = struct {
    const class = makeClass(struct {
        inline fn unwrap(self: *Element) *WindowButton {
            return @fieldParentPtr(WindowButton, "node", self.getNode());
        }

        pub fn destroy(self: *Element) void {
            allocator.destroy(unwrap(self));
        }

        pub fn release(self: *Element) void {
            const window_button = unwrap(self);

            c.zwlr_foreign_toplevel_handle_v1_activate(
                window_button.handle,
                window_button.seat,
            );
        }

        pub const render = renderButton;
    });

    node: std.TailQueue(Element).Node,
    handle: *c.zwlr_foreign_toplevel_handle_v1,
    seat: *c.wl_seat,

    pub fn init(parent: *Element, handle: *c.zwlr_foreign_toplevel_handle_v1, seat: *c.wl_seat) !*WindowButton {
        const self = try allocator.create(WindowButton);
        self.node = .{ .data = .{ .parent = parent, .class = &class } };
        self.handle = handle;
        self.seat = seat;
        parent.children.append(&self.node);
        return self;
    }

    pub fn element(self: *WindowButton) *Element {
        return &self.node.data;
    }
};

pub const ShortcutButton = struct {
    const class = makeClass(struct {
        inline fn unwrap(self: *Element) *ShortcutButton {
            return @fieldParentPtr(ShortcutButton, "node", self.getNode());
        }

        fn setsid() std.os.pid_t {
            return @bitCast(std.os.pid_t, @truncate(u32, std.os.linux.syscall0(.setsid)));
        }

        pub fn destroy(self: *Element) void {
            allocator.destroy(unwrap(self));
        }

        pub fn release(self: *Element) void {
            const shortcut_button = unwrap(self);

            const child = std.os.fork() catch |err| {
                std.log.warn("shortcut: fork failed: {}", .{err});
                return;
            };

            if (child == 0) {
                // make us a session leader so we don't terminate if the taskbar closes
                if (setsid() < 0) {
                    std.log.warn("shortcut: setsid failed", .{});
                }

                const grandchild = std.os.fork() catch |err| {
                    std.log.warn("shortcut: fork failed: {}", .{err});
                    return;
                };

                if (grandchild == 0) {
                    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", shortcut_button.command, null };
                    const err = std.os.execveZ("/bin/sh", &argv, std.c.environ);
                    std.log.warn("shortcut: execv failed: {}", .{err});
                }

                std.os.exit(0);
            }

            _ = std.os.waitpid(child, 0);
        }

        pub const render = renderButton;
    });

    node: std.TailQueue(Element).Node,
    command: [*:0]const u8,

    pub fn init(parent: *Element, command: [*:0]const u8) !*ShortcutButton {
        const self = try allocator.create(ShortcutButton);
        self.node = .{ .data = .{ .parent = parent, .class = &class } };
        self.command = command;
        parent.children.append(&self.node);
        return self;
    }

    pub fn element(self: *ShortcutButton) *Element {
        return &self.node.data;
    }
};

pub const Text = struct {
    const class = makeClass(struct {
        inline fn unwrap(self: *Element) *Text {
            return @fieldParentPtr(Text, "node", self.getNode());
        }

        pub fn destroy(self: *Element) void {
            const text = unwrap(self);
            allocator.free(text.text);
            allocator.destroy(text);
        }

        pub fn render(self: *Element, cr: *c.cairo_t) void {
            const text = unwrap(self).text.ptr;
            c.cairo_set_source_rgb(cr, 0, 0, 0);

            var fe: c.cairo_font_extents_t = undefined;
            c.cairo_font_extents(cr, &fe);
            var te: c.cairo_text_extents_t = undefined;
            c.cairo_text_extents(cr, text, &te);

            c.cairo_rectangle(cr, 0, 0, @intToFloat(f64, self.width), fe.height);
            c.cairo_clip(cr);

            c.cairo_translate(cr, 0, fe.ascent);
            c.cairo_show_text(cr, text);
        }
    });

    node: std.TailQueue(Element).Node,
    text: [:0]const u8,

    pub fn init(parent: *Element, text: [:0]const u8) !*Text {
        const self = try allocator.create(Text);
        self.node = .{ .data = .{ .parent = parent, .class = &class } };
        self.text = text;
        parent.children.append(&self.node);
        return self;
    }

    pub fn element(self: *Text) *Element {
        return &self.node.data;
    }
};

pub const Image = struct {
    const class = makeClass(struct {
        inline fn unwrap(self: *Element) *Image {
            return @fieldParentPtr(Image, "node", self.getNode());
        }

        pub fn destroy(self: *Element) void {
            const image = unwrap(self);
            c.cairo_surface_destroy(image.surface);
            allocator.destroy(image);
        }

        pub fn render(self: *Element, cr: *c.cairo_t) void {
            const surface = unwrap(self).surface;
            const width = c.cairo_image_surface_get_width(surface);
            const height = c.cairo_image_surface_get_height(surface);
            const h_scale = @intToFloat(f64, self.width) / @intToFloat(f64, width);
            const v_scale = @intToFloat(f64, self.height) / @intToFloat(f64, height);
            c.cairo_scale(cr, h_scale, v_scale);
            c.cairo_set_source_surface(cr, surface, 0, 0);
            c.cairo_mask_surface(cr, surface, 0, 0);
            c.cairo_fill(cr);
        }
    });

    node: std.TailQueue(Element).Node,
    surface: *c.cairo_surface_t,

    pub fn init(parent: *Element, surface: *c.cairo_surface_t) !*Image {
        const self = try allocator.create(Image);
        self.node = .{ .data = .{ .parent = parent, .class = &class } };
        self.surface = surface;
        parent.children.append(&self.node);
        _ = c.cairo_surface_reference(surface);
        return self;
    }

    pub fn element(self: *Image) *Element {
        return &self.node.data;
    }
};

parent: ?*Element = null,
children: std.TailQueue(Element) = .{},

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,

class: *const Class,

pressed: bool = false,

pressed_hover: bool = false,

inline fn getNode(self: *Element) *std.TailQueue(Element).Node {
    return @fieldParentPtr(std.TailQueue(Element).Node, "data", self);
}

pub fn deinit(self: *Element) void {
    var it = self.children.first;
    while (it) |node| {
        it = node.next;
        node.data.deinit();
    }

    if (self.parent) |parent| {
        parent.children.remove(self.getNode());
    }
    self.class.destroy(self);
}

pub fn press(self: *Element, x: i32, y: i32) bool {
    if (x < 0 or x >= self.width) return false;
    if (y < 0 or y >= self.height) return false;

    if (self.class.release != null) {
        self.pressed = true;
        self.pressed_hover = true;
        return true;
    }

    var it = self.children.first;
    while (it) |node| {
        if (node.data.press(x - node.data.x, y - node.data.y)) {
            return true;
        }
        it = node.next;
    }

    return false;
}

pub fn motion(self: *Element, x: i32, y: i32) bool {
    if (self.pressed) {
        self.pressed_hover = x >= 0 and x < self.width and y >= 0 and y < self.height;
        return true;
    }

    var it = self.children.first;
    while (it) |node| {
        if (node.data.motion(x - node.data.x, y - node.data.y)) {
            return true;
        }
        it = node.next;
    }

    return false;
}

pub fn release(self: *Element) bool {
    if (self.pressed) {
        self.pressed = false;
        if (self.pressed_hover) {
            self.class.release.?(self);
            self.pressed_hover = false;
        }
        return true;
    }

    var it = self.children.first;
    while (it) |node| {
        if (node.data.release()) return true;
        it = node.next;
    }

    return false;
}

pub fn renderChild(self: *Element, cr: *c.cairo_t) void {
    if (self.class.render) |f| {
        c.cairo_save(cr);
        f(self, cr);
        c.cairo_restore(cr);
    }

    var it = self.children.first;
    while (it) |node| {
        c.cairo_save(cr);
        c.cairo_translate(cr, @intToFloat(f64, node.data.x), @intToFloat(f64, node.data.y));
        node.data.renderChild(cr);
        c.cairo_restore(cr);
        it = node.next;
    }
}

pub fn render(self: *Element, client: *Client) void {
    const surface = c.cairo_image_surface_create_for_data(
        client.buffer.?.memory.ptr,
        c.CAIRO_FORMAT_ARGB32,
        client.width,
        client.height,
        client.width * 4,
    ).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);

    c.cairo_select_font_face(
        cr,
        client.config.fontName(),
        c.CAIRO_FONT_SLANT_NORMAL,
        c.CAIRO_FONT_WEIGHT_NORMAL,
    );
    c.cairo_set_font_size(cr, @intToFloat(f64, client.config.font_size));
    c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_NONE);
    c.cairo_set_line_width(cr, 1);

    self.renderChild(cr);
}
