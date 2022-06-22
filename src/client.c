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
#include "util.h"

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
};;

struct wl_buffer *refresh_pool_buffer(Client *client);

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

void client_rerender(Client *client);

static void rerender(Client *client) {
    client_rerender(client);
}

void update_gui(Client *client);

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

ToplevelList *toplevel_list_init(Client *client);

PointerManager *pointer_manager_init(Client *client);

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

    self->toplevel_list = toplevel_list_init(self);
    if (!self->toplevel_list) {
        log_error("failed to create toplevel list");
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

    self->icons = icons_init();

    self->pointer_manager = pointer_manager_init(self);

    return self;
}
