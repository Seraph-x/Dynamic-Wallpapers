#include "timed-audio-ring.h"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <thread>

static void require(bool condition, const char* message) {
  if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
static void continuous480To512(bool consumerFirst, bool jitter) {
  constexpr double rate = 48000, delay = 0.04;
  TimedAudioRing<> ring(rate, delay);
  require(ring.setPlaying(true, 0) == AudioControlResult::accepted, "enable");
  require(ring.setGain(1), "gain");
  std::array<float, 480> input;
  std::array<float, 512> l{}, r{};
  int produced = 0;
  // Event times use source frames, avoiding accumulated sleep/clock rounding.
  for (int rendered = 0; rendered < 48000; rendered += 512) {
    const auto arrival = [&](int frame) { return frame + (jitter && (frame / 480) % 2 ? 240 : 0); };
    while (consumerFirst ? arrival(produced) < rendered : arrival(produced) <= rendered) {
      for (int i = 0; i < 480; ++i) input[i] = float(produced + i + 1);
      const float* channels[] = {input.data(), input.data()};
      require(ring.push(channels, 480, produced / 48) == AudioPushResult::accepted, "push");
      produced += 480;
    }
    require(ring.render(l.data(), r.data(), 512, rendered / rate), "render");
    for (int i = 0; i < 512; ++i) {
      const int expected = rendered + i - 1920;
      require(l[i] == (expected < 0 ? 0 : float(expected + 1)), "480/512 exact continuous sample");
      require(l[i] == r[i], "stereo match");
    }
  }
  require(ring.stats().missingFrames == 0, "continuous running has no missing frames");
  require(ring.stats().preRollFrames == 1920, "pre-roll is visible");
}
static void missingDoesNotMoveDeadline() {
  TimedAudioRing<64> ring(1000, .010);
  ring.setPlaying(true, 0); ring.setGain(1);
  float values[] = {1, 2, 3, 4};
  const float* channels[] = {values, values};
  ring.push(channels, 4, 0);
  ring.push(channels, 4, 8); // 4 ms of genuinely absent source material.
  float l[22]{}, r[22]{};
  ring.render(l, r, 22, 0);
  require(l[10] == 1 && l[13] == 4 && l[18] == 1, "timestamps preserve the real gap");
  require(ring.stats().missingFrames == 4, "real gap is counted exactly");
  require(ring.stats().timestampDiscontinuities == 1, "PTS gap is visible");
  ring.render(l, r, 4, .022);
  require(ring.stats().missingFrames == 8, "empty stream does not move its deadline");
}
static void muteEpochAndCutoff() {
  TimedAudioRing<64> ring(1000, .010);
  ring.setGain(1); ring.setPlaying(true, 0);
  float old[] = {9, 9, 9, 9}, fresh[] = {1, 2, 3, 4};
  const float* oldChannels[] = {old, old};
  const float* newChannels[] = {fresh, fresh};
  ring.push(oldChannels, 4, 0);
  require(ring.setPlaying(false, .002) == AudioControlResult::accepted, "mute");
  require(ring.push(oldChannels, 4, 4) == AudioPushResult::muted, "muted callback rejected visibly");
  ring.setPlaying(true, .006);
  ring.push(newChannels, 4, 4); // Current epoch, but first two frames predate cutoff.
  float l[4]{}, r[4]{};
  ring.render(l, r, 2, .016);
  require(l[0] == 3 && l[1] == 4, "no old epoch or pre-cutoff data after resume");
  const auto stats = ring.stats();
  require(stats.staleFrames == 4 && stats.cutoffFrames == 2 && stats.mutedFrames == 4, "suppression counters");
  require(stats.missingFrames == 0, "resume has exact expected frames");
}
static void capacityWrapAndValidation() {
  TimedAudioRing<8, 2> ring(1000, 0);
  ring.setGain(1); ring.setPlaying(true, 0);
  float samples[] = {1, 2, 3, 4, 5, 6, 7, 8};
  const float* data[] = {samples, samples};
  require(ring.push(data, 8, 0) == AudioPushResult::accepted, "fill exact capacity");
  require(ring.push(data, 1, 8) == AudioPushResult::overflow, "full rejects without overwrite");
  float l[8]{}, r[8]{};
  ring.render(l, r, 4, 0);
  require(l[0] == 1 && l[3] == 4, "overflow preserved unread samples");
  require(ring.push(data, 4, 8) == AudioPushResult::accepted, "wrap push");
  ring.render(l, r, 8, .004);
  require(l[0] == 5 && l[3] == 8 && l[4] == 1 && l[7] == 4, "wrapped sample order");
  require(ring.push(data, 1, 0) == AudioPushResult::invalid, "backwards PTS rejected");
  require(ring.push(data, 0, 12) == AudioPushResult::invalid, "zero frames rejected");
  require(ring.push(data, 9, 12) == AudioPushResult::invalid, "oversize packet rejected");
  require(ring.push(nullptr, 1, 12) == AudioPushResult::invalid, "null data rejected");
  require(!ring.setGain(std::numeric_limits<float>::quiet_NaN()), "invalid gain rejected");
  require(!ring.render(l, r, 1, -1), "invalid render host time rejected");
  require(ring.stats().overflowFrames == 1 && ring.stats().invalidPackets == 4, "error counters exact");
  require(ring.setPlaying(true, .012) == AudioControlResult::accepted, "control one");
  require(ring.setPlaying(true, .012) == AudioControlResult::accepted, "control two");
  require(ring.setPlaying(true, .012) == AudioControlResult::full, "control overflow visible");
  require(ring.setPlaying(false, .012) == AudioControlResult::accepted, "mute never needs a queue slot");
  ring.render(l, r, 1, .012);
  require(l[0] == 0 && ring.stats().controlOverflows == 1, "mute still works with full control queue");
}
static void gainDoesNotResetTimeline() {
  TimedAudioRing<64> ring(1000, 0);
  ring.setPlaying(true, 0); ring.setGain(0);
  float samples[] = {1, 2, 3, 4}; const float* data[] = {samples, samples};
  ring.push(data, 4, 0);
  float l[2]{}, r[2]{};
  ring.render(l, r, 2, 0); require(l[0] == 0, "gain zero is silent");
  ring.setGain(.5f); ring.render(l, r, 2, .002);
  require(l[0] == 1.5f && l[1] == 2, "gain change preserves current source position");
}
static void timestampQuantizationAndLateFrames() {
  TimedAudioRing<64> ring(48000, 0);
  ring.setPlaying(true, 0); ring.setGain(1);
  float samples[] = {1, 2, 3, 4}; const float* data[] = {samples, samples};
  // Several short packets all legitimately share the same truncated millisecond.
  for (int i = 0; i < 4; ++i) require(ring.push(data, 4, 0) == AudioPushResult::accepted, "sub-ms packet");
  float l[8]{}, r[8]{};
  ring.render(l, r, 8, 8.0 / 48000);
  require(ring.stats().lateFrames == 8, "late samples remain visible");
  require(l[0] == 1 && l[7] == 4, "fractional timestamps do not collapse packet time");
  require(ring.stats().timestampDiscontinuities == 0, "quantization is not a discontinuity");
}
static void overlappingPTSIsNotRetimed() {
  TimedAudioRing<64> ring(1000, 0);
  ring.setPlaying(true, 0);
  float samples[10]{}; const float* data[] = {samples, samples};
  ring.push(data, 10, 0);
  require(ring.push(data, 10, 9) == AudioPushResult::invalid,
          "a 1ms backwards overlap must not be silently retimed as continuous");
}
static void concurrentSPSC() {
  TimedAudioRing<64> ring(1000, 0);
  ring.setPlaying(true, 0); ring.setGain(1);
  std::atomic<int> published{0};
  std::thread producer([&] {
    for (int packet = 0; packet < 1000; ++packet) {
      float value = float(packet + 1); const float* data[] = {&value, &value};
      // The test producer explicitly retries full capacity; this is not a queue
      // fallback. Production callers receive and must handle the overflow.
      AudioPushResult result;
      do {
        result = ring.push(data, 1, packet);
        if (result == AudioPushResult::overflow) std::this_thread::yield();
      } while (result == AudioPushResult::overflow);
      require(result == AudioPushResult::accepted, "concurrent push");
      published.store(packet + 1, std::memory_order_release);
    }
  });
  for (int packet = 0; packet < 1000; ++packet) {
    while (published.load(std::memory_order_acquire) < packet + 1) std::this_thread::yield();
    float l, r; ring.render(&l, &r, 1, packet / 1000.0);
    require(l == float(packet + 1) && r == l, "concurrent exact sample");
  }
  producer.join();
  require(ring.stats().missingFrames == 0, "concurrent stream exact");
}
static void fractionalPacketTime() {
  TimedAudioRing<256> ring(44100, 0);
  ring.setPlaying(true, 0); ring.setGain(1);
  float samples[10]; const float* data[] = {samples, samples};
  for (int packet = 0; packet < 20; ++packet) {
    for (int i = 0; i < 10; ++i) samples[i] = float(packet * 10 + i + 1);
    const int64_t pts = int64_t(std::floor((.0009 + packet * 10.0 / 44100) * 1000));
    require(ring.push(data, 10, pts) == AudioPushResult::accepted, "fractional packet PTS");
  }
  float l[200]{}, r[200]{}; ring.render(l, r, 200, 0);
  for (int i = 0; i < 200; ++i) require(l[i] == float(i + 1), "no quantization drift");
  require(ring.stats().timestampDiscontinuities == 0, "unknown initial sub-ms phase preserved");
}
static void resamplingDoesNotBridgeGapsOrInventLookahead() {
  TimedAudioRing<64> ring(1000, .010);
  ring.setPlaying(true, 0); ring.setGain(1);
  float values[] = {1, 2, 3, 4}; const float* data[] = {values, values};
  ring.push(data, 4, 0); ring.push(data, 4, 8);
  float l[22]{}, r[22]{}; ring.render(l, r, 22, .0005);
  require(l[10] == 1.5f && l[12] == 3.5f && l[18] == 1.5f, "adjacent samples interpolate");
  for (int i = 13; i < 18; ++i) require(l[i] == 0, "lost packet is never bridged");
  require(l[21] == 0, "missing right neighbor is not held or extrapolated");
  require(ring.stats().missingFrames == 6 && ring.stats().resampledFrames == 6,
          "gap and missing lookahead remain exactly visible");
}
static void fractionalCutoffExcludesOldNeighbor() {
  TimedAudioRing<16> ring(1000, .010);
  ring.setPlaying(true, .0015); ring.setGain(1);
  float values[] = {0, 1, 2, 3}; const float* data[] = {values, values};
  ring.push(data, 4, 0);
  float l[2]{}, r[2]{}; ring.render(l, r, 2, .0115);
  require(l[0] == 0 && l[1] == 2.5f, "pre-cutoff sample is not interpolation neighbor");
  require(ring.stats().cutoffFrames == 2 && ring.stats().missingFrames == 1, "cutoff boundary is explicit");
}
static void lateArrivalRemainsVisibleWithInterpolation() {
  TimedAudioRing<16> ring(1000, 0);
  ring.setPlaying(true, 0); ring.setGain(1);
  float l, r; ring.render(&l, &r, 1, .0005);
  float values[] = {1, 3}; const float* data[] = {values, values};
  ring.push(data, 2, 0);
  ring.render(&l, &r, 1, .00075);
  require(l == 2.5f, "newly available adjacent samples interpolate current time");
  require(ring.stats().missingFrames == 1 && ring.stats().lateFrames == 1,
          "late left neighbor remains diagnosed even when useful now");
}
static void concurrentControls() {
  TimedAudioRing<64> ring(1000, .020);
  std::thread producer([&] {
    float sample = .25f; const float* data[] = {&sample, &sample};
    for (int i = 0; i < 10000; ++i) {
      const auto result = ring.push(data, 1, i);
      require(result != AudioPushResult::invalid, "valid concurrent producer timestamp");
    }
  });
  std::thread consumer([&] {
    for (int i = 0; i < 10000; ++i) {
      float l, r;
      require(ring.render(&l, &r, 1, i / 1000.0), "concurrent control snapshot valid");
    }
  });
  for (int i = 0; i < 1000; ++i) {
    require(ring.setPlaying(false, i / 1000.0) == AudioControlResult::accepted, "concurrent mute");
    const auto result = ring.setPlaying(true, i / 1000.0);
    require(result != AudioControlResult::invalid, "concurrent enable accepted or explicit full");
    ring.setGain((i % 100) / 100.0f);
  }
  producer.join(); consumer.join();
}
static void clockDriftIsResampled(double ppm, double base = 0) {
  constexpr double rate = 48000;
  TimedAudioRing<> ring(rate, .040);
  ring.setPlaying(true, base); ring.setGain(1);
  float samples[480]{};
  const float* data[] = {samples, samples};
  float l[512]{}, r[512]{};
  int produced = 0;
  for (int frame = 0; frame < 96000; frame += 512) {
    const double time = frame / rate * (1 + ppm / 1000000);
    while (produced / rate <= time) {
      for (int i = 0; i < 480; ++i) samples[i] = float((produced + i + 1) / rate);
      require(ring.push(data, 480, int64_t(base * 1000) + produced / 48) == AudioPushResult::accepted, "drift packet");
      produced += 480;
    }
    ring.render(l, r, 512, base + time);
    for (int i = 0; i < 512; ++i) {
      const double sourceTime = time + i / rate - .040;
      const float expected = sourceTime < 0 ? 0 : float(sourceTime + 1 / rate);
      require(std::abs(l[i] - expected) < 0.000001f && l[i] == r[i],
              "clock drift follows continuous source ramp, with no inserted silence");
    }
  }
  const auto stats = ring.stats();
  require(stats.missingFrames == 0 && stats.lateFrames == 0,
          "continuous resampling has no artificial missing or late frames");
  require(stats.resampledFrames > 0, "resampling work is observable");
  std::printf("clockDrift ppm=%.0f missingFrames=%llu lateFrames=%llu resampledFrames=%llu\n", ppm,
              (unsigned long long)stats.missingFrames, (unsigned long long)stats.lateFrames,
              (unsigned long long)stats.resampledFrames);
}
static void largeUptimePreservesAdjacentSamples(double base) {
  TimedAudioRing<> ring(48000, .060);
  ring.setPlaying(true, base); ring.setGain(1);
  float samples[480]; for (auto& value : samples) value = 1;
  const float* data[] = {samples, samples};
  require(ring.push(data, 480, int64_t(base * 1000)) == AudioPushResult::accepted, "large uptime push");
  float l[400]{}, r[400]{};
  ring.render(l, r, 400, base + .060 + .5 / 48000);
  require(ring.stats().missingFrames == 0, "large uptime must not turn adjacent samples into gaps");
  for (int i = 0; i < 400; ++i) require(l[i] == 1 && r[i] == 1, "large uptime constant signal");
}
static void largeUptimeDoesNotBridgeGap(double base) {
  TimedAudioRing<64> ring(1000, .010);
  ring.setPlaying(true, base); ring.setGain(1);
  float samples[] = {1, 2, 3, 4}; const float* data[] = {samples, samples};
  ring.push(data, 4, int64_t(base * 1000));
  ring.push(data, 4, int64_t(base * 1000) + 8);
  float l[22]{}, r[22]{}; ring.render(l, r, 22, base + .0005);
  require(ring.stats().missingFrames == 6, "large uptime true gap and lookahead stay visible");
  for (int i = 13; i < 18; ++i) require(l[i] == 0, "large uptime gap stays silent");
}
int main() {
  continuous480To512(false, false);
  continuous480To512(true, false);
  continuous480To512(false, true);
  continuous480To512(true, true);
  missingDoesNotMoveDeadline();
  muteEpochAndCutoff();
  capacityWrapAndValidation();
  gainDoesNotResetTimeline();
  timestampQuantizationAndLateFrames();
  overlappingPTSIsNotRetimed();
  concurrentSPSC();
  fractionalPacketTime();
  concurrentControls();
  resamplingDoesNotBridgeGapsOrInventLookahead();
  fractionalCutoffExcludesOldNeighbor();
  lateArrivalRemainsVisibleWithInterpolation();
  clockDriftIsResampled(100);
  clockDriftIsResampled(-100);
  for (double base : {1000000., 10000000., 20000000.}) {
    largeUptimePreservesAdjacentSamples(base);
    largeUptimeDoesNotBridgeGap(base);
    clockDriftIsResampled(100, base);
    clockDriftIsResampled(-100, base);
  }
  std::puts("PASS: timed audio ring tests");
}
