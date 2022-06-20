#ifndef ILBAR_GUI_H
#define ILBAR_GUI_H

#include <cairo.h>
#include <wayland-util.h>
#include <stdbool.h>

typedef struct Client Client;

typedef struct ElementClass ElementClass;

/** A GUI element. */
typedef struct {
    /** The list of elements at this level. */
    struct wl_list link;
    /** The list of children of this element. */
    struct wl_list children;
    /** The dimensions of the element, relative to its parent. */
    int x, y, width, height;
    /** THe class of this element. */
    const ElementClass *class;
    /** If true, the element has been pressed. */
    bool pressed;
    /** If true, the cursor is pressed on the element */
    bool pressed_hover;
    /** class-specific data */
    union {
        char *text;
        struct {
            struct zwlr_foreign_toplevel_handle_v1 *handle;
            struct wl_seat *seat;
        };
        cairo_surface_t *image;
    };
} Element;

struct ElementClass {
    bool clickable;
    void (*free_data)(Element *self);
    void (*release)(Element *self);
    void (*render)(Element *self, cairo_t *cr);
};

extern const ElementClass WindowButton;
extern const ElementClass Text;
extern const ElementClass Image;

Element *element_init_root(void);

Element *element_init_child(Element *parent, const ElementClass *class);

void element_destroy(Element *element);

bool element_press(Element *element, int x, int y);

bool element_motion(Element *element, int x, int y);

bool element_release(Element *element);

void element_render(Element *element, cairo_t *cr);

void element_render_root(Element *element, Client *client);

#endif
