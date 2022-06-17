#ifndef ILBAR_RENDER_H
#define ILBAR_RENDER_H

#include <cairo.h>
#include <stdint.h>

/** Render the taskbar. Fails silently. */
void render_taskbar(uint32_t width, uint32_t height, unsigned char *buffer);

#endif
