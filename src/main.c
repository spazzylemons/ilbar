#include <cj.h>
#include <errno.h>
#include <log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"
#include "client.h"

static void print_help(const char *name) {
    printf("usage: %s [-h] [-v] [-d display] [-c config]\n", name);
    printf("  -h          display this help and exit\n");
    printf("  -v          display program information and exit\n");
    printf("  -d display  set Wayland display (default: $WAYLAND_DISPLAY)\n");
    printf("  -c config   change config file path\n");
}

static void print_version(void) {
    printf("ilbar - unversioned build\n");
    printf("copyright (c) 2022 spazzylemons\n");
    printf("license: MIT <https://opensource.org/licenses/MIT>\n");
}

static void load_default_config(Config *config) {
    config->height = 28;
}

static char *alloc_printf(const char *fmt, ...) {
    va_list arg;
    va_start(arg, fmt);
    int n = vsnprintf(NULL, 0, fmt, arg) + 1;
    va_end(arg);
    if (n <= 0) return NULL;
    char *buf = malloc(n);
    if (!buf) return NULL;
    va_start(arg, fmt);
    vsnprintf(buf, n, fmt, arg);
    va_end(arg);
    return buf;
}

static FILE *open_config_file(const char *config_path) {
    char *generated = NULL;
    if (!config_path) {
        const char *config_home = getenv("XDG_CONFIG_HOME");
        if (config_home) {
            generated = alloc_printf("%s/ilbar/config.json", config_home);
        } else {
            const char *home = getenv("HOME");
            generated = alloc_printf("%s/.config/ilbar/config.json", home);
        }
        if (generated) {
            log_error("unable to allocate config path");
            return NULL;
        }
        config_path = generated;
    }
    FILE *result = fopen(config_path, "r");
    if (!result) {
        log_error(
            "cannot open config file %s: %s", config_path, strerror(errno));
        free(generated);
        return NULL;
    }
    free(generated);
    return result;
}

static void parse_config_file(const CJValue *value, Config *config) {
    if (value->type != CJ_OBJECT) {
        log_error("config root is not an object");
        return;
    }
    const CJObject *root = &value->as.object;

    for (size_t i = 0; i < root->length; ++i) {
        if (strcmp(root->members[i].key.chars, "height") == 0) {
            const CJValue *height = &root->members[i].value;
            if (height->type != CJ_NUMBER ||
                height->as.number <= 0 ||
                height->as.number > UINT32_MAX) {
                log_error("invalid height value");
            } else {
                config->height = height->as.number;
            }
        }
    }
}

static void read_config_file(const char *config_path, Config *config) {
    FILE *file = open_config_file(config_path);
    if (!file) return;

    char buffer[64];
    CJFileReader fr;
    cj_init_file_reader(&fr, file, buffer, sizeof(buffer));
    CJValue json;
    if (cj_parse(NULL, &fr.reader, &json) != CJ_SUCCESS) {
        fclose(file);
        return;
    }
    fclose(file);
    parse_config_file(&json, config);
    cj_free(NULL, &json);
}

int main(int argc, char *argv[]) {
    const char *display = NULL;
    const char *config_path = NULL;
    int opt;
    while ((opt = getopt(argc, argv, "hvd:c:")) != -1) {
        switch (opt) {
        case 'h':
            print_help(argv[0]);
            exit(EXIT_SUCCESS);
        case 'v':
            print_version();
            exit(EXIT_SUCCESS);
        case 'd':
            display = optarg;
            break;
        case 'c':
            config_path = optarg;
            break;
        default:
            exit(EXIT_FAILURE);
        }
    }

    Config config;
    load_default_config(&config);
    read_config_file(config_path, &config);

    Client *client = client_init(display, &config);
    if (client == NULL) {
        return EXIT_FAILURE;
    }
    client_run(client);
    client_deinit(client);
    return EXIT_SUCCESS;
}
