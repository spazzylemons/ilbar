#include "client.h"
#include "gui.h"

void element_render_root(Element *element, Client *client) {
    cairo_surface_t *surface = cairo_image_surface_create_for_data(
        client->buffer,
        CAIRO_FORMAT_ARGB32,
        client->width,
        client->height,
        client->width * 4);
    cairo_t *cr = cairo_create(surface);

    cairo_select_font_face(cr, client->config->font,
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, client->config->font_size);
    cairo_set_antialias(cr, CAIRO_ANTIALIAS_NONE);
    cairo_set_line_width(cr, 1.0);

    element_render(element, cr);

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}
