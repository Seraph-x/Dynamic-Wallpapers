#include "LocalWebRequestContext.hpp"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_scheme.h"
#include "include/wrapper/cef_stream_resource_handler.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <optional>
#include <system_error>
#include <unistd.h>

namespace dw {
std::string localWebPath(const CefString& url, const std::string& host) {
  CefURLParts parts;
  if (!CefParseURL(url, parts) || CefString(&parts.scheme) != "https" || CefString(&parts.host) != host ||
      !CefString(&parts.username).empty() || !CefString(&parts.password).empty() ||
      (!CefString(&parts.port).empty() && CefString(&parts.port) != "443"))
    throw std::runtime_error("Request outside this project's HTTPS origin");
  auto path = CefURIDecode(CefString(&parts.path), true,
      static_cast<cef_uri_unescape_rule_t>(UU_SPACES | UU_PATH_SEPARATORS | UU_URL_SPECIAL_CHARS_EXCEPT_PATH_SEPARATORS)).ToString();
  if (path.empty() || path.front() != '/' || path.find('\0') != std::string::npos)
    throw std::runtime_error("Invalid project URL path");
  return path.substr(1);  // Decode once; query and fragment never become filesystem components.
}

static CefResponse::HeaderMap localHeaders(const std::string& host, bool scene = false) {
  CefResponse::HeaderMap headers;
  headers.emplace("Cache-Control", "no-store");
  headers.emplace("X-Content-Type-Options", "nosniff");
  headers.emplace("Referrer-Policy", "no-referrer");
  if (scene) {
    // Engine SceneScript intentionally compiles author scene scripts. Only the
    // bundled runtime can be loaded as a script; frames and navigation are denied.
    headers.emplace("Content-Security-Policy", "default-src 'none'; script-src https://" + host +
        "/__runtime/ 'unsafe-eval'; style-src https://" + host + "/__runtime/ 'unsafe-inline'; "
        "img-src 'self' data: blob:; media-src 'self' data: blob:; font-src 'self' data: blob:; worker-src https://" + host + "/__runtime/ blob:; "
        "frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; connect-src https://" + host);
    return headers;
  }
  // Explicit HTTPS source avoids implicitly allowing a ws/wss upgrade of 'self'.
  headers.emplace("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; "
      "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' data: blob:; "
      "worker-src 'self' blob:; frame-src 'self'; object-src 'none'; base-uri 'self'; form-action 'none'; "
      "connect-src https://" + host);
  return headers;
}

class LocalFileResponse final : public CefResourceHandler {
 public:
  LocalFileResponse(std::shared_ptr<ProjectFiles> files, ProjectResource resource,
                    std::string url, std::string mime, std::string host, WebResourceReporter reporter, bool scene = false)
      : files_(std::move(files)), resource_(std::make_unique<ProjectResource>(std::move(resource))),
        url_(std::move(url)), mime_(std::move(mime)), headers_(localHeaders(host, scene)), reporter_(std::move(reporter)),
        length_(resource_->size()) { reporter_({"resource-open", url_, std::to_string(length_)}); }
  ~LocalFileResponse() override { Cancel(); }
  bool Open(CefRefPtr<CefRequest>, bool& handle, CefRefPtr<CefCallback>) override {
    handle = true; return true;
  }
  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& length, CefString&) override {
    response->SetStatus(200); response->SetMimeType(mime_); response->SetHeaderMap(headers_); length = length_;
  }
  bool Skip(int64_t requested, int64_t& skipped, CefRefPtr<CefResourceSkipCallback>) override {
    std::lock_guard lock(mutex_);
    if (!resource_ || requested < 0 || requested > length_ - offset_) { skipped = -2; return false; }
    offset_ += requested; skipped = requested; return true;
  }
  bool Read(void* output, int requested, int& read, CefRefPtr<CefResourceReadCallback>) override {
    std::lock_guard lock(mutex_);
    read = 0;
    if (!resource_ || offset_ == length_) return false;
    try {
      files_->verifyIdentity();
      if (requested <= 0) throw std::runtime_error("Invalid resource read length");
      ssize_t count;
      do { count = pread(resource_->descriptor(), output, std::min<int64_t>(requested, length_ - offset_), offset_); }
      while (count < 0 && errno == EINTR);
      if (count < 0) throw std::system_error(errno, std::generic_category(), "Read local resource");
      if (count == 0) throw std::runtime_error("Local resource truncated during request");
      offset_ += count; read = static_cast<int>(count); return true;
    } catch (const std::exception& error) {
      reporter_({"resource-error", url_, error.what()}); read = -2; return false;
    }
  }
  void Cancel() override {
    std::lock_guard lock(mutex_);
    if (!resource_) return;
    try { resource_->close(); reporter_({"resource-close", url_, "closed"}); }
    catch (const std::exception& error) { reporter_({"resource-error", url_, error.what()}); }
    resource_.reset();
  }
 private:
  std::shared_ptr<ProjectFiles> files_;
  std::unique_ptr<ProjectResource> resource_;
  const std::string url_, mime_;
  const CefResponse::HeaderMap headers_;
  WebResourceReporter reporter_;
  const int64_t length_;
  int64_t offset_ = 0;
  std::mutex mutex_;
  IMPLEMENT_REFCOUNTING(LocalFileResponse);
};

class StringReader final : public CefReadHandler {
 public:
  explicit StringReader(std::string body) : body_(std::move(body)) {}
  size_t Read(void* pointer, size_t size, size_t count) override {
    if (!size) return 0;
    count = std::min(count, (body_.size() - offset_) / size);
    memcpy(pointer, body_.data() + offset_, size * count); offset_ += size * count; return count;
  }
  int Seek(int64_t offset, int whence) override {
    int64_t next = whence == SEEK_SET ? offset : whence == SEEK_CUR ? int64_t(offset_) + offset :
        whence == SEEK_END ? int64_t(body_.size()) + offset : -1;
    if (next < 0 || uint64_t(next) > body_.size()) return -1;
    offset_ = size_t(next); return 0;
  }
  int64_t Tell() override { return int64_t(offset_); }
  int Eof() override { return offset_ == body_.size(); }
  bool MayBlock() override { return false; }
 private:
  const std::string body_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(StringReader);
};

class LocalRequestPolicy final : public CefResourceRequestHandler {
 public:
  LocalRequestPolicy(std::shared_ptr<ProjectFiles> files, std::string host, WebResourceReporter reporter)
      : files_(std::move(files)), host_(std::move(host)), reporter_(std::move(reporter)) {}
  LocalRequestPolicy(std::shared_ptr<ProjectFiles> files, std::shared_ptr<ProjectFiles> runtime,
                     std::shared_ptr<SceneSession> scene, std::string host, WebResourceReporter reporter)
      : files_(std::move(files)), runtime_(std::move(runtime)), scene_(std::move(scene)),
        host_(std::move(host)), reporter_(std::move(reporter)) {}
  void contextReady() { ready_.store(true); }
  void setEditor(std::shared_ptr<EditorSession> editor) { editor_ = std::move(editor); }
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                                    CefRefPtr<CefCallback>) override {
    try { validate(request, frame); return RV_CONTINUE; }
    catch (const std::exception& error) { reporter_({"request-denied", request->GetURL(), error.what()}); return RV_CANCEL; }
  }
  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                                 CefRefPtr<CefRequest> request) override {
    try {
      auto path = validate(request, frame);
      auto files = files_;
      bool sceneProjectResource = false;
      if (scene_ || editor_) {
        auto route = dataRoute(path, request->GetMethod(), frame && frame->IsMain());
        if (route.mount == SceneMount::config)
          return memoryResponse(200, "application/json", editor_ ? editor_->configuration : scene_->configuration);
        if (route.mount == SceneMount::spectrum) {
          auto spectrum = scene_->spectrumJSON();
          if (spectrum) return memoryResponse(200, "application/json", *spectrum);
          reporter_({"scene-spectrum-retired", request->GetURL(), "In-flight spectrum request cancelled after page close"});
          return memoryResponse(410, "application/json", "{\"error\":\"Scene closed\"}");
        }
        if (route.mount == SceneMount::event) {
          if (request->GetHeaderByName("Content-Type") != "application/json")
            throw std::runtime_error("Scene event requires application/json");
          auto data = request->GetPostData();
          if (!data || data->HasExcludedElements()) throw std::runtime_error("Missing scene event body");
          CefPostData::ElementVector elements; data->GetElements(elements);
          std::string body;
          for (auto element : elements) {
            if (element->GetType() != PDE_TYPE_BYTES || (!editor_ && element->GetBytesCount() > 8192 - body.size()))
              throw std::runtime_error("Invalid or oversized scene event body");
            std::string bytes(element->GetBytesCount(), '\0');
            element->GetBytes(bytes.size(), bytes.data()); body += bytes;
          }
          if (editor_ && !editor_->receive(body))
            reporter_({"editor-event-retired", request->GetURL(), "Editor event cancelled after close"});
          if (scene_ && !scene_->receive(body))
            reporter_({"scene-event-retired", request->GetURL(), "In-flight event delivered after page cancellation; not dispatched"});
          return memoryResponse(200, "application/json", "{}");
        }
        files = route.mount == SceneMount::runtime ? runtime_ : files_;
        sceneProjectResource = route.mount == SceneMount::project;
        path = route.path;
      }
      std::optional<ProjectResource> resource;
      try { resource.emplace(files->open(path)); }
      catch (const std::filesystem::filesystem_error& error) {
        if ((sceneProjectResource || path == "favicon.ico") && error.code() == std::errc::no_such_file_or_directory) {
          reporter_({"resource-missing-optional", request->GetURL(), error.what()});
          // Source.read distinguishes optional built-in asset probes (null)
          // from mandatory reads (engine error); a missing file is real HTTP 404.
          static const char body[] = "Local project resource not found\n";
          return new CefStreamResourceHandler(404, "Not Found", "text/plain", localHeaders(host_, scene_ != nullptr),
              CefStreamReader::CreateForData(const_cast<char*>(body), sizeof(body) - 1));
        }
        throw;
      }
      auto extension = std::filesystem::path(path).extension().string();
      if (!extension.empty()) extension.erase(0, 1);
      auto mime = (extension == "js" || extension == "mjs") ? CefString("text/javascript") : CefGetMimeType(extension);
      if (mime.empty()) mime = "application/octet-stream";
      return new LocalFileResponse(files, std::move(*resource), request->GetURL(), mime, host_, reporter_, scene_ != nullptr || editor_ != nullptr);
    } catch (const std::exception& error) {
      reporter_({"resource-denied", request->GetURL(), error.what()});
      // The error response is real HTTP failure, not successful placeholder content.
      static const char body[] = "Local project resource denied\n";
      return new CefStreamResourceHandler(403, "Forbidden", "text/plain", localHeaders(host_, scene_ != nullptr),
          CefStreamReader::CreateForData(const_cast<char*>(body), sizeof(body) - 1));
    }
  }
  void OnProtocolExecution(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                           bool& allow) override {
    allow = false; reporter_({"protocol-denied", request->GetURL(), "OS protocol handlers are not available"});
  }
 private:
  SceneRoute dataRoute(std::string path, const std::string& method, bool mainFrame) const {
    if (editor_) {
      if (path == "__editor/config") path = "__scene/config";
      else if (path == "__editor/event") path = "__scene/event";
      else if (path.starts_with("__scene/")) throw std::runtime_error("Scene API is not available to Editor");
    }
    return sceneRoute(path, method, mainFrame);
  }
  CefRefPtr<CefResourceHandler> memoryResponse(int status, const std::string& mime, const std::string& body) const {
    // The read handler owns the response bytes through asynchronous completion.
    auto stream = CefStreamReader::CreateForHandler(new StringReader(body));
    return new CefStreamResourceHandler(status, status == 200 ? "OK" : "Forbidden", mime, localHeaders(host_, scene_ != nullptr || editor_ != nullptr), stream);
  }
  std::string validate(CefRefPtr<CefRequest> request, CefRefPtr<CefFrame> frame) const {
    if (!ready_.load()) throw std::runtime_error("Local project context has not passed initialization");
    if (scene_ || editor_) {
      auto path = localWebPath(request->GetURL(), host_);
      auto route = dataRoute(path, request->GetMethod(), frame && frame->IsMain());
      if ((route.mount == SceneMount::event || route.mount == SceneMount::spectrum) &&
          localWebPath(frame->GetURL(), host_) != "__runtime/index.html")
        throw std::runtime_error("Scene data source is not the trusted main frame");
      return path;
    }
    if (request->GetMethod() != "GET" && request->GetMethod() != "HEAD")
      throw std::runtime_error("Only local resource GET/HEAD requests are available");
    return localWebPath(request->GetURL(), host_);
  }
  std::shared_ptr<ProjectFiles> files_, runtime_;
  std::shared_ptr<SceneSession> scene_;
  std::shared_ptr<EditorSession> editor_;
  const std::string host_;
  WebResourceReporter reporter_;
  std::atomic<bool> ready_{false};
  IMPLEMENT_REFCOUNTING(LocalRequestPolicy);
};

class LocalSchemeFactory final : public CefSchemeHandlerFactory {
 public:
  LocalSchemeFactory(CefRefPtr<LocalRequestPolicy> policy, WebResourceReporter reporter)
      : policy_(std::move(policy)), reporter_(std::move(reporter)) {}
  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString&, CefRefPtr<CefRequest> request) override {
    reporter_({"factory-request", request->GetURL(), request->GetMethod(), browser != nullptr, frame != nullptr});
    return policy_->GetResourceHandler(browser, frame, request);
  }
 private:
  CefRefPtr<LocalRequestPolicy> policy_;
  WebResourceReporter reporter_;
  IMPLEMENT_REFCOUNTING(LocalSchemeFactory);
};

class LocalContext final : public CefRequestContextHandler {
 public:
  LocalContext(std::shared_ptr<ProjectFiles> files, std::string host, WebResourceReporter reporter)
      : host_(std::move(host)), policy_(new LocalRequestPolicy(std::move(files), host_, reporter)), reporter_(std::move(reporter)) {}
  LocalContext(std::shared_ptr<ProjectFiles> project, std::shared_ptr<ProjectFiles> runtime,
               std::shared_ptr<SceneSession> scene, std::string host, WebResourceReporter reporter)
      : host_(std::move(host)), policy_(new LocalRequestPolicy(std::move(project), std::move(runtime),
          std::move(scene), host_, reporter)), reporter_(std::move(reporter)) {}
  ~LocalContext() override { reporter_({"context-handler-destroyed", "https://" + host_, "handler released; backend-context lifetime not asserted"}); }
  void setEditor(std::shared_ptr<EditorSession> editor) { policy_->setEditor(std::move(editor)); }
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    const auto origin = "https://" + host_;
    // CEF explicitly does not set an incognito default when both URLs are empty.
    // Every permitted page in this independent context has this one origin.
    context->SetContentSetting(origin, origin, CEF_CONTENT_SETTING_TYPE_SOUND, CEF_CONTENT_SETTING_VALUE_BLOCK);
    const auto value = context->GetContentSetting(origin, origin, CEF_CONTENT_SETTING_TYPE_SOUND);
    if (value != CEF_CONTENT_SETTING_VALUE_BLOCK) {
      reporter_({"context-error", origin, "SOUND block did not apply: " + std::to_string(value)}); return;
    }
    if (!context->RegisterSchemeHandlerFactory("https", host_, new LocalSchemeFactory(policy_, reporter_))) {
      reporter_({"context-error", origin, "Project scheme registration failed"}); return;
    }
    policy_->contextReady();
    reporter_({"context-ready", origin, std::to_string(value)});
  }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool, bool, const CefString&, bool& disableDefault) override {
    disableDefault = true;  // Applies to requests CEF delivers here; coverage is tested separately.
    reporter_({"request", request->GetURL(), request->GetMethod(), browser != nullptr, frame != nullptr});
    return policy_;
  }
 private:
  const std::string host_;
  CefRefPtr<LocalRequestPolicy> policy_;
  WebResourceReporter reporter_;
  IMPLEMENT_REFCOUNTING(LocalContext);
};

CefRefPtr<CefRequestContextHandler> makeLocalWebRequestContext(
    std::shared_ptr<ProjectFiles> files, std::string host, WebResourceReporter reporter) {
  return new LocalContext(std::move(files), std::move(host), std::move(reporter));
}
CefRefPtr<CefRequestContextHandler> makeSceneRequestContext(
    std::shared_ptr<ProjectFiles> project, std::shared_ptr<ProjectFiles> runtime,
    std::shared_ptr<SceneSession> scene, std::string host, WebResourceReporter reporter) {
  return new LocalContext(std::move(project), std::move(runtime), std::move(scene), std::move(host), std::move(reporter));
}
CefRefPtr<CefRequestContextHandler> makeEditorRequestContext(
    std::shared_ptr<ProjectFiles> project, std::shared_ptr<ProjectFiles> runtime,
    std::shared_ptr<EditorSession> editor, std::string host, WebResourceReporter reporter) {
  CefRefPtr<LocalContext> context = new LocalContext(std::move(project), std::move(runtime),
      std::shared_ptr<SceneSession>{}, std::move(host), std::move(reporter));
  context->setEditor(std::move(editor)); return context;
}
}  // namespace dw
