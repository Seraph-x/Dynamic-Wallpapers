#import <AppKit/AppKit.h>
#include "LocalWebRequestContext.hpp"
#include "source-outcome.hpp"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_parser.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include <atomic>
#include <array>
#include <cstdio>
#include <memory>

@interface SourceProbeApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation SourceProbeApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent*)event { CefScopedSendingEvent scope; [super sendEvent:event]; }
@end

static void report(const std::shared_ptr<SourceState>& state, const dw::WebResourceEvent& event) {
  if (event.kind == "resource-error" || event.kind == "file-error") ++state->resourceErrors;
  if (event.kind == "resource-open") ++state->resourcesOpened;
  if (event.kind == "resource-close") ++state->resourcesClosed;
  auto dictionary = CefDictionaryValue::Create();
  dictionary->SetString("kind", event.kind); dictionary->SetString("url", event.url);
  dictionary->SetString("detail", event.detail);
  dictionary->SetBool("browserPresent", event.browserPresent); dictionary->SetBool("framePresent", event.framePresent);
  auto value = CefValue::Create(); value->SetDictionary(dictionary);
  fprintf(stderr, "SOURCE_EVENT %s\n", CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString().c_str());
}

class SourceClient final : public CefClient, public CefLifeSpanHandler, public CefRenderHandler,
                           public CefLoadHandler, public CefDisplayHandler, public CefRequestHandler {
 public:
  SourceClient(std::shared_ptr<SourceState> state, std::string host) : state_(std::move(state)), host_(std::move(host)) {}
  ~SourceClient() override { state_->clientDestroyed = true; fprintf(stderr, "SOURCE_LIFECYCLE client-destroyed\n"); }
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> value) override { browser = value; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    browser = nullptr; state_->closed = true; fprintf(stderr, "SOURCE_LIFECYCLE before-close\n");
  }
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override { rect = CefRect(0, 0, 640, 360); }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList&, const void* buffer, int width, int height) override {
    if (!state_->loaded || width <= 20 || height <= 20) return;
    const auto* pixel = static_cast<const unsigned char*>(buffer) + (20 * width + 20) * 4;
    if (pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0) state_->greenPaint = true;
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int status) override {
    if (frame->IsMain()) { state_->loaded = status == 200; if (status != 200) state_->failed = true; }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
                   const CefString& message, const CefString& url) override {
    report(state_, {"load-error", url, std::to_string(code) + ": " + message.ToString()});
    if (frame->IsMain()) state_->failed = true;
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request, bool, bool) override {
    try { dw::localWebPath(request->GetURL(), host_); return false; }
    catch (const std::exception& error) { report(state_, {"navigation-denied", request->GetURL(), error.what()}); return true; }
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& url, const CefString&,
      WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    report(state_, {"popup-denied", url, "No popup browser"}); return true;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int code, const CefString& message) override {
    state_->failed = true;
    report(state_, {"renderer-error", "", std::to_string(status) + "/" + std::to_string(code) + ": " + message.ToString()});
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString& message, const CefString&, int) override {
    auto text = message.ToString();
    report(state_, {"console", "", text});
    if (text.rfind("SOURCE_RESULT ", 0) == 0) state_->result = text.substr(14);
    if (text.rfind("SOURCE_FAILURE ", 0) == 0) state_->failed = true;
    return true;
  }
 private:
  const std::shared_ptr<SourceState> state_;
  const std::string host_;
  IMPLEMENT_REFCOUNTING(SourceClient);
};

static void pump() {
  CefDoMessageLoopWork();
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}

class SourceApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  bool initialized = false;
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override {
    initialized = true;
    fprintf(stderr, "SOURCE_LIFECYCLE global-context-initialized\n");
  }
 private:
  IMPLEMENT_REFCOUNTING(SourceApp);
};

int main(int argc, char** argv) {
  @autoreleasepool {
    bool helper = false;
    for (int i = 1; i < argc; ++i) if (std::string(argv[i]).rfind("--type=", 0) == 0) helper = true;
    CefScopedSandboxContext sandbox;
    if (helper && !sandbox.Initialize(argc, argv)) { fprintf(stderr, "SOURCE_ERROR helper sandbox initialization failed\n"); return 2; }
    CefScopedLibraryLoader loader;
    if (!(helper ? loader.LoadInHelper() : loader.LoadInMain())) return 3;
    CefMainArgs args(argc, argv);
    CefRefPtr<SourceApp> app = new SourceApp;
    int subprocess = CefExecuteProcess(args, app, nullptr);
    if (subprocess >= 0) return subprocess;
    if (argc != 4) { fprintf(stderr, "usage: CEFSourceProbe PROJECT_ROOT CACHE_ROOT HOST\n"); return 64; }
    [SourceProbeApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    CefSettings settings;
    settings.no_sandbox = false;
    settings.windowless_rendering_enabled = true;
    CefString(&settings.root_cache_path) = argv[2];
    if (!CefInitialize(args, settings, app, nullptr)) return 4;
    std::array<std::shared_ptr<SourceState>, 2> states{
        std::make_shared<SourceState>(), std::make_shared<SourceState>()};
    std::array<bool, 2> successes{false, false};
    CefRefPtr<CefRequestContext> previousContext;
    for (size_t round = 0; round < states.size(); ++round) {
      auto state = states[round];
      bool success = false;
      const std::string host = "round" + std::to_string(round + 1) + "-" + argv[3];
      fprintf(stderr, "SOURCE_ROUND begin=%zu origin=https://%s\n", round + 1, host.c_str());
      try {
        auto files = std::make_shared<dw::ProjectFiles>(argv[1], [state](const std::string& message) {
          report(state, {"file-error", "", message});
        });
        CefRefPtr<CefRequestContextHandler> handler = dw::makeLocalWebRequestContext(files, host,
            [state](const dw::WebResourceEvent& event) { report(state, event); });
        CefRequestContextSettings contextSettings;  // Empty cache_path: independent in-memory context.
        CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(contextSettings, handler);
        if (previousContext) {
          const bool same = context->IsSame(previousContext);
          const bool sharing = context->IsSharingWith(previousContext);
          fprintf(stderr, "SOURCE_ISOLATION same=%d sharing=%d\n", same, sharing);
          if (same || sharing) throw std::runtime_error("Round contexts unexpectedly share storage");
          // The old page is already closed. Release its last harness context ref
          // after this identity comparison, before creating the next page.
          previousContext = nullptr;
        }
        CefRefPtr<SourceClient> client = new SourceClient(state, host);
        CefWindowInfo window; window.SetAsWindowless(nullptr);
        CefBrowserSettings browserSettings;
        if (!CefBrowserHost::CreateBrowser(window, client, "https://" + host + "/index.html",
                                           browserSettings, nullptr, context)) throw std::runtime_error("CreateBrowser failed");
        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!state->failed && !(state->loaded && state->greenPaint && !state->result.empty()) && [deadline timeIntervalSinceNow] > 0) pump();
        success = !state->failed && state->loaded && state->greenPaint && !state->result.empty();
        fprintf(stderr, "SOURCE_LIFECYCLE close-request pageChecksReady=%d\n", success);
        if (client->browser) client->browser->GetHost()->CloseBrowser(true);
        deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!state->closed && [deadline timeIntervalSinceNow] > 0) pump();
        if (round == 0) previousContext = context;
        client = nullptr; context = nullptr; handler = nullptr; files = nullptr;
        while (!state->clientDestroyed && [deadline timeIntervalSinceNow] > 0) pump();
        success = success && state->closed && state->clientDestroyed;
      } catch (const std::exception& error) {
        success = false;
        state->failed = true;
        fprintf(stderr, "SOURCE_ERROR %s\n", error.what());
      }
      successes[round] = success;
      fprintf(stderr, "SOURCE_ROUND end=%zu closed=%d clientDestroyed=%d\n", round + 1, state->closed, state->clientDestroyed);
      if (!success) break;  // Do not start a replacement after failed page closure.
    }
    previousContext = nullptr;
    fprintf(stderr, "SOURCE_LIFECYCLE before-shutdown\n");
    CefShutdown();
    fprintf(stderr, "SOURCE_LIFECYCLE after-shutdown\n");
    bool allPassed = true;
    for (size_t round = 0; round < states.size(); ++round) {
      const auto& state = states[round];
      const bool success = state->passed(successes[round], app->initialized);
      allPassed = allPassed && success;
      fprintf(stderr, "SOURCE_SUMMARY success=%d round=%zu loaded=%d greenPaint=%d closed=%d clientDestroyed=%d opened=%d released=%d resourceErrors=%d sandboxRequested=1\n",
          success, round + 1, state->loaded, state->greenPaint, state->closed, state->clientDestroyed,
          int(state->resourcesOpened), int(state->resourcesClosed), int(state->resourceErrors));
      fprintf(stderr, "SOURCE_RESULT %s\n", state->result.c_str());
    }
    return allPassed ? 0 : 1;
  }
}
