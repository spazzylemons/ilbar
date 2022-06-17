#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "client.h"

#define DEFAULT_HEIGHT 32

static void print_help(const char *name) {
    printf("usage: %s [-h] [-v] [-d display] [-s size]\n", name);
    printf("  -h          display this help and exit\n");
    printf("  -v          display program information and exit\n");
    printf("  -d display  set Wayland display (default: $WAYLAND_DISPLAY)\n");
    printf("  -s size     set taskbar height (default: %d)\n", DEFAULT_HEIGHT);
}

static void print_version(void) {
    printf("ilbar - unversioned build\n");
    printf("copyright (c) 2022 spazzylemons\n");
    printf("license: MIT <https://opensource.org/licenses/MIT>\n");
}

int main(int argc, char *argv[]) {
    const char *display = NULL;
    uint32_t height = DEFAULT_HEIGHT;
    int opt;
    while ((opt = getopt(argc, argv, "hvd:s:")) != -1) {
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
        case 's':
            long new_height = atol(optarg);
            if (new_height <= 0 || new_height > UINT32_MAX) {
                fprintf(stderr, "invalid height: '%s'\n", optarg);
                exit(EXIT_FAILURE);
            }
            height = new_height;
            break;
        default:
            exit(EXIT_FAILURE);
        }
    }

    Client *client = client_init(display, height);
    if (client == NULL) {
        return EXIT_FAILURE;
    }
    client_run(client);
    client_deinit(client);  
    return EXIT_SUCCESS;
}
