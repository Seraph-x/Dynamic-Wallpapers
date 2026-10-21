#include "WebPageState.hpp"
#include "include/cef_task.h"
#include "include/cef_audio_handler.h"
#include <time.h>

namespace {
class CloseCreatedPage final : public CefTask {
 public:
  explicit CloseCreatedPage(std::shared_ptr<DWWebPageState> state) : state_(std::move(state)) {}
  void Execute() override {
    if (state_->browser) state_->browser->GetHost()->CloseBrowser(true);
  }
 private:
  const std::shared_ptr<DWWebPageState> state_;
  IMPLEMENT_REFCOUNTING(CloseCreatedPage);
};
class WebClient final : public CefClient, public CefLifeSpanHandler, public CefRenderHandler,
    public CefLoadHandler, public CefDisplayHandler, public CefRequestHandler,
    public CefPermissionHandler, public CefDownloadHandler, public CefJSDialogHandler, public CefDialogHandler,
    public CefAudioHandler {
 public:
  explicit WebClient(std::shared_ptr<DWWebPageState> state) : state_(std::move(state)) {}
  ~WebClient() override { state_->clientDestroyed = true; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return this; }
  bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters& parameters) override {
    parameters.sample_rate = DWWebAudioBuffer::sampleRate;
    parameters.channel_layout = CEF_CHANNEL_LAYOUT_STEREO;
    parameters.frames_per_buffer = DWWebAudioBuffer::packetFrames;
    return true;
  }
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters& parameters, int channels) override {
    if (!state_->audio) { state_->fail("Native webpage audio output is unavailable"); return; }
    state_->audio->streamStarted(parameters.sample_rate, channels, parameters.frames_per_buffer);
  }
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float** data, int frames, int64_t pts) override {
    // Locked CEF 708dc14 audio_capturer.cc passes capture_time.since_origin(),
    // a monotonic TimeTicks value; its public Unix Epoch comment is inaccurate.
    if (state_->audio) state_->audio->push(data, frames, pts);
  }
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override {
    // CEF TimeTicks and AVAudioTime use the uptime clock, which excludes sleep.
    // macOS steady_clock includes sleep and would discard valid restart PCM.
    if (state_->audio) state_->audio->streamStopped(
        double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9);
  }
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString& message) override {
    state_->audioStreamError(message.ToString());
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    fprintf(stderr, "DWWEB after-created origin=%s closing=%d\n", state_->host.c_str(), int(state_->closing.load()));
    state_->browser = browser;
    // Alloy finishes accessing its platform delegate after this callback.
    // Closing inline can destroy that delegate before creation returns.
    if (state_->closing && !CefPostTask(TID_UI, new CloseCreatedPage(state_)))
      state_->fail("Could not schedule cancellation after browser creation");
    fprintf(stderr, "DWWEB after-created-return origin=%s\n", state_->host.c_str());
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    fprintf(stderr, "DWWEB before-close origin=%s\n", state_->host.c_str());
    state_->browser = nullptr; state_->browserClosed = true;
  }
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override { rect = CefRect(0, 0, state_->width, state_->height); }
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    info.device_scale_factor = state_->scale;
    info.rect = info.available_rect = CefRect(0, 0, state_->width, state_->height);
    return true;
  }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
               const void* buffer, int width, int height) override {
    if (type != PET_VIEW || state_->closing || !state_->loaded) return;
    if (state_->paint(buffer, width, height)) state_->painted = true;
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
    if (!frame->IsMain() || state_->closing) return;
    if (status != 200) { state_->fail("Main document returned HTTP " + std::to_string(status)); return; }
    state_->loaded = true;
    browser->GetHost()->Invalidate(PET_VIEW);
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& message, const CefString& url) override {
    if (code == ERR_ABORTED && state_->closing) return;  // An explicitly cancelled load, not a successful page.
    state_->fail("Load error " + std::to_string(code) + ": " + url.ToString() + ": " + message.ToString());
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request, bool, bool) override {
    try { dw::localWebPath(request->GetURL(), state_->host); return false; }
    catch (const std::exception& error) { state_->fail(error.what()); return true; }
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& url, const CefString&,
      WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    state_->fail("Popup denied: " + url.ToString()); return true;
  }
  bool CanDownload(CefRefPtr<CefBrowser>, const CefString& url, const CefString&) override {
    state_->fail("Download denied: " + url.ToString()); return false;
  }
  bool OnFileDialog(CefRefPtr<CefBrowser>, FileDialogMode, const CefString&, const CefString&,
      const std::vector<CefString>&, const std::vector<CefString>&, const std::vector<CefString>&,
      CefRefPtr<CefFileDialogCallback> callback) override {
    callback->Cancel(); state_->fail("File chooser denied: webpage access is limited to its project"); return true;
  }
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& origin,
      uint32_t, CefRefPtr<CefMediaAccessCallback> callback) override {
    callback->Cancel(); state_->fail("Device permission denied: " + origin.ToString()); return true;
  }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString& origin, uint32_t,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY); state_->fail("Permission denied: " + origin.ToString()); return true;
  }
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString&, JSDialogType, const CefString& message,
      const CefString&, CefRefPtr<CefJSDialogCallback>, bool& suppress) override {
    suppress = true; state_->fail("Page dialog blocked: " + message.ToString()); return false;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int code, const CefString& message) override {
    state_->fail("Renderer terminated " + std::to_string(status) + "/" + std::to_string(code) + ": " + message.ToString());
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t severity, const CefString& message,
                        const CefString& source, int line) override {
    fprintf(stderr, "DWWEB console origin=%s severity=%d %s:%d %s\n", state_->host.c_str(), int(severity),
            source.ToString().c_str(), line, message.ToString().c_str());
    if (severity >= LOGSEVERITY_ERROR) {
      if (state_->isOptionalResource(source.ToString())) {
        fprintf(stderr, "DWWEB WARNING optional-resource-console %s\n", message.ToString().c_str());
      } else state_->fail(message.ToString());
    }
    return true;
  }
 private:
  const std::shared_ptr<DWWebPageState> state_;
  IMPLEMENT_REFCOUNTING(WebClient);
};
}
CefRefPtr<CefClient> DWMakeWebClient(std::shared_ptr<DWWebPageState> state) { return new WebClient(std::move(state)); }
