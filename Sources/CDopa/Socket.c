#include "CDopa.h"
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int dopa_set_socket_flags(int fd) {
    int descriptor_flags = fcntl(fd, F_GETFD);
    if (descriptor_flags < 0) return -1;
    if (fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) return -1;

    int status_flags = fcntl(fd, F_GETFL);
    if (status_flags < 0) return -1;
    if (fcntl(fd, F_SETFL, status_flags | O_NONBLOCK) < 0) return -1;
    return 0;
}

static int dopa_unix_address(const char *path, struct sockaddr_un *address,
                             socklen_t *length) {
    if (!path) {
        errno = EINVAL;
        return -1;
    }
    size_t path_length = strlen(path);
    if (path_length == 0) {
        errno = EINVAL;
        return -1;
    }
    // sun_path includes the terminating NUL for pathname sockets. Refuse an
    // overlong path instead of allowing a silent truncation.
    if (path_length >= sizeof(address->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }

    memset(address, 0, sizeof(*address));
#ifdef __APPLE__
    address->sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) +
                                 path_length + 1);
#endif
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, path_length + 1);
    *length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + path_length + 1);
    return 0;
}

int dopa_unix_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (dopa_set_socket_flags(fd) == 0) return fd;

    int failure = errno;
    close(fd);
    errno = failure;
    return -1;
}

int dopa_unix_connect(int fd, const char *path) {
    struct sockaddr_un address;
    socklen_t length = 0;
    if (dopa_unix_address(path, &address, &length) != 0) return -1;
    return connect(fd, (const struct sockaddr *)&address, length);
}

int dopa_unix_bind(int fd, const char *path) {
    struct sockaddr_un address;
    socklen_t length = 0;
    if (dopa_unix_address(path, &address, &length) != 0) return -1;
    // The socket inode is created by bind. Keep the process umask restrictive
    // for that operation, then set the exact requested mode while the caller
    // still owns the state-directory lock.
    mode_t previous_umask = umask(0077);
    int result = bind(fd, (const struct sockaddr *)&address, length);
    int failure = errno;
    if (result == 0 && chmod(path, S_IRUSR | S_IWUSR) != 0) {
        result = -1;
        failure = errno;
        (void)unlink(path);
    }
    (void)umask(previous_umask);
    if (result != 0) errno = failure;
    return result;
}

int dopa_unix_listen(int fd, int backlog) {
    return listen(fd, backlog);
}

int dopa_unix_accept(int listener) {
    int fd;
    do { fd = accept(listener, NULL, NULL); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return -1;
    if (dopa_set_socket_flags(fd) == 0) return fd;

    int failure = errno;
    close(fd);
    errno = failure;
    return -1;
}

int dopa_unix_peer_uid(int fd, uid_t *uid) {
    if (!uid) {
        errno = EINVAL;
        return -1;
    }
    gid_t gid = 0;
    return getpeereid(fd, uid, &gid);
}

int dopa_unix_peer_pid(int fd, pid_t *pid) {
#if defined(SOL_LOCAL) && defined(LOCAL_PEERPID)
    if (!pid) {
        errno = EINVAL;
        return -1;
    }
    socklen_t length = (socklen_t)sizeof(*pid);
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pid, &length);
#else
    (void)fd;
    (void)pid;
    errno = ENOTSUP;
    return -1;
#endif
}
