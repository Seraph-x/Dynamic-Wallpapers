// Compile this translation unit instead of compiling WebPage.mm separately.
#import "../../Sources/WebWallpaperBridge/WebPage.mm"
#import <dispatch/dispatch.h>
#include <array>
#include <stdexcept>

namespace {
void requirePageState(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void requireBackgroundThreadRejection(void (^operation)(void), const char* message) {
  __block BOOL rejected = NO;
  __block BOOL ranOnBackgroundThread = NO;
  dispatch_group_t group = dispatch_group_create();
  // dispatch_sync may execute inline on its caller; async guarantees a worker.
  dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    ranOnBackgroundThread = !NSThread.isMainThread;
    @try { operation(); }
    @catch (NSException* error) {
      rejected = [error.name isEqualToString:NSInternalInconsistencyException];
    }
  });
  const auto waitResult = dispatch_group_wait(group,
      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  requirePageState(waitResult == 0, "background thread contract exceeded its 5-second deadline");
  requirePageState(ranOnBackgroundThread, "thread contract must execute on a background thread");
  requirePageState(rejected, message);
}
}

@interface DWPageStateRuntime : DWWebRuntime
@property(nonatomic) NSUInteger retireCount;
@end
@implementation DWPageStateRuntime
- (void)retirePage:(DWWebPage*)page {
  (void)page;
  ++self.retireCount;
}
@end

// Same-translation-unit category access keeps test setup out of production APIs.
@interface DWWebPage (StateContractTests)
- (void)testCloseTimeoutRemainsTerminal:(DWPageStateRuntime*)runtime;
- (void)testReadyErrorRevokesReadiness;
- (void)testIntentionalAudioDisconnect:(DWPageStateRuntime*)runtime;
- (void)testUnexpectedAudioError:(BOOL)duringClose;
- (void)testActiveAudioStreamRestart;
- (void)testOptionalResourceWarningDoesNotFailPlayback;
@end

@implementation DWWebPage (StateContractTests)
- (void)testActiveAudioStreamRestart {
  auto state = _resources->state;
  state->audio = std::make_shared<DWWebAudioBuffer>(0.05);
  auto client = DWMakeWebClient(state);
  auto handler = client->GetAudioHandler();
  CefAudioParameters parameters;
  requirePageState(handler->GetAudioParameters(nullptr, parameters), "actual audio parameters");
  handler->OnAudioStreamStarted(nullptr, parameters, 2);
  requirePageState(state->audio->setGain(0.8, NSProcessInfo.processInfo.systemUptime),
                   "active page must enable its original gain");
  std::array<float, 480> signal; signal.fill(1);
  const float* packet[] = {signal.data(), signal.data()};
  const auto verifyOutput = [&] {
    const auto pts = int64_t(std::ceil((NSProcessInfo.processInfo.systemUptime + 0.02) * 1000));
    handler->OnAudioStreamPacket(nullptr, packet, 480, pts);
    std::array<float, 100> left{}, right{};
    requirePageState(state->audio->render(left.data(), right.data(), 100, double(pts) / 1000 + 0.05),
                     "actual stream output render");
    for (float value : left)
      requirePageState(std::abs(value - 0.8) < 1e-6,
                       "live webpage stream restart must retain actual output on the host audio clock");
  };
  verifyOutput();
  // CEF retires silent capturers while a page remains alive and may restart
  // them later. Exercise the real callback, including its choice of clock.
  handler->OnAudioStreamStopped(nullptr);
  handler->OnAudioStreamStarted(nullptr, parameters, 2);
  verifyOutput();
  requirePageState(state->audio->errorCode() == DWWebAudioError::none,
                   "stream restart must not leave an audio failure");
  state->audio->beginClose(NSProcessInfo.processInfo.systemUptime);
  handler->OnAudioStreamStopped(nullptr);
  state->audio->outputStopped = true;
  requirePageState(state->audio->released(), "restarted stream must still release all callbacks");
}

- (void)testIntentionalAudioDisconnect:(DWPageStateRuntime*)runtime {
  auto state = _resources->state;
  state->audio = std::make_shared<DWWebAudioBuffer>(0.06);
  state->audio->streamStarted(48000, 2, 480);
  state->audio->beginClose(NSProcessInfo.processInfo.systemUptime);
  state->audio->outputStopped = true;
  __block NSUInteger callbacks = 0;
  __block NSError* result = nil;
  [self closeWithCompletion:^(NSError* error) { ++callbacks; result = error; }];
  state->audioStreamError("Socket closed unexpectedly");
  [self tick];
  requirePageState(callbacks == 0 && !self.closed && runtime.retireCount == 0,
      "intentional socket disconnect must still wait for the stream stop barrier");
  state->audio->streamStopped(NSProcessInfo.processInfo.systemUptime);
  [self tick];
  requirePageState(callbacks == 1 && result == nil && self.closed && runtime.retireCount == 1,
      "explicitly closed output with every resource released must finish closing");
  requirePageState([self.audioDiagnostics[@"shutdownDisconnects"] unsignedIntValue] == 1,
      "intentional socket disconnect must remain observable in diagnostics");
  [self tick];
  [self closeWithCompletion:^(NSError* error) { ++callbacks; result = error; }];
  requirePageState(callbacks == 2 && result == nil && runtime.retireCount == 1,
      "repeated successful close must not retire the slot again");
}

- (void)testUnexpectedAudioError:(BOOL)duringClose {
  auto state = _resources->state;
  state->audio = std::make_shared<DWWebAudioBuffer>(0.06);
  state->closing = duringClose;
  // Even the known socket error is fatal unless native output has stopped
  // as part of an explicit close. Other shutdown errors remain fatal too.
  state->audioStreamError("Socket closed unexpectedly");
  requirePageState(!state->failure(duringClose).empty() &&
      state->audio->errorCode() == DWWebAudioError::stream,
      "unexpected stream failure must be reported and gate native output");
}

- (void)testCloseTimeoutRemainsTerminal:(DWPageStateRuntime*)runtime {
  auto state = _resources->state;
  state->closing = true;
  state->browserClosed = false;
  _closeDeadline = 0;
  __block NSUInteger callbacks = 0;
  __block NSError* timeout = nil;
  [self closeWithCompletion:^(NSError* error) { ++callbacks; timeout = error; }];
  [self tick];
  requirePageState(callbacks == 1 && timeout != nil,
                   "expired close deadline must deliver one failure callback");
  requirePageState([timeout.localizedDescription containsString:@"deadline"],
                   "close failure must identify the expired deadline");
  requirePageState(!self.closed && runtime.retireCount == 0,
                   "close timeout must retain the page ownership slot");

  state->browserClosed = true;
  state->clientDestroyed = true;
  state->contextDestroyed = true;
  state->opened = 1;
  state->released = 1;
  [self tick];
  [self tick];
  __block NSError* repeated = nil;
  [self closeWithCompletion:^(NSError* error) { ++callbacks; repeated = error; }];
  requirePageState(callbacks == 2 && repeated == timeout,
                   "repeated close must preserve the original timeout error");
  requirePageState(!self.closed && runtime.retireCount == 0,
                   "late resource release must not convert a timed-out close into success");
}

- (void)testReadyErrorRevokesReadiness {
  const std::array<unsigned char, 4> pixel{0, 255, 0, 255};
  requirePageState([self commitFrame:pixel.data() width:1 height:1],
                   "readiness fixture must commit a real image");
  id committedFrame = self.view.layer.contents;
  requirePageState(committedFrame != nil, "committed frame must exist on the real view layer");
  auto state = _resources->state;
  state->loaded = true;
  state->painted = true;
  __block NSUInteger readyCalls = 0, errorCalls = 0;
  __block NSError* reportedError = nil;
  self.onReady = ^{ ++readyCalls; };
  self.onError = ^(NSError* error) { ++errorCalls; reportedError = error; };
  [self tick];
  requirePageState(self.ready && readyCalls == 1 && errorCalls == 0,
                   "loaded committed frame must make the real page ready once");

  state->fail("Renderer terminated: page-state contract");
  [self tick];
  [self tick];
  requirePageState(errorCalls == 1 &&
                   [reportedError.localizedDescription containsString:@"Renderer terminated"],
                   "post-ready renderer failure must be reported exactly once");
  requirePageState(self.view.layer.contents == committedFrame,
                   "post-ready renderer failure must retain the last committed frame");
  requirePageState(!self.ready && readyCalls == 1,
                   "post-ready renderer failure must revoke readiness without another ready callback");
}

- (void)testOptionalResourceWarningDoesNotFailPlayback {
  auto state = _resources->state;
  state->resourceEvent({"resource-missing-optional", "https://page.invalid/favicon.ico", "not found"});
  requirePageState(state->resourceWarnings == 1 && state->failure(false).empty(),
                   "missing optional favicon must remain observable without failing playback");
  state->resourceEvent({"resource-denied", "https://page.invalid/main.js", "not found"});
  requirePageState(!state->failure(false).empty(),
                   "missing or denied functional resources must remain fatal");
}
@end

void DWRunPageStateTests() {
  std::string failures;
  const auto run = [&](const char* name, const auto& test) {
    @autoreleasepool {
      try {
        DWPageStateRuntime* runtime = [[DWPageStateRuntime alloc]
            initWithFrameworkDirectory:@"/unused-framework" helperExecutable:@"/unused-helper"
            cacheDirectory:@"/unused-cache"];
        DWWebPage* page = [[DWWebPage alloc] initWithRuntime:runtime root:@"/unused-project"
            entry:@"index.html" size:NSMakeSize(1, 1) scale:1];
        test(page, runtime);
        fprintf(stderr, "WEB_PAGE_STATE PASS %s\n", name);
      } catch (const std::exception& error) {
        fprintf(stderr, "WEB_PAGE_STATE FAIL %s: %s\n", name, error.what());
        failures += std::string(name) + ": " + error.what() + "\n";
      }
    }
  };
  run("close-timeout-terminal", [](DWWebPage* page, DWPageStateRuntime* runtime) {
    [page testCloseTimeoutRemainsTerminal:runtime];
  });
  run("ready-error-terminal", [](DWWebPage* page, DWPageStateRuntime*) {
    [page testReadyErrorRevokesReadiness];
  });
  run("intentional-audio-disconnect", [](DWWebPage* page, DWPageStateRuntime* runtime) {
    [page testIntentionalAudioDisconnect:runtime];
  });
  run("running-audio-error", [](DWWebPage* page, DWPageStateRuntime*) {
    [page testUnexpectedAudioError:NO];
  });
  run("unstopped-output-audio-error", [](DWWebPage* page, DWPageStateRuntime*) {
    [page testUnexpectedAudioError:YES];
  });
  run("active-audio-stream-restart", [](DWWebPage* page, DWPageStateRuntime*) {
    [page testActiveAudioStreamRestart];
  });
  run("optional-resource-warning", [](DWWebPage* page, DWPageStateRuntime*) {
    [page testOptionalResourceWarningDoesNotFailPlayback];
  });
  run("runtime-page-thread", [](DWWebPage*, DWPageStateRuntime* runtime) {
    requireBackgroundThreadRejection(^{
      NSError* error = nil;
      [runtime pageWithProjectRoot:@"/unused-project" entry:@"index.html"
          size:NSMakeSize(1, 1) scale:1 error:&error];
    }, "runtime page creation must reject background access even with assertions disabled");
  });
  run("page-view-thread", [](DWWebPage* page, DWPageStateRuntime*) {
    requireBackgroundThreadRejection(^{ (void)page.view; },
        "page view access must reject background access even with assertions disabled");
  });
  run("page-callback-thread", [](DWWebPage* page, DWPageStateRuntime*) {
    requireBackgroundThreadRejection(^{ page.onReady = ^{}; },
        "page callback setter must reject background access even with assertions disabled");
    requireBackgroundThreadRejection(^{ (void)page.onError; },
        "page callback getter must reject background access even with assertions disabled");
  });
  if (!failures.empty()) throw std::runtime_error("Page state contracts failed:\n" + failures);
}
