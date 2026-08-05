#include <stdio.h>
#include <stdlib.h>

#include "parasa.h"
#include "foundations.h"
#include "parasa_helpers.h"

typedef void (* menu_func_f)(void *);

typedef
struct menu_item_s {
	char const * name;
	menu_func_f func;
}
menu_item_t;

typedef
struct menu_listing_s {
	char const * key;
	menu_item_t * vals;
}
menu_listing_t;

 menu_listing_t menu_listing[] = {
	{"NEW", (menu_item_t []) {
		{"FOUNDATION", new_foundation},
		{"CONTAINER", new_container},
	}},
};

void draw_main_menu() {

}

int main(int argc, char *argv[]) {
	if (parasa_load_config(argv[1])) {
		fprintf(stderr, "failed to load config %s", argv[1] ? argv[1] : "DEFAULT");
		return 1;
	}

	// 1. Initialize global libzfs instance handle
	if (!libzfs_core_init()) {
        fprintf(stderr, "Failed to initialize libzfs\n");
        return 1;
    }
	int fix_mode = 0;
	if (parasa_doctor(fix_mode)) {

	}

	draw_main_menu();
	libzfs_core_fini();
	return EXIT_SUCCESS;
}
