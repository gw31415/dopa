#include "CDopa.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

pid_t dopa_spawn_pam_sudo(const char *command, const char *prompt, int *master_fd) {
  if (command == NULL || prompt == NULL || master_fd == NULL) {
    errno = EINVAL;
    return -1;
  }

  int descriptor_bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
  struct proc_fdinfo *descriptors = NULL;
  int descriptor_count = 0;
  if (descriptor_bytes > 0) {
    // Allow a little room for descriptors opened between the sizing and read calls.
    descriptor_bytes += (int)(16 * sizeof(struct proc_fdinfo));
    descriptors = malloc((size_t)descriptor_bytes);
    if (descriptors != NULL) {
      int bytes_read = proc_pidinfo(
          getpid(), PROC_PIDLISTFDS, 0, descriptors, descriptor_bytes);
      if (bytes_read > 0) {
        descriptor_count = bytes_read / (int)sizeof(struct proc_fdinfo);
      }
    }
  }
  int master = -1;
  pid_t child = forkpty(&master, NULL, NULL, NULL);
  if (child < 0) {
    free(descriptors);
    return -1;
  }
  if (child == 0) {
    char *const arguments[] = {
        "/usr/bin/sudo", "-k", "-p", (char *)prompt, "--", "/bin/sh", "-c",
        (char *)command, NULL,
    };
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    sigprocmask(SIG_SETMASK, &empty_mask, NULL);
    struct sigaction default_action = {.sa_handler = SIG_DFL};
    sigemptyset(&default_action.sa_mask);
    const int reset_signals[] = {
        SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU,
    };
    for (size_t index = 0; index < sizeof(reset_signals) / sizeof(reset_signals[0]); index++) {
      sigaction(reset_signals[index], &default_action, NULL);
    }
    if (descriptors != NULL) {
      for (int index = 0; index < descriptor_count; index++) {
        int descriptor = descriptors[index].proc_fd;
        if (descriptor >= 3) {
          close(descriptor);
        }
      }
    } else {
      // proc_pidinfo is expected to work for our own process. Retain a bounded
      // fallback so a diagnostic failure cannot leak the app's common low FDs.
      for (int descriptor = 3; descriptor < 1024; descriptor++) {
        close(descriptor);
      }
    }
    execve("/usr/bin/sudo", arguments, environ);
    _exit(127);
  }

  free(descriptors);
  int descriptor_flags = fcntl(master, F_GETFD);
  int status_flags = fcntl(master, F_GETFL);
  if (descriptor_flags < 0 || status_flags < 0
      || fcntl(master, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0
      || fcntl(master, F_SETFL, status_flags | O_NONBLOCK) < 0) {
    int saved_errno = errno;
    close(master);
    kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    errno = saved_errno;
    return -1;
  }
  *master_fd = master;
  return child;
}
