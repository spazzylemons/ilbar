#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input-event-codes.h>
#include <log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wlr-foreign-toplevel-management-unstable-v1-protocol.h>
#include <wlr-layer-shell-unstable-v1-protocol.h>
#include <relative-pointer-unstable-v1-protocol.h>

#include "client.h"
#include "util.h"

struct {
    uint8_t bytes[2];
    uint16_t value;
} endian_check = { .bytes = { 0, 1 } };

/** Specification for loading an interface from the registry. */
typedef struct {
    /** The interface to bind to. */
    const struct wl_interface *interface;
    /** The minimum supported version. */
    uint32_t version;
    /** The location to store the interface. */
    size_t offset;
} InterfaceSpec;

const InterfaceSpec specs[] = {
    { &wl_shm_interface,                           1,
        offsetof(Client, shm) },
    { &wl_compositor_interface,                    4,
        offsetof(Client, compositor) },
    { &zwlr_layer_shell_v1_interface,              4,
        offsetof(Client, layer_shell) },
    { &wl_seat_interface,                          7,
        offsetof(Client, seat) },
    { &zwlr_foreign_toplevel_manager_v1_interface, 3,
        offsetof(Client, toplevel_manager) },
    { &zwp_relative_pointer_manager_v1_interface,  1,
        offsetof(Client, pointer_manager) },
    { NULL },
};

#define SPEC_PTR(_spec_, _client_) \
    (*((void**) (void*) &((char*) (void*) _client_)[_spec_->offset]))

static void on_registry_global(
    void               *data,
    struct wl_registry *registry,
    uint32_t            name,
    const char         *interface,
    uint32_t            version
) {
    Client *client = data;
    for (const InterfaceSpec *spec = specs; spec->interface; ++spec) {
        if (strcmp(interface, spec->interface->name) == 0) {
            if (version >= spec->version) {
                SPEC_PTR(spec, client) = wl_registry_bind(
                    registry,
                    name,
                    spec->interface,
                    spec->version);
            } else {
                log_error("interface %s is available, but too old",
                    spec->interface->name);
            }
            return;
        }
    }
}

static void on_registry_global_remove(
    void               *UNUSED(data),
    struct wl_registry *UNUSED(registry),
    uint32_t            UNUSED(name)
) {}

static const struct wl_registry_listener registry_listener = {
    .global        = on_registry_global,
    .global_remove = on_registry_global_remove,
};

static const struct wl_buffer_listener buffer_listener;

static struct wl_buffer *refresh_pool_buffer(Client *client) {
    int size = client->width * client->height * 4;

    struct wl_shm_pool *pool =
        wl_shm_create_pool(client->shm, client->buffer_fd, size);
    if (!pool) {
        log_warn("failed to create shm pool");
        return NULL;
    }

    uint32_t format = (endian_check.value == 1)
        ? WL_SHM_FORMAT_BGRX8888
        : WL_SHM_FORMAT_XRGB8888;

    struct wl_buffer *pool_buffer = wl_shm_pool_create_buffer(
        pool,
        0,
        client->width,
        client->height,
        client->width * 4,
        format);
    wl_shm_pool_destroy(pool);
    if (!pool_buffer) {
        log_warn("failed to create shm pool buffer");
    } else {
        wl_buffer_add_listener(pool_buffer, &buffer_listener, client);
    }

    return pool_buffer;
}

static void on_buffer_release(
    void             *data,
    struct wl_buffer *buffer
) {
    Client *client = data;
    if (buffer == client->pool_buffer) {
        wl_buffer_destroy(buffer);
        client->pool_buffer = refresh_pool_buffer(client);
    }
}

static const struct wl_buffer_listener buffer_listener = {
    .release = on_buffer_release,
};

static int alloc_shm(Client *client, int size) {
    static uint8_t counter = 0;
    /* create shm file name using various factors to avoid collision */
    pid_t pid = getpid();
    char *name = alloc_print(
        "/ilbar-shm-%d-%p-%d", pid, (void*) client, counter);
    if (!name) {
        log_warn("failed to allocate shm file name");
        return -1;
    }
    log_info("opening new shm file: %s", name);
    /* open a shared memory file */
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        free(name);
        return -1;
    }
    /* file should cease to exist when we're done with it */
    shm_unlink(name);
    free(name);
    /* allocate buffer */
    while (ftruncate(fd, size) < 0) {
        if (errno != EINTR) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

static void update_shm(Client *client, uint32_t width, uint32_t height) {
    uint64_t size = (uint64_t) width * (uint64_t) height * 4;
    if (size > INT_MAX) {
        log_warn("taskbar dimensions too large");
        return;
    }
    int new_size = size;
    int old_size = client->width * client->height * 4;
    if (old_size == new_size) return;

    int fd = alloc_shm(client, new_size);
    if (fd < 0) {
        log_warn("failed to open shm file");
        return;
    }

    unsigned char *buffer =
        mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (buffer == MAP_FAILED) {
        log_warn("failed to mmap new shm");
        close(fd);
        return;
    }

    if (client->buffer) {
        munmap(client->buffer, old_size);
    }
    client->buffer = buffer;

    if (client->buffer_fd >= 0) {
        close(client->buffer_fd);
    }
    client->buffer_fd = fd;

    client->width = width;
    client->height = height;
}

static void rerender(Client *client) {
    if (client->buffer && client->buffer_fd && client->gui) {
        if (!client->pool_buffer) {
            client->pool_buffer = refresh_pool_buffer(client);
        }
        if (client->pool_buffer) {
            element_render_root(client->gui, client);
            wl_surface_attach(client->wl_surface, client->pool_buffer, 0, 0);
            wl_surface_commit(client->wl_surface);
            wl_surface_damage(client->wl_surface,
                0, 0, client->width, client->height);
        }
    }
}

static bool create_taskbar_button(
    Client *client, Toplevel *toplevel, Element *root, int x) {
    Element *button = element_init_child(root, &WindowButton);
    if (button) {
        button->x = x;
        button->y = 4;
        button->width = client->config->width;
        button->height = client->config->height - 6;
        button->handle = toplevel->handle;
        button->seat = client->seat;

        int text_x = client->config->margin;
        int text_width = client->config->width - (2 * client->config->margin);
        if (client->icons && toplevel->app_id) {
            cairo_surface_t *image = icons_get(client->icons, toplevel->app_id);
            if (image) {
                Element *icon = element_init_child(button, &Image);
                if (icon) {
                    icon->x = client->config->margin;
                    icon->y = (button->height - 16) / 2;
                    icon->image = image;
                    text_x += 16 + client->config->margin;
                    text_width -= 16 + client->config->margin;
                } else {
                    cairo_surface_destroy(image);
                }
            }
        }
        Element *text = element_init_child(button, &Text);
        if (text) {
            text->x = text_x;
            text->y = (button->height - client->config->font_height) / 2;
            text->width = text_width;
            text->height = client->config->font_height;
            if (toplevel->title) text->text = strdup(toplevel->title);
        }
        return true;
    }
    element_destroy(button);
    return false;
}

static Element *create_gui(Client *client) {
    Element *root = element_init_root();
    if (!root) return NULL;

    root->x = 0;
    root->y = 0;
    root->width = client->width;
    root->height = client->height;

    int x = client->config->margin;

    Toplevel *toplevel;
    wl_list_for_each_reverse(toplevel, &client->toplevels, link) {
        if (create_taskbar_button(client, toplevel, root, x)) {
            x += client->config->width + client->config->margin;
        }
    }

    return root;
}

static void update_gui(Client *client) {
    Element *new_gui = create_gui(client);
    if (new_gui) {
        if (client->gui) element_destroy(client->gui);
        client->gui = new_gui;
        rerender(client);
    }
}

static void on_surface_configure(
    void                         *data,
    struct zwlr_layer_surface_v1 *surface,
    uint32_t                      serial,
    uint32_t                      width,
    uint32_t                      height
) {
    Client *client = data;
    zwlr_layer_surface_v1_ack_configure(surface, serial);

    update_shm(client, width, height);
    update_gui(client);
}

static void on_surface_closed(
    void                         *data,
    struct zwlr_layer_surface_v1 *surface
) {
    Client *client = data;
    if (surface == client->layer_surface) {
        log_info("surface was closed, shutting down");
        client->should_close = true;
    }
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
    .configure = on_surface_configure,
    .closed    = on_surface_closed,
};

static void on_pointer_enter(
    void              *data,
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(serial),
    struct wl_surface *UNUSED(surface),
    wl_fixed_t         surface_x,
    wl_fixed_t         surface_y
) {
    Client *client = data;
    client->mouse_x = surface_x;
    client->mouse_y = surface_y;
}

static void on_pointer_leave(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(serial),
    struct wl_surface *UNUSED(surface)
) {}

static void on_pointer_motion(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(time),
    wl_fixed_t         UNUSED(surface_x),
    wl_fixed_t         UNUSED(surface_y)
) {}

static void on_pointer_button(
    void              *data,
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(serial),
    uint32_t           UNUSED(time),
    uint32_t           button,
    uint32_t           state
) {
    Client *client = data;
    if (button == BTN_LEFT) {
        if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
            client_press(client);
        } else {
            client_release(client);
        }
    }
}

static void on_pointer_axis(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(time),
    uint32_t           UNUSED(axis),
    wl_fixed_t         UNUSED(value)
) {}

static void on_pointer_frame(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer)
) {}

static void on_pointer_axis_source(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(axis_source)
) {}

static void on_pointer_axis_stop(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(time),
    uint32_t           UNUSED(axis)
) {}

static void on_pointer_axis_discrete(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(axis),
    int32_t            UNUSED(discrete)
) {}

static const struct wl_pointer_listener pointer_listener = {
    .enter         = on_pointer_enter,
    .leave         = on_pointer_leave,
    .motion        = on_pointer_motion,
    .button        = on_pointer_button,
    .axis          = on_pointer_axis,
    .frame         = on_pointer_frame,
    .axis_source   = on_pointer_axis_source,
    .axis_stop     = on_pointer_axis_stop,
    .axis_discrete = on_pointer_axis_discrete,
};

static void on_relative_motion(
    void                           *data,
    struct zwp_relative_pointer_v1 *UNUSED(relative),
    uint32_t                        UNUSED(utime_hi),
    uint32_t                        UNUSED(utime_lo),
    wl_fixed_t                      dx,
    wl_fixed_t                      dy,
    wl_fixed_t                      UNUSED(dx_unaccel),
    wl_fixed_t                      UNUSED(dy_unaccel)
) {
    Client *client = data;
    client->mouse_x += dx;
    client->mouse_y += dy;
    client_motion(client);
}

static const struct zwp_relative_pointer_v1_listener relative_listener = {
    .relative_motion = on_relative_motion,
};

static void on_touch_down(
    void              *data,
    struct wl_touch   *UNUSED(touch),
    uint32_t           UNUSED(serial),
    uint32_t           UNUSED(time),
    struct wl_surface *UNUSED(surface),
    int32_t            UNUSED(id),
    wl_fixed_t         x,
    wl_fixed_t         y
) {
    Client *client = data;
    client->mouse_x = x;
    client->mouse_y = y;
    client_press(client);
}

static void on_touch_up(
    void              *data,
    struct wl_touch   *UNUSED(touch),
    uint32_t           UNUSED(serial),
    uint32_t           UNUSED(time),
    int32_t            UNUSED(id)
) {
    Client *client = data;
    client_release(client);
}

static void on_touch_motion(
    void              *data,
    struct wl_touch   *UNUSED(touch),
    uint32_t           UNUSED(time),
    int32_t            UNUSED(id),
    wl_fixed_t         x,
    wl_fixed_t         y
) {
    Client *client = data;
    client->mouse_x = x;
    client->mouse_y = y;
    client_motion(client);
}

static void on_touch_frame(
    void              *UNUSED(data),
    struct wl_touch   *UNUSED(touch)
) {}

static void on_touch_cancel(
    void              *UNUSED(data),
    struct wl_touch   *UNUSED(touch)
) {}

static void on_touch_shape(
    void              *UNUSED(data),
    struct wl_touch   *UNUSED(touch),
    int32_t            UNUSED(id),
    wl_fixed_t         UNUSED(major),
    wl_fixed_t         UNUSED(minor)
) {}

static void on_touch_orientation(
    void              *UNUSED(data),
    struct wl_touch   *UNUSED(touch),
    int32_t            UNUSED(id),
    wl_fixed_t         UNUSED(orientation)
) {}

static const struct wl_touch_listener touch_listener = {
    .down        = on_touch_down,
    .up          = on_touch_up,
    .motion      = on_touch_motion,
    .frame       = on_touch_frame,
    .cancel      = on_touch_cancel,
    .shape       = on_touch_shape,
    .orientation = on_touch_orientation,
};

static void on_seat_capabilities(
    void           *data,
    struct wl_seat *seat,
    uint32_t        capabilities
) {
    Client *client = data;

    if (capabilities & WL_SEAT_CAPABILITY_POINTER) {
        struct wl_pointer *pointer = wl_seat_get_pointer(seat);
        if (pointer) {
            struct zwp_relative_pointer_v1 *relative_pointer =
                zwp_relative_pointer_manager_v1_get_relative_pointer(
                    client->pointer_manager,
                    pointer);
            if (relative_pointer) {
                if (client->relative_pointer)
                    zwp_relative_pointer_v1_destroy(client->relative_pointer);
                client->relative_pointer = relative_pointer;
                if (client->pointer) wl_pointer_destroy(client->pointer);
                client->pointer = pointer;
                zwp_relative_pointer_v1_add_listener(
                    client->relative_pointer, &relative_listener, client);
                wl_pointer_add_listener(
                    client->pointer, &pointer_listener, client);
            } else {
                wl_pointer_destroy(pointer);
                log_warn("failed to obtain the relative pointer");
            }
        } else {
            log_warn("failed to obtain the pointer");
        }
    }

    if (capabilities & WL_SEAT_CAPABILITY_TOUCH) {
        struct wl_touch *touch = wl_seat_get_touch(seat);
        if (touch) {
            if (client->touch) wl_touch_destroy(client->touch);
            client->touch = touch;
            wl_touch_add_listener(client->touch, &touch_listener, client);
        } else {
            log_warn("failed to obtain the touch");
        }
    }
}

static void on_seat_name(
    void           *UNUSED(data),
    struct wl_seat *UNUSED(seat),
    const char     *UNUSED(name)
) {}

static const struct wl_seat_listener seat_listener = {
    .capabilities = on_seat_capabilities,
    .name         = on_seat_name,
};

static Toplevel *add_toplevel(Client *client,
    struct zwlr_foreign_toplevel_handle_v1 *handle) {
    Toplevel *toplevel = malloc(sizeof(Toplevel));
    if (!toplevel) {
        log_warn("failed to allocate for a new window");
        return NULL;
    }

    wl_list_insert(&client->toplevels, &toplevel->link);
    toplevel->handle = handle;
    toplevel->title = NULL;
    toplevel->app_id = NULL;

    return toplevel;
}

static Toplevel *find_toplevel(Client *client,
    struct zwlr_foreign_toplevel_handle_v1 *handle) {
    Toplevel *toplevel;
    wl_list_for_each(toplevel, &client->toplevels, link) {
        if (toplevel->handle == handle) {
            return toplevel;
        }
    }
    return NULL;
}

static Toplevel *find_or_add_toplevel(Client *client,
    struct zwlr_foreign_toplevel_handle_v1 *handle) {
    Toplevel *toplevel = find_toplevel(client, handle);
    if (toplevel) return toplevel;
    return add_toplevel(client, handle);
}

static void free_toplevel(Toplevel *toplevel) {
    wl_list_remove(&toplevel->link);
    zwlr_foreign_toplevel_handle_v1_destroy(toplevel->handle);
    free(toplevel->title);
    free(toplevel->app_id);
    free(toplevel);
}

static void free_all_toplevels(Client *client) {
    Toplevel *toplevel, *tmp;
    wl_list_for_each_safe(toplevel, tmp, &client->toplevels, link) {
        free_toplevel(toplevel);
    }
}

static void on_handle_title(
    void                                   *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle,
    const char                             *title
) {
    Client *client = data;
    Toplevel *toplevel = find_or_add_toplevel(client, handle);
    if (toplevel) {
        char *title_copy = strdup(title);
        if (title_copy) {
            free(toplevel->title);
            toplevel->title = title_copy;
        } else {
            log_warn("failed to copy title '%s'", title);
        }
    }
    update_gui(client);
}

static void on_handle_app_id(
    void                                   *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle,
    const char                             *app_id
) {
    Client *client = data;
    Toplevel *toplevel = find_or_add_toplevel(client, handle);
    if (toplevel) {
        char *app_id_copy = strdup(app_id);
        if (app_id_copy) {
            free(toplevel->app_id);
            toplevel->app_id = app_id_copy;
        } else {
            log_warn("failed to copy app ID '%s'", app_id);
        }
    }
    update_gui(client);
}

static void on_handle_output_enter(
    void                                   *UNUSED(data),
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(handle),
    struct wl_output                       *UNUSED(output)
) {}

static void on_handle_output_exit(
    void                                   *UNUSED(data),
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(handle),
    struct wl_output                       *UNUSED(output)
) {}

static void on_handle_state(
    void                                   *UNUSED(data),
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(handle),
    struct wl_array                        *UNUSED(state)
) {}

static void on_handle_done(
    void                                   *UNUSED(data),
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(handle)
) {}

static void on_handle_closed(
    void                                   *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle
) {
    Client *client = data;

    /* Destroy the GUI to prevet invalid handles */
    if (client->gui) {
        element_destroy(client->gui);
        client->gui = NULL;
    }

    Toplevel *toplevel = find_toplevel(client, handle);
    if (toplevel) {
        free_toplevel(toplevel);
    } else {
        zwlr_foreign_toplevel_handle_v1_destroy(handle);
    }

    update_gui(client);
}

static void on_handle_parent(
    void                                   *UNUSED(data),
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(handle),
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(parent)
) {}

static const struct zwlr_foreign_toplevel_handle_v1_listener
handle_listener = {
    .title        = on_handle_title,
    .app_id       = on_handle_app_id,
    .output_enter = on_handle_output_enter,
    .output_leave = on_handle_output_exit,
    .state        = on_handle_state,
    .done         = on_handle_done,
    .closed       = on_handle_closed,
    .parent       = on_handle_parent,
};

static void on_toplevel_toplevel(
    void                                    *data,
    struct zwlr_foreign_toplevel_manager_v1 *UNUSED(toplevel_manager),
    struct zwlr_foreign_toplevel_handle_v1  *handle
) {
    // TODO
    Client *client = data;
    zwlr_foreign_toplevel_handle_v1_add_listener(
        handle, &handle_listener, client);
    add_toplevel(client, handle);
}

static void on_toplevel_finished(
    void                                    *data,
    struct zwlr_foreign_toplevel_manager_v1 *toplevel_manager
) {
    Client *client = data;
    free_all_toplevels(client);
    zwlr_foreign_toplevel_manager_v1_destroy(toplevel_manager);
    client->toplevel_manager = NULL;
    log_warn("toplevel manager closed early, functionality limited");
}

static const struct zwlr_foreign_toplevel_manager_v1_listener
toplevel_listener = {
    .toplevel = on_toplevel_toplevel,
    .finished = on_toplevel_finished,
};

Client *client_init(const char *display, const Config *config) {
    /* allocate client, set all values to null */
    Client *self = malloc(sizeof(Client));
    if (!self) {
        log_error("failed to allocate client");
        return NULL;
    }
    memset(self, 0, sizeof(Client));
    self->config = config;
    self->buffer_fd = -1;
    wl_list_init(&self->toplevels);

    self->display = wl_display_connect(display);
    if (!self->display) {
        log_error("failed to open the Wayland display");
        client_deinit(self);
        return NULL;
    }
    log_info("connected to display %s",
        display ? display : getenv("WAYLAND_DISPLAY"));

    struct wl_registry *registry = wl_display_get_registry(self->display);
    if (!registry) {
        log_error("failed to get the Wayland registry");
        client_deinit(self);
        return NULL;
    }

    wl_registry_add_listener(registry, &registry_listener, self);
    if (wl_display_roundtrip(self->display) < 0) {
        log_error("failed to perform roundtrip");
        wl_registry_destroy(registry);
        client_deinit(self);
        return NULL;
    }

    bool bad_interfaces = false;
    for (const InterfaceSpec *spec = specs; spec->interface; ++spec) {
        if (!SPEC_PTR(spec, self)) {
            log_error("interface %s is unavailable or not new enough",
                spec->interface->name);
            bad_interfaces = true;
        }
    }
    wl_registry_destroy(registry);
    if (bad_interfaces) {
        client_deinit(self);
        return NULL;
    }

    self->wl_surface = wl_compositor_create_surface(self->compositor);
    if (!self->wl_surface) {
        log_error("failed to create Wayland surface");
        client_deinit(self);
        return NULL;
    }

    self->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
        self->layer_shell,
        self->wl_surface,
        NULL,
        ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        "ilbar");
    if (!self->layer_surface) {
        log_error("failed to create layer surface");
        client_deinit(self);
        return NULL;
    }

    zwlr_layer_surface_v1_add_listener(
        self->layer_surface, &layer_surface_listener, self);

    /* anchor to all but bottom */
    zwlr_layer_surface_v1_set_anchor(self->layer_surface,
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT  |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM);
    zwlr_layer_surface_v1_set_size(self->layer_surface, 0, config->height);
    zwlr_layer_surface_v1_set_exclusive_zone(
        self->layer_surface, config->height);

    wl_surface_commit(self->wl_surface);

    wl_seat_add_listener(self->seat, &seat_listener, self);

    zwlr_foreign_toplevel_manager_v1_add_listener(
        self->toplevel_manager, &toplevel_listener, self);

    self->icons = icons_init();

    return self;
}

void client_run(Client *self) {
    while (!self->should_close && wl_display_dispatch(self->display) >= 0);

    int err = wl_display_get_error(self->display);
    if (err) {
        log_fatal("disconnected: %s", strerror(err));
    }
}

void client_deinit(Client *self) {
    free_all_toplevels(self);

    if (self->icons) icons_deinit(self->icons);

    if (self->gui) element_destroy(self->gui);

    if (self->pool_buffer) wl_buffer_destroy(self->pool_buffer);
    if (self->buffer) munmap(self->buffer, self->width * self->height * 4);
    if (self->buffer_fd >= 0) close(self->buffer_fd);

    if (self->relative_pointer)
        zwp_relative_pointer_v1_destroy(self->relative_pointer);
    if (self->pointer) wl_pointer_destroy(self->pointer);
    if (self->touch) wl_touch_destroy(self->touch);

    if (self->layer_surface) zwlr_layer_surface_v1_destroy(self->layer_surface);
    if (self->wl_surface) wl_surface_destroy(self->wl_surface);

    if (self->shm) wl_shm_destroy(self->shm);
    if (self->compositor) wl_compositor_destroy(self->compositor);
    if (self->layer_shell) zwlr_layer_shell_v1_destroy(self->layer_shell);
    if (self->seat) wl_seat_destroy(self->seat);
    if (self->toplevel_manager)
        zwlr_foreign_toplevel_manager_v1_destroy(self->toplevel_manager);
    if (self->pointer_manager)
        zwp_relative_pointer_manager_v1_destroy(self->pointer_manager);

    if (self->display) wl_display_disconnect(self->display);

    free(self);
}

void client_press(Client *self) {
    if (self->gui && !self->mouse_down) {
        element_press(
            self->gui,
            wl_fixed_to_int(self->mouse_x),
            wl_fixed_to_int(self->mouse_y));
    }
    self->mouse_down = true;
    rerender(self);
}

void client_motion(Client *self) {
    if (self->gui) {
        element_motion(
            self->gui,
            wl_fixed_to_int(self->mouse_x),
            wl_fixed_to_int(self->mouse_y));
    }

    rerender(self);
}

void client_release(Client *self) {
    if (self->gui && self->mouse_down) {
        element_release(self->gui);
    }
    self->mouse_down = false;
    rerender(self);
}
