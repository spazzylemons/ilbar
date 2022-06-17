#ifndef ILBAR_CLIENT_H
#define ILBAR_CLIENT_H

#include <stdbool.h>
#include <stdint.h>

/** The interface to Wayland. */
typedef struct {
    /** Global display object */
    struct wl_display *display;
    /** Global shared memory object */
    struct wl_shm *shm;
    /** Global compositor object */
    struct wl_compositor *compositor;
    /** Global layer shell object */
    struct zwlr_layer_shell_v1 *layer_shell;
    /** Global seat object */
    struct wl_seat *seat;
    /** Current Wayland surface object */
    struct wl_surface *wl_surface;
    /** Current layer surface object */
    struct zwlr_layer_surface_v1 *layer_surface;
    /** Current pointer object */
    struct wl_pointer            *pointer;
    /** Current touch object */
    struct wl_touch              *touch;
    /** When set to true, events stop being dispatched. */
    bool should_close;
    /** The current dimensions of the surface. */
    uint32_t width, height;
    /** The last seen position of the pointer or touch. */
    int mouse_x, mouse_y;
} Client;

/** Create a new client object. */
Client *client_init(const char *display, uint32_t height);
/** Run the client. */
void client_run(Client *self);
/** Destroy the client and all related resources. */
void client_deinit(Client *self);
/** Perform a mouse click at the last seen mouse coordinates. */
void client_click(Client *self);

#endif
