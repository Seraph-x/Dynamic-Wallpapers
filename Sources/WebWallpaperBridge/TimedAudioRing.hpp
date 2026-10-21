#pragma once
#include <array>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

enum class AudioPushResult { accepted, muted, invalid, overflow };
enum class AudioControlResult { accepted, invalid, full };
struct AudioRingStats {
  uint64_t missingFrames, preRollFrames, mutedFrames, lateFrames, staleFrames, cutoffFrames;
  uint64_t overflowFrames, invalidPackets, timestampDiscontinuities;
  uint64_t controlOverflows, invalidControls, invalidRenders, interruptedFrames, appliedEpoch;
  uint64_t resampledFrames;
};

// One push thread, one render thread, one control thread.
// The owner must join both callback lifetimes before destroying this object.
// Source PTS and render host time must already share the same monotonic origin.
// Gain does not reset the timeline; setPlaying changes its epoch and cutoff.
template<size_t Capacity = 16384, size_t ControlCapacity = 32>
class TimedAudioRing {
  static_assert(Capacity > 0 && ControlCapacity > 0);
  static_assert(std::atomic<uint64_t>::is_always_lock_free);
  static_assert(std::atomic<float>::is_always_lock_free);
 public:
  TimedAudioRing(double sampleRate, double delaySeconds, size_t capacity = Capacity)
      : rate_(sampleRate), delay_(delaySeconds), capacity_(capacity), samples_(capacity) {
    if (!capacity_ || !std::isfinite(rate_) || rate_ <= 0 || !std::isfinite(delay_) || delay_ < 0)
      throw std::invalid_argument("invalid audio sample rate or playout delay");
  }

  // Control-thread-only. A mute always publishes immediately and needs no queue
  // slot. An enable with a full control queue is rejected, never silently applied.
  AudioControlResult setPlaying(bool playing, double cutoffHostSeconds) {
    if (!std::isfinite(cutoffHostSeconds) || cutoffHostSeconds < 0 ||
        cutoffHostSeconds >= double(std::numeric_limits<int64_t>::max()) ||
        nextEpoch_ == (std::numeric_limits<uint64_t>::max() >> 1)) {
      ++invalidControls_; return AudioControlResult::invalid;
    }
    const uint64_t epoch = nextEpoch_ + 1;
    if (playing) {
      const auto w = commandWrite_.load(std::memory_order_relaxed);
      if (w - commandRead_.load(std::memory_order_acquire) == ControlCapacity) {
        ++controlOverflows_; return AudioControlResult::full;
      }
      commands_[w % ControlCapacity] = {epoch, cutoffHostSeconds};
      commandWrite_.store(w + 1, std::memory_order_release);
    }
    nextEpoch_ = epoch;
    control_.store((epoch << 1) | uint64_t(playing), std::memory_order_release);
    return AudioControlResult::accepted;
  }

  bool setGain(float gain) {
    if (!std::isfinite(gain) || gain < 0 || gain > 1) { ++invalidControls_; return false; }
    gain_.store(gain, std::memory_order_release);
    return true;
  }

  AudioPushResult push(const float** data, int frames, int64_t ptsMillis) {
    const auto token = control_.load(std::memory_order_acquire);
    if (!data || !data[0] || !data[1] || frames <= 0 || size_t(frames) > capacity_ || ptsMillis < 0) {
      ++invalidPackets_; return AudioPushResult::invalid;
    }
    if (!(token & 1)) { mutedFrames_ += frames; return AudioPushResult::muted; }
    const auto epoch = token >> 1;
    const int64_t origin = producerEpoch_ == epoch ? sourceOriginMillis_ : ptsMillis;
    double start = double(ptsMillis - origin) / 1000;
    bool discontinuity = false;
    // Initial PTS locates the true source time within a 1 ms interval. Track
    // the intersection of later observations, preserving the initial nominal
    // sample timeline (at most 1 ms phase uncertainty, no per-packet drift).
    double offsetLow = 0, offsetHigh = .001;
    constexpr double roundingTolerance = 1e-9;
    if (producerEpoch_ == epoch) {
      offsetLow = std::max(sourceOffsetLow_, start - nextSourceTime_);
      offsetHigh = std::min(sourceOffsetHigh_, start + .001 - nextSourceTime_);
      if (offsetHigh - offsetLow > roundingTolerance) {
        start = nextSourceTime_;
      } else if (start + .001 <= nextSourceTime_ + sourceOffsetLow_ + roundingTolerance) {
        ++invalidPackets_; return AudioPushResult::invalid;
      } else {
        ++timestampDiscontinuities_; discontinuity = true;
        offsetLow = 0; offsetHigh = .001;
      }
    }
    const auto w = write_.load(std::memory_order_relaxed);
    if (uint64_t(frames) > capacity_ - (w - read_.load(std::memory_order_acquire))) {
      overflowFrames_ += frames; return AudioPushResult::overflow;
    }
    if (discontinuity) ++segment_;
    for (int i = 0; i < frames; ++i)
      samples_[(w + i) % capacity_] =
          {data[0][i], data[1][i], start + i / rate_, epoch, origin, w + uint64_t(i), segment_};
    producerEpoch_ = epoch; sourceOriginMillis_ = origin;
    nextSourceTime_ = start + frames / rate_;
    sourceOffsetLow_ = offsetLow; sourceOffsetHigh_ = offsetHigh;
    write_.store(w + frames, std::memory_order_release);
    return AudioPushResult::accepted;
  }

  // Returns API validity, not audibility or sound-system success. Missing audio
  // is rendered as silence and remains an explicit counter, never "re-primed".
  bool render(float* left, float* right, unsigned frames, double hostTimeSeconds) {
    if (!left || !right || !std::isfinite(hostTimeSeconds) || hostTimeSeconds < 0) {
      ++invalidRenders_; return false;
    }
    for (unsigned i = 0; i < frames; ++i) left[i] = right[i] = 0;
    const auto token = control_.load(std::memory_order_acquire);
    const auto epoch = token >> 1;
    applyCommands(epoch);
    auto r = read_.load(std::memory_order_relaxed);
    const auto w = write_.load(std::memory_order_acquire);
    if (!(token & 1)) {
      // Do not discard packets from an enable that raced this muted snapshot.
      const auto began = r;
      while (r < w && samples_[r % capacity_].epoch <= epoch) ++r;
      staleFrames_ += r - began;
      read_.store(r, std::memory_order_release);
      hasLeft_ = false; hasPreviousTarget_ = false;
      appliedEpoch_.store(epoch, std::memory_order_release);
      return true;
    }
    if (consumerEpoch_ != epoch) { ++invalidRenders_; return false; }
    uint64_t missing = 0, preRoll = 0, resampled = 0;
    const float gain = gain_.load(std::memory_order_acquire);
    const double blockTime = hostTimeSeconds - double(consumerOriginSeconds_) - delay_;
    // The supplied host double is already rounded. One ULP bounds that input
    // uncertainty; local operations add their own representable spacing.
    targetTolerance_ = timeTolerance + ulp(hostTimeSeconds) + ulp(blockTime) + ulp(delay_);
    if (targetTolerance_ >= .5 / rate_) { ++invalidRenders_; return false; }
    for (unsigned i = 0; i < frames; ++i) {
      const double target = blockTime + i / rate_;
      float sourceLeft = 0, sourceRight = 0;
      bool interpolated = false;
      if (sampleAt(r, w, epoch, target, sourceLeft, sourceRight, interpolated)) {
        left[i] = sourceLeft * gain; right[i] = sourceRight * gain;
        resampled += interpolated;
      } else if (target < cutoff_ - targetTolerance_) {
        ++preRoll;
      } else {
        ++missing;
      }
      previousTarget_ = target; hasPreviousTarget_ = true;
    }
    read_.store(r, std::memory_order_release);
    // This prevents a control change observed during rendering from leaving
    // nonzero output in this block. Already submitted device buffers are outside
    // this queue's ownership and cannot be recalled by this check.
    if (control_.load(std::memory_order_acquire) != token) {
      for (unsigned i = 0; i < frames; ++i) left[i] = right[i] = 0;
      interruptedFrames_ += frames;
    } else {
      missingFrames_ += missing; preRollFrames_ += preRoll; resampledFrames_ += resampled;
      appliedEpoch_.store(epoch, std::memory_order_release);
    }
    return true;
  }

  AudioRingStats stats() const {
    return {missingFrames_.load(), preRollFrames_.load(), mutedFrames_.load(),
      lateFrames_.load(), staleFrames_.load(), cutoffFrames_.load(), overflowFrames_.load(),
      invalidPackets_.load(), timestampDiscontinuities_.load(), controlOverflows_.load(),
      invalidControls_.load(), invalidRenders_.load(), interruptedFrames_.load(), appliedEpoch_.load(),
      resampledFrames_.load()};
  }

 private:
  struct Frame {
    float left, right; double sourceTime; uint64_t epoch;
    int64_t originMillis; uint64_t sequence, segment;
  };
  struct Command { uint64_t epoch; double cutoff; };
  void applyCommands(uint64_t epoch) {
    auto r = commandRead_.load(std::memory_order_relaxed);
    const auto w = commandWrite_.load(std::memory_order_acquire);
    while (r < w && commands_[r % ControlCapacity].epoch <= epoch) {
      const auto& command = commands_[r++ % ControlCapacity];
      consumerEpoch_ = command.epoch;
      consumerOriginSeconds_ = int64_t(std::floor(command.cutoff));
      cutoff_ = command.cutoff - double(consumerOriginSeconds_);
      cutoffTolerance_ = timeTolerance + ulp(command.cutoff);
      hasLeft_ = false; hasPreviousTarget_ = false;
    }
    commandRead_.store(r, std::memory_order_release);
  }
  // Floating point arithmetic tolerance (1 ns), not a sample-matching window.
  static constexpr double timeTolerance = 1e-9;
  static double ulp(double value) {
    return std::nextafter(std::abs(value), std::numeric_limits<double>::infinity()) - std::abs(value);
  }
  double sourceTime(const Frame& frame) const {
    return double(frame.originMillis / 1000 - consumerOriginSeconds_) +
           double(frame.originMillis % 1000) / 1000 + frame.sourceTime;
  }
  void discardIneligible(uint64_t& r, uint64_t w, uint64_t epoch) {
    while (r < w) {
      const auto& sample = samples_[r % capacity_];
      if (sample.epoch > epoch) break;
      if (sample.epoch < epoch) ++staleFrames_;
      else if (sourceTime(sample) + cutoffTolerance_ < cutoff_) ++cutoffFrames_;
      else break;
      ++r;
    }
  }
  bool sampleAt(uint64_t& r, uint64_t w, uint64_t epoch, double target,
                float& left, float& right, bool& interpolated) {
    discardIneligible(r, w, epoch);
    while (r < w && samples_[r % capacity_].epoch == epoch &&
           sourceTime(samples_[r % capacity_]) <= target + targetTolerance_) {
      // A newly arrived sample already requested by an earlier render is late.
      // Advancing over samples between two output times is normal resampling.
      const auto& incoming = samples_[r % capacity_];
      if (hasPreviousTarget_ ? sourceTime(incoming) <= previousTarget_ + targetTolerance_
                            : sourceTime(incoming) + 1 / rate_ <= target + targetTolerance_)
        ++lateFrames_;
      leftSample_ = samples_[r++ % capacity_]; hasLeft_ = true;
      discardIneligible(r, w, epoch);
    }
    if (!hasLeft_ || target < sourceTime(leftSample_) - targetTolerance_) return false;
    if (std::abs(target - sourceTime(leftSample_)) <= targetTolerance_) {
      left = leftSample_.left; right = leftSample_.right; return true;
    }
    if (r == w || samples_[r % capacity_].epoch != epoch) return false;
    const auto& next = samples_[r % capacity_];
    // Adjacency is an integer source sequence, not subtraction of large clocks.
    // A timestamp discontinuity starts a new segment, so real gaps stay gaps.
    if (next.segment != leftSample_.segment || next.sequence != leftSample_.sequence + 1 ||
        target >= sourceTime(next)) return false;
    const double weight = (target - sourceTime(leftSample_)) * rate_;
    left = float(leftSample_.left + weight * (next.left - leftSample_.left));
    right = float(leftSample_.right + weight * (next.right - leftSample_.right));
    interpolated = true; return true;
  }
  const double rate_, delay_;
  const size_t capacity_;
  std::vector<Frame> samples_;  // Allocated once, before producer/render callbacks begin.
  std::array<Command, ControlCapacity> commands_{};
  std::atomic<uint64_t> read_{0}, write_{0}, commandRead_{0}, commandWrite_{0}, control_{0};
  std::atomic<float> gain_{0};
  uint64_t nextEpoch_ = 0; // control thread only
  uint64_t producerEpoch_ = 0; // producer thread only
  double nextSourceTime_ = 0; // producer thread only, relative to sourceOriginMillis_
  int64_t sourceOriginMillis_ = 0;
  uint64_t segment_ = 0;
  double sourceOffsetLow_ = 0, sourceOffsetHigh_ = .001; // producer thread only
  uint64_t consumerEpoch_ = 0; // render thread only
  double cutoff_ = 0; // render thread only, relative to consumerOriginSeconds_
  int64_t consumerOriginSeconds_ = 0;
  double targetTolerance_ = timeTolerance, cutoffTolerance_ = timeTolerance;
  Frame leftSample_{}; // render-owned copy, never retains a released queue slot
  bool hasLeft_ = false, hasPreviousTarget_ = false;
  double previousTarget_ = 0;
  std::atomic<uint64_t> missingFrames_{0}, preRollFrames_{0}, mutedFrames_{0}, lateFrames_{0};
  std::atomic<uint64_t> staleFrames_{0}, cutoffFrames_{0}, overflowFrames_{0}, invalidPackets_{0};
  std::atomic<uint64_t> timestampDiscontinuities_{0}, controlOverflows_{0}, invalidControls_{0};
  std::atomic<uint64_t> invalidRenders_{0}, interruptedFrames_{0}, appliedEpoch_{0}, resampledFrames_{0};
};
