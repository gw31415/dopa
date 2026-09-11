#ifndef C_DOPA_H
#define C_DOPA_H
#include <stdint.h>
#include <sys/types.h>
int dopa_install_signals(void);
int dopa_stop_requested(void);
int dopa_openat(int directory, const char *path, int flags, mode_t mode);
int dopa_full_sync(int fd);
int dopa_spawn_guardian(pid_t *pid, const char *executable, char *const arguments[], char *const environment[], int channel);
int dopa_wait_guardian(pid_t pid, int *status);
// Read/write SleepDisabled through the IOKit SPI, never a subprocess.
int32_t dopa_read_sleep_disabled(int *disabled);
int32_t dopa_set_sleep_disabled(int disabled);
#endif
