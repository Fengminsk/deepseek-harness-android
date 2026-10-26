#include <stddef.h>

/* Host-only no-libc WASM test glue. Not linked into the Android supervisor. */
void *memset(void *target, int value, size_t count) {
  unsigned char *bytes = target;
  for (size_t i = 0; i < count; ++i) bytes[i] = (unsigned char)value;
  return target;
}

void *memcpy(void *target, const void *source, size_t count) {
  unsigned char *to = target;
  const unsigned char *from = source;
  for (size_t i = 0; i < count; ++i) to[i] = from[i];
  return target;
}
