#include "CDopa.h"
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>

static volatile sig_atomic_t stopped = 0;
static void stop_handler(int signal_number) { (void)signal_number; stopped = 1; }
int dopa_stop_requested(void) { return stopped != 0; }
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
