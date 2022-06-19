#ifndef ILBAR_CONFIG_H
#define ILBAR_CONFIG_H

#include <cj.h>

typedef struct {
    char *font;
    int font_size;
    int height;
    int margin;
    int width;

    /** generated - the height of the font */
    double font_height;
} Config;

/** Load the default configuration. */
void config_defaults(Config *config);

/** Parse a configuration file. */
void config_parse(Config *config, const CJValue *value);

/** Generate additional fields. */
void config_process(Config *config);

/** Free a configuration oject. */
void config_deinit(Config *config);

#endif
