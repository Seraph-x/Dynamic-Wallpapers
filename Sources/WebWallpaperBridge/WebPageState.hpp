#pragma once
#include "LocalWebRequestContext.hpp"
#include "include/cef_client.h"
#include "WebAudioBuffer.hpp"
#include <atomic>
#include <functional>
#include <mutex>
#include <unordered_set>

struct DWWebPageState {
  enum class FailureScope { operation, page };
  const std::string host;
  const int width, height;
  const float scale;
  CefRefPtr<CefBrowser> browser;  // CEF UI thread only.
  std::atomic<bool> closing{false}, browserClosed{true}, clientDestroyed{true}, contextDestroyed{true};
  std::atomic<unsigned> opened{0}, released{0};
  std::atomic<unsigned> shutdownDisconnects{0};
  std::atomic<unsigned> resourceWarnings{0};
  bool loaded = false, painted = false;
  std::shared_ptr<dw::SceneSession> scene;
  std::shared_ptr<dw::EditorSession> editor;
  uint64_t committedPaints = 0, engineReadyAfterPaint = 0;
  bool engineReady = false;
  std::function<bool(const void*, int, int)> paint;
  std::function<void(void*)> attachNative;
  std::function<void(void*)> detachNative;
  std::function<void(int, const std::string&, const std::string&, int)> consoleDiagnostic;
  std::shared_ptr<DWWebAudioBuffer> audio;
  std::mutex errorMutex;
  std::string error, closeError;
  std::unordered_set<std::string> optionalResourceURLs;
  DWWebPageState(std::string value, int w, int h, float s) : host(std::move(value)), width(w), height(h), scale(s) {}
  void fail(const std::string& message, FailureScope scope = FailureScope::operation) {
    if (audio) audio->fail(DWWebAudioError::stream);
    fprintf(stderr, "DWWEB ERROR origin=%s closing=%d %s\n", host.c_str(), int(closing.load()), message.c_str());
    std::lock_guard lock(errorMutex);
    // Content callbacks may arrive after close starts. Their actual error stays
    // visible as a page failure; only teardown failures own the close outcome.
    auto& destination = scope == FailureScope::page ? error : (closing ? closeError : error);
    if (destination.empty()) destination = message;
  }
  std::string failure(bool duringClose) {
    std::lock_guard lock(errorMutex); return duringClose ? closeError : error;
  }
  void optionalResourceMissing(const dw::WebResourceEvent& event) {
    ++resourceWarnings;
    fprintf(stderr, "DWWEB WARNING origin=%s %s: %s: %s\n", host.c_str(), event.kind.c_str(),
            event.url.c_str(), event.detail.c_str());
    std::lock_guard lock(errorMutex);
    optionalResourceURLs.insert(event.url);
  }
  bool isOptionalResource(const std::string& url) {
    std::lock_guard lock(errorMutex); return optionalResourceURLs.contains(url);
  }
  void audioStreamError(const std::string& message) {
    // Alloy destroys the loopback socket during CloseBrowser. The observed
    // disconnect is not a release acknowledgement: stream stop, callbacks,
    // browser/client/context and file ownership still gate page retirement.
    if (closing && audio && audio->outputStopped && message == "Socket closed unexpectedly") {
      ++shutdownDisconnects;
      fprintf(stderr, "DWWEB shutdown-audio-disconnect origin=%s %s\n", host.c_str(), message.c_str());
      return;
    }
    fail("Webpage audio stream failed: " + message);
  }
  void resourceEvent(const dw::WebResourceEvent& event) {
    if (event.kind == "resource-open") ++opened;
    else if (event.kind == "resource-close") ++released;
    else if (event.kind == "context-handler-destroyed") contextDestroyed = true;
    else if (event.kind == "scene-event-retired" || event.kind == "scene-spectrum-retired" || event.kind == "editor-event-retired")
      fprintf(stderr, "DWWEB cancelled-scene-event origin=%s %s\n", host.c_str(), event.detail.c_str());
    else if (event.kind == "resource-missing-optional") optionalResourceMissing(event);
    else if (event.kind == "resource-error" || event.kind == "file-error" || event.kind == "context-error" ||
             event.kind == "resource-denied" || event.kind == "request-denied" || event.kind == "protocol-denied")
      fail(event.kind + ": " + event.url + ": " + event.detail);
  }
};

CefRefPtr<CefClient> DWMakeWebClient(std::shared_ptr<DWWebPageState> state);
