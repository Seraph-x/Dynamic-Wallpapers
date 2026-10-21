#import "WebWallpaperBridge.h"
#import <dispatch/dispatch.h>
#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"
#include <cstdio>
#include <functional>
#include <memory>
#include <algorithm>
#include <atomic>
#include <stdexcept>
#include <string>

namespace {
std::string mode;
unsigned initializeCalls = 0, shutdownCalls = 0, unloadCalls = 0, exitCodeCalls = 0;
std::string failures;
CefRefPtr<CefBrowserProcessHandler> pumpHandler;
unsigned pumpCalls = 0, pumpDepth = 0, maximumPumpDepth = 0;
bool nestNextPump = false;
bool nestedWorkObserved = false;
bool shutdownNextPump = false;
__weak DWWebRuntime* runtimeForPump = nil;
std::atomic<bool> pumpedOffMain{false};

struct PumpObservation {
  unsigned before = 0;
  bool done = false;
  NSTimer* timer = nil;
};

void spinFor(double seconds) {
  const double deadline = NSProcessInfo.processInfo.systemUptime + seconds;
  do {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
  } while (NSProcessInfo.processInfo.systemUptime < deadline);
}

bool waitFor(const std::function<bool()>& predicate, double seconds = .5) {
  const double deadline = NSProcessInfo.processInfo.systemUptime + seconds;
  while (!predicate() && NSProcessInfo.processInfo.systemUptime < deadline) spinFor(.001);
  return predicate();
}

void check(bool condition, const char* message) {
  if (condition) return;
  fprintf(stderr, "WEB_RUNTIME_FAILURE FAIL %s\n", message);
  failures += std::string(message) + "\n";
}

DWWebRuntime* makeRuntime(char** argv) {
  return [[DWWebRuntime alloc] initWithFrameworkDirectory:@(argv[2])
      helperExecutable:@(argv[0]) cacheDirectory:@(argv[3])];
}

void testInitializationFailure(char** argv) {
  DWWebRuntime* runtime = makeRuntime(argv);
  NSError* error = nil;
  check(![runtime startWithError:&error] && error != nil,
        "failed CefInitialize must return a runtime error");
  check(initializeCalls == 1 && runtime.initializationCount == 0,
        "failed initialization must be attempted once and never count as successful");
  check([error.userInfo[@"CEFInitializationExitCode"] intValue] == 72,
        "failed initialization must expose the mandatory process exit code to the application");
  for (int attempt = 0; attempt < 2; ++attempt) {
    error = nil;
    check(![runtime shutdownWithError:&error] && error != nil,
          "shutdown after failed initialization must preserve the terminal error");
  }
  error = nil;
  check(![runtime startWithError:&error] && error != nil,
        "failed runtime must not restart");
  DWWebRuntime* another = makeRuntime(argv);
  error = nil;
  check(![another startWithError:&error] && error != nil,
        "a second runtime must be rejected after a process initialization attempt");
  check([error.localizedDescription containsString:@"不能重新初始化"],
        "second runtime rejection must come from the process lifecycle guard, not duplicate library loading");
  check(initializeCalls == 1, "a second runtime must not call CefInitialize again");
  check(shutdownCalls == 0 && runtime.shutdownCount == 0,
        "failed initialization must never call CefShutdown");
}

void testUnloadFailure(char** argv) {
  DWWebRuntime* runtime = makeRuntime(argv);
  NSError* error = nil;
  check([runtime startWithError:&error] && error == nil,
        "injected successful initialization must enter the real runtime started state");
  check(initializeCalls == 1 && runtime.initializationCount == 1,
        "successful initialization must be counted exactly once");
  for (int attempt = 0; attempt < 2; ++attempt) {
    error = nil;
    check(![runtime shutdownWithError:&error] && error != nil,
          "failed library unload must remain an error on every shutdown call");
  }
  check(shutdownCalls == 1 && runtime.shutdownCount == 1,
        "repeated shutdown after unload failure must not call CefShutdown again");
  check(unloadCalls >= 1, "unload failure fixture must exercise cef_unload_library");
}

void testExternalPump(char** argv) {
  DWWebRuntime* runtime = makeRuntime(argv);
  __block NSError* error = nil;
  check([runtime startWithError:&error] && error == nil, "external pump runtime must start");
  if (!pumpHandler) throw std::runtime_error("initialization must expose the browser process handler");
  check(waitFor([] { return pumpCalls > 0; }), "initialization-scheduled work must reach the main-thread pump");
  unsigned before = pumpCalls;
  spinFor(.08);
  check(pumpCalls == before && ![[runtime valueForKey:@"pumpTimer"] isValid],
        "an idle runtime must not wake the main thread for maintenance work");
  check(![[runtime valueForKey:@"timer"] isValid],
        "an idle runtime must not retain the page lifecycle timer");

  DWWebPage* idlePage = [runtime pageWithProjectRoot:NSTemporaryDirectory() entry:@"index.html"
      size:NSMakeSize(16, 9) scale:1 error:&error];
  check(idlePage != nil && error == nil && runtime.activePageCount == 1,
        "page creation must enter the active runtime lifecycle");
  check([[runtime valueForKey:@"timer"] isValid],
        "an active page must start lifecycle checks");
  check(waitFor([before] { return pumpCalls > before; }),
        "an active page must restart maintenance pumping");
  const auto idlePageClosed = std::make_shared<std::atomic_bool>(false);
  [idlePage closeWithCompletion:^(NSError* value) { error = value; idlePageClosed->store(true); }];
  check(waitFor([idlePageClosed] { return idlePageClosed->load(); }) && error == nil && runtime.activePageCount == 0,
        "closing the last page must retire its runtime slot");
  check(![[runtime valueForKey:@"timer"] isValid],
        "closing the last page must stop lifecycle checks");
  spinFor(.08);
  check(![[runtime valueForKey:@"pumpTimer"] isValid],
        "closing the last page must drain the pending maintenance timer");
  before = pumpCalls;
  spinFor(.08);
  check(pumpCalls == before, "an idle runtime must remain asleep after draining pending work");

  const auto delayed = std::make_shared<PumpObservation>();
  pumpHandler->OnScheduleMessagePumpWork(60);
  dispatch_async(dispatch_get_main_queue(), ^{
    delayed->before = pumpCalls;
    delayed->timer = [runtime valueForKey:@"pumpTimer"];
    delayed->done = true;
  });
  check(waitFor([delayed] { return delayed->done; }), "positive schedule must reach the main queue");
  spinFor(.02);
  check(pumpCalls == delayed->before && delayed->timer.valid,
        "delayed pump work must remain pending for its first 20 ms");
  check(waitFor([delayed] { return pumpCalls > delayed->before && !delayed->timer.valid; }),
        "delayed pump work must execute");

  const auto replaced = std::make_shared<PumpObservation>();
  dispatch_async(dispatch_get_main_queue(), ^{ replaced->before = pumpCalls; });
  pumpHandler->OnScheduleMessagePumpWork(100);
  dispatch_async(dispatch_get_main_queue(), ^{
    replaced->timer = [runtime valueForKey:@"pumpTimer"];
    check(replaced->timer.valid, "replacement fixture must capture a live delayed timer");
  });
  pumpHandler->OnScheduleMessagePumpWork(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    check(pumpCalls == replaced->before + 1, "immediate replacement must execute exactly once before the queue observation");
    check(!replaced->timer.valid, "immediate work must invalidate the replaced delayed timer");
    replaced->done = true;
  });
  check(waitFor([replaced] { return replaced->done; }, .07), "immediate replacement must reach its queue observation");
  spinFor(.12);
  check(!replaced->timer.valid, "obsolete delayed timer must stay invalid after explicit work completes");

  const auto immediateObserved = std::make_shared<PumpObservation>();
  dispatch_async(dispatch_get_main_queue(), ^{ immediateObserved->before = pumpCalls; });
  pumpHandler->OnScheduleMessagePumpWork(0);
  pumpHandler->OnScheduleMessagePumpWork(100);
  dispatch_async(dispatch_get_main_queue(), ^{
    check(pumpCalls == immediateObserved->before + 1,
          "a later positive delay must preserve exactly one preceding immediate pump");
    immediateObserved->timer = [runtime valueForKey:@"pumpTimer"];
    check(immediateObserved->timer.valid, "positive delay after immediate work must install a timer");
    dispatch_async(dispatch_get_main_queue(), ^{
      check(immediateObserved->timer.valid &&
            [runtime valueForKey:@"pumpTimer"] == immediateObserved->timer,
            "queued maintenance must preserve the existing positive-delay timer identity");
      immediateObserved->done = true;
    });
  });
  check(waitFor([immediateObserved] { return immediateObserved->done; }),
        "immediate-work observation must run on the main queue");
  check(waitFor([immediateObserved] {
    return !immediateObserved->timer.valid && pumpCalls > immediateObserved->before + 1;
  }), "positive delay after immediate work must eventually execute too");

  const auto background = std::make_shared<PumpObservation>();
  dispatch_semaphore_t callbackFinished = dispatch_semaphore_create(0);
  CefBrowserProcessHandler* handler = pumpHandler.get();  // pumpHandler owns it through callback completion.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    dispatch_async(dispatch_get_main_queue(), ^{ background->before = pumpCalls; });
    handler->OnScheduleMessagePumpWork(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      check(pumpCalls == background->before + 1,
            "background schedule must execute exactly one pump before its queue observation");
      background->done = true;
    });
    dispatch_semaphore_signal(callbackFinished);
  });
  // Wait without servicing the main queue until all three FIFO entries are submitted.
  if (dispatch_semaphore_wait(callbackFinished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0)
    throw std::runtime_error("background schedule callback did not return within its deadline");
  check(waitFor([background] { return background->done; }),
        "background schedule observation must run on the main queue");

  nestNextPump = true;
  nestedWorkObserved = false;
  pumpHandler->OnScheduleMessagePumpWork(0);
  check(waitFor([] { return nestedWorkObserved; }), "nested scheduling must reach its deferred-work observation");
  check(maximumPumpDepth == 1, "nested NSRunLoop must not reenter CefDoMessageLoopWork");

  before = pumpCalls;
  runtimeForPump = runtime;
  shutdownNextPump = true;
  pumpHandler->OnScheduleMessagePumpWork(0);
  check(waitFor([before] { return pumpCalls > before && !shutdownNextPump; }),
        "shutdown rejection fixture must execute inside the pump");
  before = pumpCalls;
  pumpHandler->OnScheduleMessagePumpWork(0);
  check(waitFor([before] { return pumpCalls > before; }),
        "rejected in-pump shutdown must leave the runtime able to pump");
  runtimeForPump = nil;

  pumpHandler->OnScheduleMessagePumpWork(60);
  error = nil;
  check([runtime shutdownWithError:&error], "external pump runtime must shut down");
  check(error == nil, "safe shutdown after in-pump rejection must not retain a terminal error");
  before = pumpCalls;
  pumpHandler->OnScheduleMessagePumpWork(0);
  spinFor(.1);
  check(pumpCalls == before, "shutdown must invalidate queued timers and late schedule callbacks");
  check(shutdownCalls == 1, "external pump runtime must shut CEF down exactly once");
  check(!pumpedOffMain, "CefDoMessageLoopWork must run on the main thread");
  pumpHandler = nullptr;
}
}  // namespace

// These symbols replace calls in the separately compiled test WebRuntime object
// only. The real framework remains loaded for CEF strings and wrapper classes.
bool DWTestCefInitialize(const CefMainArgs&, const CefSettings& settings, CefRefPtr<CefApp> app, void*) {
  ++initializeCalls;
  const bool result = mode != "init-failure";
  if (mode == "external-pump") {
    check(settings.external_message_pump, "CEF initialization must enable external_message_pump");
    pumpHandler = app->GetBrowserProcessHandler();
    if (pumpHandler) pumpHandler->OnScheduleMessagePumpWork(0);
    spinFor(.01);
    check(pumpCalls == 0, "scheduled work must wait until CefInitialize has returned");
  }
  fprintf(stderr, "WEB_RUNTIME_FAILURE STUB CefInitialize call=%u result=%d\n", initializeCalls, result);
  return result;
}
void DWTestCefShutdown() {
  ++shutdownCalls;
  fprintf(stderr, "WEB_RUNTIME_FAILURE STUB CefShutdown call=%u\n", shutdownCalls);
}
extern "C" int DWTestCefUnloadLibrary() {
  ++unloadCalls;
  const int result = mode == "external-pump";
  fprintf(stderr, "WEB_RUNTIME_FAILURE STUB cef_unload_library call=%u result=%d\n", unloadCalls, result);
  return result;  // Real test-framework cleanup remains in main after all references exit.
}
int DWTestCefGetExitCode() {
  ++exitCodeCalls;
  fprintf(stderr, "WEB_RUNTIME_FAILURE STUB CefGetExitCode call=%u result=72\n", exitCodeCalls);
  return 72;
}
void DWTestCefDoMessageLoopWork() {
  if (mode != "external-pump") throw std::runtime_error("failure contract unexpectedly pumped the CEF message loop");
  if (!NSThread.isMainThread) {
    pumpedOffMain = true;
    return;
  }
  ++pumpCalls;
  ++pumpDepth;
  maximumPumpDepth = std::max(maximumPumpDepth, pumpDepth);
  if (shutdownNextPump) {
    shutdownNextPump = false;
    const unsigned shutdownBefore = shutdownCalls, unloadBefore = unloadCalls;
    NSError* error = nil;
    const BOOL stopped = [runtimeForPump shutdownWithError:&error];
    check(!stopped && error != nil, "shutdown inside CefDoMessageLoopWork must return an explicit error");
    check(shutdownCalls == shutdownBefore && unloadCalls == unloadBefore,
          "in-pump shutdown rejection must not call CefShutdown or unload the framework");
  }
  if (nestNextPump) {
    nestNextPump = false;
    const unsigned beforeDeferred = pumpCalls;
    pumpHandler->OnScheduleMessagePumpWork(0);
    spinFor(.025);
    check(pumpCalls == beforeDeferred, "nested run loop must not execute another pump before the current call returns");
    // Runtime queues deferred work only after this stub returns. A second-hop
    // observation sits behind that work, before any maintenance timer can fire.
    dispatch_async(dispatch_get_main_queue(), ^{
      dispatch_async(dispatch_get_main_queue(), ^{
        check(pumpCalls == beforeDeferred + 1,
              "nested scheduling must execute exactly one deferred pump before its queue observation");
        nestedWorkObserved = true;
      });
    });
  }
  --pumpDepth;
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc != 4) {
      fprintf(stderr, "usage: RuntimeFailureTests MODE FRAMEWORK CACHE\n");
      return 64;
    }
    mode = argv[1];
    if (mode != "init-failure" && mode != "unload-failure" && mode != "external-pump") {
      fprintf(stderr, "unknown failure mode: %s\n", mode.c_str());
      return 64;
    }
    DWWebCreateApplication();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    try {
      if (mode == "init-failure") testInitializationFailure(argv);
      else if (mode == "unload-failure") testUnloadFailure(argv);
      else testExternalPump(argv);
      // Both test runtimes and all CEF settings/app references have left scope.
      check(cef_unload_library() != 0, "real test framework cleanup failed");
      if (!failures.empty()) throw std::runtime_error(failures);
      fprintf(stderr, "WEB_RUNTIME_FAILURE PASS mode=%s initialize=%u shutdown=%u unload=%u exitCode=%u\n",
              mode.c_str(), initializeCalls, shutdownCalls, unloadCalls, exitCodeCalls);
      return 0;
    } catch (const std::exception& error) {
      fprintf(stderr, "WEB_RUNTIME_FAILURE FAILED mode=%s: %s\n", mode.c_str(), error.what());
      return 1;
    }
  }
}
