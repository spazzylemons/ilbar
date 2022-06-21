#ifndef ILBAR_ICONS_H
#define ILBAR_ICONS_H

#include <gtk-3.0/gtk/gtk.h>

#include "cache.h"

/** Fetches icons using GTK. */
typedef struct IconManager IconManager;

/** Construct a new icon manager. */
IconManager *icons_init(void);
/** Destroy an icon manager and related resources. */
void icons_deinit(IconManager *icons);
/** Get an icon as a surface. */
cairo_surface_t *icons_get(IconManager *icons, const char *name);

#endif
