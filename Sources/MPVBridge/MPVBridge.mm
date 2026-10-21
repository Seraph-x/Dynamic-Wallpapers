#import "MPVBridge.h"
#include <mpv/client.h>
#include <mpv/render.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <initializer_list>
#include <sys/stat.h>

static NSError *MPVError(int code, NSString *operation) {
    return [NSError errorWithDomain:@"DynamicWallpaper.MPV" code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %s", operation, mpv_error_string(code)]}];
}

static const mpv_node *MPVNodeField(const mpv_node *node, const char *name) {
    if (node->format != MPV_FORMAT_NODE_MAP) return nullptr;
    for (int index = 0; index < node->u.list->num; index++) {
        if (std::strcmp(node->u.list->keys[index], name) == 0) return &node->u.list->values[index];
    }
    return nullptr;
}

@implementation DWMPVBridge {
    dispatch_queue_t _controlQueue, _renderQueue;
    dispatch_source_t _controlSignal, _renderSignal;
    mpv_handle *_mpv;
    mpv_render_context *_render;
    std::atomic<bool> _closing, _failed;
    BOOL _started, _loaded, _videoReady;
    BOOL _frameInFlight, _needsFrame;
    uint64_t _firstDecodedFrameFlags, _coalescedFrameCount;
    NSInteger _width, _height;
    BOOL _fill;
    NSDictionary *_lastControlMetadata, *_renderMetadata, *_pendingMetadata;
    NSData *_pendingPixels;
    DWMPVBridge *_callbackLifetime;
    DWMPVFrameHandler _frame;
    DWMPVErrorHandler _failure;
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height fill:(BOOL)fill {
    if ((self = [super init])) {
        _width = width; _height = height; _fill = fill;
        _closing.store(false); _failed.store(false);
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        _controlQueue = dispatch_queue_create("local.dynamicwallpaper.mpv.control", attributes);
        _renderQueue = dispatch_queue_create("local.dynamicwallpaper.mpv.render", attributes);
        _controlSignal = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, _controlQueue);
        _renderSignal = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, _renderQueue);
        __weak DWMPVBridge *weakSelf = self;
        dispatch_source_set_event_handler(_controlSignal, ^{ [weakSelf drainControl]; });
        dispatch_source_set_event_handler(_renderSignal, ^{ [weakSelf drainRender]; });
        dispatch_resume(_controlSignal); dispatch_resume(_renderSignal);
    }
    return self;
}

static void WakeControl(void *context) {
    DWMPVBridge *bridge = (__bridge DWMPVBridge *)context;
    dispatch_source_merge_data(bridge->_controlSignal, 1);
}

static void WakeRender(void *context) {
    DWMPVBridge *bridge = (__bridge DWMPVBridge *)context;
    dispatch_source_merge_data(bridge->_renderSignal, 1);
}

- (void)fail:(NSError *)error {
    if (_closing.load() || _failed.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self->_closing.load()) self->_failure(error); });
}

- (BOOL)check:(int)result operation:(NSString *)operation {
    if (result >= 0) return YES;
    [self fail:MPVError(result, operation)];
    return NO;
}

- (void)startPath:(NSString *)path frame:(DWMPVFrameHandler)frame failure:(DWMPVErrorHandler)failure {
    if (_started || _closing.load()) {
        dispatch_async(dispatch_get_main_queue(), ^{ failure(MPVError(MPV_ERROR_INVALID_PARAMETER, @"Repeated or closed start")); });
        return;
    }
    _started = YES;
    _frame = [frame copy]; _failure = [failure copy];
    dispatch_async(_controlQueue, ^{
        if (self->_closing.load()) return;
        const char *filePath = path.fileSystemRepresentation;
        struct stat status;
        NSCharacterSet *nul = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)];
        if (!path.isAbsolutePath || !filePath || [path rangeOfCharacterFromSet:nul].location != NSNotFound ||
            stat(filePath, &status) != 0 || !S_ISREG(status.st_mode) ||
            self->_width < 1 || self->_height < 1 || self->_width > INT_MAX || self->_height > INT_MAX) {
            [self fail:MPVError(MPV_ERROR_INVALID_PARAMETER, @"Local regular media path or render size")]; return;
        }
        self->_mpv = mpv_create();
        if (!self->_mpv) { [self fail:MPVError(MPV_ERROR_NOMEM, @"mpv_create")]; return; }
        if (![self configure]) return;
        if (![self check:mpv_initialize(self->_mpv) operation:@"Initialize"]) return;
        if (![self check:mpv_request_log_messages(self->_mpv, "error") operation:@"Observe decoder errors"]) return;
        for (const char *property : {"dwidth", "dheight", "duration", "hwdec-current"}) {
            if (![self check:mpv_observe_property(self->_mpv, 0, property, MPV_FORMAT_NONE) operation:@"Observe video metadata"]) return;
        }
        self->_callbackLifetime = self;
        mpv_set_wakeup_callback(self->_mpv, WakeControl, (__bridge void *)self);
        // Only control may wait for rendering; rendering never waits for control or main.
        dispatch_sync(self->_renderQueue, ^{
            mpv_render_param create[] = {{MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_SW}, {MPV_RENDER_PARAM_INVALID, nullptr}};
            if ([self check:mpv_render_context_create(&self->_render, self->_mpv, create) operation:@"Create software renderer"])
                mpv_render_context_set_update_callback(self->_render, WakeRender, (__bridge void *)self);
        });
        if (self->_closing.load() || self->_failed.load()) return;
        const char *command[] = {"loadfile", path.fileSystemRepresentation, nullptr};
        [self check:mpv_command(self->_mpv, command) operation:@"Load local media"];
        dispatch_source_merge_data(self->_controlSignal, 1);
    });
}

- (BOOL)configure {
    dispatch_assert_queue(_controlQueue);
    const char *options[][2] = {{"config", "no"}, {"load-scripts", "no"}, {"ytdl", "no"},
        {"input-default-bindings", "no"}, {"input-vo-keyboard", "no"},
        {"access-references", "no"}, {"load-unsafe-playlists", "no"},
        {"sub-auto", "no"}, {"audio-file-auto", "no"}, {"demuxer", "lavf"},
        {"vo", "libmpv"}, {"ao", "coreaudio"}, {"hwdec", "videotoolbox-copy"},
        {"loop-file", "inf"}, {"pause", "yes"}, {"mute", "yes"}, {"volume", "0"}, {"terminal", "no"}};
    for (auto &option : options) {
        if (![self check:mpv_set_option_string(_mpv, option[0], option[1])
                  operation:[NSString stringWithFormat:@"Option %s", option[0]]]) return NO;
    }
    // A node map preserves commas inside the FFmpeg format whitelist.
    char *keys[] = {(char *)"protocol_whitelist", (char *)"format_whitelist"};
    mpv_node values[2] = {};
    values[0].format = MPV_FORMAT_STRING; values[0].u.string = (char *)"file";
    values[1].format = MPV_FORMAT_STRING; values[1].u.string = (char *)"matroska,webm,avi";
    mpv_node_list list = {2, values, keys};
    mpv_node node = {}; node.format = MPV_FORMAT_NODE_MAP; node.u.list = &list;
    return [self check:mpv_set_option(_mpv, "demuxer-lavf-o", MPV_FORMAT_NODE, &node) operation:@"Local container/protocol whitelist"];
}

- (void)drainControl {
    dispatch_assert_queue(_controlQueue);
    if (_closing.load() || !_mpv) return;
    BOOL metadataChanged = NO;
    mpv_event *event;
    while ((event = mpv_wait_event(_mpv, 0))->event_id != MPV_EVENT_NONE) {
        if (event->event_id == MPV_EVENT_FILE_LOADED) { _loaded = [self validateVideoTrack]; metadataChanged = YES; }
        if (event->event_id == MPV_EVENT_VIDEO_RECONFIG) { _videoReady = YES; metadataChanged = YES; }
        if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) metadataChanged = YES;
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = (mpv_event_log_message *)event->data;
            if (log->log_level <= MPV_LOG_LEVEL_ERROR) {
                NSString *message = [NSString stringWithFormat:@"libmpv %s: %s", log->prefix, log->text];
                [self fail:[NSError errorWithDomain:@"DynamicWallpaper.MPV" code:MPV_ERROR_GENERIC
                                          userInfo:@{NSLocalizedDescriptionKey: message}]];
            }
        }
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = (mpv_event_end_file *)event->data;
            _loaded = NO; _videoReady = NO;
            // loop-file loops by seeking; unloading/redirecting this one local file is unexpected.
            int code = end->error < 0 ? end->error : MPV_ERROR_NOTHING_TO_PLAY;
            [self fail:MPVError(code, [NSString stringWithFormat:@"Unexpected playback end (reason %d)", end->reason])];
        }
        if (event->event_id == MPV_EVENT_QUEUE_OVERFLOW)
            [self fail:MPVError(MPV_ERROR_EVENT_QUEUE_FULL, @"Playback event queue overflow")];
        if (event->event_id == MPV_EVENT_SHUTDOWN)
            [self fail:MPVError(MPV_ERROR_UNINITIALIZED, @"Unexpected shutdown")];
    }
    if (metadataChanged && _loaded && _videoReady && !_failed.load()) [self publishMetadata];
}

- (BOOL)validateVideoTrack {
    dispatch_assert_queue(_controlQueue);
    mpv_node tracks = {};
    if (![self check:mpv_get_property(_mpv, "track-list", MPV_FORMAT_NODE, &tracks) operation:@"Read video tracks"]) return NO;
    BOOL selectedVideo = NO;
    if (tracks.format == MPV_FORMAT_NODE_ARRAY) {
        for (int index = 0; index < tracks.u.list->num; index++) {
            const mpv_node *track = &tracks.u.list->values[index];
            const mpv_node *type = MPVNodeField(track, "type");
            const mpv_node *selected = MPVNodeField(track, "selected");
            const mpv_node *albumart = MPVNodeField(track, "albumart");
            if (type && type->format == MPV_FORMAT_STRING && std::strcmp(type->u.string, "video") == 0 &&
                selected && selected->format == MPV_FORMAT_FLAG && selected->u.flag &&
                (!albumart || (albumart->format == MPV_FORMAT_FLAG && !albumart->u.flag))) selectedVideo = YES;
        }
    }
    mpv_free_node_contents(&tracks);
    if (!selectedVideo) [self fail:MPVError(MPV_ERROR_NOTHING_TO_PLAY, @"No selected non-albumart video track")];
    return selectedVideo;
}

- (BOOL)readMetadataProperty:(const char *)name format:(mpv_format)format value:(void *)value {
    dispatch_assert_queue(_controlQueue);
    int result = mpv_get_property(_mpv, name, format, value);
    // A property can be absent until decoder configuration. Observers wake us when it becomes available.
    if (result == MPV_ERROR_PROPERTY_UNAVAILABLE) return NO;
    return [self check:result operation:[NSString stringWithFormat:@"Video metadata %s", name]];
}

- (void)publishMetadata {
    dispatch_assert_queue(_controlQueue);
    int64_t width = 0, height = 0;
    double duration = 0;
    if (![self readMetadataProperty:"dwidth" format:MPV_FORMAT_INT64 value:&width] ||
        ![self readMetadataProperty:"dheight" format:MPV_FORMAT_INT64 value:&height] ||
        ![self readMetadataProperty:"duration" format:MPV_FORMAT_DOUBLE value:&duration]) return;
    if (width <= 0 || height <= 0 || !std::isfinite(duration) || duration <= 0) {
        [self fail:MPVError(MPV_ERROR_INVALID_PARAMETER, @"Invalid video metadata")]; return;
    }
    char *decoder = nullptr;
    if (![self readMetadataProperty:"hwdec-current" format:MPV_FORMAT_STRING value:&decoder]) return;
    NSDictionary *metadata = @{@"width": @(width), @"height": @(height), @"duration": @(duration),
        @"hardwareDecoder": @(decoder), @"controlQueueLabel": @(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL))};
    mpv_free(decoder);
    if ([_lastControlMetadata isEqualToDictionary:metadata]) return;
    _lastControlMetadata = metadata;
    dispatch_async(_renderQueue, ^{
        if (self->_closing.load() || self->_failed.load() || !self->_render) return;
        self->_renderMetadata = metadata;
        self->_needsFrame = YES;
        [self drainRender];
    });
}

- (void)drainRender {
    dispatch_assert_queue(_renderQueue);
    if (!_render) return;
    if (mpv_render_context_update(_render) & MPV_RENDER_UPDATE_FRAME) _needsFrame = YES;
    // Never wait for main-thread delivery: synchronous audio control may be waiting for this renderer.
    if (_needsFrame) [self renderFrame];
}

- (BOOL)renderSize:(int *)size {
    if (!_renderMetadata) { size[0] = (int)_width; size[1] = (int)_height; return YES; }
    double width = [_renderMetadata[@"width"] doubleValue], height = [_renderMetadata[@"height"] doubleValue];
    double x = (double)_width / width, y = (double)_height / height;
    double factor = _fill ? fmax(x, y) : fmin(x, y);
    double w = ceil(width * factor), h = ceil(height * factor);
    if (!std::isfinite(w) || !std::isfinite(h) || w < 1 || h < 1 || w > INT_MAX || h > INT_MAX) {
        [self fail:MPVError(MPV_ERROR_INVALID_PARAMETER, @"Invalid render dimensions")]; return NO;
    }
    size[0] = (int)w; size[1] = (int)h;
    return YES;
}

- (void)discardPendingFrame {
    int skip = 1;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_SKIP_RENDERING, &skip}, {MPV_RENDER_PARAM_INVALID, nullptr}};
    [self check:mpv_render_context_render(_render, params) operation:@"Drain failed or closing renderer"];
}

- (void)renderFrame {
    dispatch_assert_queue(_renderQueue);
    _needsFrame = NO;
    // Consuming UPDATE_FRAME obligates us to render, even when preparation fails.
    // Drain on this queue without waiting for another callback or synchronous core control.
    if (_closing.load() || _failed.load()) { [self discardPendingFrame]; return; }
    mpv_render_frame_info info = {};
    mpv_render_param query = {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info};
    if (![self check:mpv_render_context_get_info(_render, query) operation:@"Next render frame"]) {
        [self discardPendingFrame]; return;
    }
    int size[2];
    if (![self renderSize:size]) { [self discardPendingFrame]; return; }
    size_t stride = size[0] * (size_t)4;
    if ((size_t)size[1] > SIZE_MAX / stride) {
        [self fail:MPVError(MPV_ERROR_INVALID_PARAMETER, @"Render allocation overflow")];
        [self discardPendingFrame]; return;
    }
    void *memory = calloc((size_t)size[1], stride);
    if (!memory) {
        [self fail:MPVError(MPV_ERROR_NOMEM, @"Allocate render pixels")];
        [self discardPendingFrame]; return;
    }
    NSMutableData *pixels = [[NSMutableData alloc] initWithBytesNoCopy:memory length:stride * size[1] freeWhenDone:YES];
    mpv_render_param params[] = {{MPV_RENDER_PARAM_SW_SIZE, size}, {MPV_RENDER_PARAM_SW_FORMAT, (void *)"rgba"},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, pixels.mutableBytes}, {MPV_RENDER_PARAM_INVALID, nullptr}};
    if (![self check:mpv_render_context_render(_render, params) operation:@"Render RGBA frame"]) return;
    if (!_firstDecodedFrameFlags && (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) &&
        !(info.flags & (MPV_RENDER_FRAME_INFO_REDRAW | MPV_RENDER_FRAME_INFO_REPEAT))) _firstDecodedFrameFlags = info.flags;
    if (!_firstDecodedFrameFlags || !_renderMetadata || _closing.load() || _failed.load()) return;
    NSMutableDictionary *metadata = [_renderMetadata mutableCopy];
    metadata[@"renderWidth"] = @(size[0]); metadata[@"renderHeight"] = @(size[1]);
    metadata[@"firstDecodedFrameFlags"] = @(_firstDecodedFrameFlags);
    metadata[@"renderQueueLabel"] = @(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));
    if (_pendingPixels) _coalescedFrameCount++;
    metadata[@"coalescedFrameCount"] = @(_coalescedFrameCount);
    _pendingPixels = pixels; _pendingMetadata = [metadata copy];
    [self deliverPendingFrame];
}

- (void)deliverPendingFrame {
    dispatch_assert_queue(_renderQueue);
    if (_frameInFlight || !_pendingPixels || _closing.load() || _failed.load()) return;
    NSData *pixels = _pendingPixels; NSDictionary *metadata = _pendingMetadata;
    _pendingPixels = nil; _pendingMetadata = nil; _frameInFlight = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_closing.load() && !self->_failed.load()) self->_frame(pixels, metadata);
        dispatch_async(self->_renderQueue, ^{
            self->_frameInFlight = NO;
            [self deliverPendingFrame];
        });
    });
    // A Core Animation submission is not a vsync; do not opt into report_swap with synthetic timing.
}

- (BOOL)setPaused:(BOOL)paused error:(NSError **)error {
    dispatch_assert_queue_not(_renderQueue);
    __block int result = MPV_ERROR_UNINITIALIZED;
    dispatch_sync(_controlQueue, ^{ if (self->_mpv && !self->_closing.load())
        result = mpv_set_property_string(self->_mpv, "pause", paused ? "yes" : "no"); });
    if (result < 0 && error) *error = MPVError(result, @"Pause");
    return result >= 0;
}

- (BOOL)setMuted:(BOOL)muted volume:(double)volume error:(NSError **)error {
    dispatch_assert_queue_not(_renderQueue);
    __block int result = MPV_ERROR_UNINITIALIZED;
    dispatch_sync(_controlQueue, ^{
        if (!self->_mpv || self->_closing.load()) return;
        result = 0;
        if (muted) result = mpv_set_property_string(self->_mpv, "mute", "yes");
        double level = volume;
        if (result >= 0) result = mpv_set_property(self->_mpv, "volume", MPV_FORMAT_DOUBLE, &level);
        // Apply the new level before unmuting, never briefly expose the previous level.
        if (result >= 0 && !muted) result = mpv_set_property_string(self->_mpv, "mute", "no");
    });
    if (result < 0 && error) *error = MPVError(result, @"Audio settings");
    return result >= 0;
}

- (NSNumber *)numberProperty:(NSString *)name error:(NSError **)error {
    dispatch_assert_queue_not(_renderQueue);
    __block double value = 0; __block int result = MPV_ERROR_UNINITIALIZED;
    dispatch_sync(_controlQueue, ^{ if (self->_mpv && !self->_closing.load())
        result = mpv_get_property(self->_mpv, name.UTF8String, MPV_FORMAT_DOUBLE, &value); });
    if (result < 0) { if (error) *error = MPVError(result, name); return nil; }
    return @(value);
}

- (NSNumber *)flagProperty:(NSString *)name error:(NSError **)error {
    dispatch_assert_queue_not(_renderQueue);
    __block int value = 0; __block int result = MPV_ERROR_UNINITIALIZED;
    dispatch_sync(_controlQueue, ^{ if (self->_mpv && !self->_closing.load())
        result = mpv_get_property(self->_mpv, name.UTF8String, MPV_FORMAT_FLAG, &value); });
    if (result < 0) { if (error) *error = MPVError(result, name); return nil; }
    return @(value != 0);
}

- (void)closeWithCompletion:(void (^)(void))completion {
    _closing.store(true);
    dispatch_async(_controlQueue, ^{
        if (self->_mpv) mpv_set_wakeup_callback(self->_mpv, nullptr, nullptr);
        dispatch_sync(self->_renderQueue, ^{
            if (self->_render) {
                mpv_render_context_set_update_callback(self->_render, nullptr, nullptr);
                mpv_render_context_free(self->_render); self->_render = nullptr;
            }
            self->_pendingPixels = nil; self->_pendingMetadata = nil; self->_renderMetadata = nil;
            dispatch_source_cancel(self->_renderSignal);
        });
        if (self->_mpv) { mpv_terminate_destroy(self->_mpv); self->_mpv = nullptr; }
        self->_lastControlMetadata = nil; self->_callbackLifetime = nil;
        dispatch_source_cancel(self->_controlSignal);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_frame = nil; self->_failure = nil;
            // Older main deliveries have now queued their render ACKs. Drain them before completing close.
            dispatch_async(self->_renderQueue, ^{
                self->_frameInFlight = NO;
                dispatch_async(dispatch_get_main_queue(), completion);
            });
        });
    });
}
@end
