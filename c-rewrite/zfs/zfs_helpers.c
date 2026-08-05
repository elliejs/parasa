#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/nvpair.h>
#include <libzfs_core.h>

#include "../parasa_helpers.h"
#include "zfs_helpers.h"

static
char const * zprops_list[][2] = {
	{"atime",       "off"},
	{"compression", "zstd"},
	{"aclmode",     "passthrough"},
	{"mountpoint",  "none"},
	{"canmount",    "noauto"},
};

int create_dataset(char const * name) {
	nvlist_t *props = NULL;

	if (nvlist_alloc(&props, NV_UNIQUE_NAME, 0)) {
		fprintf(stderr, "[ZFS]: Failed to allocate nvlist\n");
		return 1;
	}

	for (int i = 0; i < STACK_ARR_LEN(zprops_list); i++) {
		if (nvlist_add_string(props, zprops_list[i][0], zprops_list[i][1])) {
			fprintf(stderr, "[ZFS]: Failed to add property to nvlist\n");
			nvlist_free(props);
			return 1;
		}
	}

	// LZC_DATSET_TYPE_ZFS  = standard filesystem
	int err = lzc_create(name, LZC_DATSET_TYPE_ZFS, props, NULL, 0);
	if (!err) {
		// lzc_create returns standard errno values (e.g., EEXIST, ENOENT)
		fprintf(stderr, "[ZFS]: Failed to create dataset. Error code: %d\n", err);
	} else {
		printf("[ZFS]: Dataset '%s' created successfully.\n", name);
	}

	nvlist_free(props);
}

