#import "WebRuntimeInternal.h"
#include "SceneProtocol.hpp"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include <algorithm>
#include <cmath>
#include <functional>
#include <optional>

@interface DWWebRuntime (MessagePump)
- (void)schedulePumpAt:(NSTimeInterval)deadline;
- (void)performMessagePumpWork;
- (void)scheduleMaintenancePump;
- (void)startPageLifecycleTimerIfNeeded;
- (void)stopPageLifecycleTimerIfIdle;
@end

@interface DWWebApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@property(nonatomic) BOOL terminationRequestInProgress;
@end
@implementation DWWebApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent*)event { CefScopedSendingEvent scope; [super sendEvent:event]; }
- (void)terminate:(id)sender {
  if (self.terminationRequestInProgress) return;
  self.terminationRequestInProgress = YES;
  [[NSNotificationCenter defaultCenter] postNotificationName:DWApplicationWillRequestTerminationNotification object:self];
  // Let a cancelled file chooser unwind its modal loop before AppKit checks it.
  // Keep duplicate Quit requests out of the later transcode confirmation too.
  [[NSRunLoop mainRunLoop] performInModes:@[NSDefaultRunLoopMode] block:^{
    [super terminate:sender];
    self.terminationRequestInProgress = NO;
  }];
}
@end

NSNotificationName const DWApplicationWillRequestTerminationNotification = @"DWApplicationWillRequestTermination";
void DWWebCreateApplication(void) { DWRequireWebMainThread(); [DWWebApplication sharedApplication]; }

namespace {
// Match the locked CEF external-pump example. The callback is not a complete
// wake-up source: work discovered inside CEF's time slice can remain pending.
constexpr NSTimeInterval maximumPumpInterval = 33.0 / 1000.0;
constexpr NSTimeInterval pageLifecycleInterval = 1.0 / 30.0;
bool processHasAttemptedCEF = false;  // A failed initialization also forbids any later CEF initialization.
class RuntimeApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit RuntimeApp(std::function<void(int64_t)> schedule) : schedule_(std::move(schedule)) {}
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override { fprintf(stderr, "DWWEB runtime-context-initialized\n"); }
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    command->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");
    command->AppendSwitch("disable-background-networking");
  }
  void OnScheduleMessagePumpWork(int64_t delay_ms) override { schedule_(delay_ms); }
 private:
  const std::function<void(int64_t)> schedule_;
  IMPLEMENT_REFCOUNTING(RuntimeApp);
};
}

@implementation DWWebRuntime {
  NSString* _frameworkDirectory;
  NSString* _helperExecutable;
  NSString* _cacheDirectory;
  NSMutableSet<DWWebPage*>* _pages;
  NSTimer* _timer;
  NSTimer* _pumpTimer;
  BOOL _pumping;
  BOOL _pumpAgain;
  BOOL _initializing;
  std::optional<NSTimeInterval> _initialPumpDeadline;
  CefRefPtr<RuntimeApp> _app;
  BOOL _started;
  BOOL _terminated;
  BOOL _loadedLibrary;
  NSError* _terminalFailure;
  NSUInteger _initializationCount;
  NSUInteger _shutdownCount;
}
- (instancetype)initWithFrameworkDirectory:(NSString*)frameworkDirectory
                         helperExecutable:(NSString*)helperExecutable
                           cacheDirectory:(NSString*)cacheDirectory {
  DWRequireWebMainThread();
  if ((self = [super init])) {
    _frameworkDirectory = [frameworkDirectory copy]; _helperExecutable = [helperExecutable copy];
    _cacheDirectory = [cacheDirectory copy]; _pages = [NSMutableSet set];
  }
  return self;
}
- (NSUInteger)initializationCount { DWRequireWebMainThread(); return _initializationCount; }
- (NSUInteger)shutdownCount { DWRequireWebMainThread(); return _shutdownCount; }
- (NSUInteger)activePageCount { DWRequireWebMainThread(); return _pages.count; }
- (BOOL)startWithError:(NSError**)error {
  DWRequireWebMainThread();
  if (_started) return YES;
  NSString* failure = nil;
  if (_terminated || processHasAttemptedCEF) failure = @"CEF 运行时已终止或由另一实例持有，不能重新初始化。";
  else if (![NSApp conformsToProtocol:@protocol(CefAppProtocol)])
    failure = @"网页运行时要求在应用启动前创建 DWWebApplication。";
  else if (![_frameworkDirectory isAbsolutePath] || ![_helperExecutable isAbsolutePath] || ![_cacheDirectory isAbsolutePath])
    failure = @"CEF 依赖与缓存必须使用明确的绝对路径。";
  else if (![NSFileManager.defaultManager isExecutableFileAtPath:_helperExecutable])
    failure = @"CEF 辅助进程不可用。";
  if (failure) { if (error) *error = DWWebError(failure); return NO; }
  NSString* library = [_frameworkDirectory stringByAppendingPathComponent:@"Chromium Embedded Framework"];
  if (!cef_load_library(library.fileSystemRepresentation)) {
    if (error) *error = DWWebError(@"无法载入锁定的 CEF Framework。"); return NO;
  }
  _loadedLibrary = YES;
  std::string executable = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
  char* arguments[] = {executable.data()};
  CefMainArgs args(1, arguments);
  CefSettings settings;
  settings.no_sandbox = false;
  settings.windowless_rendering_enabled = true;
  // The application loop is already running on first webpage use. CEF's
  // external pump avoids installing native observers halfway through a loop.
  settings.external_message_pump = true;
  CefString(&settings.framework_dir_path) = _frameworkDirectory.fileSystemRepresentation;
  CefString(&settings.browser_subprocess_path) = _helperExecutable.fileSystemRepresentation;
  CefString(&settings.root_cache_path) = _cacheDirectory.fileSystemRepresentation;
  if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"])
    CefString(&settings.main_bundle_path) = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;
  __weak DWWebRuntime* weakSelf = self;
  _app = new RuntimeApp([weakSelf](int64_t delay) {
    const NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + std::max(0.0, double(delay) / 1000.0);
    // CEF may request work from any thread, including during initialization.
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf schedulePumpAt:deadline]; });
  });
  processHasAttemptedCEF = true;
  _initializing = YES;
  const bool initialized = CefInitialize(args, settings, _app, nullptr);
  _initializing = NO;
  if (!initialized) {
    _initialPumpDeadline.reset();
    const int exitCode = CefGetExitCode();
    _app = nullptr;
    _terminated = YES;
    _terminalFailure = [NSError errorWithDomain:@"DynamicWallpaper.Web" code:1 userInfo:@{
      NSLocalizedDescriptionKey: [NSString stringWithFormat:@"CEF 初始化失败（exit %d），需要退出应用；不会重新初始化或更换后端。", exitCode],
      @"CEFInitializationExitCode": @(exitCode)
    }];
    if (error) *error = _terminalFailure;
    return NO;
  }
  _started = YES; ++_initializationCount;
  if (_initialPumpDeadline) {
    [self schedulePumpAt:*_initialPumpDeadline];
    _initialPumpDeadline.reset();
  }
  fprintf(stderr, "DWWEB runtime-started sandboxRequested=1 externalPump=1\n");
  return YES;
}
- (void)startPageLifecycleTimerIfNeeded {
  DWRequireWebMainThread();
  if (!_started || _terminated || _timer || !_pages.count) return;
  __weak DWWebRuntime* weakSelf = self;
  _timer = [NSTimer timerWithTimeInterval:pageLifecycleInterval repeats:YES block:^(NSTimer*) {
    DWWebRuntime* owner = weakSelf;
    if (!owner || !owner->_started) return;
    for (DWWebPage* page in owner->_pages.allObjects) [page tick];
  }];
  [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)stopPageLifecycleTimerIfIdle {
  DWRequireWebMainThread();
  if (_pages.count) return;
  [_timer invalidate]; _timer = nil;
}
- (void)schedulePumpAt:(NSTimeInterval)deadline {
  DWRequireWebMainThread();
  // Initialization can itself service an AppKit loop (for example a system
  // dialog). Preserve requests it consumes, but never pump before it returns.
  if (_initializing) { _initialPumpDeadline = deadline; return; }
  if (!_started || _terminated) return;
  [_pumpTimer invalidate]; _pumpTimer = nil;
  const NSTimeInterval delay = deadline - NSProcessInfo.processInfo.systemUptime;
  // An immediate request must run before a later queued request can replace
  // its timer. This matches CEF's external-pump scheduler on the main thread.
  if (delay <= 0) { [self performMessagePumpWork]; return; }
  __weak DWWebRuntime* weakSelf = self;
  _pumpTimer = [NSTimer timerWithTimeInterval:std::min(delay, maximumPumpInterval)
      repeats:NO block:^(NSTimer* timer) {
    DWWebRuntime* owner = weakSelf;
    if (!owner || owner->_pumpTimer != timer) return;
    owner->_pumpTimer = nil;
    [owner performMessagePumpWork];
  }];
  [NSRunLoop.mainRunLoop addTimer:_pumpTimer forMode:NSRunLoopCommonModes];
}
- (void)performMessagePumpWork {
  DWRequireWebMainThread();
  if (!_started || _terminated) return;
  if (_pumping) { _pumpAgain = YES; return; }
  _pumping = YES;
  @try { CefDoMessageLoopWork(); }
  @finally { _pumping = NO; }
  if (_pumpAgain) {
    _pumpAgain = NO;
    __weak DWWebRuntime* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf performMessagePumpWork]; });
  } else if (!_pumpTimer) {
    // Queue behind CEF's actual requests. A maintenance request must never
    // replace a timer that an already queued callback is about to install.
    __weak DWWebRuntime* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf scheduleMaintenancePump]; });
  }
}
- (void)scheduleMaintenancePump {
  DWRequireWebMainThread();
  if (!_started || _terminated || _pumpTimer || !_pages.count) return;
  [self schedulePumpAt:NSProcessInfo.processInfo.systemUptime + maximumPumpInterval];
}
- (DWWebPage*)pageWithProjectRoot:(NSString*)root entry:(NSString*)entry
                           size:(NSSize)size scale:(CGFloat)scale error:(NSError**)error {
  DWRequireWebMainThread();
  if (!_started || _terminated) {
    if (error) *error = DWWebError(@"网页运行时尚未启动或已经关闭。"); return nil;
  }
  if (!root.isAbsolutePath || entry.length == 0 || !std::isfinite(size.width) || !std::isfinite(size.height) ||
      !std::isfinite(scale) || size.width <= 0 || size.height <= 0 || scale <= 0 ||
      size.width * scale > INT_MAX || size.height * scale > INT_MAX) {
    if (error) *error = DWWebError(@"网页项目路径或视口尺寸无效。"); return nil;
  }
  DWWebPage* page = [[DWWebPage alloc] initWithRuntime:self root:root entry:entry size:size scale:scale];
  [_pages addObject:page];
  [self startPageLifecycleTimerIfNeeded];
  [self scheduleMaintenancePump];
  return page;
}
- (DWWebPage*)scenePageWithProjectRoot:(NSString*)root runtimeRoot:(NSString*)runtimeRoot
    entry:(NSString*)entry representation:(NSString*)representation sceneID:(NSString*)sceneID
    generation:(uint64_t)generation size:(NSSize)size scale:(CGFloat)scale error:(NSError**)error {
  DWRequireWebMainThread();
  if (!runtimeRoot.isAbsolutePath || sceneID.length == 0 ||
      [sceneID lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128 || generation == 0 || generation > 9007199254740991ULL ||
      (![representation isEqual:@"loose"] && ![representation isEqual:@"package"])) {
    if (error) *error = DWWebError(@"Scene identity, runtime path or representation is invalid"); return nil;
  }
  NSString* extension = entry.pathExtension.lowercaseString;
  if (([representation isEqual:@"loose"] && ![extension isEqual:@"json"]) ||
      ([representation isEqual:@"package"] && ![extension isEqual:@"pkg"])) {
    if (error) *error = DWWebError(@"Scene entry extension does not match representation"); return nil;
  }
  try {
    dw::sceneRoute("__project/" + std::string(entry.UTF8String), "GET", true);
    if ([entry rangeOfString:@"\0"].location != NSNotFound ||
        [sceneID rangeOfString:@"\0"].location != NSNotFound)
      throw std::runtime_error("Scene identity or entry contains NUL");
  } catch (const std::exception& failure) {
    if (error) *error = DWWebError(@(failure.what())); return nil;
  }
  DWWebPage* page = [self pageWithProjectRoot:root entry:entry size:size scale:scale error:error];
  [page configureSceneRuntimeRoot:runtimeRoot entry:entry representation:representation sceneID:sceneID generation:generation];
  return page;
}
- (void)retirePage:(DWWebPage*)page {
  DWRequireWebMainThread();
  [_pages removeObject:page];
  [self stopPageLifecycleTimerIfIdle];
}
- (BOOL)shutdownWithError:(NSError**)error {
  DWRequireWebMainThread();
  if (_terminalFailure) { if (error) *error = _terminalFailure; return NO; }
  if (_initializing || _pumping) {
    if (error) *error = DWWebError(@"CEF 初始化或消息循环仍在执行，本次关闭尚未执行。");
    return NO;  // Keep ownership and permit a later call after the CEF stack exits.
  }
  if (_pages.count) { if (error) *error = DWWebError(@"网页仍在运行或关闭失败，不能关闭 CEF 运行时。"); return NO; }
  if (_terminated) return YES;
  _terminated = YES;
  [_pumpTimer invalidate]; _pumpTimer = nil; _pumpAgain = NO;
  if (_started) {
    [_timer invalidate]; _timer = nil;
    fprintf(stderr, "DWWEB before-runtime-shutdown\n");
    CefShutdown();
    fprintf(stderr, "DWWEB after-runtime-shutdown\n");
    ++_shutdownCount; _started = NO;
  }
  _app = nullptr;
  if (_loadedLibrary) {
    if (!cef_unload_library()) {
      _terminalFailure = DWWebError(@"CEF Framework 卸载失败。");
      if (error) *error = _terminalFailure; return NO;
    }
    _loadedLibrary = NO;
  }
  return YES;
}
- (void)dealloc {
  if (_started || _pages.count) fprintf(stderr, "DWWEB ERROR runtime owner released before successful shutdown\n");
  [_timer invalidate];
  [_pumpTimer invalidate];
}
@end
