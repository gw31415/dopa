#ifndef C_DOPA_H
#define C_DOPA_H
#include <stdint.h>
#include <sys/types.h>
int dopa_install_signals(void);
int dopa_stop_requested(void);
// Read end of the stop self-pipe for poll()/select() loops. A stop signal
// makes it readable; readers drain it and re-check dopa_stop_requested().
// Returns -1 when the pipe cannot be created (callers fall back to bounded
// polling). Never closed by readers.
int dopa_stop_fd(void);
int dopa_openat(int directory, const char *path, int flags, mode_t mode);
int dopa_full_sync(int fd);
int dopa_unix_socket(void);
int dopa_unix_connect(int fd, const char *path);
int dopa_unix_bind(int fd, const char *path);
int dopa_unix_listen(int fd, int backlog);
int dopa_unix_accept(int listener);
int dopa_unix_peer_uid(int fd, uid_t *uid);
int dopa_unix_peer_pid(int fd, pid_t *pid);
int dopa_spawn_guardian(pid_t *pid, const char *executable, char *const arguments[], char *const environment[]);
int dopa_poll_guardian(pid_t pid, int *status);
pid_t dopa_spawn_pam_sudo(const char *command, const char *prompt, int *master_fd);
// Read/write SleepDisabled through the IOKit SPI, never a subprocess.
int32_t dopa_read_sleep_disabled(int *disabled);
int32_t dopa_set_sleep_disabled(int disabled);
#endif
