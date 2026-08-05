#ifndef PARASA_H
#define PARASA_H

#include <libzfs_core.h>

typedef
struct config_s {
	char const * data_pool;
	char const * const * const data_pool_skel;
	size_t const data_pool_skel_len;

	char const * boot_pool;
	char const * const * const boot_pool_skel;
	size_t const boot_pool_skel_len; 
}
config_t;

extern config_t config;

#endif
