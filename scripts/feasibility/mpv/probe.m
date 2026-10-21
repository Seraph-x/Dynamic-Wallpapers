#import <AppKit/AppKit.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <math.h>

static void checked(int result) {
    if (result < 0) { fprintf(stderr, "mpv error: %s\n", mpv_error_string(result)); exit(2); }
}
static void option(mpv_handle *mpv, const char *key, const char *value) {
    checked(mpv_set_option_string(mpv, key, value));
}
static double number(mpv_handle *mpv, const char *key) {
    double value = 0;
    checked(mpv_get_property(mpv, key, MPV_FORMAT_DOUBLE, &value));
    return value;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) { fprintf(stderr, "usage: probe local-media output.png\n"); return 2; }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 320, 180)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Isolated libmpv feasibility";
    NSImageView *view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
    window.contentView = view;
    [window orderFront:nil];
    mpv_handle *mpv = mpv_create();
    if (!mpv) return 2;
    option(mpv, "config", "no"); option(mpv, "load-scripts", "no");
    option(mpv, "ytdl", "no"); option(mpv, "input-default-bindings", "no");
    option(mpv, "vo", "libmpv"); option(mpv, "ao", "coreaudio");
    option(mpv, "hwdec", "no"); option(mpv, "loop-file", "inf");
    option(mpv, "pause", "yes"); option(mpv, "mute", "yes");
    option(mpv, "volume", "20"); option(mpv, "terminal", "yes");
    option(mpv, "term-status-msg", "");
    checked(mpv_initialize(mpv));
    char *version = mpv_get_property_string(mpv, "mpv-version");
    printf("version=%s\n", version); mpv_free(version);
    char *configuration = mpv_get_property_string(mpv, "mpv-configuration");
    if (!configuration) { fprintf(stderr, "missing mpv-configuration\n"); return 2; }
    printf("mpv_configuration=%s\n", configuration); mpv_free(configuration);
    mpv_render_context *render = NULL;
    mpv_render_param create[] = {{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW}, {0}};
    checked(mpv_render_context_create(&render, mpv, create));
    const char *command[] = {"loadfile", argv[1], NULL};
    checked(mpv_command(mpv, command));
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:320 pixelsHigh:180 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:1280 bitsPerPixel:32];
    int size[] = {320, 180}; size_t stride = 1280;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, "rgba"}, {MPV_RENDER_PARAM_SW_STRIDE, &stride},
        {MPV_RENDER_PARAM_SW_POINTER, bitmap.bitmapData}, {0}};
    double start = NSDate.timeIntervalSinceReferenceDate, playStart = 0, pausePos = 0, previous = 0;
    int frames = 0, loops = 0, phase = 0; BOOL loaded = NO;
    while (NSDate.timeIntervalSinceReferenceDate - start < 10) {
        mpv_event *event;
        while ((event = mpv_wait_event(mpv, 0))->event_id != MPV_EVENT_NONE) {
            if (event->event_id == MPV_EVENT_FILE_LOADED) loaded = YES;
            if (event->event_id == MPV_EVENT_END_FILE) {
                mpv_event_end_file *end = event->data;
                if (end->error < 0) checked(end->error);
            }
        }
        if (mpv_render_context_update(render) & MPV_RENDER_UPDATE_FRAME) {
            checked(mpv_render_context_render(render, params));
            NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(320, 180)];
            [image addRepresentation:bitmap]; view.image = image;
            [view displayIfNeeded]; mpv_render_context_report_swap(render); frames++;
            if (loaded && phase == 0) {
                unsigned char low = 255, high = 0;
                for (int i=0; i<320*180*4; i+=4) { low=MIN(low, bitmap.bitmapData[i]); high=MAX(high, bitmap.bitmapData[i]); }
                if (high - low < 20) { fprintf(stderr,"first frame lacks test-pattern contrast\n"); return 3; }
                NSError *error = nil;
                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (![png writeToFile:@(argv[2]) options:NSDataWritingAtomic error:&error]) { NSLog(@"%@", error); return 3; }
                printf("first_frame rendered=%d contrast=%d NSView=%s\n", frames, high-low, view.window ? "attached" : "missing");
                if (!view.window) return 3;
                char *audio = mpv_get_property_string(mpv, "current-ao");
                if (!audio || !audio[0]) { fprintf(stderr,"FAIL: audio output was not initialized\n"); return 6; }
                printf("audio_output=%s\n", audio); mpv_free(audio);
                checked(mpv_set_property_string(mpv, "mute", "no"));
                checked(mpv_set_property_string(mpv, "pause", "no"));
                playStart = NSDate.timeIntervalSinceReferenceDate; phase=1;
            }
        }
        if (phase) {
            double elapsed = NSDate.timeIntervalSinceReferenceDate-playStart;
            double position = number(mpv,"time-pos");
            if (position < previous-0.5) loops++;
            previous=position;
            if (phase==1 && elapsed>0.7) {
                checked(mpv_set_property_string(mpv,"pause","yes"));
                pausePos=number(mpv,"time-pos"); phase=2;
            } else if (phase==2 && elapsed>1.4) {
                printf("pause delta=%.6f\n", fabs(position-pausePos));
                if (fabs(position-pausePos)>0.05) return 4;
                checked(mpv_set_property_string(mpv,"volume","40"));
                printf("volume readback=%.1f (acoustic output not measured)\n",number(mpv,"volume"));
                if (fabs(number(mpv,"volume")-40)>0.01) return 4;
                checked(mpv_set_property_string(mpv,"pause","no")); phase=3;
            }
            if (phase==3 && loops>=2) break;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    printf("result frames=%d loops=%d phase=%d\n",frames,loops,phase);
    checked(mpv_set_property_string(mpv,"mute","yes"));
    mpv_render_context_free(render); mpv_terminate_destroy(mpv);
    [window orderOut:nil];
    return frames>0 && loops>=2 && phase==3 ? 0 : 5;
} }
