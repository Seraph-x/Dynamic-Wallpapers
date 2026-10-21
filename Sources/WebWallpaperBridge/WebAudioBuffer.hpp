#pragma once
#include "TimedAudioRing.hpp"
#include <atomic>

enum class DWWebAudioError { none, format, invalidPacket, overflow, control, render, stream, deviceChanged };

/// CEF has one producer per browser; AVAudioEngine has one render consumer.
/// Main-thread controls own epochs. Error publication is safe on any callback.
class DWWebAudioBuffer {
 public:
  static constexpr int sampleRate = 48000, packetFrames = 480;
  explicit DWWebAudioBuffer(double delay) : delaySeconds(delay), ring_(sampleRate, delay, capacityForDelay(delay)) {}
  const double delaySeconds;
  std::atomic<uint64_t> streamStarts{0}, streamStops{0}, packets{0}, droppedAfterClose{0};
  std::atomic<unsigned> activeCallbacks{0}, activeRenders{0};
  std::atomic<bool> outputStopped{false};

  void fail(DWWebAudioError error) {
    auto expected = DWWebAudioError::none;
    error_.compare_exchange_strong(expected, error);
  }
  DWWebAudioError errorCode() const { return error_.load(); }
  bool setGain(float gain, double host) {
    if (!std::isfinite(gain) || gain < 0 || gain > 1 || !std::isfinite(host) || host < 0) {
      fail(DWWebAudioError::control); return false;
    }
    if (gain > 0 && (closing_ || errorCode() != DWWebAudioError::none)) return false;
    const bool enable = gain > 0;
    if (enable != enabled_) {
      if (ring_.setPlaying(enable, std::ceil(host * sampleRate) / sampleRate) != AudioControlResult::accepted) {
        fail(DWWebAudioError::control); return false;
      }
      enabled_ = enable;
    }
    desiredGain_ = gain;
    if (!ring_.setGain(gain)) { fail(DWWebAudioError::control); return false; }
    return true;
  }
  void streamStarted(int rate, int channels, int frames) {
    ++streamStarts;
    if (streamActive_.exchange(true) || rate != sampleRate || channels != 2 || frames != packetFrames)
      fail(DWWebAudioError::format);
  }
  // CEF calls this on UI, after the last callback for this stream. A later
  // stream has a fresh timeline even when the page's desired gain is unchanged.
  void streamStopped(double host) {
    ++streamStops;
    if (!streamActive_.exchange(false)) { fail(DWWebAudioError::stream); return; }
    const float gain = desiredGain_;
    if (!setGain(0, host)) return;
    if (!closing_ && errorCode() == DWWebAudioError::none) setGain(gain, host);
  }
  void push(const float** data, int frames, int64_t pts) {
    ++activeCallbacks;
    struct Leave { std::atomic<unsigned>& count; ~Leave() { --count; } } leave{activeCallbacks};
    ++packets;
    if (closing_) { ++droppedAfterClose; return; }
    if (errorCode() != DWWebAudioError::none) return;
    if (!streamActive_ || !data || !data[0] || !data[1] || frames <= 0 || frames > 16384 || pts < 0) {
      fail(DWWebAudioError::invalidPacket); return;
    }
    for (int channel = 0; channel < 2; ++channel)
      for (int i = 0; i < frames; ++i)
        if (!std::isfinite(data[channel][i])) { fail(DWWebAudioError::invalidPacket); return; }
    const auto result = ring_.push(data, frames, pts);
    if (result == AudioPushResult::invalid) fail(DWWebAudioError::invalidPacket);
    if (result == AudioPushResult::overflow) fail(DWWebAudioError::overflow);
  }
  bool render(float* left, float* right, unsigned frames, double host) {
    ++activeRenders;
    struct Leave { std::atomic<unsigned>& count; ~Leave() { --count; } } leave{activeRenders};
    if (!left || !right) { fail(DWWebAudioError::render); return false; }
    const bool valid = ring_.render(left, right, frames, host);
    if (!valid) fail(DWWebAudioError::render);
    // Includes errors published during this block. Device buffers already
    // submitted are outside our ownership and are measured separately.
    if (closing_ || errorCode() != DWWebAudioError::none) {
      std::fill_n(left, frames, 0); std::fill_n(right, frames, 0);
    }
    return valid;
  }
  void beginClose(double host) { closing_ = true; setGain(0, host); }
  bool released() const {
    return closing_ && outputStopped && streamStarts == streamStops && activeCallbacks == 0 && activeRenders == 0;
  }
  AudioRingStats stats() const { return ring_.stats(); }

 private:
  static size_t capacityForDelay(double delay) {
    const double frames = std::ceil(delay * sampleRate) + 4 * packetFrames;
    if (!std::isfinite(delay) || delay < 0 || !std::isfinite(frames) ||
        frames >= double(std::numeric_limits<size_t>::max()))
      throw std::invalid_argument("invalid native audio queue capacity");
    return std::max<size_t>(16384, size_t(frames));
  }
  TimedAudioRing<> ring_;
  std::atomic<DWWebAudioError> error_{DWWebAudioError::none};
  std::atomic<bool> closing_{false}, streamActive_{false};
  bool enabled_ = false;
  float desiredGain_ = 0;
};
