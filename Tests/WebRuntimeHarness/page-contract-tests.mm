#include "WebPageState.hpp"
#include "include/cef_dialog_handler.h"
#include <array>
#include <cstdio>
#include <stdexcept>
#include <string>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void testPaintCommit(bool committed) {
  auto state = std::make_shared<DWWebPageState>("paint-contract.invalid", 1, 1, 1);
  const std::array<unsigned char, 4> pixel{0, 255, 0, 255};
  int paintCalls = 0;
  state->loaded = true;
  state->paint = [&](const void* buffer, int width, int height) -> bool {
    ++paintCalls;
    require(buffer == pixel.data() && width == 1 && height == 1,
            "OnPaint must pass the actual frame to the commit callback");
    return committed;
  };
  state->clientDestroyed = false;
  {
    auto client = DWMakeWebClient(state);
    auto renderer = client->GetRenderHandler();
    require(renderer != nullptr, "WebClient must expose a render handler");
    renderer->OnPaint(nullptr, PET_VIEW, {CefRect(0, 0, 1, 1)}, pixel.data(), 1, 1);
    require(paintCalls == 1, "loaded view paint must invoke the commit callback once");
    require(state->painted == committed,
            committed ? "successful frame commit must mark the page painted"
                      : "failed frame commit must not mark the page painted");
  }
  require(state->clientDestroyed, "paint contract test retained its CEF client");
}

class FileDialogRecorder final : public CefFileDialogCallback {
 public:
  unsigned cancellations = 0;
  unsigned continuations = 0;
  void Continue(const std::vector<CefString>&) override { ++continuations; }
  void Cancel() override { ++cancellations; }

 private:
  IMPLEMENT_REFCOUNTING(FileDialogRecorder);
};

void testFileDialogDenied() {
  for (const auto mode : {FILE_DIALOG_OPEN, FILE_DIALOG_OPEN_MULTIPLE,
                          FILE_DIALOG_OPEN_FOLDER, FILE_DIALOG_SAVE}) {
    auto state = std::make_shared<DWWebPageState>("dialog-contract.invalid", 1, 1, 1);
    state->clientDestroyed = false;
    {
      auto client = DWMakeWebClient(state);
      auto dialog = client->GetDialogHandler();
      require(dialog != nullptr, "WebClient must expose a file dialog handler");
      CefRefPtr<FileDialogRecorder> callback = new FileDialogRecorder;
      const bool handled = dialog->OnFileDialog(nullptr, mode, "Contract file chooser",
                                                "", {}, {}, {}, callback);
      require(handled, "file chooser denial must suppress the native default dialog");
      require(callback->cancellations == 1 && callback->continuations == 0,
              "file chooser denial must cancel exactly once and never continue");
      require(!state->failure(false).empty(), "file chooser denial must report a page failure");
      require(state->failure(true).empty(), "file chooser denial must not become a close failure");
    }
    require(state->clientDestroyed, "dialog contract test retained its CEF client");
  }
}
}  // namespace

// Invoke on the CEF UI thread after startup and before global shutdown.
// Every CEF reference is scoped to a test, including exception unwinding.
void DWRunPageContractTests() {
  std::string failures;
  const auto run = [&](const char* name, const auto& test) {
    try {
      test();
      fprintf(stderr, "WEB_PAGE_CONTRACT PASS %s\n", name);
    } catch (const std::exception& error) {
      fprintf(stderr, "WEB_PAGE_CONTRACT FAIL %s: %s\n", name, error.what());
      failures += std::string(name) + ": " + error.what() + "\n";
    }
  };
  run("rejected-frame", [] { testPaintCommit(false); });
  run("committed-frame", [] { testPaintCommit(true); });
  run("file-dialog-denied", testFileDialogDenied);
  if (!failures.empty()) throw std::runtime_error("Page contracts failed:\n" + failures);
}
