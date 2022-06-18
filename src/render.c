#include "render.h"

#include <limits.h>
#include <log.h>

#define BUTTON_WIDTH 160
#define BUTTON_MARGIN 3
#define TEXT_SIZE 11

static void render_button(
    cairo_t *cr, int x, int y, int width, int height) {
    double left = x - 0.5, right = left + width;
    double top = y - 0.5, bottom = top + height;

    cairo_save(cr);

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

    cairo_restore(cr);
}

static void render_text(
    cairo_t *cr, int x, int y, int width, const char *text) {
    double xp = x - 0.5;
    double yp = y - 0.5;
    if (text == NULL) text = "(null)";

    cairo_save(cr);

    cairo_set_source_rgb(cr, 0.0, 0.0, 0.0);

    cairo_font_extents_t fe;
    cairo_font_extents(cr, &fe);
    cairo_text_extents_t te;
    cairo_text_extents(cr, text, &te);

    cairo_rectangle(cr, xp, yp - fe.ascent, width, fe.ascent + fe.descent);
    cairo_clip(cr);

    cairo_move_to(cr, xp, yp);
    cairo_show_text(cr, text);

    cairo_restore(cr);
}

void render_taskbar(Client *client) {
    uint32_t width = client->width;
    uint32_t height = client->height;
    unsigned char *buffer = client->buffer;

    if (width > INT_MAX || height > INT_MAX || height > INT_MAX / 4) {
        log_warn("surface is too big to draw to");
        return;
    }

    cairo_surface_t *surface = cairo_image_surface_create_for_data(
        buffer,
        CAIRO_FORMAT_ARGB32,
        width,
        height,
        width * 4);
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

    cairo_set_line_width(cr, 1.0);

    cairo_set_source_rgb(cr, 0.75, 0.75, 0.75);
    cairo_rectangle(cr, 0.0, 0.0, width, height);
    cairo_fill(cr);

    cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    cairo_move_to(cr, 0.0, 1.5);
    cairo_rel_line_to(cr, width, 0.0);
    cairo_stroke(cr);

    Toplevel *toplevel;
    double pos = BUTTON_MARGIN;
    wl_list_for_each_reverse(toplevel, &client->toplevels, link) {
        render_text(cr, pos + BUTTON_MARGIN, 18, BUTTON_WIDTH - (2 * BUTTON_MARGIN), toplevel->title);
        render_button(cr, pos, 4, BUTTON_WIDTH, 22);
        pos += BUTTON_WIDTH + BUTTON_MARGIN;
    }

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}