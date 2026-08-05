#include <stdio.h>
#include <string.h>

#include "parasa.h"
#include "parasa_helpers.h"
#include "zfs/zfs_helpers.h"

#define MAX_NAME_LEN 256

static
int check_pool(char const * pool, char const * const * const skeleton, size_t const skel_len, int const do_fix) {
	for (int i = 0; i < skel_len; i++) {
		char fullname[MAX_NAME_LEN];
		strncat(fullname, pool, MAX_NAME_LEN);
		strncat(fullname, "/", MAX_NAME_LEN);
		strncat(fullname, skeleton[i], MAX_NAME_LEN);
		if (!lzc_exists(fullname)) {
			if (do_fix) {
				int err = create_dataset(fullname);
				if (err) return err;
			} else {
				fprintf(stderr, "[DOCTOR]: %s doesn't exist\n", fullname);
				return 1;
			}
		}
	}
	return 0;
}

int parasa_doctor(int do_fix) {
	return check_pool(config.boot_pool, config.boot_pool_skel, config.boot_pool_skel_len, do_fix)
		|| check_pool(config.data_pool, config.data_pool_skel, config.data_pool_skel_len, do_fix)
		;;
}

static
char const * zdata_skeleton[] = {
	"foundations", "container-data", "system-data",
	"parasa.git", "recipes.git", "src.git",
};

static
char const * zboot_skeleton[] = {
	"foundations", "containers", "systems",
	"build",
};

config_t config = {
	.data_pool = "zbamidbar",
	.data_pool_skel = zdata_skeleton,
	.data_pool_skel_len = STACK_ARR_LEN(zdata_skeleton),

	.boot_pool = "zbereshit",
	.boot_pool_skel = zboot_skeleton,
	.boot_pool_skel_len = STACK_ARR_LEN(zboot_skeleton),
};

int parasa_load_config(char const * config_file) {
	if (!config_file) return 0;
	// TODO
	return 0;
}


