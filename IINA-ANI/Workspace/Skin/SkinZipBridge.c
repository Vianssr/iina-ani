#include "SkinZipBridge.h"
#include <limits.h>
#include <zlib.h>

int skin_inflate_raw(const uint8_t *input, size_t input_size,
                     uint8_t *output, size_t output_capacity,
                     size_t *bytes_read, size_t *bytes_written) {
    z_stream stream = {0};
    if (input_size > UINT_MAX || output_capacity > UINT_MAX) return Z_MEM_ERROR;
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_size;
    stream.next_out = output;
    stream.avail_out = (uInt)output_capacity;
    int status = inflateInit2(&stream, -MAX_WBITS);
    if (status != Z_OK) return status;
    status = inflate(&stream, Z_FINISH);
    *bytes_read = stream.total_in;
    *bytes_written = stream.total_out;
    int end_status = inflateEnd(&stream);
    if (status == Z_STREAM_END && end_status == Z_OK) return Z_OK;
    return status == Z_OK ? Z_BUF_ERROR : status;
}

uint32_t skin_zip_crc32(const uint8_t *bytes, size_t length) {
    uLong value = crc32(0L, Z_NULL, 0);
    while (length) {
        uInt chunk = length > UINT_MAX ? UINT_MAX : (uInt)length;
        value = crc32(value, bytes, chunk);
        bytes += chunk;
        length -= chunk;
    }
    return (uint32_t)value;
}
