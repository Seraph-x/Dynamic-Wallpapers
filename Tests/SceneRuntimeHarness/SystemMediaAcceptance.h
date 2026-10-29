// Included after the harness's main-thread lifecycle/pixel helpers.
#include <initializer_list>
enum class MediaPixelState { empty, ready, metadataOnly };
static bool mediaPixels(DWWebPage* page, MediaPixelState expected) {
  CGImageRef image = (__bridge CGImageRef)page.view.layer.contents;
  if (!image) return false;
  CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
  require(data != nullptr, "system media pixel read failed");
  const UInt8* bytes = CFDataGetBytePtr(data);
  const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image), stride = CGImageGetBytesPerRow(image);
  require(width == 640 && height == 360, "unexpected actual media canvas dimensions");
  const UInt8* status = bytes + 50 * stride + 100 * 4;
  const UInt8* left = bytes + 130 * stride + 250 * 4;
  const UInt8* right = bytes + 130 * stride + 390 * 4;
  const UInt8* previous = bytes + 230 * stride + 250 * 4;
  // CEF submits BGRA; source PNG independently contains red then blue pixels.
  const bool metadata = expected == MediaPixelState::empty
    ? status[2] > 220 && status[0] < 30 && status[1] < 30
    : status[1] > 220 && status[0] < 30 && status[2] < 30;
  const bool artwork = expected == MediaPixelState::ready
    ? left[2] > 220 && left[0] < 30 && right[0] > 220 && right[2] < 30
    : left[0] == 0 && left[1] == 0 && left[2] == 0 && right[0] == 0 && right[1] == 0 && right[2] == 0 && previous[0] == 0 && previous[1] == 0 && previous[2] == 0;
  const bool matches = metadata && artwork;
  CFRelease(data); return matches;
}
static void publishMedia(DWWebPage* page, NSData* bytes, uint64_t revision) {
  __block bool complete = false; __block NSError* failure = nil;
  [page setSceneMediaSnapshotJSONData:bytes mediaRevision:revision completion:^(NSError* error) { failure = error; complete = true; }];
  waitUntil(^{ return BOOL(complete); }, 5, "native media command acknowledgement timed out");
  require(!failure, failure.localizedDescription.UTF8String ?: "native media update failed");
}
static void systemMediaAcceptance(DWWebRuntime* runtime, NSString* runtimeRoot, NSString* fixtures) {
  NSData* actual = [NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:@"actual-media.json"]];
  NSData* empty = [NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:@"empty-media.json"]];
  require(actual != nil && empty != nil, "missing authored media snapshots");
  for (NSString* form in @[@"loose", @"package"]) {
    NSError* creationError = nil;
    DWWebPage* page = [runtime scenePageWithProjectRoot:[fixtures stringByAppendingPathComponent:form] runtimeRoot:runtimeRoot
      entry:[form isEqual:@"loose"] ? @"scene.json" : @"scene.pkg" representation:form sceneID:NSUUID.UUID.UUIDString
      generation:11 size:NSMakeSize(640, 360) scale:1 error:&creationError];
    require(page != nil, creationError.localizedDescription.UTF8String ?: "native media page create failed");
    __block bool ready = false, closed = false; __block NSError* failure = nil;
    NSMutableArray* commands = [NSMutableArray array];
    NSMutableArray* artworkIssues = [NSMutableArray array];
    page.onReady = ^{ ready = true; }; page.onError = ^(NSError* value) { failure = value; };
    page.onSceneMediaControl = ^(NSDictionary* request) { [commands addObject:request]; };
    page.onSceneMediaArtworkError = ^(NSDictionary* issue) { [artworkIssues addObject:issue]; };
    [page start];
    waitUntil(^{ return BOOL(ready || failure); }, 11, "native media preparation timed out");
    require(!failure && ready, failure.localizedDescription.UTF8String ?: "native media preparation failed");
    playing(page, NO);
    for (uint64_t revision : {0ULL, 9007199254740992ULL}) {
      __block bool rejected = false;
      [page setSceneMediaSnapshotJSONData:actual mediaRevision:revision completion:^(NSError* error) { rejected = error != nil; }];
      require(rejected && !failure, "invalid native media revision was dispatched");
    }
    __block bool invalidRejected = false;
    [page setSceneMediaSnapshotJSONData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding] mediaRevision:1
      completion:^(NSError* error) { invalidRejected = error != nil; }];
    require(invalidRejected && !failure, "invalid native media data was dispatched");
    publishMedia(page, actual, 1);
    waitUntil(^{ return BOOL(mediaPixels(page, MediaPixelState::ready) || failure); }, 3, "native metadata/artwork pixels did not commit");
    require(!failure, "native media page failed after actual pixels");
    playing(page, YES);
    NSArray* expected = @[@"play", @"pause", @"playPause", @"skipNext", @"skipPrevious"];
    for (NSUInteger index = 0; index < expected.count; ++index) {
      NSError* pointerError = nil;
      require([page sendScenePointerAtPoint:NSMakePoint((70 + index * 120) / 640., 300 / 360.) kind:@"click" error:&pointerError], "media button pointer rejected");
      waitUntil(^{ return BOOL(commands.count == index + 1 || failure); }, 3, "actual media hook did not reach native callback");
      require(!failure && [commands[index][@"command"] isEqual:expected[index]] && [commands[index][@"mediaRevision"] isEqual:@1], "native media callback changed command or identity");
    }
    playing(page, NO);
    NSMutableDictionary* broken = [[NSJSONSerialization JSONObjectWithData:actual options:0 error:nil] mutableCopy];
    broken[@"thumbnail"] = @"data:image/png;base64,iVBORw0KGgo=";
    NSData* brokenBytes = [NSJSONSerialization dataWithJSONObject:broken options:0 error:nil];
    publishMedia(page, brokenBytes, 2);
    waitUntil(^{ return BOOL((artworkIssues.count == 1 && mediaPixels(page, MediaPixelState::metadataOnly)) || failure); }, 3, "native artwork failure was not independent and visible");
    require(!failure && [artworkIssues[0][@"mediaRevision"] isEqual:@2] && [artworkIssues[0][@"message"] length] > 0, "native artwork failure lost its actual cause/identity");
    publishMedia(page, brokenBytes, 2);
    require(artworkIssues.count == 1, "metadata refresh implicitly retried failed artwork");
    publishMedia(page, brokenBytes, 3);
    waitUntil(^{ return BOOL(artworkIssues.count == 2 || failure); }, 3, "same PNG on a new native identity did not retry");
    require(!failure && [artworkIssues[1][@"mediaRevision"] isEqual:@3], "new artwork failure reused a retired identity");
    publishMedia(page, empty, 4); publishMedia(page, actual, 5);
    waitUntil(^{ return BOOL(mediaPixels(page, MediaPixelState::ready) || failure); }, 3, "native explicit artwork retry did not commit pixels");
    publishMedia(page, empty, 6);
    waitUntil(^{ return BOOL(mediaPixels(page, MediaPixelState::empty) || failure); }, 3, "native media clear did not commit empty pixels");
    require(!failure, "native media page failed while clearing");
    __block bool cancelled = false;
    [page setSceneMediaSnapshotJSONData:actual mediaRevision:7 completion:^(NSError* error) { cancelled = error != nil; }];
    [page closeWithCompletion:^(NSError* error) { failure = error; closed = true; }];
    waitUntil(^{ return BOOL(closed); }, 6, "native media resources did not close");
    require(!failure && cancelled && page.closed && runtime.activePageCount == 0, "native media close retained resources or acknowledged a cancelled update");
    __block bool rejectedClosed = false;
    [page setSceneMediaSnapshotJSONData:actual mediaRevision:8 completion:^(NSError* error) { rejectedClosed = error != nil; }];
    require(rejectedClosed, "closed native media page accepted an update");
    fprintf(stderr, "SCENE_NATIVE_MEDIA PASS representation=%s actualPixels=1 neutralColors=1 fiveNativeControls=1 invalidRejected=1 emptyTexturesClear=1 decoderErrorVisible=1 samePNGNewIdentity=1 explicitRetry=1 closeCancels=1 resourcesReleased=1\n", form.UTF8String);
  }
}
static void systemMediaBoundaryAcceptance(DWWebRuntime* runtime, NSString* runtimeRoot, NSString* fixtures) {
  NSData* authored = [NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:@"actual-media.json"]];
  NSMutableDictionary* probe = [[NSJSONSerialization JSONObjectWithData:authored options:0 error:nil] mutableCopy];
  require(probe != nil, "missing native media boundary data");
  probe[@"title"] = @"trigger-probe"; probe[@"thumbnail"] = NSNull.null;
  NSData* data = [NSJSONSerialization dataWithJSONObject:probe options:0 error:nil];
  for (NSString* mode in @[@"stale", @"frame"]) {
    NSError* error = nil;
    DWWebPage* page = [runtime scenePageWithProjectRoot:[fixtures stringByAppendingPathComponent:[@"boundary-" stringByAppendingString:mode]]
      runtimeRoot:runtimeRoot entry:@"scene.json" representation:@"loose" sceneID:NSUUID.UUID.UUIDString generation:12
      size:NSMakeSize(640, 360) scale:1 error:&error];
    require(page != nil, error.localizedDescription.UTF8String ?: "media boundary page failed");
    __block bool ready = false, frameBlocked = false, closed = false; __block NSError* failure = nil;
    __block NSUInteger commands = 0;
    page.onReady = ^{ ready = true; }; page.onError = ^(NSError* value) { failure = value; };
    page.onSceneMediaControl = ^(NSDictionary*) { ++commands; };
    page.onDiagnostic = ^(NSDictionary* diagnostic) {
      NSString* message = diagnostic[@"message"];
      if ([message isKindOfClass:NSString.class] && [message containsString:@"frame-src"]) frameBlocked = true;
    };
    [page start]; waitUntil(^{ return BOOL(ready || failure); }, 11, "real media boundary preparation timed out");
    require(ready && !failure && frameHash(page) != 0, "boundary probe requires actual engine readiness/pixels");
    __block bool published = false; __block NSError* publishFailure = nil;
    [page setSceneMediaSnapshotJSONData:data mediaRevision:1 completion:^(NSError* value) { publishFailure = value; published = true; }];
    if ([mode isEqual:@"stale"]) {
      waitUntil(^{ return BOOL(failure != nil); }, 3, "stale native media control was not rejected");
      require([failure.localizedDescription containsString:@"Stale or invalid scene event identity"], "stale media rejection lost its actual cause");
    } else {
      waitUntil(^{ return BOOL(frameBlocked && failure); }, 3, "scene iframe attempt was not blocked with a visible error");
      require(frameBlocked && failure && [failure.localizedDescription containsString:@"frame-src"], "actual scene CSP did not expose the blocked iframe error");
    }
    require(commands == 0, "rejected native media control reached a player callback");
    __block NSError* closeFailure = nil;
    [page closeWithCompletion:^(NSError* value) { closeFailure = value; closed = true; }];
    waitUntil(^{ return BOOL(closed); }, 6, "media boundary page did not release resources");
    require(!closeFailure && page.closed && runtime.activePageCount == 0, "media boundary page retained resources");
    require(published, "media boundary left a command completion pending");
    if (publishFailure) fprintf(stderr, "SCENE_NATIVE_MEDIA_BOUNDARY rejected-command mode=%s reason=%s\n", mode.UTF8String, publishFailure.localizedDescription.UTF8String);
    fprintf(stderr, "SCENE_NATIVE_MEDIA_BOUNDARY PASS mode=%s actualEngine=1 blocked=1 callbacks=0 released=1\n", mode.UTF8String);
  }
}
