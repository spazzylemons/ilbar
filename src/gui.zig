const allocator = @import("main.zig").allocator;
const c = @import("c.zig");
const std = @import("std");

fn rootRender(self: ?*c.Element, cr: ?*c.cairo_t) callconv(.C) void {
    c.cairo_set_source_rgb(cr, 0.75, 0.75, 0.75);
    c.cairo_rectangle(cr, 0, 0, @intToFloat(f64, self.?.width), @intToFloat(f64, self.?.height));
    c.cairo_fill(cr);

    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_move_to(cr, 0, 1.5);
    c.cairo_rel_line_to(cr, @intToFloat(f64, self.?.width), 0);
    c.cairo_stroke(cr);
}

const root_class = c.ElementClass{
    .clickable = false,
    .free_data = null,
    .release = null,
    .render = rootRender,
};

fn windowButtonRelease(self: ?*c.Element) callconv(.C) void {
    c.zwlr_foreign_toplevel_handle_v1_activate(
        self.?.unnamed_0.unnamed_0.handle,
        self.?.unnamed_0.unnamed_0.seat,
    );
}

fn windowButtonRender(self: ?*c.Element, cr: ?*c.cairo_t) callconv(.C) void {
    const left: f64 = 0.5;
    const right = left + @intToFloat(f64, self.?.width) - 1;
    const top: f64 = 0.5;
    const bottom = top + @intToFloat(f64, self.?.height) - 1;

    if (self.?.pressed_hover) {
        // inset button
        c.cairo_translate(cr, @intToFloat(f64, self.?.width), @intToFloat(f64, self.?.height));
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

pub export var WindowButton = c.ElementClass{
    .clickable = true,
    .free_data = null,
    .release = windowButtonRelease,
    .render = windowButtonRender,
};

fn textFree(self: ?*c.Element) callconv(.C) void {
    std.c.free(self.?.unnamed_0.text);
}

fn textRender(self: ?*c.Element, cr: ?*c.cairo_t) callconv(.C) void {
    if (self.?.unnamed_0.text) |text| {
        c.cairo_set_source_rgb(cr, 0, 0, 0);

        var fe: c.cairo_font_extents_t = undefined;
        c.cairo_font_extents(cr, &fe);
        var te: c.cairo_text_extents_t = undefined;
        c.cairo_text_extents(cr, text, &te);

        c.cairo_rectangle(cr, 0, 0, @intToFloat(f64, self.?.width), fe.height);
        c.cairo_clip(cr);

        c.cairo_translate(cr, 0, fe.ascent);
        c.cairo_show_text(cr, text);
    }
}

pub export var Text = c.ElementClass{
    .clickable = false,
    .free_data = textFree,
    .release = null,
    .render = textRender,
};

fn imageFree(self: ?*c.Element) callconv(.C) void {
    if (self.?.unnamed_0.image) |img| {
        c.cairo_surface_destroy(img);
    }
}

fn imageRender(self: ?*c.Element, cr: ?*c.cairo_t) callconv(.C) void {
    if (self.?.unnamed_0.image) |img| {
        c.cairo_set_source_surface(cr, img, 0, 0);
        c.cairo_mask_surface(cr, img, 0, 0);
        c.cairo_fill(cr);
    }
}

pub export var Image = c.ElementClass{
    .clickable = false,
    .free_data = imageFree,
    .release = null,
    .render = imageRender,
};

fn allocElement() !*c.Element {
    const element = try allocator.create(c.Element);
    @memset(@ptrCast([*]u8, element), 0, @sizeOf(c.Element));
    return element;
}

export fn element_init_root() ?*c.Element {
    const element = allocElement() catch return null;
    c.wl_list_init(&element.link);
    c.wl_list_init(&element.children);
    element.class = &root_class;
    return element;
}

export fn element_init_child(parent: *c.Element, class: *c.ElementClass) ?*c.Element {
    const element = allocElement() catch return null;
    c.wl_list_insert(&parent.children, &element.link);
    c.wl_list_init(&element.children);
    element.class = class;
    return element;
}

export fn element_destroy(element: *c.Element) void {
    if (element.class.*.free_data) |f| {
        f(element);
    }

    var child = @fieldParentPtr(c.Element, "link", element.children.next.?);
    var tmp = @fieldParentPtr(c.Element, "link", child.link.next.?);
    while (&child.link != &element.children) {
        element_destroy(child);
        child = tmp;
        tmp = @fieldParentPtr(c.Element, "link", child.link.next.?);
    }

    c.wl_list_remove(&element.link);
    allocator.destroy(element);
}

export fn element_press(element: *c.Element, x: c_int, y: c_int) bool {
    if (x < 0 or x >= element.width) return false;
    if (y < 0 or y >= element.height) return false;

    if (element.class.*.clickable) {
        element.pressed = true;
        element.pressed_hover = true;
        return true;
    }

    var child = @fieldParentPtr(c.Element, "link", element.children.next.?);
    while (&child.link != &element.children) {
        if (element_press(child, x - child.x, y - child.y)) {
            return true;
        }
        child = @fieldParentPtr(c.Element, "link", child.link.next.?);
    }

    return false;
}

export fn element_motion(element: *c.Element, x: c_int, y: c_int) bool {
    if (element.pressed) {
        element.pressed_hover =
            x >= 0 and x < element.width and y >= 0 and y < element.height;
        return true;
    }

    var child = @fieldParentPtr(c.Element, "link", element.children.next.?);
    while (&child.link != &element.children) {
        if (element_motion(child, x - child.x, y - child.y)) {
            return true;
        }
        child = @fieldParentPtr(c.Element, "link", child.link.next.?);
    }

    return false;
}

export fn element_release(element: *c.Element) bool {
    if (element.pressed) {
        element.pressed = false;
        if (element.pressed_hover) {
            if (element.class.*.release) |f| {
                f(element);
            }
        }
        element.pressed_hover = false;
        return true;
    }

    var child = @fieldParentPtr(c.Element, "link", element.children.next.?);
    while (&child.link != &element.children) {
        if (element_release(child)) {
            return true;
        }
        child = @fieldParentPtr(c.Element, "link", child.link.next.?);
    }

    return false;
}

export fn element_render(element: *c.Element, cr: *c.cairo_t) void {
    if (element.class.*.render) |f| {
        c.cairo_save(cr);
        f(element, cr);
        c.cairo_restore(cr);
    }

    var child = @fieldParentPtr(c.Element, "link", element.children.next.?);
    while (&child.link != &element.children) {
        c.cairo_save(cr);
        c.cairo_translate(cr, @intToFloat(f64, child.x), @intToFloat(f64, child.y));
        element_render(child, cr);
        c.cairo_restore(cr);
        child = @fieldParentPtr(c.Element, "link", child.link.next.?);
    }
}
