#include "render.h"

#include <limits.h>
#include <log.h>

void render_taskbar(uint32_t width, uint32_t height, unsigned char *buffer) {
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
    
    cairo_set_source_rgb(cr, 0.75, 0.75, 0.75);
    cairo_rectangle(cr, 0.0, 0.0, width, height);
    cairo_fill(cr);

    cairo_set_source_rgb(cr, 0.0, 0.0, 0.0);
    cairo_set_font_size(cr, height);
    cairo_move_to(cr, 0.0, height * 0.75);
    cairo_show_text(cr, "hello, world!");

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}