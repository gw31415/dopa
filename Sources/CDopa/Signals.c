#include "CDopa.h"
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>

static volatile sig_atomic_t stopped = 0;
// Self-pipe so a stop signal wakes a thread blocked in poll(): the handler
// sets the flag (the authoritative state) and writes one byte. The read end
// is non-blocking and close-on-exec; readers drain it and re-check the flag.
static int stop_read_fd = -1;
static volatile sig_atomic_t stop_write_fd = -1;
static void stop_handler(int signal_number) {
    int saved_errno = errno;
    (void)signal_number;
    stopped = 1;
    if (stop_write_fd >= 0) {
        char pending = 1;
        (void)write((int)stop_write_fd, &pending, 1);
    }
    errno = saved_errno;
}
int dopa_stop_requested(void) { return stopped != 0; }
int dopa_stop_fd(void) {
    if (stop_read_fd >= 0) return stop_read_fd;
    int fds[2];
    if (pipe(fds) != 0) return -1;
    int read_fd_flags = fcntl(fds[0], F_GETFD);
    int write_fd_flags = fcntl(fds[1], F_GETFD);
    int read_status_flags = fcntl(fds[0], F_GETFL);
    int write_status_flags = fcntl(fds[1], F_GETFL);
    if (read_fd_flags < 0 || write_fd_flags < 0 || read_status_flags < 0 ||
        write_status_flags < 0 ||
        fcntl(fds[0], F_SETFD, read_fd_flags | FD_CLOEXEC) != 0 ||
        fcntl(fds[1], F_SETFD, write_fd_flags | FD_CLOEXEC) != 0 ||
        fcntl(fds[0], F_SETFL, read_status_flags | O_NONBLOCK) != 0 ||
        fcntl(fds[1], F_SETFL, write_status_flags | O_NONBLOCK) != 0) {
        // A blocking write end is unsafe in a signal handler. Abandon the
        // self-pipe entirely and let the daemon use its bounded-poll fallback.
        int saved_errno = errno;
        (void)close(fds[0]);
        (void)close(fds[1]);
        errno = saved_errno;
        return -1;
    }
    stop_read_fd = fds[0];
    stop_write_fd = (sig_atomic_t)fds[1];
    // A stop that arrived before the pipe existed is already recorded in the
    // flag; reflect it so a reader waiting only on the pipe still wakes.
    if (stopped != 0) {
        char pending = 1;
        (void)write((int)stop_write_fd, &pending, 1);
    }
    return stop_read_fd;
}
int dopa_install_signals(void) {
    struct sigaction action = {0};
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);
    const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        if (sigaction(signals[i], &action, NULL) != 0) return -1;
    }
    action.sa_handler = SIG_IGN;
    return sigaction(SIGPIPE, &action, NULL);
}
int dopa_openat(int directory, const char *path, int flags, mode_t mode) {
    return openat(directory, path, flags, mode);
}
int dopa_full_sync(int fd) { return fcntl(fd, F_FULLFSYNC); }
