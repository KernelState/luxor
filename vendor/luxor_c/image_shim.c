// Decoders that are painful or setjmp-heavy to call from Zig: libpng, libjpeg,
// libwebp and nanosvg (SVG). Each produces a flat RGBA8888 buffer (and width /
// height). Buffers are malloc'd and must be released with `luxor_free_image`,
// which pairs with the allocator used (libwebp uses free-compatible pointers).
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

#include <png.h>
#include <jpeglib.h>
#include <webp/decode.h>

/* ------------------------------- PNG ------------------------------------- */
static void png_read_mem(png_structp png, png_bytep out, size_t bytes) {
    png_voidp io_ptr = png_get_io_ptr(png);
    png_bytep* base = (png_bytep*)io_ptr;
    memcpy(out, *base, bytes);
    *base += bytes;
}

unsigned char* luxor_decode_png(const void* data, size_t len, int* w, int* h) {
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) return NULL;
    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, NULL, NULL);
        return NULL;
    }
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &info, NULL);
        return NULL;
    }

    // Route reads over an in-memory cursor.
    png_bytep base = (png_bytep)data;
    png_set_read_fn(png, &base, png_read_mem);

    png_read_info(png, info);
    png_uint_32 pw = 0, ph = 0;
    int bitdepth = 0, colortype = 0;
    png_get_IHDR(png, info, &pw, &ph, &bitdepth, &colortype, NULL, NULL, NULL);

    // Normalize everything to 8-bit RGBA.
    if (colortype == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (colortype == PNG_COLOR_TYPE_GRAY && bitdepth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (bitdepth == 16) png_set_strip_16(png);
    if (colortype == PNG_COLOR_TYPE_GRAY || colortype == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(png);
    if (colortype == PNG_COLOR_TYPE_RGB || colortype == PNG_COLOR_TYPE_GRAY) png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    png_read_update_info(png, info);

    png_uint_32 rowbytes = png_get_rowbytes(png, info);
    if (rowbytes != pw * 4) {
        png_destroy_read_struct(&png, &info, NULL);
        return NULL;
    }
    unsigned char* out = (unsigned char*)malloc((size_t)pw * (size_t)ph * 4);
    if (!out) {
        png_destroy_read_struct(&png, &info, NULL);
        return NULL;
    }
    png_bytep* rows = (png_bytep*)malloc(sizeof(png_bytep) * ph);
    for (png_uint_32 y = 0; y < ph; y++) rows[y] = out + (size_t)y * rowbytes;
    png_read_image(png, rows);
    free(rows);
    png_read_end(png, info);
    png_destroy_read_struct(&png, &info, NULL);

    *w = (int)pw;
    *h = (int)ph;
    return out;
}

/* ------------------------------- JPEG ------------------------------------ */
static jmp_buf jpg_jmp;
static void jpg_error_exit(j_common_ptr cinfo) {
    longjmp(jpg_jmp, 1);
}

unsigned char* luxor_decode_jpeg(const void* data, size_t len, int* w, int* h) {
    struct jpeg_decompress_struct cinfo;
    struct jpeg_error_mgr jerr;
    cinfo.err = jpeg_std_error(&jerr);
    jerr.error_exit = jpg_error_exit;
    if (setjmp(jpg_jmp)) {
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, (const unsigned char*)data, len);
    jpeg_read_header(&cinfo, TRUE);
    cinfo.out_color_space = JCS_EXT_RGBA;
    jpeg_start_decompress(&cinfo);

    int pw = (int)cinfo.output_width;
    int ph = (int)cinfo.output_height;
    unsigned char* out = (unsigned char*)malloc((size_t)pw * (size_t)ph * 4);
    if (!out) {
        jpeg_abort_decompress(&cinfo);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }
    int row_stride = pw * 4;
    while (cinfo.output_scanline < cinfo.output_height) {
        unsigned char* row = out + cinfo.output_scanline * row_stride;
        jpeg_read_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);

    *w = pw;
    *h = ph;
    return out;
}

/* ------------------------------- WebP ------------------------------------ */
unsigned char* luxor_decode_webp(const void* data, size_t len, int* w, int* h) {
    unsigned char* out = WebPDecodeRGBA((const uint8_t*)data, len, w, h);
    return out; // free with WebPFree() == free()
}

/* ------------------------------- free ------------------------------------ */
void luxor_free_image(void* p) {
    free(p);
}