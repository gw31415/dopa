#include "CDopa.h"
#include <spawn.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>

int dopa_spawn_guardian(pid_t *pid, const char *executable, char *const arguments[], char *const environment[]) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result) return result;
    result = posix_spawnattr_init(&attributes);
    if (result) { posix_spawn_file_actions_destroy(&actions); return result; }
    // Inherit no unrelated descriptors. Unlike Foundation.Process, do not make
    // the child a process-group leader: its setsid must succeed after exec.
    result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    // POSIX_SPAWN_CLOEXEC_DEFAULT closes inherited descriptors unless they
    // appear in the file actions. Preserve stderr for guardian diagnostics.
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);
    if (!result) result = posix_spawn(pid, executable, &actions, &attributes, arguments, environment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}

int dopa_poll_guardian(pid_t pid, int *status) {
    if (!status) { errno = EINVAL; return -1; }
    int raw;
    pid_t result;
    do { result = waitpid(pid, &raw, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result == 0) return 0;
    if (result < 0) return -1;
    *status = WIFEXITED(raw) ? WEXITSTATUS(raw) : 128 + WTERMSIG(raw);
    return 1;
}
