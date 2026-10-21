#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>

// Prototype lifetime accounting. The owner keeps this object alive until CEF
// shutdown. Client destruction proves no future client callbacks can begin;
// audio/device presentation time is a separate, explicitly estimated boundary.
class CloseBarrier {
 public:
  void requestClose() { requested_ = true; }
  bool requested() const { return requested_; }
  void streamStarted() { ++starts_; }
  void streamStopped() { ++stops_; }
  void callbackEntered() { ++callbacks_; }
  void callbackLeft() { --callbacks_; }
  void audioError() { ++errors_; }
  void browserClosed() { browserClosed_ = true; }
  void clientDestroyed() { clientDestroyed_ = true; }
  bool outputStopped(double lastNonzeroEndHost, double presentationLatency) {
    if (!std::isfinite(lastNonzeroEndHost) || lastNonzeroEndHost < 0 ||
        !std::isfinite(presentationLatency) || presentationLatency < 0 ||
        !std::isfinite(lastNonzeroEndHost + presentationLatency)) return false;
    presentationDeadline_ = lastNonzeroEndHost + presentationLatency;
    outputStopped_ = true;
    return true;
  }
  bool resourcesReleased() const {
    return requested_ && browserClosed_ && clientDestroyed_ && outputStopped_ &&
           callbacks_ == 0 && starts_ == stops_;
  }
  bool presentationDeadlineReached(double host) const {
    return resourcesReleased() && std::isfinite(host) && host >= presentationDeadline_;
  }
  uint64_t starts() const { return starts_; }
  uint64_t stops() const { return stops_; }
  uint64_t errors() const { return errors_; }
  uint64_t callbacks() const { return callbacks_; }
  double presentationDeadline() const { return presentationDeadline_; }
 private:
  std::atomic<bool> requested_{false}, browserClosed_{false}, clientDestroyed_{false}, outputStopped_{false};
  std::atomic<uint64_t> starts_{0}, stops_{0}, callbacks_{0}, errors_{0};
  // Main-thread-only; published before outputStopped_.
  double presentationDeadline_ = 0;
};
