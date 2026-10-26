#include "linux_guest_children.h"

#include <limits.h>

int dsh_parse_direct_children(const char *data, size_t length, int32_t *out,
                              size_t capacity) {
  if (!data || (!out && capacity)) return -1;
  size_t count = 0;
  size_t index = 0;
  while (index < length) {
    while (index < length && (data[index] == ' ' || data[index] == '\n')) ++index;
    if (index == length) break;
    int32_t pid = 0;
    size_t digits = 0;
    while (index < length && data[index] >= '0' && data[index] <= '9') {
      int digit = data[index++] - '0';
      if (pid > (INT32_MAX - digit) / 10) return -1;
      pid = pid * 10 + digit;
      ++digits;
    }
    if (!digits || pid <= 0 || count >= capacity ||
        (index < length && data[index] != ' ' && data[index] != '\n')) return -1;
    out[count++] = pid;
  }
  return (int)count;
}
