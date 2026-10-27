/* Enumerate the real FFmpeg7 decoder API without initializing playback or audio. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <libavcodec/avcodec.h>

static void json_string(const char *text) {
    putchar('"');
    for (const unsigned char *value = (const unsigned char *)text; *value; value++) {
        if (*value == '"' || *value == '\\') putchar('\\');
        if (*value < 0x20) printf("\\u%04x", *value);
        else putchar(*value);
    }
    putchar('"');
}

static void *symbol(void *library, const char *name) {
    dlerror();
    void *result = dlsym(library, name);
    const char *error = dlerror();
    if (error || !result) {
        fprintf(stderr, "Required FFmpeg API unavailable: %s: %s\n", name,
                error ? error : "null symbol");
        exit(3);
    }
    return result;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: codec-audit LIBAVCODEC_61_PATH\n");
        return 2;
    }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 3; }
    unsigned (*version)(void) = (unsigned (*)(void))symbol(library, "avcodec_version");
    const AVCodec *(*iterate)(void **) = (const AVCodec *(*)(void **))symbol(library, "av_codec_iterate");
    int (*is_decoder)(const AVCodec *) = (int (*)(const AVCodec *))symbol(library, "av_codec_is_decoder");
    const char *(*name)(enum AVCodecID) = (const char *(*)(enum AVCodecID))symbol(library, "avcodec_get_name");
    const char *(*configuration)(void) = (const char *(*)(void))symbol(library, "avcodec_configuration");
    const char *(*license)(void) = (const char *(*)(void))symbol(library, "avcodec_license");
    unsigned actual_version = version();
    if ((actual_version >> 16) != LIBAVCODEC_VERSION_MAJOR) {
        fprintf(stderr, "FFmpeg ABI differs: actual=%u headers=%u\n",
                actual_version >> 16, LIBAVCODEC_VERSION_MAJOR);
        return 4;
    }
    printf("{\"schema_version\":1,\"libavcodec_version\":%u,\"configuration\":", actual_version);
    json_string(configuration()); printf(",\"license\":"); json_string(license());
    printf(",\"decoders\":[");
    void *opaque = NULL;
    const AVCodec *codec;
    int count = 0;
    while ((codec = iterate(&opaque))) {
        if (!is_decoder(codec)) continue;
        if (count++) putchar(',');
        printf("{\"implementation\":"); json_string(codec->name);
        printf(",\"codec\":"); json_string(name(codec->id));
        printf(",\"codec_id\":%d,\"media_type\":%d,\"capabilities\":%d}",
                codec->id, codec->type, codec->capabilities);
    }
    printf("]}\n");
    if (!count) { fprintf(stderr, "No actual decoders enumerated\n"); return 5; }
    dlclose(library);
    return 0;
}
