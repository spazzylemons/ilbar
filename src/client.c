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

#include "client.h"
#include "render.h"
#include "util.h"

#define NUM_INTERFACES 5

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
    void **out;
} InterfaceSpec;

static void on_registry_global(
    void               *data,
    struct wl_registry *registry,
    uint32_t            name,
    const char         *interface,
    uint32_t            version
) {
    const InterfaceSpec *specs = data;
    for (int i = 0; i < NUM_INTERFACES; ++i) {
        const InterfaceSpec *spec = &specs[i];
        if (strcmp(interface, spec->interface->name) == 0) {
            if (version >= spec->version) {
                *spec->out = wl_registry_bind(
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

static void on_buffer_release(
    void             *UNUSED(data),
    struct wl_buffer *buffer
) {
    wl_buffer_destroy(buffer);
}

static const struct wl_buffer_listener buffer_listener = {
    .release = on_buffer_release,
};

static int alloc_shm(Client *client, int size) {
    static uint8_t counter = 0;
    /* create shm file name using various factors to avoid collision */
    pid_t pid = getpid();
    int n = snprintf(
        NULL, 0, "/ilbar-shm-%d-%p-%d", pid, (void*) client, counter) + 1;
    char name[n];
    snprintf(name, n, "/ilbar-shm-%d-%p-%d", pid, (void*) client, counter++);
    log_info("opening new shm file: %s", name);
    /* open a shared memory file */
    int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return -1;
    /* file should cease to exist when we're done with it */
    shm_unlink(name);
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

static struct wl_buffer *draw_frame(Client *client) {
    int stride = client->width * 4;
    int size = stride * client->height;

    struct wl_shm_pool *pool =
        wl_shm_create_pool(client->shm, client->buffer_fd, size);
    if (!pool) {
        log_warn("failed to create shm pool");
        return NULL;
    }

    uint32_t format = (endian_check.value == 1)
        ? WL_SHM_FORMAT_BGRX8888
        : WL_SHM_FORMAT_XRGB8888;

    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool,
        0,
        client->width,
        client->height,
        stride,
        format);
    wl_shm_pool_destroy(pool);
    if (!buffer) {
        log_warn("failed to create shm pool buffer");
        return NULL;
    }
    render_taskbar(client);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    return buffer;
}

static void rerender(Client *client) {
    if (client->buffer && client->buffer_fd) {
        struct wl_buffer *buffer = draw_frame(client);
        if (buffer) {
            wl_surface_attach(client->wl_surface, buffer, 0, 0);
            wl_surface_commit(client->wl_surface);
            wl_surface_damage(client->wl_surface,
                0, 0, client->width, client->height);
        }
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
    rerender(client);
}

static void on_surface_closed(
    void                         *data,
    struct zwlr_layer_surface_v1 *UNUSED(surface)
) {
    Client *client = data;
    client->should_close = true;
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
    client->mouse_x = wl_fixed_to_int(surface_x);
    client->mouse_y = wl_fixed_to_int(surface_y);
}

static void on_pointer_leave(
    void              *UNUSED(data),
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(serial),
    struct wl_surface *UNUSED(surface)
) {}

static void on_pointer_motion(
    void              *data,
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(time),
    wl_fixed_t         surface_x,
    wl_fixed_t         surface_y
) {
    Client *client = data;
    client->mouse_x = wl_fixed_to_int(surface_x);
    client->mouse_y = wl_fixed_to_int(surface_y);
}

static void on_pointer_button(
    void              *data,
    struct wl_pointer *UNUSED(pointer),
    uint32_t           UNUSED(serial),
    uint32_t           UNUSED(time),
    uint32_t           button,
    uint32_t           state
) {
    if (button == BTN_LEFT) {
        if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
            client_click(data);
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
    client->mouse_x = wl_fixed_to_int(x);
    client->mouse_y = wl_fixed_to_int(y);
    client_click(client);
}

static void on_touch_up(
    void              *UNUSED(data),
    struct wl_touch   *UNUSED(touch),
    uint32_t           UNUSED(serial),
    uint32_t           UNUSED(time),
    int32_t            UNUSED(id)
) {}

static void on_touch_motion(
    void              *UNUSED(data),
    struct wl_touch   *UNUSED(touch),
    uint32_t           UNUSED(time),
    int32_t            UNUSED(id),
    wl_fixed_t         UNUSED(x),
    wl_fixed_t         UNUSED(y)
) {}

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
            if (client->pointer) wl_pointer_destroy(client->pointer);
            client->pointer = pointer;
            wl_pointer_add_listener(client->pointer, &pointer_listener, client);
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
}

static void on_handle_app_id(
    void                                   *UNUSED(data),
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(handle),
    const char                             *UNUSED(app_id)
) {}

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
    void                                   *data,
    struct zwlr_foreign_toplevel_handle_v1 *UNUSED(handle)
) {
    Client *client = data;
    rerender(client);
}

static void on_handle_closed(
    void                                   *data,
    struct zwlr_foreign_toplevel_handle_v1 *handle
) {
    Client *client = data;

    Toplevel *toplevel = find_toplevel(client, handle);
    if (toplevel) {
        free_toplevel(toplevel);
    } else {
        zwlr_foreign_toplevel_handle_v1_destroy(handle);
    }
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

Client *client_init(const char *display, uint32_t height) {
    /* allocate client, set all values to null */
    Client *self = malloc(sizeof(Client));
    if (!self) {
        log_error("failed to allocate client");
        return NULL;
    }
    memset(self, 0, sizeof(Client));
    self->buffer_fd = -1;
    wl_list_init(&self->toplevels);

    self->display = wl_display_connect(display);
    if (!self->display) {
        log_error("failed to open the Wayland display");
        client_deinit(self);
        return NULL;
    }

    struct wl_registry *registry = wl_display_get_registry(self->display);
    if (!registry) {
        log_error("failed to get the Wayland registry");
        client_deinit(self);
        return NULL;
    }

    InterfaceSpec specs[NUM_INTERFACES] = {
        {
            .interface = &wl_shm_interface,
            .version = 1,
            .out = (void**) (void*) &self->shm,
        },

        {
            .interface = &wl_compositor_interface,
            .version = 4,
            .out = (void**) (void*) &self->compositor,
        },

        {
            .interface = &zwlr_layer_shell_v1_interface,
            .version = 4,
            .out = (void**) (void*) &self->layer_shell,
        },

        {
            .interface = &wl_seat_interface,
            .version = 7,
            .out = (void**) (void*) &self->seat,
        },

        {
            .interface = &zwlr_foreign_toplevel_manager_v1_interface,
            .version = 3,
            .out = (void**) (void*) &self->toplevel_manager,
        },
    };

    wl_registry_add_listener(registry, &registry_listener, &specs);
    if (wl_display_roundtrip(self->display) < 0) {
        log_error("failed to perform roundtrip");
        wl_registry_destroy(registry);
        client_deinit(self);
        return NULL;
    }

    bool bad_interfaces = false;
    for (int i = 0; i < NUM_INTERFACES; ++i) {
        if (!*specs[i].out) {
            log_error("interface %s is unavailable or not new enough",
                specs[i].interface->name);
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
        ZWLR_LAYER_SHELL_V1_LAYER_TOP,
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
    zwlr_layer_surface_v1_set_size(self->layer_surface, 0, height);
    zwlr_layer_surface_v1_set_exclusive_zone(self->layer_surface, height);

    wl_surface_commit(self->wl_surface);

    wl_seat_add_listener(self->seat, &seat_listener, self);

    zwlr_foreign_toplevel_manager_v1_add_listener(
        self->toplevel_manager, &toplevel_listener, self);

    return self;
}

void client_run(Client *self) {
    while (!self->should_close && wl_display_dispatch(self->display));
}

void client_deinit(Client *self) {
    free_all_toplevels(self);

    if (self->buffer) munmap(self->buffer, self->width * self->height * 4);
    if (self->buffer_fd >= 0) close(self->buffer_fd);

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

    if (self->display) wl_display_disconnect(self->display);

    free(self);
}

void client_click(Client *self) {
    /* just close the taskbar on click as there's nothing else to do */
    self->should_close = true;
}
