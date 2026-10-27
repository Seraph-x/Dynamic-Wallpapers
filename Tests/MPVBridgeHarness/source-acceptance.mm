// Compile and exercise the actual product bridge; no synthetic frames or mpv mocks.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../../Sources/MPVBridge/MPVBridge.mm"

static void *NativePointer(DWMPVBridge *bridge, const char *name) {
    Ivar ivar = class_getInstanceVariable(DWMPVBridge.class, name);
    NSCAssert(ivar, @"Product native ivar changed: %s", name);
    void *pointer = nullptr;
    memcpy(&pointer, (const char *)(__bridge void *)bridge + ivar_getOffset(ivar), sizeof(pointer));
    return pointer;
}

@interface SourceAcceptance : NSObject
- (instancetype)initWithMedia:(NSString *)media report:(NSString *)report codec:(NSString *)codec;
- (void)start;
@end

@implementation SourceAcceptance {
    DWMPVBridge *_bridge;
    dispatch_source_t _timer;
    NSString *_media, *_report, *_codec, *_propertyError;
    NSString *_audioOutput, *_audioDecoder, *_videoDecoder, *_actualCodec, *_hwdec, *_fileFormat;
    NSMutableSet<NSNumber *> *_hashes;
    NSMutableDictionary *_settings;
    NSDictionary *_firstMetadata, *_lastMetadata;
    NSData *_firstPixels, *_lastPixels;
    NSUInteger _frames, _loops, _callbacksAfterClose;
    double _lastPosition, _audioMaximum, _sampleRate;
    BOOL _started, _finishing, _pausePending, _pauseVerified, _closeCompleted;
}

- (instancetype)initWithMedia:(NSString *)media report:(NSString *)report codec:(NSString *)codec {
    if ((self = [super init])) {
        _media = media; _report = report; _codec = codec;
        _hashes = [NSMutableSet set]; _settings = [NSMutableDictionary dictionary];
        _bridge = [[DWMPVBridge alloc] initWithWidth:64 height:48 fill:NO];
    }
    return self;
}

- (NSString *)stringProperty:(const char *)name {
    __block NSString *value = nil; __block int status = MPV_ERROR_PROPERTY_UNAVAILABLE;
    dispatch_queue_t queue = (__bridge dispatch_queue_t)NativePointer(_bridge, "_controlQueue");
    dispatch_sync(queue, ^{
        mpv_handle *handle = (mpv_handle *)NativePointer(self->_bridge, "_mpv");
        if (!handle) return;
        char *text = nullptr;
        status = mpv_get_property(handle, name, MPV_FORMAT_STRING, &text);
        if (status >= 0 && text) value = @(text);
        mpv_free(text);
    });
    if (status < 0 && status != MPV_ERROR_PROPERTY_UNAVAILABLE)
        _propertyError = [NSString stringWithFormat:@"Property %s: %s", name, mpv_error_string(status)];
    return value;
}

- (NSNumber *)numberProperty:(NSString *)name {
    NSError *error = nil;
    NSNumber *value = [_bridge numberProperty:name error:&error];
    if (error && error.code != MPV_ERROR_PROPERTY_UNAVAILABLE) _propertyError = error.localizedDescription;
    return value;
}

- (BOOL)checkSettings {
    NSError *error = nil;
    NSNumber *paused = [_bridge flagProperty:@"pause" error:&error];
    NSNumber *muted = [_bridge flagProperty:@"mute" error:&error];
    NSNumber *volume = [self numberProperty:@"volume"];
    if (!paused || !muted || !volume || !paused.boolValue || !muted.boolValue ||
        fabs(volume.doubleValue) > 0.001) return NO;
    _settings[@"initialPause"] = paused; _settings[@"initialMute"] = muted;
    _settings[@"initialVolume"] = volume;
    NSDictionary *expected = @{@"hwdec": @"videotoolbox-copy", @"vo": @"libmpv", @"ao": @"coreaudio",
        @"load-scripts": @"no", @"ytdl": @"no", @"loop-file": @"inf"};
    for (NSString *name in expected) {
        NSString *actual = [self stringProperty:[@"options/" stringByAppendingString:name].UTF8String];
        if (![actual isEqual:expected[name]]) return NO;
        _settings[name] = actual;
    }
    if (![_bridge setMuted:YES volume:31.25 error:&error]) return NO;
    NSNumber *changed = [self numberProperty:@"volume"];
    if (!changed || fabs(changed.doubleValue - 31.25) > 0.001) return NO;
    _settings[@"mutedVolumeReadback"] = changed;
    if (![_bridge setMuted:NO volume:0 error:&error]) return NO;
    NSNumber *unmuted = [_bridge flagProperty:@"mute" error:&error];
    NSNumber *zeroVolume = [self numberProperty:@"volume"];
    if (!unmuted || !zeroVolume || unmuted.boolValue || fabs(zeroVolume.doubleValue) > 0.001) return NO;
    _settings[@"unmutedAtZeroVolume"] = @YES;
    return [_bridge setMuted:YES volume:0 error:&error] && [_bridge setPaused:NO error:&error];
}

- (void)observePixels:(NSData *)pixels metadata:(NSDictionary *)metadata {
    if (_closeCompleted) _callbacksAfterClose++;
    if (_finishing) return;
    NSInteger width = [metadata[@"renderWidth"] integerValue];
    NSInteger height = [metadata[@"renderHeight"] integerValue];
    if (width <= 0 || width > 64 || height <= 0 || height > 48 ||
        pixels.length != (NSUInteger)(width * height * 4)) {
        [self finish:[NSString stringWithFormat:@"Unexpected actual RGBA bytes=%lu for fit render %ldx%ld",
                      pixels.length, width, height]]; return;
    }
    const uint8_t *bytes = (const uint8_t *)pixels.bytes;
    uint64_t hash = 1469598103934665603ULL;
    unsigned minimum = 255, maximum = 0;
    for (NSUInteger index = 0; index < pixels.length; index++) {
        hash = (hash ^ bytes[index]) * 1099511628211ULL;
        if ((index % 4) != 3) { minimum = MIN(minimum, bytes[index]); maximum = MAX(maximum, bytes[index]); }
    }
    if (maximum - minimum < 32) { [self finish:@"Decoded frame lacks expected test-pattern pixels"]; return; }
    [_hashes addObject:@(hash)]; _frames++; _lastMetadata = metadata; _lastPixels = pixels;
    if (_started) return;
    _firstMetadata = metadata; _firstPixels = pixels;
    uint64_t flags = [metadata[@"firstDecodedFrameFlags"] unsignedLongLongValue];
    if (!(flags & MPV_RENDER_FRAME_INFO_PRESENT) ||
        (flags & (MPV_RENDER_FRAME_INFO_REDRAW | MPV_RENDER_FRAME_INFO_REPEAT))) {
        [self finish:@"First actual frame was not decoded PRESENT"]; return;
    }
    if (![self checkSettings]) { [self finish:@"Actual initial/audio setting readback failed"]; return; }
    _started = YES;
}

- (void)verifyPauseAt:(double)position {
    _pausePending = YES;
    NSError *error = nil;
    if (![_bridge setPaused:YES error:&error]) { [self finish:error.localizedDescription]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (self->_finishing) return;
        NSNumber *now = [self numberProperty:@"time-pos"];
        NSError *error = nil;
        NSNumber *paused = [self->_bridge flagProperty:@"pause" error:&error];
        if (!now || !paused.boolValue || fabs(now.doubleValue - position) > 0.08 ||
            ![self->_bridge setPaused:NO error:&error]) {
            [self finish:@"Pause stopped-time/resume check failed"]; return;
        }
        self->_settings[@"pausedClockDelta"] = @(fabs(now.doubleValue - position));
        self->_settings[@"pauseAndResumeVerified"] = @YES;
        self->_pauseVerified = YES; self->_pausePending = NO;
    });
}

- (void)poll {
    if (!_started || _finishing) return;
    NSNumber *position = [self numberProperty:@"time-pos"];
    NSNumber *audio = [self numberProperty:@"audio-pts"];
    _audioOutput = [self stringProperty:"current-ao"];
    _audioDecoder = [self stringProperty:"current-tracks/audio/decoder-desc"];
    _videoDecoder = [self stringProperty:"current-tracks/video/decoder-desc"];
    _actualCodec = [self stringProperty:"current-tracks/video/codec"];
    _hwdec = [self stringProperty:"hwdec-current"];
    _fileFormat = [self stringProperty:"file-format"];
    _sampleRate = [self numberProperty:@"audio-params/samplerate"].doubleValue;
    if (_propertyError) { [self finish:_propertyError]; return; }
    _audioMaximum = MAX(_audioMaximum, audio.doubleValue);
    double duration = [_lastMetadata[@"duration"] doubleValue];
    if (position && _lastPosition > duration * 0.7 && position.doubleValue < duration * 0.25) _loops++;
    if (position) _lastPosition = position.doubleValue;
    if (!_pausePending && !_pauseVerified && position.doubleValue > 0.4)
        [self verifyPauseAt:position.doubleValue];
    if (_frames < 20 || _hashes.count < 8 || !_loops || !_pauseVerified || _audioMaximum < 0.5) return;
    if (![_audioOutput isEqual:@"coreaudio"] || _sampleRate <= 0 || !_audioDecoder.length ||
        ![_actualCodec isEqual:_codec]) { [self finish:@"Decoded audio/video pipeline differs"]; return; }
    BOOL avi = [_media.pathExtension isEqual:@"avi"];
    if ((avi && ![_fileFormat isEqual:@"avi"]) || (!avi && ![_fileFormat containsString:@"matroska"])) {
        [self finish:@"Actual demuxed container differs from the local-format contract"]; return;
    }
    if ([_codec isEqual:@"h264"] && ![_hwdec isEqual:@"videotoolbox-copy"]) {
        [self finish:@"Expected actual H264 VideoToolbox-copy decoding"]; return;
    }
    if ([_codec isEqual:@"av1"] &&
        (![_videoDecoder containsString:@"dav1d"] || ![_hwdec isEqual:@"no"])) {
        [self finish:@"Expected actual dav1d software AV1 decoding"]; return;
    }
    [self finish:nil];
}

- (void)writeResult:(NSString *)failure closed:(BOOL)closed framesAtClose:(NSUInteger)frames {
    BOOL passed = !failure && closed && frames == _frames && !_callbacksAfterClose;
    NSMutableDictionary *result = [@{
        @"schema_version": @1, @"passed": @(passed), @"fixture": _media.lastPathComponent,
        @"videoCodec": _actualCodec ?: @"", @"videoDecoder": _videoDecoder ?: @"",
        @"fileFormat": _fileFormat ?: @"",
        @"hardwareDecoder": _hwdec ?: @"", @"audioOutput": _audioOutput ?: @"",
        @"audioDecoder": _audioDecoder ?: @"", @"audioSampleRate": @(_sampleRate),
        @"maximumAudioPTS": @(_audioMaximum), @"acousticOutputMeasured": @NO,
        @"frameCount": @(_frames), @"distinctPixelHashes": @(_hashes.count), @"loops": @(_loops),
        @"firstFrameMetadata": _firstMetadata ?: @{}, @"lastFrameMetadata": _lastMetadata ?: @{},
        @"settingsReadbacks": _settings, @"nativeHandleAndRendererFreed": @(closed),
        @"callbacksAfterCloseCompletion": @(_callbacksAfterClose), @"failure": failure ?: @""
    } mutableCopy];
    NSError *error = nil;
    NSString *stem = [_report stringByDeletingPathExtension];
    for (NSString *label in @[@"first", @"last"]) {
        NSData *pixels = [label isEqual:@"first"] ? _firstPixels : _lastPixels;
        if (!pixels) continue;
        NSString *path = [stem stringByAppendingFormat:@"-%@.rgba", label];
        if (![pixels writeToFile:path options:NSDataWritingWithoutOverwriting error:&error]) passed = NO;
        result[[label stringByAppendingString:@"RGBAFile"]] = path.lastPathComponent;
    }
    result[@"passed"] = @(passed);
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    if (!json || ![json writeToFile:_report options:NSDataWritingWithoutOverwriting error:&error]) {
        fprintf(stderr, "REPORT FAILED: %s\n", error.description.UTF8String); exit(2);
    }
    fprintf(stderr, "ACTUAL BRIDGE %s: %s frames=%lu distinct=%lu loops=%lu audioPTS=%.3f closed=%d\n",
            passed ? "PASS" : "FAIL", _media.lastPathComponent.UTF8String,
            _frames, _hashes.count, _loops, _audioMaximum, closed);
    exit(passed ? 0 : 1);
}

- (void)finish:(NSString *)failure {
    if (_finishing) return;
    _finishing = YES;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    NSError *error = nil;
    NSString *reportedFailure = failure;
    if (_started && ![_bridge setMuted:YES volume:0 error:&error] && !failure)
        reportedFailure = error.localizedDescription;
    [_bridge closeWithCompletion:^{
        self->_closeCompleted = YES;
        BOOL closed = !NativePointer(self->_bridge, "_mpv") && !NativePointer(self->_bridge, "_render");
        NSUInteger frames = self->_frames;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self writeResult:reportedFailure closed:closed framesAtClose:frames];
        });
    }];
}

- (void)start {
    __weak SourceAcceptance *weakSelf = self;
    [_bridge startPath:_media frame:^(NSData *pixels, NSDictionary *metadata) {
        [weakSelf observePixels:pixels metadata:metadata];
    } failure:^(NSError *error) { [weakSelf finish:error.localizedDescription]; }];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                              100 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ [self poll]; });
    dispatch_resume(_timer);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 55 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self finish:@"Actual native phase did not complete within its 60-second budget"];
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) { fprintf(stderr, "usage: source-acceptance MEDIA REPORT EXPECTED_CODEC\n"); return 64; }
        SourceAcceptance *probe = [[SourceAcceptance alloc] initWithMedia:@(argv[1])
            report:@(argv[2]) codec:@(argv[3])];
        [probe start];
        dispatch_main();
    }
}
