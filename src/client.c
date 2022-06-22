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

ToplevelList *toplevel_list_init(Client *client);

PointerManager *pointer_manager_init(Client *client);

void add_surface_listener(Client *client);

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

    add_surface_listener(self);

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
