#import <AppKit/AppKit.h>
#import "WebWallpaperBridge.h"
#include <cstdio>
#include <stdexcept>

void DWRunPageContractTests();

static void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
static void waitUntil(BOOL (^predicate)(void), double seconds, const char* message) {
  const double deadline = NSProcessInfo.processInfo.systemUptime + seconds;
  while (!predicate()) {
    if (NSProcessInfo.processInfo.systemUptime >= deadline) throw std::runtime_error(message);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
  }
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc != 5) { fprintf(stderr, "usage: WebRuntimeTests FRAMEWORK HELPER CACHE PROJECT\n"); return 64; }
    DWWebCreateApplication();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    DWWebRuntime* runtime = [[DWWebRuntime alloc] initWithFrameworkDirectory:@(argv[1])
        helperExecutable:@(argv[2]) cacheDirectory:@(argv[3])];
    __block NSError* error = nil;
    try {
      require([runtime startWithError:&error], error.localizedDescription.UTF8String ?: "runtime start failed");
      require([runtime startWithError:&error], "starting the same live runtime must reuse it");
      require(runtime.initializationCount == 1, "runtime initialized more than once");
      DWRunPageContractTests();
      NSString* previousOrigin = nil;
      for (int round = 0; round < 2; ++round) {
        __block bool ready = false, closed = false;
        __block NSError* failure = nil;
        DWWebPage* page = [runtime pageWithProjectRoot:@(argv[4]) entry:@"index.html"
            size:NSMakeSize(320, 180) scale:1 error:&error];
        require(page != nil, error.localizedDescription.UTF8String ?: "page creation failed");
        require(page.frameRate == 30, "page did not use the default 30 FPS cap");
        require([page setFrameRate:24 error:&error] && page.frameRate == 24,
                error.localizedDescription.UTF8String ?: "24 FPS cap was not applied");
        require([page setFrameRate:60 error:&error] && page.frameRate == 60,
                error.localizedDescription.UTF8String ?: "60 FPS cap was not applied");
        require([page setFrameRate:30 error:&error] && page.frameRate == 30,
                error.localizedDescription.UTF8String ?: "30 FPS cap was not restored");
        page.onReady = ^{ ready = true; };
        page.onError = ^(NSError* value) { failure = value; };
        require(!page.ready && !page.closed, "page was ready before any CEF frame");
        require(runtime.activePageCount == 1, "page ownership not retained");
        require(![page.origin isEqualToString:previousOrigin], "page origins reused");
        previousOrigin = page.origin;
        [page start];
        waitUntil(^{ return BOOL(ready || failure); }, 10, "real CEF first frame timed out");
        require(!failure, failure.localizedDescription.UTF8String ?: "page failed");
        require(page.ready && page.view.layer.contents, "ready without committed view contents");
        require(page.defaultAudioMuted, "default browser audio was not muted before readiness");
        CGImageRef frame = (__bridge CGImageRef)page.view.layer.contents;
        CFDataRef pixels = CGDataProviderCopyData(CGImageGetDataProvider(frame));
        const auto* bytes = CFDataGetBytePtr(pixels);
        const auto offset = 20 * CGImageGetBytesPerRow(frame) + 20 * 4;
        const bool green = bytes[offset] == 0 && bytes[offset + 1] == 255 && bytes[offset + 2] == 0;
        CFRelease(pixels);
        require(green, "actual Canvas pixels were not delivered through the product bridge");
        NSView* frozenView = page.view;
        [page closeWithCompletion:^(NSError* value) { failure = value; closed = true; }];
        waitUntil(^{ return BOOL(closed); }, 5, "page close completion timed out");
        require(!failure && page.closed && runtime.activePageCount == 0, "page resources not released");
        require(frozenView.layer.contents != nil, "close discarded the paused frame");
        fprintf(stderr, "WEB_RUNTIME round=%d ready=1 closed=1 retainedFrame=1 origin=%s\n", round + 1, page.origin.UTF8String);
      }
      __block bool cancelled = false;
      DWWebPage* pending = [runtime pageWithProjectRoot:@(argv[4]) entry:@"index.html"
          size:NSMakeSize(320, 180) scale:1 error:&error];
      require(pending != nil, "cancel fixture creation failed");
      pending.onReady = ^{ fprintf(stderr, "ERROR: cancelled page became ready\n"); std::abort(); };
      [pending start];
      [pending closeWithCompletion:^(NSError* value) { error = value; cancelled = true; }];
      waitUntil(^{ return BOOL(cancelled); }, 5, "pending page cancellation timed out");
      require(!error && pending.closed && runtime.activePageCount == 0, "pending page did not close");
      require([runtime shutdownWithError:&error], error.localizedDescription.UTF8String ?: "runtime shutdown failed");
      require(runtime.shutdownCount == 1, "runtime shutdown count was not one");
      require(![runtime startWithError:&error] && error != nil, "terminated runtime was reinitialized");
      fprintf(stderr, "WEB_RUNTIME passed initialized=1 shutdown=1 pages=0 sequential=2 cancelled=1\n");
      return 0;
    } catch (const std::exception& failure) {
      fprintf(stderr, "WEB_RUNTIME FAILED %s\n", failure.what());
      NSError* shutdownError = nil;
      if (![runtime shutdownWithError:&shutdownError])
        fprintf(stderr, "WEB_RUNTIME cleanup failed: %s\n", shutdownError.localizedDescription.UTF8String);
      return 1;
    }
  }
}
