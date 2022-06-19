#include <cairo.h>
#include <limits.h>
#include <log.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"

static char default_font[] = "FreeSans";

void config_defaults(Config *config) {
    config->font = default_font;
    config->font_size = 11;
    config->height = 28;
    config->margin = 3;
    config->width = 160;
}

/** Information about a config field. */
typedef struct ConfigField {
    /** The key for this field. */
    const char *key;
    /** The offset into the config structure. */
    size_t offset;
    /** The parser for this field. */
    void (*parse)(
        const struct ConfigField *field, const CJValue *value, void *ptr);
    /** Extra data for the parser. */
    void *data;
} ConfigField;

static void parse_str(
    const ConfigField *field, const CJValue *value, void *ptr) {
    char **str = ptr;

    if (value->type != CJ_STRING) {
        log_error("invalid value for %s", field->key);
        return;
    }

    char *copy = strdup(value->as.string.chars);
    if (!copy) {
        log_error("failed to copy string for %s", field->key);
        return;
    }

    if (*str != field->data) free(*str);
    *str = copy;
}

static void parse_int(
    const ConfigField *field, const CJValue *value, void *ptr) {
    if (value->type != CJ_NUMBER ||
        value->as.number <= 0 ||
        value->as.number > INT_MAX) {
        log_error("invalid value for %s", field->key);
        return;
    }

    *((int*) ptr) = value->as.number;
}

static const ConfigField fields[] = {
    { "font",      offsetof(Config, font),      parse_str, default_font },
    { "font size", offsetof(Config, font_size), parse_int, NULL },
    { "height",    offsetof(Config, height),    parse_int, NULL },
    { "margin",    offsetof(Config, margin),    parse_int, NULL },
    { "width",     offsetof(Config, width),     parse_int, NULL },
    { NULL },
};

void config_parse(Config *config, const CJValue *value) {
    if (value->type != CJ_OBJECT) {
        log_error("config root is not an object");
        return;
    }
    const CJObject *root = &value->as.object;

    for (size_t i = 0; i < root->length; ++i) {
        const char *key = root->members[i].key.chars;
        const CJValue *value = &root->members[i].value;
        for (const ConfigField *field = fields; field->key; ++field) {
            if (strcmp(field->key, key)) continue;
            void *ptr = &((char*) (void*) config)[field->offset];
            field->parse(field, value, ptr);
        }
    }
}

static double get_font_height(Config *config) {
    /* no complete dummy surface available - recording surface is closest */
    cairo_surface_t *target = cairo_recording_surface_create(
        CAIRO_CONTENT_COLOR_ALPHA, NULL);
    cairo_t *cr = cairo_create(target);
    cairo_select_font_face(cr, config->font,
        CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, config->font_size);
    cairo_font_extents_t fe;
    cairo_font_extents(cr, &fe);
    cairo_destroy(cr);
    cairo_surface_destroy(target);
    return fe.height;
}

void config_process(Config *config) {
    config->font_height = get_font_height(config);
}

void config_deinit(Config *config) {
    if (config->font != default_font) free(config->font);
}
