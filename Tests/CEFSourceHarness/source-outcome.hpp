#pragma once
#include <atomic>
#include <string>

struct SourceState {
  std::atomic<int> resourceErrors{0}, resourcesOpened{0}, resourcesClosed{0};
  bool loaded = false, greenPaint = false, closed = false, clientDestroyed = false, failed = false;
  std::string result;
  bool passed(bool priorChecksSucceeded, bool engineInitialized) const {
    return priorChecksSucceeded && engineInitialized && !failed && closed && clientDestroyed &&
           resourceErrors == 0 && resourcesOpened == resourcesClosed;
  }
};
