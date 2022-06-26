const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const Client = @import("Client.zig");
const std = @import("std");

const Element = @This();

const Class = struct {
    freeData: ?fn (self: *Element) void = null,
    release: ?fn (self: *Element) void = null,
    render: ?fn (self: *Element, cr: *c.cairo_t) void = null,
};

fn makeClass(comptime T: type) Class {
    var result = Class{};
    inline for (@typeInfo(T).Struct.decls) |field| {
        @field(result, field.name) = @field(T, field.name);
    }
    return result;
}

const root_class = makeClass(struct {
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

pub const window_button_class = makeClass(struct {
    pub fn release(self: *Element) void {
        c.zwlr_foreign_toplevel_handle_v1_activate(
            self.data.window_button.handle,
            self.data.window_button.seat,
        );
    }

    pub const render = renderButton;
});

fn setsid() std.os.pid_t {
    return @bitCast(std.os.pid_t, @truncate(u32, std.os.linux.syscall0(.setsid)));
}

pub const shortcut_button_class = makeClass(struct {
    pub fn release(self: *Element) void {
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
                const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", self.data.command, null };
                const err = std.os.execveZ("/bin/sh", &argv, std.c.environ);
                std.log.warn("shortcut: execv failed: {}", .{err});
            }

            std.os.exit(0);
        }

        _ = std.os.waitpid(child, 0);
    }

    pub const render = renderButton;
});

pub const text_class = makeClass(struct {
    pub fn freeData(self: *Element) void {
        if (self.data.text) |text| {
            allocator.free(text);
        }
    }

    pub fn render(self: *Element, cr: *c.cairo_t) void {
        if (self.data.text) |text| {
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
    }
});

pub const image_class = makeClass(struct {
    pub fn freeData(self: *Element) void {
        if (self.data.image) |image| {
            c.cairo_surface_destroy(image);
        }
    }

    pub fn render(self: *Element, cr: *c.cairo_t) void {
        if (self.data.image) |image| {
            const width = c.cairo_image_surface_get_width(image);
            const height = c.cairo_image_surface_get_height(image);
            const h_scale = @intToFloat(f64, self.width) / @intToFloat(f64, width);
            const v_scale = @intToFloat(f64, self.height) / @intToFloat(f64, height);
            c.cairo_scale(cr, h_scale, v_scale);
            c.cairo_set_source_surface(cr, image, 0, 0);
            c.cairo_mask_surface(cr, image, 0, 0);
            c.cairo_fill(cr);
        }
    }
});

parent: ?*Element = null,
node: *std.TailQueue(Element).Node,
children: std.TailQueue(Element) = .{},

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,

class: *const Class,

data: union {
    text: ?[:0]const u8,
    window_button: struct {
        handle: *c.zwlr_foreign_toplevel_handle_v1,
        seat: *c.wl_seat,
    },
    image: ?*c.cairo_surface_t,
    command: [*:0]const u8,
} = undefined,

pressed: bool = false,

pressed_hover: bool = false,

pub fn init() !*Element {
    const node = try allocator.create(std.TailQueue(Element).Node);
    node.* = .{
        .data = .{
            .node = node,
            .class = &root_class,
        },
    };
    return &node.data;
}

pub fn initChild(parent: *Element, class: *const Class) !*Element {
    const node = try allocator.create(std.TailQueue(Element).Node);
    node.* = .{
        .data = .{
            .parent = parent,
            .node = node,
            .class = class,
        },
    };
    parent.children.append(node);
    return &node.data;
}

pub fn deinit(self: *Element) void {
    if (self.class.freeData) |f| f(self);

    var it = self.children.first;
    while (it) |node| {
        it = node.next;
        node.data.deinit();
    }

    if (self.parent) |parent| {
        parent.children.remove(self.node);
    }
    allocator.destroy(self.node);
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
