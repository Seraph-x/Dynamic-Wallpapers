#include "WebAudioBuffer.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <stdexcept>

static void require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}
static void gatesAndGain() {
  DWWebAudioBuffer audio(.05);
  std::array<float, 480> signal; signal.fill(1);
  const float* packet[] = {signal.data(), signal.data()};
  std::array<float, 100> left{}, right{};
  audio.streamStarted(48000, 2, 480);
  audio.push(packet, 480, 10000);
  require(audio.render(left.data(), right.data(), 100, 10.05), "prepared render");
  for (float sample : left) require(sample == 0, "preloading must not submit audio");
  require(audio.setGain(.2, 11), "enable controlled output");
  audio.push(packet, 480, 11000);
  require(audio.render(left.data(), right.data(), 100, 11.05), "playing render");
  for (float sample : left) require(std::abs(sample - .2) < 1e-6, "actual output gain .2");
  require(audio.setGain(.8, 11.002), "live gain update");
  require(audio.render(left.data(), right.data(), 100, 11.05 + 100.0 / 48000), "updated render");
  for (float sample : left) require(std::abs(sample - .8) < 1e-6, "gain must not reset source timeline");
  require(audio.setGain(0, 11.004), "mute");
  audio.render(left.data(), right.data(), 100, 11.06);
  for (float sample : left) require(sample == 0, "queued output must be gated immediately");
  require(audio.setGain(1, 12), "unmute");
  audio.render(left.data(), right.data(), 100, 12.05);
  for (float sample : left) require(sample == 0, "old queued sound must not return");
  audio.push(packet, 480, 12000);
  audio.beginClose(12.001);
  audio.render(left.data(), right.data(), 100, 12.06);
  for (float sample : left) require(sample == 0, "close gates pending PCM");
  require(!audio.setGain(1, 12.002), "closed output cannot be reenabled");
  require(!audio.released(), "stream and output still own resources");
  audio.streamStopped(12.003);
  audio.outputStopped = true;
  require(audio.released(), "all producer and output resources finished");
}
static void errorsRemainVisibleAndSilent() {
  DWWebAudioBuffer invalid(.05);
  invalid.streamStarted(44100, 2, 480);
  require(invalid.errorCode() != DWWebAudioError::none, "unsupported stream format must fail");
  require(!invalid.setGain(1, 1), "failed stream cannot enable output");
  DWWebAudioBuffer audio(.05);
  audio.streamStarted(48000, 2, 480);
  require(audio.setGain(1, 10), "positive setup");
  std::array<float, 480> signal; signal.fill(1); signal[7] = NAN;
  const float* packet[] = {signal.data(), signal.data()};
  audio.push(packet, 480, 10000);
  require(audio.errorCode() == DWWebAudioError::invalidPacket, "invalid PCM must be reported");
  std::array<float, 100> left{}, right{};
  audio.render(left.data(), right.data(), 100, 10.05);
  for (float sample : left) require(sample == 0, "invalid PCM cannot leak to device");
}
static void deviceBufferFitsBeforeFirstPlayout() {
  const double delay = .04 + 2.0 * 8192 / 48000;
  DWWebAudioBuffer audio(delay);
  audio.streamStarted(48000, 2, 480);
  require(audio.setGain(1, 10), "large-quantum output setup");
  std::array<float, 480> samples; samples.fill(.5);
  const float* packet[] = {samples.data(), samples.data()};
  for (int i = 0; i < 39; ++i) audio.push(packet, 480, 10000 + i * 10);
  require(audio.errorCode() == DWWebAudioError::none,
          "device-derived delay must fit the queue before its first playable sample");
  std::array<float, 100> left{}, right{};
  require(audio.render(left.data(), right.data(), 100, 10 + delay), "large-quantum output render");
  for (auto sample : left) require(sample == .5, "large-quantum output remains real signal");
}
int main() {
  try { gatesAndGain(); errorsRemainVisibleAndSilent(); deviceBufferFitsBeforeFirstPlayout(); std::puts("WEB_AUDIO_BUFFER PASS functional-gates gain stale-output close invalid-pcm device-capacity"); }
  catch (const std::exception& error) { std::fprintf(stderr, "WEB_AUDIO_BUFFER FAIL %s\n", error.what()); return 1; }
}
