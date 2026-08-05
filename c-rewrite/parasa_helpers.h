#ifndef PARASA_HELPERS_H
#define PARASA_HELPERS_H

int parasa_load_config(char const * config_file);
int parasa_doctor(int fix_mode);

#define STACK_ARR_LEN(X) sizeof(X) / sizeof(X[0])


#endif
