#ifndef LUXOR_IMAGE_SHIM_H
#define LUXOR_IMAGE_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Each returns a malloc'd RGBA8888 buffer and width/height, or NULL on failure.
unsigned char* luxor_decode_png(const void* data, size_t len, int* w, int* h);
unsigned char* luxor_decode_jpeg(const void* data, size_t len, int* w, int* h);
unsigned char* luxor_decode_webp(const void* data, size_t len, int* w, int* h);

// Returns 1 on success and the intrinsic SVG size in SVG units; 0 on failure.
int luxor_svg_natural_size(const char* svg, int* w, int* h);

// Rasterizes `svg` (a mutable, null-terminated buffer) to cover a `tw` by `th`
// box, centered. Returns a malloc'd RGBA8888 buffer of exactly tw*th*4 bytes.
unsigned char* luxor_svg_render(char* svg, int tw, int th, int* w, int* h);

void luxor_free_image(void* p);

#ifdef __cplusplus
}
#endif

#endif