#ifndef ILBAR_CLIENT_H
#define ILBAR_CLIENT_H

#include <stdbool.h>
#include <stdint.h>

#include <wayland-util.h>

#include "config.h"

/** An open toplevel window. */
typedef struct {
    /** Intrusive list */
    struct wl_list link;
    /** The window handle. */
    struct zwlr_foreign_toplevel_handle_v1 *handle;
    /** The last seen title as an owned copy. */
    char *title;
} Toplevel;

/** The interface to Wayland. */
typedef struct {
    /** The config settings */
    const Config *config;
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
    /** Global importer object */
    struct zwlr_foreign_toplevel_manager_v1 *toplevel_manager;
    /** Current Wayland surface object */
    struct wl_surface *wl_surface;
    /** Current layer surface object */
    struct zwlr_layer_surface_v1 *layer_surface;
    /** Current pointer object */
    struct wl_pointer *pointer;
    /** Current touch object */
    struct wl_touch *touch;
    /** The current pixel buffer, or NULL if not currently allocated. */
    unsigned char *buffer;
    /** The buffer file descriptor, or -1 if not currently opened. */
    int buffer_fd;
    /** When set to true, events stop being dispatched. */
    bool should_close;
    /** The current dimensions of the surface. */
    uint32_t width, height;
    /** The last seen position of the pointer or touch. */
    int mouse_x, mouse_y;
    /** A list of toplevel info. */
    struct wl_list toplevels;
} Client;

/** Create a new client object. */
Client *client_init(const char *display, const Config *config);
/** Run the client. */
void client_run(Client *self);
/** Destroy the client and all related resources. */
void client_deinit(Client *self);
/** Perform a mouse click at the last seen mouse coordinates. */
void client_click(Client *self);

#endif
