#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

/* Debug-only fixed child name. The probe never accepts a path from Binder. */
static const char kChild[] = "fixture.txt";

JNIEXPORT jint JNICALL
Java_com_minnnng_dsh_1android_DebugGuestDirectoryProbe_probeRead(
    JNIEnv* env, jobject self, jint directory_fd, jbyteArray expected) {
  (void)self;
  if (directory_fd < 0 || expected == NULL) return -1;
  const jsize length = (*env)->GetArrayLength(env, expected);
  if (length < 1 || length > 128) return -1;
  int fd = openat(directory_fd, kChild, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return errno;
  unsigned char actual[128];
  size_t offset = 0;
  while (offset < (size_t)length) {
    ssize_t read_count = read(fd, actual + offset, (size_t)length - offset);
    if (read_count <= 0) {
      close(fd);
      return -1;
    }
    offset += (size_t)read_count;
  }
  close(fd);
  jbyte wanted[128];
  (*env)->GetByteArrayRegion(env, expected, 0, length, wanted);
  if ((*env)->ExceptionCheck(env)) return -1;
  return memcmp(actual, wanted, (size_t)length) == 0 ? 0 : -1;
}

JNIEXPORT jint JNICALL
Java_com_minnnng_dsh_1android_DebugGuestDirectoryProbe_probeWrite(
    JNIEnv* env, jobject self, jint directory_fd) {
  (void)env;
  (void)self;
  if (directory_fd < 0) return -1;
  int fd = openat(directory_fd, kChild, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return errno;
  close(fd);
  return 0;
}
