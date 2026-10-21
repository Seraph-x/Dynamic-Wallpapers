#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <mpv/render.h>

// Observe calls made by the product, forwarding arguments/results unchanged to libmpv.
// PRESENT after a successful render may already describe the *next* queued frame.
static thread_local unsigned successfulSkips;
static int ObserveRender(mpv_render_context *context, mpv_render_param *params) {
    BOOL skip = NO;
    for (mpv_render_param *param = params; param->type != MPV_RENDER_PARAM_INVALID; ++param)
        if (param->type == MPV_RENDER_PARAM_SKIP_RENDERING) skip = *(int *)param->data != 0;
    int result = mpv_render_context_render(context, params);
    if (skip && result >= 0) ++successfulSkips;
    return result;
}
// Compile the actual product implementation. All injection stays in this test executable.
#ifndef DW_MPV_BRIDGE_IMPLEMENTATION
#define DW_MPV_BRIDGE_IMPLEMENTATION "../../Sources/MPVBridge/MPVBridge.mm"
#endif
#define mpv_render_context_render ObserveRender
#import DW_MPV_BRIDGE_IMPLEMENTATION
#undef mpv_render_context_render

@interface PendingFrameBridge : DWMPVBridge
@property(nonatomic, copy) void (^observed)(uint64_t, unsigned);
@end

@implementation PendingFrameBridge {
    unsigned _presentCount;
    BOOL _injected, _reported;
    uint64_t _injectedFlags;
    unsigned _skipsBeforeFailure;
}

- (mpv_render_context *)context {
    Ivar ivar = class_getInstanceVariable(DWMPVBridge.class, "_render");
    NSCAssert(ivar != nullptr, @"Product render context ivar changed");
    mpv_render_context *context = nullptr;
    memcpy(&context, (const char *)(__bridge void *)self + ivar_getOffset(ivar), sizeof(context));
    return context;
}

- (uint64_t)actualFlags {
    mpv_render_frame_info info = {};
    mpv_render_param query = {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info};
    int result = mpv_render_context_get_info([self context], query);
    NSCAssert(result >= 0, @"Real frame query failed: %d", result);
    fprintf(stderr, "FRAME info flags=%llu target_time=%lld\n", info.flags, info.target_time);
    return info.flags;
}

- (BOOL)renderSize:(int *)size {
    uint64_t flags = [self actualFlags];
    if (!_injected && (flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
        !(flags & (MPV_RENDER_FRAME_INFO_REDRAW | MPV_RENDER_FRAME_INFO_REPEAT)) && ++_presentCount == 2) {
        _injected = YES;
        _injectedFlags = flags;
        _skipsBeforeFailure = successfulSkips;
        fprintf(stderr, "INJECT real NEXT_FRAME_INFO.flags=%llu at second decoded PRESENT\n", flags);
        [self fail:MPVError(MPV_ERROR_INVALID_PARAMETER, @"Injected render dimensions failure")];
        return NO;
    }
    return [super renderSize:size];
}

- (void)drainRender {
    [super drainRender];
    if (!_injected || _reported) return;
    _reported = YES;
    uint64_t after = [self actualFlags], before = _injectedFlags;
    unsigned skips = successfulSkips - _skipsBeforeFailure;
    fprintf(stderr, "OBSERVE after product drain NEXT_FRAME_INFO.flags=%llu successful_product_skips=%u\n", after, skips);
    dispatch_async(dispatch_get_main_queue(), ^{ self.observed(before, skips); });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: pending-frame MEDIA\n"); return 64; }
        [NSApplication sharedApplication];
        PendingFrameBridge *bridge = [[PendingFrameBridge alloc] initWithWidth:64 height:64 fill:NO];
        __block BOOL gotFailure = NO, started = NO;
        __weak PendingFrameBridge *weakBridge = bridge;
        bridge.observed = ^(uint64_t before, unsigned skips) {
            PendingFrameBridge *bridge = weakBridge;
            BOOL passed = gotFailure && started && (before & MPV_RENDER_FRAME_INFO_PRESENT) &&
                skips == 1;
            if (!passed) fprintf(stderr, "ASSERT FAILED: product must consume failed pending PRESENT before drain returns\n");
            NSError *error = nil;
            BOOL controlled = [bridge setMuted:YES volume:0 error:&error] && [bridge setPaused:YES error:&error];
            if (!controlled) fprintf(stderr, "CONTROL FAILED: %s\n", error.description.UTF8String);
            [bridge closeWithCompletion:^{
                fprintf(stderr, "CLOSED actual bridge resources; result=%s\n", passed && controlled ? "PASS" : "FAIL");
                exit(passed && controlled ? 0 : 1);
            }];
        };
        [bridge startPath:@(argv[1]) frame:^(NSData *, NSDictionary *) {
            if (started) return;
            started = YES;
            NSError *error = nil;
            if (![bridge setPaused:NO error:&error]) {
                fprintf(stderr, "START FAILED: %s\n", error.description.UTF8String); exit(2);
            }
        } failure:^(NSError *error) {
            gotFailure = [error.localizedDescription containsString:@"Injected render dimensions failure"];
            fprintf(stderr, "FAILURE callback: %s\n", error.localizedDescription.UTF8String);
            if (!gotFailure) exit(2);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "TIMEOUT: pending-frame scenario did not finish\n"); exit(124);
        });
        [NSApp run];
    }
}
