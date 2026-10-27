#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE 1
#endif

#define DSH_EXPORT_PATH_BYTES 4096
#define DSH_UNKNOWN_RENAME_ERRNO_BASE 65536

/* Roots are supplied only by the App controller. Staging and workspace paths
 * are fixed here as well, so the JNI entry cannot rename an arbitrary source.
 * This function never uses hardlinks or a replace-capable rename fallback. */
static int directory_at(int parent, const char *name) {
    return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static int sync_directory(int fd) {
    int status;
    do { status = fsync(fd); } while (status < 0 && errno == EINTR);
    return status;
}

static int relative_path(const char *value, int leaf) {
    if (!value[0] || value[0] == '/') return 0;
    const char *start = value;
    for (const char *p = value; ; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '\\' || c == ':' || (c && (c < 32 || c == 127))) return 0;
        if (!c || c == '/') {
            size_t length = (size_t)(p - start);
            if (!length || length > 255 || (length == 1 && start[0] == '.')
                || (length == 2 && start[0] == '.' && start[1] == '.')) return 0;
            if (!c) return 1;
            if (leaf) return 0;
            start = p + 1;
        }
    }
}

static char *utf8_bytes(JNIEnv *env, jbyteArray array) {
    if (!array) return NULL;
    jsize length = (*env)->GetArrayLength(env, array);
    if (length < 1 || length > DSH_EXPORT_PATH_BYTES) return NULL;
    char *text = malloc((size_t)length + 1);
    if (!text) return NULL;
    (*env)->GetByteArrayRegion(env, array, 0, length, (jbyte *)text);
    if ((*env)->ExceptionCheck(env) || memchr(text, 0, (size_t)length)) {
        free(text);
        return NULL;
    }
    text[length] = 0;
    return text;
}

/* -65536-errno preserves an indeterminate rename EIO result. Other negative
 * errno values precede publication; positive errno follows a successful rename. */
static int publish_export(const char *root, const char *source, char *destination) {
    int root_fd = -1, stage_parent_fd = -1, stage_fd = -1, source_fd = -1;
    int workspace_parent_fd = -1, destination_fd = -1;
    int result = -EINVAL;
    struct stat source_stat, named_stat;
    if (root[0] != '/' || !relative_path(source, 1) || !relative_path(destination, 0)) goto done;

    root_fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root_fd < 0) { result = -errno; goto done; }
    stage_parent_fd = directory_at(root_fd, "linux-vm");
    if (stage_parent_fd < 0) { result = -errno; goto done; }
    stage_fd = directory_at(stage_parent_fd, "export-staging");
    if (stage_fd < 0) { result = -errno; goto done; }
    source_fd = openat(stage_fd, source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (source_fd < 0) { result = -errno; goto done; }
    if (fstat(source_fd, &source_stat) < 0) { result = -errno; goto done; }
    if (!S_ISREG(source_stat.st_mode) || source_stat.st_uid != getuid() || source_stat.st_nlink != 1) goto done;

    workspace_parent_fd = directory_at(root_fd, "dsh");
    if (workspace_parent_fd < 0) { result = -errno; goto done; }
    destination_fd = directory_at(workspace_parent_fd, "workspace");
    if (destination_fd < 0) { result = -errno; goto done; }
    char *name = destination;
    for (;;) {
        char *slash = strchr(name, '/');
        if (!slash) break;
        *slash = 0;
        int next = directory_at(destination_fd, name);
        if (next < 0 && errno == ENOENT) {
            if (mkdirat(destination_fd, name, 0700) < 0 && errno != EEXIST) {
                result = -errno;
                goto done;
            }
            if (sync_directory(destination_fd) < 0) { result = -errno; goto done; }
            next = directory_at(destination_fd, name);
        }
        if (next < 0) { result = -errno; goto done; }
        close(destination_fd);
        destination_fd = next;
        name = slash + 1;
    }

    /* The controller exclusively owns this private temporary name until return. */
    if (fstatat(stage_fd, source, &named_stat, AT_SYMLINK_NOFOLLOW) < 0) { result = -errno; goto done; }
    if (!S_ISREG(named_stat.st_mode) || source_stat.st_dev != named_stat.st_dev
        || source_stat.st_ino != named_stat.st_ino) { result = -ESTALE; goto done; }
#ifdef SYS_renameat2
    if (syscall(SYS_renameat2, stage_fd, source, destination_fd, name, RENAME_NOREPLACE) < 0) {
        int failure = errno;
        result = failure == EIO ? -DSH_UNKNOWN_RENAME_ERRNO_BASE - failure : -failure;
        goto done;
    }
#else
    result = -ENOSYS;
    goto done;
#endif

    result = 0;
    if (fstatat(destination_fd, name, &named_stat, AT_SYMLINK_NOFOLLOW) < 0) result = errno;
    else if (!S_ISREG(named_stat.st_mode) || source_stat.st_dev != named_stat.st_dev
        || source_stat.st_ino != named_stat.st_ino) result = ESTALE;
    if (sync_directory(destination_fd) < 0 && result == 0) result = errno;
    if (sync_directory(stage_fd) < 0 && result == 0) result = errno;

done:
    if (destination_fd >= 0) close(destination_fd);
    if (workspace_parent_fd >= 0) close(workspace_parent_fd);
    if (source_fd >= 0) close(source_fd);
    if (stage_fd >= 0) close(stage_fd);
    if (stage_parent_fd >= 0) close(stage_parent_fd);
    if (root_fd >= 0) close(root_fd);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_minnnng_dsh_1android_LinuxVmFilePublisher_publishNative(JNIEnv *env, jobject owner,
    jbyteArray root_bytes, jbyteArray source_bytes, jbyteArray destination_bytes) {
    (void)owner;
    char *root = utf8_bytes(env, root_bytes);
    char *source = utf8_bytes(env, source_bytes);
    char *destination = utf8_bytes(env, destination_bytes);
    int result = -EINVAL;
    if (root && source && destination && !(*env)->ExceptionCheck(env)) {
        result = publish_export(root, source, destination);
    }
    free(destination);
    free(source);
    free(root);
    return result;
}
