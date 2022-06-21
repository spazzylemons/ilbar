#include <gio/gdesktopappinfo.h>
#include <log.h>
#include <wayland-util.h>

#include "icons.h"
#include "util.h"

#define ICON_CACHE_SIZE 29

static size_t icon_cache_hash(const void *key) {
    const char *str = key;
    size_t result = 0;
    while (*str) {
        result <<= 8;
        result |= *str++;
    }
    return result;
}

static bool icon_cache_equal(const void *a, const void *b) {
    return strcmp(a, b) == 0;
}

static void icon_cache_free(const CacheEntry *entry) {
    free(entry->key);
    cairo_surface_destroy(entry->value);
}

static const CacheCallbacks icon_cache_callbacks = {
    .hash = icon_cache_hash,
    .equal = icon_cache_equal,
    .free = icon_cache_free,
};

/** Search a .desktop file for an icon. */
static char *search_applications(const char *fmt, ...) {
    va_list arg;
    va_start(arg, fmt);
    char *filename = alloc_vprint(fmt, arg);
    va_end(arg);
    if (!filename) return NULL;
    FILE *file = fopen(filename, "r");
    free(filename);
    if (!file) return NULL;

    struct wl_array line_buffer;
    wl_array_init(&line_buffer);

    char buf[64];
    char *result = NULL;
    for (;;) {
        size_t amt = fread(buf, 1, sizeof(buf), file);
        if (amt == 0) break;
        for (size_t i = 0; i < amt; i++) {
            char *ptr = wl_array_add(&line_buffer, 1);
            if (!ptr) goto done;
            *ptr = buf[i];
            if (buf[i] == '\n') {
                char *data = line_buffer.data;
                if (line_buffer.size > 5 && memcmp(data, "Icon=", 5) == 0) {
                    size_t size = line_buffer.size - 5;
                    if ((result = malloc(size))) {
                        memcpy(result, data + 5, size - 1);
                        result[size - 1] = '\0';
                    }
                    goto done;
                }
                line_buffer.size = 0;
            }
        }
    }
done:
    wl_array_release(&line_buffer);
    fclose(file);
    return result;
}

static char *get_icon_name_from_desktop(const char *name) {
    /* remove possible trailing .desktop */
    size_t name_length = strlen(name);
    char *desktop_name;
    if (name_length > 8 && strcmp(&name[name_length - 8], ".desktop") == 0) {
        desktop_name = strdup(name);
    } else {
        desktop_name = alloc_print("%s.desktop", name);
    }
    if (!desktop_name) return NULL;

    char *result = NULL;
    /* try local directory first */
    char *xdg_data_home = getenv("XDG_DATA_HOME");
    if (xdg_data_home) {
        result = search_applications(
            "%s/applications/%s", 
            xdg_data_home, desktop_name);
    } else {
        result = search_applications(
            "%s/local/share/applications/%s", 
            getenv("HOME"), desktop_name);
    }
    /* try global directories next */
    if (!result) {
        const char *xdg_data_dirs = getenv("XDG_DATA_DIRS");
        if (!xdg_data_dirs) {
            xdg_data_dirs = "/usr/local/share:/usr/share";
        }
        while (!result) {
            const char *sep = strstr(xdg_data_dirs, ":");
            int len;
            if (sep) {
                len = sep - xdg_data_dirs;
            } else {
                len = strlen(xdg_data_dirs);
            }
            result = search_applications(
                "%.*s/applications/%s", 
                len, xdg_data_dirs, desktop_name);
            if (!sep) break;
            xdg_data_dirs += len + 1;
        }
    }
    free(desktop_name);
    return result;
}

static char *get_icon_name(const char *name) {
    /* try the app id first */
    char *result = get_icon_name_from_desktop(name);
    if (result) return result;
    /* ask gtk for the icon */
    gchar ***search = g_desktop_app_info_search(name);
    if (search) {
        for (gchar ***strv = search; *strv; ++strv) {
            if (!result) {
                for (gchar **apps = *strv; *apps; ++apps) {
                    gchar *app = *apps;
                    result = get_icon_name_from_desktop(app);
                    if (result) break;
                }
            }
            g_strfreev(*strv);
        }
        g_free(search);
    }
    return result;
}

IconManager *icons_init(void) {
    IconManager *icons = malloc(sizeof(IconManager));
    if (!icons) {
        log_warn("failed to allocate icon manager");
        return NULL;
    }

    icons->cache = cache_init(ICON_CACHE_SIZE, &icon_cache_callbacks);
    if (!icons->cache) {
        log_warn("failed to create icon cache");
        free(icons);
        return NULL;
    }

    icons->theme = gtk_icon_theme_get_default();
    if (!icons->theme) {
        log_warn("failed to get icon theme");
        cache_deinit(icons->cache);
        free(icons);
        return NULL;
    }
    /* the theme is not automatically ref'd */
    g_object_ref(icons->theme);

    return icons;
}

void icons_deinit(IconManager *icons) {
    cache_deinit(icons->cache);
    g_object_unref(icons->theme);
    free(icons);
}

cairo_surface_t *icons_get(IconManager *icons, const char *name) {
    cairo_surface_t *surface = cache_get(icons->cache, name);
    if (surface) {
        cairo_surface_reference(surface);
        return surface;
    }
    char *icon_name = get_icon_name(name);
    if (!icon_name) {
        log_warn("failed to find icon for app ID %s", name);
        return NULL;
    }

    GdkPixbuf *pixbuf = gtk_icon_theme_load_icon(
        icons->theme, icon_name, 16, 0, NULL);
    if (!pixbuf) {
        log_warn("icon %s not found", icon_name);
        free(icon_name);
        return NULL;
    }

    if (gdk_pixbuf_get_colorspace(pixbuf) != GDK_COLORSPACE_RGB) {
        log_warn("icon is not in RGB colorspace");
    } else if (gdk_pixbuf_get_bits_per_sample(pixbuf) != 8) {
        log_warn("icon is not 8bpp");
    } else if (!gdk_pixbuf_get_has_alpha(pixbuf)) {
        log_warn("icon does not have alpha channel");
    } else if (gdk_pixbuf_get_n_channels(pixbuf) != 4) {
        log_warn("icon does not have 4 channels");
    } else {
        int width = gdk_pixbuf_get_width(pixbuf);
        int height = gdk_pixbuf_get_height(pixbuf);
        guchar *src = gdk_pixbuf_get_pixels(pixbuf);

        cairo_surface_t *surface = cairo_image_surface_create(
            CAIRO_FORMAT_ARGB32, width, height);
        cairo_surface_flush(surface);
        uint32_t *dst = (void*) cairo_image_surface_get_data(surface);
        if (!dst) {
            log_warn("failed to create icon surface");
            cairo_surface_destroy(surface);
            free(icon_name);
            g_object_unref(pixbuf);
            return NULL;
        }
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                uint32_t r = *src++;
                uint32_t g = *src++;
                uint32_t b = *src++;
                uint32_t a = *src++;
                *dst++ = (a << 24) | (r << 16) | (g << 8) | b;
            }
        }
        cairo_surface_mark_dirty(surface);
        g_object_unref(pixbuf);
        char *key = strdup(name);
        if (key) {
            cairo_surface_reference(surface);
            cache_put(icons->cache, key, surface);
        }
        free(icon_name);
        return surface;
    }

    free(icon_name);
    g_object_unref(pixbuf);
    return NULL;
}
