#include <stdlib.h>

#include "client.h"

int main(void) {
    Client *client = client_init();
    if (client == NULL) {
        return EXIT_FAILURE;
    }
    client_run(client);
    client_deinit(client);  
    return EXIT_SUCCESS;
}
