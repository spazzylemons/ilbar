#include "client.h"
#include "gui.h"

#include <log.h>
#include <stdlib.h>
#include <string.h>
#include <wlr-foreign-toplevel-management-unstable-v1-protocol.h>

#define TEXT_SIZE 11

static void root_render(Element *self, cairo_t *cr) {
    cairo_set_source_rgb(cr, 0.75, 0.75, 0.75);
    cairo_rectangle(cr, 0.0, 0.0, self->width, self->height);
    cairo_fill(cr);

    cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    cairo_move_to(cr, 0.0, 1.5);
    cairo_rel_line_to(cr, self->width, 0.0);
    cairo_stroke(cr);
}

static const ElementClass Root = {
    .free_data = NULL,
    .click = NULL,
    .render = root_render,
};

static void window_button_click(Element *self) {
    zwlr_foreign_toplevel_handle_v1_activate(self->handle, self->seat);
}

static void window_button_render(Element *self, cairo_t *cr) {
    double left = -0.5, right = left + self->width;
    double top = -0.5, bottom = top + self->height;

    cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    cairo_move_to(cr, left, bottom - 1.0);
    cairo_line_to(cr, left, top);
    cairo_line_to(cr, right - 1.0, top);
    cairo_stroke(cr);

    cairo_set_source_rgb(cr, 0.5, 0.5, 0.5);
    cairo_move_to(cr, right - 1.0, top + 1.0);
    cairo_line_to(cr, right - 1.0, bottom - 1.0);
    cairo_line_to(cr, left + 1.0, bottom - 1.0);
    cairo_stroke(cr);

    cairo_set_source_rgb(cr, 0.0, 0.0, 0.0);
    cairo_move_to(cr, right, top);
    cairo_line_to(cr, right, bottom);
    cairo_line_to(cr, left, bottom);
    cairo_stroke(cr);
}

const ElementClass WindowButton = {
    .free_data = NULL,
    .click = window_button_click,
    .render = window_button_render,
};

static void text_free(Element *self) {
    free(self->text);
}

static void text_render(Element *self, cairo_t *cr) {
    const char *text = self->text;
    if (text == NULL) text = "(null)";

    cairo_set_source_rgb(cr, 0.0, 0.0, 0.0);

    cairo_font_extents_t fe;
    cairo_font_extents(cr, &fe);
    cairo_text_extents_t te;
    cairo_text_extents(cr, text, &te);

    cairo_rectangle(cr, 0.0, 0.0, self->width, fe.height);
    cairo_clip(cr);

    cairo_translate(cr, 0.0, fe.ascent);
    cairo_show_text(cr, text);
}

const ElementClass Text = {
    .free_data = text_free,
    .click = NULL,
    .render = text_render,
};

static Element *alloc_element(void) {
    Element *element = malloc(sizeof(Element));
    if (!element) {
        log_error("cannot allocate an element");
    }
    memset(element, 0, sizeof(Element));
    return element;
}

Element *element_init_root(void) {
    Element *element = alloc_element();
    if (!element) return NULL;

    wl_list_init(&element->link);
    wl_list_init(&element->children);
    element->class = &Root;

    return element;
}

Element *element_init_child(Element *parent, const ElementClass *class) {
    Element *element = alloc_element();
    if (!element) return NULL;

    wl_list_insert(&parent->children, &element->link);
    wl_list_init(&element->children);
    element->class = class;

    return element;
}


void element_destroy(Element *element) {
    if (element->class->free_data) {
        element->class->free_data(element);
    }

    Element *child, *tmp;
    wl_list_for_each_safe(child, tmp, &element->children, link) {
        element_destroy(child);
    }

    wl_list_remove(&element->link);
    free(element);
}

bool element_click(Element *element, int x, int y) {
    if (x < 0 || x >= element->width) return false;
    if (y < 0 || y >= element->height) return false;

    if (element->class->click) {
        element->class->click(element);
        return true;
    }

    Element *child;
    wl_list_for_each(child, &element->children, link) {
        if (element_click(child, x - child->x, y - child->y)) {
            return true;
        }
    }

    return false;
}

void element_render(Element *element, cairo_t *cr) {
    if (element->class->render) {
        cairo_save(cr);
        element->class->render(element, cr);
        cairo_restore(cr);
    }

    Element *child;
    wl_list_for_each(child, &element->children, link) {
        cairo_save(cr);
        cairo_translate(cr, child->x, child->y);
        element_render(child, cr);
        cairo_restore(cr);
    }
}

void element_render_root(Element *element, Client *client) {
    cairo_surface_t *surface = cairo_image_surface_create_for_data(
        client->buffer,
        CAIRO_FORMAT_ARGB32,
        client->width,
        client->height,
        client->width * 4);
    if (!surface) {
        log_warn("failed to create image surface");
        return;
    }

    cairo_t *cr = cairo_create(surface);
    if (!cr) {
        log_warn("failed to create cairo instance");
        cairo_surface_destroy(surface);
        return;
    }

    cairo_select_font_face(cr, "FreeSans",
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, TEXT_SIZE);

    element_render(element, cr);

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}
