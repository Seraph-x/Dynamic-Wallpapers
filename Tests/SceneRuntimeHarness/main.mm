#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "WebWallpaperBridge.h"
#include <cstdio>
#include <cmath>
#include <stdexcept>
static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static void waitUntil(BOOL (^predicate)(), double timeout, const char* message) {
  double deadline = NSProcessInfo.processInfo.systemUptime + timeout;
  while (!predicate()) {
    if (NSProcessInfo.processInfo.systemUptime > deadline) throw std::runtime_error(message);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
  }
}
static void runFor(double seconds) {
  const double deadline = NSProcessInfo.processInfo.systemUptime + seconds;
  waitUntil(^{ return BOOL(NSProcessInfo.processInfo.systemUptime >= deadline); }, seconds + 1, "run loop deadline");
}
static uint64_t frameHash(DWWebPage* page) {
  CGImageRef image = (__bridge CGImageRef)page.view.layer.contents;
  require(image != nullptr, "no actual scene pixels committed");
  CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
  require(data != nullptr, "scene pixel read failed");
  uint64_t hash = 14695981039346656037ULL;
  const UInt8* bytes = CFDataGetBytePtr(data);
  for (CFIndex i = 0; i < CFDataGetLength(data); ++i) hash = (hash ^ bytes[i]) * 1099511628211ULL;
  CFRelease(data); return hash;
}
static NSPoint pointerMarker(DWWebPage* page) {
  CGImageRef image = (__bridge CGImageRef)page.view.layer.contents;
  require(image != nullptr, "no actual scene pixels for interaction check");
  CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
  require(data != nullptr, "interaction pixel read failed");
  const UInt8* bytes = CFDataGetBytePtr(data);
  const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image), stride = CGImageGetBytesPerRow(image);
  double x = 0, y = 0, count = 0;
  for (size_t row = 0; row < height; ++row) for (size_t column = 0; column < width; ++column) {
    const UInt8* pixel = bytes + row * stride + column * 4;
    if (pixel[0] > 180 && pixel[1] > 150 && pixel[2] < 120) { x += column; y += row; ++count; }
  }
  CFRelease(data);
  require(count > 0, "authored cyan pointer marker was not rendered");
  return NSMakePoint(x / count / width, y / count / height);
}
static void playing(DWWebPage* page, BOOL value) {
  __block bool complete = false; __block NSError* failure = nil;
  [page setScenePlaying:value completion:^(NSError* error) { failure = error; complete = true; }];
  waitUntil(^{ return BOOL(complete); }, 5, "actual scene lifecycle acknowledgement timed out");
  require(!failure, failure.localizedDescription.UTF8String ?: "scene lifecycle failed");
}
int main(int argc, char** argv) { @autoreleasepool {
  if (argc != 7) { fprintf(stderr, "usage: SceneRuntimeHarness FRAMEWORK HELPER CACHE RUNTIME LOOSE PACKAGE\n"); return 64; }
  DWWebCreateApplication(); [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  DWWebRuntime* runtime = [[DWWebRuntime alloc] initWithFrameworkDirectory:@(argv[1]) helperExecutable:@(argv[2]) cacheDirectory:@(argv[3])];
  NSError* error = nil;
  try {
    require([runtime startWithError:&error], error.localizedDescription.UTF8String ?: "CEF start failed");
    DWWebPage* invalid = [runtime scenePageWithProjectRoot:@(argv[5]) runtimeRoot:@(argv[4])
        entry:@"../scene.json" representation:@"loose" sceneID:@"invalid" generation:1
        size:NSMakeSize(320, 180) scale:1 error:&error];
    require(invalid == nil && runtime.activePageCount == 0, "unsafe scene entry created an owned page");
    DWWebPage* cancelled = [runtime scenePageWithProjectRoot:@(argv[5]) runtimeRoot:@(argv[4])
        entry:@"scene.json" representation:@"loose" sceneID:@"cancelled" generation:1
        size:NSMakeSize(320, 180) scale:1 error:&error];
    require(cancelled != nil, "preparation cancellation scene create failed");
    __block bool prestartClosed = false;
    [cancelled closeWithCompletion:^(NSError* value) { prestartClosed = value == nil; }];
    require(prestartClosed && cancelled.closed && runtime.activePageCount == 0, "pre-start cancellation retained scene resources");
    for (int index = 0; index < 2; ++index) {
      __block bool ready = false, closed = false; __block NSError* failure = nil;
      DWWebPage* page = [runtime scenePageWithProjectRoot:@(argv[5 + index]) runtimeRoot:@(argv[4])
          entry:index ? @"scene.pkg" : @"scene.json" representation:index ? @"package" : @"loose"
          sceneID:NSUUID.UUID.UUIDString generation:1 size:NSMakeSize(320, 180) scale:1 error:&error];
      require(page != nil, error.localizedDescription.UTF8String ?: "scene create failed");
      page.onReady = ^{ ready = true; }; page.onError = ^(NSError* value) { failure = value; };
      [page start];
      waitUntil(^{ return BOOL(ready || failure); }, 11, "real scene preparation timeout");
      require(!failure && page.ready, failure.localizedDescription.UTF8String ?: "scene failed readiness");
      require(page.defaultAudioMuted, "CEF default audio output was enabled");
      playing(page, YES);
      uint64_t initial = frameHash(page);
      waitUntil(^{ return BOOL(frameHash(page) != initial || failure); }, 2, "scene animation pixels did not change");
      require(!failure, "scene failed during animation");
      playing(page, NO); runFor(.2);
      uint64_t paused = frameHash(page); runFor(.4);
      require(paused == frameHash(page), "paused scene continued animating");
      playing(page, YES);
      waitUntil(^{ return BOOL(frameHash(page) != paused || failure); }, 2, "resume did not restore animation");
      NSPoint markerBefore = pointerMarker(page);
      const double targetX = markerBefore.x < .5 ? .8 : .2;
      require([page sendScenePointerAtPoint:NSMakePoint(targetX, .3) kind:@"move" error:&error], "pointer move rejected");
      waitUntil(^{ return BOOL(std::abs(pointerMarker(page).x - markerBefore.x) > .2 || failure); },
          2, "scene pointer command did not move rendered pixels");
      require([page sendScenePointerAtPoint:NSMakePoint(.75, .25) kind:@"click" error:&error], "pointer click rejected");
      require([page sendScenePointerAtPoint:NSZeroPoint kind:@"leave" error:&error], "pointer leave rejected");
      require(![page sendScenePointerAtPoint:NSMakePoint(-.1, 0) kind:@"move" error:&error], "out-of-bounds pointer accepted");
      runFor(.1); require(!failure, "scene failed after pointer commands");
      __block bool cancelledCommand = false;
      [page setScenePlaying:NO completion:^(NSError* value) { cancelledCommand = value != nil; }];
      [page closeWithCompletion:^(NSError* value) { failure = value; closed = true; }];
      waitUntil(^{ return BOOL(closed); }, 6, "actual scene resource close timeout");
      require(!failure && page.closed && runtime.activePageCount == 0 && cancelledCommand, "scene resources or command remain owned");
      fprintf(stderr, "SCENE_RUNTIME representation=%s ready=1 animated=1 pauseStable=1 resume=1 pointerPixels=1 cancelledCommand=1 closed=1 frameHash=%llu\n",
          index ? "package" : "loose", static_cast<unsigned long long>(paused));
    }
    require([runtime shutdownWithError:&error], error.localizedDescription.UTF8String ?: "CEF shutdown failed");
    return 0;
  } catch (const std::exception& failure) {
    fprintf(stderr, "SCENE_RUNTIME FAILED %s\n", failure.what()); return 1;
  }
} }
