#import "WebWallpaperBridge.h"
#include <cstdio>
#include <exception>

void DWRunPageStateTests();

int main() {
  @autoreleasepool {
    // No CEF loading or initialization: these tests exercise page state only.
    DWWebCreateApplication();
    try { DWRunPageStateTests(); return 0; }
    catch (const std::exception& error) {
      fprintf(stderr, "WEB_PAGE_STATE FAILED %s\n", error.what()); return 1;
    }
  }
}
