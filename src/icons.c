#include <log.h>
#include <wayland-util.h>

#include "icons.h"
#include "util.h"

/** Search a .desktop file for an icon. */
static char *search_applications(const char *fmt, ...) {
    va_list arg;
    va_start(arg, fmt);
    char *filename = alloc_vprint(fmt, arg);
    va_end(arg);
    printf("[%s]\n", filename);
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

static char *get_icon_name(const char *name) {
    char *result = NULL;
    /* try local directory first */
    char *xdg_data_home = getenv("XDG_DATA_HOME");
    if (xdg_data_home) {
        result = search_applications(
            "%s/applications/%s.desktop", 
            xdg_data_home, name);
    } else {
        result = search_applications(
            "%s/local/share/applications/%s.desktop", 
            getenv("HOME"), name);
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
                "%.*s/applications/%s.desktop", 
                len, xdg_data_dirs, name);
            if (!sep) break;
            xdg_data_dirs += len + 1;
        }
    }
    return result;
}

IconManager *icons_init(void) {
    IconManager *icons = malloc(sizeof(IconManager));
    if (!icons) {
        log_error("failed to allocate icon manager");
        return NULL;
    }

    icons->theme = gtk_icon_theme_get_default();
    if (!icons->theme) {
        log_error("failed to get icon theme");
        free(icons);
        return NULL;
    }
    /* the theme is not automatically ref'd */
    g_object_ref(icons->theme);

    return icons;
}

void icons_deinit(IconManager *icons) {
    g_object_unref(icons->theme);
    free(icons);
}

cairo_surface_t *icons_get(IconManager *icons, const char *name) {
    char *icon_name = get_icon_name(name);
    if (!icon_name) {
        log_error("failed to find icon for app ID %s", name);
        return NULL;
    }
    GdkPixbuf *pixbuf = gtk_icon_theme_load_icon(
        icons->theme, icon_name, 16, 0, NULL);
    if (!pixbuf) {
        log_error("icon %s not found", icon_name);
        free(icon_name);
        return NULL;
    }
    free(icon_name);

    if (gdk_pixbuf_get_colorspace(pixbuf) != GDK_COLORSPACE_RGB) {
        log_error("icon is not in RGB colorspace");
    } else if (gdk_pixbuf_get_bits_per_sample(pixbuf) != 8) {
        log_error("icon is not 8bpp");
    } else if (!gdk_pixbuf_get_has_alpha(pixbuf)) {
        log_error("icon does not have alpha channel");
    } else if (gdk_pixbuf_get_n_channels(pixbuf) != 4) {
        log_error("icon does not have 4 channels");
    } else {
        int width = gdk_pixbuf_get_width(pixbuf);
        int height = gdk_pixbuf_get_height(pixbuf);
        guchar *src = gdk_pixbuf_get_pixels(pixbuf);

        cairo_surface_t *surface = cairo_image_surface_create(
            CAIRO_FORMAT_ARGB32, width, height);
        cairo_surface_flush(surface);
        uint32_t *dst = (void*) cairo_image_surface_get_data(surface);
        if (!dst) {
            log_error("failed to create icon surface");
            cairo_surface_destroy(surface);
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
        return surface;
    }

    g_object_unref(pixbuf);
    return NULL;
}
