#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include <cstdio>

int main(int argc, char** argv) {
  @autoreleasepool {
    CefScopedSandboxContext sandbox;
    if (!sandbox.Initialize(argc, argv)) { fprintf(stderr, "DWWEB helper sandbox initialization failed\n"); return 2; }
    CefScopedLibraryLoader loader;
    if (!loader.LoadInHelper()) { fprintf(stderr, "DWWEB helper framework load failed\n"); return 3; }
    CefMainArgs args(argc, argv);
    return CefExecuteProcess(args, nullptr, nullptr);
  }
}
