#ifndef ILBAR_RENDER_H
#define ILBAR_RENDER_H

#include <cairo.h>
#include <stdint.h>

#include "client.h"

/** Render the taskbar. Fails silently. */
void render_taskbar(Client *client);

#endif
