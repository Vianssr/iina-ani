#ifndef SKIN_ZIP_BRIDGE_H
#define SKIN_ZIP_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
int skin_inflate_raw(const uint8_t *input, size_t input_size,
                     uint8_t *output, size_t output_capacity,
                     size_t *bytes_read, size_t *bytes_written);
uint32_t skin_zip_crc32(const uint8_t *bytes, size_t length);
#endif
