// rlottie's own stb_image.cpp.o is stripped from librlottie.a at
// build time (see Rakefile): it embeds a jpeg/png-only stb_image
// build that duplicates every stbi_* symbol sokol_shim.o already
// carries — a hard duplicate-symbol error on Mach-O. This glue
// re-provides the three lottie_image_* entry points VImageLoader
// binds to, forwarding to the sokol shim's full stb_image (bonus:
// GIF/PIC decoding for image-bearing lottie files works too).
//
// Declared, not #include'd: the prototypes are stable stb_image /
// rlottie C ABI, and this keeps the file include-path-free.

#ifdef __cplusplus
extern "C" {
#endif

// stb_image (implemented in backend/sokol_shim.c)
unsigned char *stbi_load(char const *filename, int *x, int *y,
                         int *comp, int req_comp);
unsigned char *stbi_load_from_memory(unsigned char const *buffer, int len,
                                     int *x, int *y, int *comp, int req_comp);
void stbi_image_free(void *retval_from_stbi_load);

// rlottie module API (referenced by src/vector/vimageloader.cpp)
unsigned char *lottie_image_load(char const *filename, int *x, int *y,
                                 int *comp, int req_comp)
{
    return stbi_load(filename, x, y, comp, req_comp);
}

unsigned char *lottie_image_load_from_data(const char *imageData, int len,
                                           int *x, int *y, int *comp,
                                           int req_comp)
{
    return stbi_load_from_memory(
        (const unsigned char *)imageData, len, x, y, comp, req_comp);
}

void lottie_image_free(unsigned char *data)
{
    stbi_image_free(data);
}

#ifdef __cplusplus
}
#endif
