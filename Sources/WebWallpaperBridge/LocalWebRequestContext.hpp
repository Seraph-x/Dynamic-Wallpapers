#pragma once
#include "LocalProjectFiles.hpp"
#include "SceneProtocol.hpp"
#include "include/cef_request_context_handler.h"
#include <memory>

namespace dw {
struct WebResourceEvent {
  std::string kind, url, detail;
  bool browserPresent = false;
  bool framePresent = false;
};
using WebResourceReporter = std::function<void(const WebResourceEvent&)>;

/// Instantiate before creating the browser. The context handler also receives
/// requests without browser/frame objects (including service-worker requests).
CefRefPtr<CefRequestContextHandler> makeLocalWebRequestContext(
    std::shared_ptr<ProjectFiles> files, std::string host, WebResourceReporter reporter);
CefRefPtr<CefRequestContextHandler> makeSceneRequestContext(
    std::shared_ptr<ProjectFiles> project, std::shared_ptr<ProjectFiles> runtime,
    std::shared_ptr<SceneSession> scene, std::string host, WebResourceReporter reporter);
CefRefPtr<CefRequestContextHandler> makeEditorRequestContext(
    std::shared_ptr<ProjectFiles> project, std::shared_ptr<ProjectFiles> runtime,
    std::shared_ptr<EditorSession> editor, std::string host, WebResourceReporter reporter);
std::string localWebPath(const CefString& url, const std::string& host);
}  // namespace dw
