#include <cj.h>
#include <errno.h>
#include <log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"
#include "client.h"
#include "util.h"

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

static FILE *open_config_file(const char *config_path) {
    char *generated = NULL;
    if (!config_path) {
        const char *config_home = getenv("XDG_CONFIG_HOME");
        if (config_home) {
            generated = alloc_print("%s/ilbar/config.json", config_home);
        } else {
            const char *home = getenv("HOME");
            generated = alloc_print("%s/.config/ilbar/config.json", home);
        }
        if (!generated) {
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

static void read_config_file(const char *config_path, Config *config) {
    FILE *file = open_config_file(config_path);
    if (!file) return;

    char buffer[64];
    CJFileReader fr;
    cj_init_file_reader(&fr, file, buffer, sizeof(buffer));
    CJValue json;
    if (cj_parse(NULL, &fr.reader, &json) != CJ_SUCCESS) {
        log_error("failed to parse config file");
        fclose(file);
        return;
    }
    fclose(file);
    config_parse(config, &json);
    cj_free(NULL, &json);
}

int main(int argc, char *argv[]) {
    gint dummy_argc = 1;
    gchar *dummy_argv_value[] = { argv[0], NULL };
    gchar **dummy_argv = dummy_argv_value;
    gdk_init(&dummy_argc, &dummy_argv);

    const char *display = NULL;
    const char *config_path = NULL;
    int opt;
    while ((opt = getopt(argc, argv, "hvd:c:")) != -1) {
        switch (opt) {
        case 'h':
            print_help(argv[0]);
            return EXIT_SUCCESS;
        case 'v':
            print_version();
            return EXIT_SUCCESS;
        case 'd':
            display = optarg;
            break;
        case 'c':
            config_path = optarg;
            break;
        default:
            return EXIT_FAILURE;
        }
    }

    Config config;
    config_defaults(&config);
    read_config_file(config_path, &config);
    config_process(&config);

    Client *client = client_init(display, &config);
    if (client == NULL) {
        config_deinit(&config);
        return EXIT_FAILURE;
    }
    client_run(client);
    client_deinit(client);
    config_deinit(&config);
    return EXIT_SUCCESS;
}
