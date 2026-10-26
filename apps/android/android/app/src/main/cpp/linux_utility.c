#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "linux_guest_sha256_core.h"

/* APK-packaged fixed utility. It accepts no path, shell source or subprocess. */
int main(int argc, char **argv) {
  if (argc != 2 || argv[0] == NULL || argv[1] == NULL ||
      (strcmp(argv[1], "sha256") != 0 &&
       strcmp(argv[1], "count_bytes") != 0 &&
       strcmp(argv[1], "count_lines") != 0)) {
    fputs("invalid command arguments\n", stderr);
    return 2;
  }

  /* Binder admission caps stdin at 64 KiB; repeat the limit in the child. */
  unsigned char buffer[64 * 1024];
  size_t count = 0;
  uint64_t lines = 0;
  for (;;) {
    unsigned char extra;
    if (count == sizeof(buffer)) {
      size_t received = fread(&extra, 1, 1, stdin);
      if (received != 0) {
        fputs("input too large\n", stderr);
        return 2;
      }
      if (ferror(stdin)) {
        fputs("input read failed\n", stderr);
        return 2;
      }
      break;
    }
    size_t received = fread(buffer + count, 1, sizeof(buffer) - count, stdin);
    for (size_t index = 0; index < received; index++) {
      if (buffer[count + index] == '\n') lines++;
    }
    count += received;
    if (ferror(stdin)) {
      fputs("input read failed\n", stderr);
      return 2;
    }
    if (feof(stdin)) break;
    if (received == 0) {
      fputs("input read made no progress\n", stderr);
      return 2;
    }
  }
  if (strcmp(argv[1], "sha256") == 0) {
    unsigned char digest[32];
    dsh_guest_sha256(buffer, count, digest);
    for (size_t index = 0; index < sizeof(digest); index++) {
      if (printf("%02x", digest[index]) < 0) {
        fputs("output write failed\n", stderr);
        return 2;
      }
    }
    if (fputs("  -\n", stdout) == EOF) {
      fputs("output write failed\n", stderr);
      return 2;
    }
  } else if (strcmp(argv[1], "count_lines") == 0) {
    if (printf("%" PRIu64 "\n", lines) < 0) {
      fputs("output write failed\n", stderr);
      return 2;
    }
  } else {
    if (printf("%zu\n", count) < 0) {
      fputs("output write failed\n", stderr);
      return 2;
    }
  }
  if (fflush(stdout) != 0) {
    fputs("output write failed\n", stderr);
    return 2;
  }
  return 0;
}
