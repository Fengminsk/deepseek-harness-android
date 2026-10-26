#ifndef DSH_LINUX_GUEST_CHILDREN_H
#define DSH_LINUX_GUEST_CHILDREN_H

#include <stddef.h>
#include <stdint.h>

// Parse one /proc/self/task/<tid>/children snapshot. Returns the PID count,
// or -1 for malformed/truncated input or insufficient output capacity.
int dsh_parse_direct_children(const char *data, size_t length, int32_t *out,
                              size_t capacity);

#endif
