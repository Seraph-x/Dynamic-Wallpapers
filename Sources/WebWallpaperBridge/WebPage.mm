#import "WebRuntimeInternal.h"
#import <QuartzCore/QuartzCore.h>
#include "WebPageState.hpp"
#import "WebAudioOutput.h"
#include "include/cef_parser.h"
#include <filesystem>
#include <cmath>
#include <climits>

namespace {
struct PageResources {
  std::shared_ptr<DWWebPageState> state;
  std::shared_ptr<dw::ProjectFiles> files, runtimeFiles;
  CefRefPtr<CefRequestContextHandler> handler;
  CefRefPtr<CefRequestContext> context;
  CefRefPtr<CefClient> client;
};
std::string entryURL(const std::string& host, const char* entry) {
  std::filesystem::path path(entry);
  auto extension = path.extension().string();
  std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
  if (path.is_absolute() || (extension != ".html" && extension != ".htm"))
    throw std::runtime_error("The entry must be a relative HTML file inside its project");
  std::string url = "https://" + host;
  for (const auto& component : path) {
    if (component == ".." || component == "." || component.empty()) throw std::runtime_error("Invalid project entry component");
    url += "/" + CefURIEncode(component.string(), false).ToString();
  }
  return url;
}
}

@implementation DWWebPage {
  __weak DWWebRuntime* _runtime;
  NSString* _root;
  NSString* _entry;
  NSString* _sceneRuntimeRoot;
  NSString* _sceneEntry;
  NSMutableDictionary<NSString*, void (^)(NSError*)>* _sceneCompletions;
  NSMutableDictionary<NSString*, NSNumber*>* _sceneDeadlines;
  NSString* _origin;
  NSView* _view;
  DWWebAudioOutput* _audioOutput;
  std::unique_ptr<PageResources> _resources;
  BOOL _started;
  BOOL _ready;
  BOOL _closed;
  BOOL _reportedFailure;
  BOOL _releasedReferences;
  NSUInteger _frameRate;
  double _prepareDeadline;
  double _closeDeadline;
  NSError* _closeFailure;
  NSMutableArray<void (^)(NSError*)>* _completions;
  void (^_onReady)(void);
  void (^_onError)(NSError*);
  void (^_onEditorDirty)(BOOL);
  void (^_onEditorResource)(NSDictionary<NSString*, id>*);
  NSMutableDictionary<NSString*, void (^)(NSDictionary*, NSError*)>* _editorCompletions;
  NSMutableDictionary<NSString*, NSNumber*>* _editorDeadlines;
  NSMutableSet<NSString*>* _editorResourceRequests;
}
- (void (^)(BOOL))onEditorDirty { DWRequireWebMainThread(); return _onEditorDirty; }
- (void)setOnEditorDirty:(void (^)(BOOL))callback { DWRequireWebMainThread(); _onEditorDirty = [callback copy]; }
- (void (^)(NSDictionary<NSString*, id>*))onEditorResource { DWRequireWebMainThread(); return _onEditorResource; }
- (void)setOnEditorResource:(void (^)(NSDictionary<NSString*, id>*))callback { DWRequireWebMainThread(); _onEditorResource = [callback copy]; }
- (BOOL)configureEditorRuntimeRoot:(NSString*)root configuration:(NSDictionary*)configuration error:(NSError**)error {
  DWRequireWebMainThread();
  NSMutableDictionary* config = [configuration mutableCopy];
  NSString* session = NSUUID.UUID.UUIDString;
  config[@"session"] = session; config[@"generation"] = @1; config[@"version"] = @1;
  NSData* data = [NSJSONSerialization dataWithJSONObject:config options:0 error:error];
  if (!data) return NO;
  _sceneRuntimeRoot = [root copy]; _entry = @"index.html";
  _resources->state->editor = std::make_shared<dw::EditorSession>(session.UTF8String, 1,
      std::string(static_cast<const char*>(data.bytes), data.length));
  _resources->state->attachNative = [](void* handle) {
    NSView* child = (__bridge NSView*)handle;
    child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  };
  _resources->state->detachNative = [](void* handle) {
    NSView* child = (__bridge NSView*)handle;
    dispatch_async(dispatch_get_main_queue(), ^{
      NSWindow* window = child.window;
      [window makeFirstResponder:nil];
      [child removeFromSuperview];
      [window recalculateKeyViewLoop];
      fprintf(stderr, "DWWEB editor-native-child-detached\n");
    });
  };
  _editorCompletions = [NSMutableDictionary dictionary]; _editorDeadlines = [NSMutableDictionary dictionary];
  _editorResourceRequests = [NSMutableSet set];
  return YES;
}
- (void)requestEditorCommand:(NSDictionary<NSString*, id>*)payload completion:(DWEditorCommandCompletion)completion {
  DWRequireWebMainThread();
  auto state = _resources->state;
  BOOL resourceReply = [payload[@"type"] isEqual:@"resource-reply"];
  if (resourceReply && (!payload[@"requestID"] || ![_editorResourceRequests containsObject:payload[@"requestID"]])) {
    completion(nil, DWWebError(@"Unsolicited Editor resource reply")); return;
  }
  if (!state->editor || (!_ready && !resourceReply) || state->closing || !state->browser || !state->failure(false).empty()) {
    completion(nil, DWWebError(@"Editor is not ready")); return;
  }
  if (![@[@"snapshot", @"freeze", @"thaw", @"load", @"mark-saved", @"add-image", @"export-pkg", @"undo", @"redo", @"resource-reply", @"replace-resource"] containsObject:payload[@"type"]]) {
    completion(nil, DWWebError(@"Unknown Editor command")); return;
  }
  NSString* identifier = NSUUID.UUID.UUIDString;
  NSMutableDictionary* command = [payload mutableCopy]; command[@"id"] = identifier;
  command[@"session"] = @(state->editor->session.c_str()); command[@"generation"] = @(state->editor->generation);
  NSError* error = nil; NSData* data = [NSJSONSerialization dataWithJSONObject:command options:0 error:&error];
  if (!data) { completion(nil, error); return; }
  if (resourceReply) [_editorResourceRequests removeObject:payload[@"requestID"]];
  _editorCompletions[identifier] = [completion copy];
  _editorDeadlines[identifier] = @(NSProcessInfo.processInfo.systemUptime + 30);
  NSString* script = [NSString stringWithFormat:@"window.__dynamicWallpaperEditor.command(%@);", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
  state->browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String, "https://" + state->host + "/__runtime/index.html", 0);
}
- (void)drainEditorEvents {
  auto state = _resources->state; if (!state->editor) return;
  std::vector<dw::EditorEvent> events;
  { std::lock_guard lock(state->editor->mutex); events.swap(state->editor->events); }
  for (const auto& event : events) {
    if (state->closing) break;
    if (event.type == "error") { state->fail(event.payload); break; }
    if (event.type == "ready") {
      if (state->engineReady) { state->fail("Duplicate Editor ready"); break; }
      state->engineReady = true;
    } else if (event.type == "dirty") { if (_onEditorDirty) _onEditorDirty(event.dirty); }
    else if (event.type == "resource") {
      if (!_onEditorResource) { state->fail("Editor resource handler unavailable"); break; }
      NSString* identifier = @(event.id.c_str());
      if ([_editorResourceRequests containsObject:identifier]) { state->fail("Duplicate Editor resource request"); break; }
      [_editorResourceRequests addObject:identifier];
      NSData* bytes = [NSData dataWithBytes:event.payload.data() length:event.payload.size()];
      _onEditorResource([NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]);
    }
    else if (event.type == "reply") {
      NSString* identifier = @(event.id.c_str());
      void (^callback)(NSDictionary*, NSError*) = _editorCompletions[identifier];
      if (!callback) { state->fail("Unsolicited or duplicate Editor reply"); break; }
      [_editorCompletions removeObjectForKey:identifier]; [_editorDeadlines removeObjectForKey:identifier];
      NSData* bytes = [NSData dataWithBytes:event.payload.data() length:event.payload.size()];
      callback([NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil], nil);
    }
  }
  for (NSString* identifier in _editorDeadlines.allKeys)
    if (NSProcessInfo.processInfo.systemUptime >= _editorDeadlines[identifier].doubleValue) { state->fail("Editor command timed out"); break; }
  if (!state->failure(false).empty()) [self failEditorCommands:DWWebError(@(state->failure(false).c_str()))];
}
- (void)failEditorCommands:(NSError*)error {
  [_editorResourceRequests removeAllObjects];
  NSArray* callbacks = _editorCompletions.allValues; [_editorCompletions removeAllObjects]; [_editorDeadlines removeAllObjects];
  for (void (^callback)(NSDictionary*, NSError*) in callbacks) callback(nil, error);
}
- (void (^)(void))onReady { DWRequireWebMainThread(); return _onReady; }
- (void)setOnReady:(void (^)(void))callback { DWRequireWebMainThread(); _onReady = [callback copy]; }
- (void (^)(NSError*))onError { DWRequireWebMainThread(); return _onError; }
- (void)setOnError:(void (^)(NSError*))callback { DWRequireWebMainThread(); _onError = [callback copy]; }
- (instancetype)initWithRuntime:(DWWebRuntime*)runtime root:(NSString*)root entry:(NSString*)entry
                          size:(NSSize)size scale:(CGFloat)scale {
  DWRequireWebMainThread();
  if ((self = [super init])) {
    _runtime = runtime; _root = [root copy]; _entry = [entry copy];
    _origin = [@"https://page-" stringByAppendingFormat:@"%@.invalid", NSUUID.UUID.UUIDString.lowercaseString];
    _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    _frameRate = 30;
    _view.wantsLayer = YES; _view.layer.contentsScale = scale;
    _view.layer.contentsGravity = kCAGravityResizeAspect;
    _resources = std::make_unique<PageResources>();
    _resources->state = std::make_shared<DWWebPageState>([_origin substringFromIndex:8].UTF8String,
        int(std::ceil(size.width)), int(std::ceil(size.height)), float(scale));
    __weak DWWebPage* weakSelf = self;
    _resources->state->paint = [weakSelf](const void* buffer, int width, int height) { return bool([weakSelf commitFrame:buffer width:width height:height]); };
    _completions = [NSMutableArray array];
  }
  return self;
}
- (void)configureSceneRuntimeRoot:(NSString*)root entry:(NSString*)entry representation:(NSString*)representation
                         sceneID:(NSString*)sceneID generation:(uint64_t)generation {
  DWRequireWebMainThread();
  _sceneRuntimeRoot = [root copy]; _sceneEntry = [entry copy];
  _entry = @"index.html";
  NSDictionary* config = @{@"version": @1, @"sceneID": sceneID, @"generation": @(generation),
    @"project": @{@"representation": representation, @"entryPath": entry},
    @"viewport": @{@"width": @(_resources->state->width), @"height": @(_resources->state->height)},
    @"fps": @(_frameRate), @"fit": @"cover", @"volume": @1, @"muted": @YES};
  NSData* data = [NSJSONSerialization dataWithJSONObject:config options:0 error:nullptr];
  _resources->state->scene = std::make_shared<dw::SceneSession>(sceneID.UTF8String, generation,
      std::string(static_cast<const char*>(data.bytes), data.length));
  _sceneCompletions = [NSMutableDictionary dictionary]; _sceneDeadlines = [NSMutableDictionary dictionary];
}
- (void)sceneCommand:(NSDictionary*)payload completion:(void (^)(NSError*))completion {
  DWRequireWebMainThread();
  const auto state = _resources->state;
  if (!state->scene || !_ready || state->closing || !state->browser || !state->failure(false).empty()) {
    completion(DWWebError(@"Scene is not ready for commands")); return;
  }
  NSString* identifier = NSUUID.UUID.UUIDString;
  NSMutableDictionary* command = [payload mutableCopy];
  command[@"id"] = identifier; command[@"sceneID"] = @(state->scene->sceneID.c_str());
  command[@"generation"] = @(state->scene->generation);
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:command options:0 error:&error];
  if (!data) { completion(error); return; }
  NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  _sceneCompletions[identifier] = [completion copy];
  _sceneDeadlines[identifier] = @(NSProcessInfo.processInfo.systemUptime + 5);
  // Only this fixed entry point executes; all arguments are JSON-serialized data.
  NSString* script = [NSString stringWithFormat:@"window.__dynamicWallpaperScene.command(%@);", json];
  state->browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String,
      "https://" + state->host + "/__runtime/index.html", 0);
}
- (void)setScenePlaying:(BOOL)playing completion:(void (^)(NSError*))completion {
  DWRequireWebMainThread();
  if (!playing) {
    NSError* error = nil;
    if (![self setOutputGain:0 error:&error]) { completion(error); return; }
  }
  [self sceneCommand:@{@"type": playing ? @"play" : @"pause"} completion:completion];
}
- (void)setSceneVolume:(double)volume muted:(BOOL)muted completion:(void (^)(NSError*))completion {
  DWRequireWebMainThread();
  if (!std::isfinite(volume) || volume < 0 || volume > 1) { completion(DWWebError(@"Invalid scene volume")); return; }
  if (muted || volume == 0) {
    NSError* error = nil;
    if (![self setOutputGain:0 error:&error]) { completion(error); return; }
  }
  [self sceneCommand:@{@"type": @"volume", @"volume": @(volume), @"muted": @(muted)} completion:completion];
}
- (void)setSceneFit:(NSString*)fit completion:(void (^)(NSError*))completion {
  DWRequireWebMainThread();
  if (![fit isEqual:@"cover"] && ![fit isEqual:@"contain"]) { completion(DWWebError(@"Invalid scene fit")); return; }
  [self sceneCommand:@{@"type": @"fit", @"fit": fit} completion:completion];
}
- (void)setSceneFrameRate:(NSUInteger)frameRate completion:(void (^)(NSError*))completion {
  DWRequireWebMainThread();
  NSError* error = nil;
  if (![self setFrameRate:frameRate error:&error]) { completion(error); return; }
  [self sceneCommand:@{@"type": @"fps", @"fps": @(frameRate)} completion:completion];
}
- (BOOL)setSceneSpectrumLeft:(NSArray<NSNumber*>*)left right:(NSArray<NSNumber*>*)right error:(NSError**)error {
  DWRequireWebMainThread();
  auto state = _resources->state;
  try {
    if (!state->scene || !_ready || _closed || state->closing)
      throw std::runtime_error("Scene spectrum is unavailable");
    auto channel = [](NSArray* values) {
      if (values.count != 64) throw std::runtime_error("Spectrum requires 64 bands");
      std::vector<double> result; result.reserve(64);
      for (id value in values) {
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
          throw std::runtime_error("Spectrum bands must be numbers");
        result.push_back([value doubleValue]);
      }
      return result;
    };
    if (!state->scene->replaceSpectrum(channel(left), channel(right)))
      throw std::runtime_error("Scene spectrum session has retired");
    return YES;
  } catch (const std::exception& failure) { if (error) *error = DWWebError(@(failure.what())); return NO; }
}
- (BOOL)sendScenePointerAtPoint:(NSPoint)point kind:(NSString*)kind error:(NSError**)error {
  DWRequireWebMainThread();
  if ((!([kind isEqual:@"move"] || [kind isEqual:@"leave"] || [kind isEqual:@"click"])) ||
      !std::isfinite(point.x) || !std::isfinite(point.y) || point.x < 0 || point.y < 0 || point.x > 1 || point.y > 1 ||
      !_resources->state->scene || !_ready || _resources->state->closing || !_resources->state->browser) {
    if (error) *error = DWWebError(@"Scene pointer event is invalid or unavailable"); return NO;
  }
  __weak DWWebPage* weakSelf = self;
  [self sceneCommand:@{@"type": @"pointer", @"kind": kind, @"x": @(point.x), @"y": @(point.y)}
      completion:^(NSError* commandError) {
        DWWebPage* owner = weakSelf;
        if (commandError && owner && !owner->_resources->state->closing)
          owner->_resources->state->fail(commandError.localizedDescription.UTF8String);
      }];
  return YES;
}
- (void)drainSceneEvents {
  const auto state = _resources->state;
  if (!state->scene) return;
  std::vector<dw::SceneEvent> events;
  { std::lock_guard lock(state->scene->mutex); events.swap(state->scene->events); }
  for (const auto& event : events) {
    if (state->closing) break;
    if (event.type == "error") {
      state->fail("Scene engine: " + event.message);
      break;  // Never acknowledge queued commands after the engine has failed.
    }
    else if (event.type == "ready" && !state->engineReady) {
      state->engineReady = true; state->engineReadyAfterPaint = state->committedPaints;
      if (state->browser) state->browser->GetHost()->Invalidate(PET_VIEW);
    } else if (event.type == "command-ack") {
      NSString* identifier = @(event.commandID.c_str());
      void (^completion)(NSError*) = _sceneCompletions[identifier];
      if (!completion) { state->fail("Unknown or duplicate scene command acknowledgement"); continue; }
      [_sceneCompletions removeObjectForKey:identifier]; [_sceneDeadlines removeObjectForKey:identifier];
      completion(nil);
    }
  }
  for (NSString* identifier in _sceneDeadlines.allKeys) {
    if (NSProcessInfo.processInfo.systemUptime < _sceneDeadlines[identifier].doubleValue) continue;
    state->fail("Scene command acknowledgement exceeded its 5-second deadline");
    break;
  }
}
- (void)failSceneCommands:(NSError*)error {
  NSArray* callbacks = _sceneCompletions.allValues;
  [_sceneCompletions removeAllObjects]; [_sceneDeadlines removeAllObjects];
  for (void (^completion)(NSError*) in callbacks) completion(error);
}
- (NSView*)view { DWRequireWebMainThread(); return _view; }
- (NSString*)origin { DWRequireWebMainThread(); return _origin; }
- (BOOL)ready { DWRequireWebMainThread(); return _ready; }
- (BOOL)closed { DWRequireWebMainThread(); return _closed; }
- (BOOL)defaultAudioMuted { DWRequireWebMainThread(); return _resources->state->browser && _resources->state->browser->GetHost()->IsAudioMuted(); }
- (NSUInteger)frameRate { DWRequireWebMainThread(); return _frameRate; }
- (NSDictionary<NSString*, NSNumber*>*)audioDiagnostics {
  DWRequireWebMainThread();
  const auto audio = _resources->state->audio;
  if (!audio) return @{@"initialized": @NO, @"resourceWarnings": @(_resources->state->resourceWarnings.load())};
  const auto stats = audio->stats();
  return @{@"initialized": @YES, @"packets": @(audio->packets.load()), @"starts": @(audio->streamStarts.load()),
    @"stops": @(audio->streamStops.load()), @"callbacks": @(audio->activeCallbacks.load()),
    @"renders": @(audio->activeRenders.load()), @"outputStopped": @(audio->outputStopped.load()),
    @"missingFrames": @(stats.missingFrames), @"lateFrames": @(stats.lateFrames),
    @"overflowFrames": @(stats.overflowFrames), @"invalidPackets": @(stats.invalidPackets),
    @"discontinuities": @(stats.timestampDiscontinuities), @"bufferSeconds": @(audio->delaySeconds),
    @"error": @(int(audio->errorCode())), @"shutdownDisconnects": @(_resources->state->shutdownDisconnects.load()),
    @"resourceWarnings": @(_resources->state->resourceWarnings.load())};
}
- (BOOL)setOutputGain:(double)gain error:(NSError**)error {
  DWRequireWebMainThread();
  const auto state = _resources->state;
  if (!std::isfinite(gain) || gain < 0 || gain > 1 ||
      (gain > 0 && (state->closing || _closed || !_ready || !state->failure(false).empty()))) {
    if (error) *error = DWWebError(@"Webpage audio gain is invalid or the page is not playable"); return NO;
  }
  if (!state->audio) {
    if (gain == 0) return YES;
    if (error) *error = DWWebError(@"Native webpage audio output has not started"); return NO;
  }
  if (!state->audio->setGain(float(gain), NSProcessInfo.processInfo.systemUptime)) {
    if (error) *error = DWWebError(@"Native webpage audio output rejected the gain change"); return NO;
  }
  return YES;
}
- (BOOL)setFrameRate:(NSUInteger)frameRate error:(NSError**)error {
  DWRequireWebMainThread();
  if (frameRate < 1 || frameRate > INT_MAX || _closed || _resources->state->closing) {
    if (error) *error = DWWebError(@"Webpage frame rate is invalid or the page is closing");
    return NO;
  }
  _frameRate = frameRate;
  if (_resources->state->browser)
    _resources->state->browser->GetHost()->SetWindowlessFrameRate(static_cast<int>(frameRate));
  return YES;
}
- (BOOL)commitFrame:(const void*)buffer width:(int)width height:(int)height {
  DWRequireWebMainThread();
  auto state = _resources->state;
  if (state->closing) return NO;
  if (!buffer || width <= 0 || height <= 0 || size_t(width) > SIZE_MAX / 4 / size_t(height)) {
    state->fail("CEF supplied an invalid webpage frame"); return NO;
  }
  CFDataRef bytes = CFDataCreate(nullptr, static_cast<const UInt8*>(buffer), size_t(width) * height * 4);
  CGDataProviderRef provider = bytes ? CGDataProviderCreateWithCFData(bytes) : nullptr;
  CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
  CGImageRef frame = provider ? CGImageCreate(width, height, 8, 32, size_t(width) * 4, colors,
      CGBitmapInfo(kCGBitmapByteOrder32Little) | CGBitmapInfo(kCGImageAlphaPremultipliedFirst),
      provider, nullptr, false, kCGRenderingIntentDefault) : nullptr;
  if (frame) {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _view.layer.contents = (__bridge id)frame;
    [CATransaction commit]; CGImageRelease(frame);
  } else state->fail("Could not allocate the webpage frame");
  if (provider) CGDataProviderRelease(provider);
  if (bytes) CFRelease(bytes);
  CGColorSpaceRelease(colors);
  return frame != nullptr;
}
- (BOOL)sendClickAtPoint:(NSPoint)point clickCount:(NSInteger)clickCount error:(NSError**)error {
  DWRequireWebMainThread();
  const auto state = _resources->state;
  if (!_ready || _closed || state->closing || !state->browser || !state->failure(false).empty()) {
    if (error) *error = DWWebError(@"Webpage is not available for input"); return NO;
  }
  if (!std::isfinite(point.x) || !std::isfinite(point.y) || point.x < 0 || point.y < 0 ||
      point.x >= state->width || point.y >= state->height || clickCount <= 0 || clickCount > INT_MAX) {
    if (error) *error = DWWebError(@"Webpage click coordinates or count are invalid"); return NO;
  }
  CefMouseEvent event; event.x = int(point.x); event.y = int(point.y);
  const auto host = state->browser->GetHost();
  event.modifiers = EVENTFLAG_LEFT_MOUSE_BUTTON;
  host->SendMouseClickEvent(event, MBT_LEFT, false, int(clickCount));
  event.modifiers = EVENTFLAG_NONE;
  host->SendMouseClickEvent(event, MBT_LEFT, true, int(clickCount));
  return YES;
}
- (void)start {
  DWRequireWebMainThread();
  auto state = _resources->state;
  if (_started || state->closing || _closed) { state->fail("This page cannot be started again"); return; }
  _started = YES; _prepareDeadline = NSProcessInfo.processInfo.systemUptime + 10;
  try {
    NSError* audioError = nil;
    if (!state->editor) {
      _audioOutput = [[DWWebAudioOutput alloc] initWithError:&audioError];
      if (!_audioOutput) throw std::runtime_error(audioError.localizedDescription.UTF8String);
      state->audio = _audioOutput.buffer;
    }
    const std::string url = (state->scene || state->editor) ? "https://" + state->host + "/__runtime/index.html" : entryURL(state->host, _entry.UTF8String);
    _resources->files = std::make_shared<dw::ProjectFiles>(_root.fileSystemRepresentation,
        [state](const std::string& message) { state->fail(message); });
    if (state->scene || state->editor) {
      _resources->runtimeFiles = std::make_shared<dw::ProjectFiles>(_sceneRuntimeRoot.fileSystemRepresentation,
          [state](const std::string& message) { state->fail(message); });
      if (state->scene) { auto entry = _resources->files->open(_sceneEntry.UTF8String); entry.close(); }
      auto metadata = _resources->files->open("project.json"); metadata.close();
      auto shell = _resources->runtimeFiles->open("index.html"); shell.close();
    } else { auto entry = _resources->files->open(_entry.UTF8String); entry.close(); }
    state->contextDestroyed = false;
    auto reporter = [state](const dw::WebResourceEvent& event) { state->resourceEvent(event); };
    _resources->handler = state->scene ? dw::makeSceneRequestContext(_resources->files, _resources->runtimeFiles,
        state->scene, state->host, reporter) : dw::makeLocalWebRequestContext(_resources->files, state->host, reporter);
    if (state->editor) _resources->handler = dw::makeEditorRequestContext(_resources->files, _resources->runtimeFiles, state->editor, state->host, reporter);
    CefRequestContextSettings settings;  // No cache path or shared context: private in-memory storage.
    _resources->context = CefRequestContext::CreateContext(settings, _resources->handler);
    if (!_resources->context || _resources->context->IsSharingWith(CefRequestContext::GetGlobalContext()))
      throw std::runtime_error("Could not create an isolated webpage context");
    state->clientDestroyed = false;
    _resources->client = DWMakeWebClient(state);
    CefWindowInfo window;
    if (state->editor) { window.SetAsChild((__bridge void*)_view, CefRect(0, 0, state->width, state->height)); window.runtime_style = CEF_RUNTIME_STYLE_ALLOY; }
    else window.SetAsWindowless(nullptr);
    CefBrowserSettings browserSettings;
    browserSettings.windowless_frame_rate = static_cast<int>(_frameRate);
    browserSettings.javascript_access_clipboard = STATE_DISABLED;
    browserSettings.javascript_dom_paste = STATE_DISABLED;
    state->browserClosed = false;
    if (!CefBrowserHost::CreateBrowser(window, _resources->client, url, browserSettings, nullptr, _resources->context)) {
      state->browserClosed = true;
      throw std::runtime_error("CEF rejected page creation");
    }
    fprintf(stderr, "DWWEB page-start origin=%s\n", _origin.UTF8String);
  } catch (const std::exception& error) { state->fail(error.what()); }
}
- (void)closeWithCompletion:(void (^)(NSError*))completion {
  DWRequireWebMainThread();
  if (_closeFailure) { completion(_closeFailure); return; }
  if (_closed) { completion(nil); return; }
  [_completions addObject:[completion copy]];
  auto state = _resources->state;
  if (state->closing.exchange(true)) return;
  [_audioOutput close];
  if (state->scene) { std::lock_guard lock(state->scene->mutex); state->scene->retired = true; state->scene->events.clear(); }
  if (state->editor) { std::lock_guard lock(state->editor->mutex); state->editor->retired = true; state->editor->events.clear(); }
  [self failEditorCommands:DWWebError(@"Editor command cancelled because page is closing")];
  [self failSceneCommands:DWWebError(@"Scene command cancelled because the page is closing")];
  _ready = NO; self.onReady = nil;
  _closeDeadline = NSProcessInfo.processInfo.systemUptime + 5;
  if (state->browser) state->browser->GetHost()->CloseBrowser(true);
  [self tick];
}
- (void)tick {
  DWRequireWebMainThread();
  if (_closed || _closeFailure) return;
  auto state = _resources->state;
  if (!state->closing) {
    [self drainSceneEvents];
    [self drainEditorEvents];
    if (state->closing) { [self tick]; return; }
    if (state->audio && state->audio->errorCode() != DWWebAudioError::none && state->failure(false).empty())
      state->fail("Native webpage audio output failed (code " + std::to_string(int(state->audio->errorCode())) + ")");
    if (_started && !_ready && NSProcessInfo.processInfo.systemUptime > _prepareDeadline)
      state->fail("Webpage preparation exceeded its 10-second deadline");
    const auto failure = state->failure(false);
    if (!failure.empty()) {
      _ready = NO;
      [self failSceneCommands:DWWebError(@(failure.c_str()))];
      if (!_reportedFailure) { _reportedFailure = YES; if (self.onError) self.onError(DWWebError(@(failure.c_str()))); }
    } else if (state->loaded && !_ready && (state->editor ? state->engineReady :
        (state->painted && (!state->scene || (state->engineReady && state->committedPaints > state->engineReadyAfterPaint))))) {
      _ready = YES;
      if (self.onReady) self.onReady();
    }
    return;
  }
  if (state->browserClosed && !_releasedReferences) {
    _resources->client = nullptr; _resources->context = nullptr; _resources->handler = nullptr; _resources->files = nullptr; _resources->runtimeFiles = nullptr;
    _releasedReferences = YES;
  }
  const bool released = state->browserClosed && state->clientDestroyed && state->contextDestroyed &&
      state->opened == state->released && (!state->audio || state->audio->released());
  auto error = state->failure(true);
  if (!released && NSProcessInfo.processInfo.systemUptime >= _closeDeadline && error.empty())
    error = "Webpage close exceeded its 5-second deadline; resource slot remains owned";
  if (error.empty() && !released) return;
  if (!error.empty()) _closeFailure = DWWebError(@(error.c_str()));
  else { _closed = YES; [_runtime retirePage:self]; }
  NSArray* callbacks = [_completions copy]; [_completions removeAllObjects];
  fprintf(stderr, "DWWEB page-close origin=%s released=%d opened=%u closedFiles=%u failed=%d shutdownDisconnects=%u\n", _origin.UTF8String,
          int(released), state->opened.load(), state->released.load(), _closeFailure != nil, state->shutdownDisconnects.load());
  for (void (^callback)(NSError*) in callbacks) callback(_closeFailure);
}
@end
