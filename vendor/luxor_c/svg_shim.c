// nanosvg-based SVG rasterizer. nanosvg mutates its input and wants it
// null-terminated, so callers pass a mutable copy. Rasterization always fills a
// `tw` by `th` buffer (content scaled to cover, centered); this gives precise
// control over the output size, which is what UI scaling of SVGs needs.
//
// Buffers are malloc'd and released with `luxor_free_image`.
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"

// Returns the SVG's intrinsic width/height (SVG units, from width/height/viewBox).
int luxor_svg_natural_size(const char* svg, int* w, int* h) {
    char* copy = (char*)malloc(strlen(svg) + 1);
    if (!copy) return 0;
    strcpy(copy, svg);
    NSVGimage* img = nsvgParse(copy, "px", 96.0f);
    free(copy);
    if (!img) return 0;
    *w = (int)(img->width + 0.5f);
    *h = (int)(img->height + 0.5f);
    if (*w <= 0) *w = 1;
    if (*h <= 0) *h = 1;
    nsvgDelete(img);
    return 1;
}

unsigned char* luxor_svg_render(char* svg, int tw, int th, int* w, int* h) {
    NSVGimage* img = nsvgParse(svg, "px", 96.0f);
    if (!img) return NULL;
    if (img->width <= 0.0f || img->height <= 0.0f) {
        nsvgDelete(img);
        return NULL;
    }
    if (tw <= 0 || th <= 0) {
        tw = (int)(img->width + 0.5f);
        th = (int)(img->height + 0.5f);
        if (tw <= 0) tw = 1;
        if (th <= 0) th = 1;
    }
    // Scale to cover the target box and center the overflow.
    float sx = (float)tw / img->width;
    float sy = (float)th / img->height;
    float scale = sx > sy ? sx : sy;
    float tx = ((float)tw - img->width * scale) * 0.5f;
    float ty = ((float)th - img->height * scale) * 0.5f;

    unsigned char* out = (unsigned char*)malloc((size_t)tw * (size_t)th * 4);
    if (!out) {
        nsvgDelete(img);
        return NULL;
    }
    memset(out, 0, (size_t)tw * (size_t)th * 4);

    NSVGrasterizer* rast = nsvgCreateRasterizer();
    if (!rast) {
        nsvgDelete(img);
        free(out);
        return NULL;
    }
    nsvgRasterize(rast, img, tx, ty, scale, out, tw, th, tw * 4);
    nsvgDeleteRasterizer(rast);
    nsvgDelete(img);

    *w = tw;
    *h = th;
    return out;
}