#ifndef DSH_LINUX_GUEST_SHA256_CORE_H
#define DSH_LINUX_GUEST_SHA256_CORE_H

#include <stddef.h>
#include <stdint.h>

/* Portable SHA-256 core shared by native FD verification and host WASM vectors. */
void dsh_guest_sha256(const uint8_t *input, size_t length, uint8_t output[32]);

#endif
