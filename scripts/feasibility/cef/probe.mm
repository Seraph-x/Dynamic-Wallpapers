#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <array>
#include <memory>
#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include "include/cef_audio_handler.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "timed-audio-ring.h"
#include "close-barrier.h"

@interface ProbeApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation ProbeApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent*)event { CefScopedSendingEvent scope; [super sendEvent:event]; }
@end

// 60 ms playout: measured ~21 ms capture age + up to 12 ms render lead +
// 10.67 ms device block + 1 ms PTS quantization + ~15 ms scheduling margin.
// This is an explicit prototype budget, not a guarantee on other devices.
struct AudioRing {
  TimedAudioRing<> timed{48000, .060};
  std::atomic<float> gain{0};
  std::atomic<double> lastRenderHost{0}, lastNonzeroEndHost{0}, lastSignalStartHost{0};
  bool previousRenderHadSignal = false; // Render thread only.
  std::atomic<uint64_t> invalidCallbacks{0}, controlGeneration{0}, renderedGeneration{0};
  void push(const float** data, int frames, int64_t pts) {
    auto result = timed.push(data, frames, pts);
    if (result == AudioPushResult::invalid || result == AudioPushResult::overflow)
      fprintf(stderr, "PROBE packet-rejected result=%d pts=%lld frames=%d\n", int(result), (long long)pts, frames);
  }
  bool render(AudioBufferList* buffers, unsigned frames, double host) {
    if (buffers->mNumberBuffers != 2) { ++invalidCallbacks; return false; }
    for (unsigned ch = 0; ch < 2; ++ch)
      if (buffers->mBuffers[ch].mNumberChannels != 1 || buffers->mBuffers[ch].mDataByteSize < frames * sizeof(float)) {
        ++invalidCallbacks; return false;
      }
    return timed.render(static_cast<float*>(buffers->mBuffers[0].mData),
                        static_cast<float*>(buffers->mBuffers[1].mData), frames, host);
  }
};

// Trusted-fixture-only diagnostic. No user project is opened by this program.
class Probe : public CefClient, public CefLifeSpanHandler,
              public CefRenderHandler, public CefLoadHandler,
              public CefDisplayHandler, public CefAudioHandler {
 public:
  explicit Probe(AudioRing* output, CloseBarrier* close) : output(output), close(close) {}
  ~Probe() override { close->clientDestroyed(); fprintf(stderr, "PROBE client-destroyed\n"); }
  CloseBarrier* close;
  AudioRing* output;
  CefRefPtr<CefBrowser> browser;
  std::atomic<int> paints{0}, packets{0}, channels{0};
  bool loaded = false, closed = false;
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefAudioHandler> GetAudioHandler() override {
    return getenv("CEF_PROBE_DIRECT_CONTROL") ? nullptr : this;
  }
  bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters& params) override {
    params.sample_rate = 48000;
    params.channel_layout = CEF_CHANNEL_LAYOUT_STEREO;
    params.frames_per_buffer = 480;
    return true;
  }
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    rect = CefRect(0, 0, 640, 360);
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> value) override {
    browser = value; fprintf(stderr, "PROBE browser-created\n");
    fprintf(stderr, "PROBE browser-muted=%d direct=%d\n",
            value->GetHost()->IsAudioMuted(), getenv("CEF_PROBE_DIRECT_CONTROL") != nullptr);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    closed = true; close->browserClosed(); browser = nullptr; fprintf(stderr, "PROBE before-close\n");
  }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType,
               const RectList&, const void* buffer, int width, int height) override {
    if (paints.fetch_add(1) == 0) {
      const unsigned char* pixels = static_cast<const unsigned char*>(buffer);
      unsigned long long sum = 0;
      for (int i = 0; i < width * height * 4; ++i) sum += pixels[i];
      fprintf(stderr, "PROBE first-paint width=%d height=%d checksum=%llu\n", width, height, sum);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> value, CefRefPtr<CefFrame> frame, int status) override {
    if (frame->IsMain()) { loaded = true; fprintf(stderr, "PROBE main-loaded status=%d muted=%d\n", status, value->GetHost()->IsAudioMuted()); }
  }
  void OnLoadStart(CefRefPtr<CefBrowser> value, CefRefPtr<CefFrame> frame, TransitionType) override {
    if (frame->IsMain() && !getenv("CEF_PROBE_DIRECT_CONTROL")) {
      fprintf(stderr, "PROBE main-load-start muted=%d\n", value->GetHost()->IsAudioMuted());
    }
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode code,
                   const CefString& message, const CefString&) override {
    fprintf(stderr, "PROBE load-error code=%d %s\n", code, message.ToString().c_str());
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t,
                        const CefString& message, const CefString&, int) override {
    fprintf(stderr, "PAGE %s\n", message.ToString().c_str()); return true;
  }
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters& params,
                             int count) override {
    close->streamStarted();
    channels = count;
    fprintf(stderr, "PROBE audio-start rate=%d channels=%d frames=%d\n",
            params.sample_rate, count, params.frames_per_buffer);
  }
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float** data,
                            int frames, int64_t pts) override {
    close->callbackEntered();
    double energy = 0;
    for (int ch = 0; ch < channels; ++ch)
      for (int i = 0; i < frames; ++i) energy += data[ch][i] * data[ch][i];
    int count = ++packets;
    if (count == 1 || count % 100 == 0)
      fprintf(stderr, "PROBE pcm packets=%d frames=%d pts=%lld rms=%f uptime=%.6f epoch=%.6f\n",
              count, frames, (long long)pts, sqrt(energy / (frames * channels)),
              NSProcessInfo.processInfo.systemUptime, NSDate.date.timeIntervalSince1970);
    if (channels == 2) output->push(data, frames, pts);
    close->callbackLeft();
  }
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override {
    close->streamStopped();
    fprintf(stderr, "PROBE audio-stopped\n");
  }
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString& message) override {
    close->audioError();
    fprintf(stderr, "PROBE audio-error closing=%d %s\n", close->requested(), message.ToString().c_str());
  }
 private:
  IMPLEMENT_REFCOUNTING(Probe);
};

class App : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> cmd) override {
    cmd->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");
  }
 private:
  IMPLEMENT_REFCOUNTING(App);
};

int main(int argc, char** argv) {
  @autoreleasepool {
    CefScopedLibraryLoader loader;
    bool helper = argc > 1 && std::string(argv[1]).rfind("--type=", 0) == 0;
    if (!(helper ? loader.LoadInHelper() : loader.LoadInMain())) return 2;
    CefMainArgs args(argc, argv);
    CefRefPtr<App> app = new App;
    int subprocess = CefExecuteProcess(args, app, nullptr);
    if (subprocess >= 0) return subprocess;
    [ProbeApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow* marker = [[NSWindow alloc] initWithContentRect:NSMakeRect(50, 50, 320, 80)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    marker.title = @"CEF audio capture probe";
    [marker orderFront:nil];
    CloseBarrier close;
    AudioRing ring;
    AudioRing* ringPointer = &ring;
    AVAudioEngine* engine = [[AVAudioEngine alloc] init];
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AVAudioSourceNode* source = [[AVAudioSourceNode alloc] initWithFormat:format
      renderBlock:^OSStatus(BOOL* silent, const AudioTimeStamp* time, AVAudioFrameCount frames, AudioBufferList* data) {
        if (!(time->mFlags & kAudioTimeStampHostTimeValid)) { ++ringPointer->invalidCallbacks; return kAudio_ParamError; }
        double host = [AVAudioTime secondsForHostTime:time->mHostTime];
        uint64_t generation = ringPointer->controlGeneration.load();
        if (!ringPointer->render(data, frames, host)) return kAudio_ParamError;
        ringPointer->lastRenderHost = host;
        int lastNonzeroFrame = -1;
        unsigned firstNonzeroFrame = frames;
        for (unsigned ch = 0; ch < data->mNumberBuffers; ++ch) {
          const float* values = static_cast<const float*>(data->mBuffers[ch].mData);
          for (unsigned i = 0; i < frames; ++i)
            if (values[i] != 0) {
              firstNonzeroFrame = std::min(firstNonzeroFrame, i);
              lastNonzeroFrame = std::max(lastNonzeroFrame, static_cast<int>(i));
            }
        }
        if (lastNonzeroFrame >= 0 && !ringPointer->previousRenderHadSignal)
          ringPointer->lastSignalStartHost = host + firstNonzeroFrame / 48000.0;
        ringPointer->previousRenderHadSignal = lastNonzeroFrame >= 0;
        if (lastNonzeroFrame >= 0) ringPointer->lastNonzeroEndHost = host + (lastNonzeroFrame + 1) / 48000.0;
        *silent = lastNonzeroFrame < 0;
        ringPointer->renderedGeneration = generation;
        return noErr;
      }];
    [engine attachNode:source];
    [engine connect:source to:engine.mainMixerNode format:format];
    AVAudioPlayerNode* drainFence = [[AVAudioPlayerNode alloc] init];
    [engine attachNode:drainFence];
    [engine connect:drainFence to:engine.mainMixerNode format:format];
    NSError* audioError = nil;
    bool direct = getenv("CEF_PROBE_DIRECT_CONTROL") != nullptr;
    if (!direct && ![engine startAndReturnError:&audioError]) {
      fprintf(stderr, "PROBE native-output-error %s\n", audioError.description.UTF8String); return 7;
    }
    if (!direct) [drainFence play];
    CefSettings settings;
    settings.no_sandbox = true;
    settings.windowless_rendering_enabled = true;
    CefString(&settings.root_cache_path) = std::string(argv[2]);
    if (!CefInitialize(args, settings, app, nullptr)) return 3;
    if (!getenv("CEF_PROBE_DIRECT_CONTROL")) {
      auto context = CefRequestContext::GetGlobalContext();
      context->SetContentSetting("", "", CEF_CONTENT_SETTING_TYPE_SOUND, CEF_CONTENT_SETTING_VALUE_BLOCK);
      auto sound = context->GetContentSetting("", "", CEF_CONTENT_SETTING_TYPE_SOUND);
      fprintf(stderr, "PROBE default-sound-content-setting=%d\n", sound);
      if (sound != CEF_CONTENT_SETTING_VALUE_BLOCK) {
        fprintf(stderr, "PROBE default-sound-setting-failed\n");
        [engine stop]; CefShutdown(); return 9;
      }
    }
    if (const char* readyPath = getenv("CEF_CAPTURE_READY_PATH")) {
      NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:15];
      while (![[NSFileManager defaultManager] fileExistsAtPath:@(readyPath)]) {
        if ([deadline timeIntervalSinceNow] <= 0) {
          fprintf(stderr, "PROBE capture-readiness-timeout\n");
          [engine stop]; CefShutdown(); return 8;
        }
        CefDoMessageLoopWork();
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
      }
      fprintf(stderr, "PROBE capture-ready epoch=%.6f\n", NSDate.date.timeIntervalSince1970);
    }
    CefRefPtr<Probe> client = new Probe(&ring, &close);
    CefWindowInfo window;
    window.SetAsWindowless(nullptr);
    CefBrowserSettings browserSettings;
    if (!CefBrowserHost::CreateBrowser(window, client, argv[1], browserSettings, nullptr, nullptr)) return 4;
    NSDate* began = [NSDate date];
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:14];
    int phase = -1;
    uint64_t lastUnderflow = 0;
    double lastSignalStart = 0;
    bool audioTimelineStarted = false;
    fprintf(stderr, "PROBE playout-delay-ms=60 native-output=%d\n", !direct);
    while ([end timeIntervalSinceNow] > 0) {
      double elapsed = -[began timeIntervalSinceNow];
      int next = elapsed < 4 ? 0 : elapsed < 6 ? 1 : elapsed < 8 ? 2 : elapsed < 10 ? 3 : 4;
      if (next != phase) {
        phase = next;
        ring.gain = phase == 1 ? .2f : phase == 2 || phase == 4 ? .8f : 0;
        if (!ring.timed.setGain(ring.gain.load())) return 10;
        fprintf(stderr, "PROBE phase=%d elapsed=%.6f gain=%.2f epoch=%.6f\n",
                phase, elapsed, ring.gain.load(), [[NSDate date] timeIntervalSince1970]);
        fprintf(stderr, "PROBE render-clock uptime=%.6f lastRenderHost=%.6f lastNonzeroEndHost=%.6f presentationLatency=%.6f sourcePresentationLatency=%.6f mixerLatency=%.6f\n",
          NSProcessInfo.processInfo.systemUptime, ring.lastRenderHost.load(),
          ring.lastNonzeroEndHost.load(), engine.outputNode.presentationLatency, source.outputPresentationLatency, engine.mainMixerNode.latency);
      }
      CefDoMessageLoopWork();
      if (!audioTimelineStarted && client->packets > 0) {
        // CEF's integer-ms PTS at 48 kHz has an integer-frame nominal origin.
        // Enable at the next complete source frame, never a fractional old frame.
        double cutoff = std::ceil(NSProcessInfo.processInfo.systemUptime * 48000.0) / 48000.0;
        if (ring.timed.setPlaying(true, cutoff) != AudioControlResult::accepted) return 11;
        audioTimelineStarted = true;
        fprintf(stderr, "PROBE timeline-start cutoff=%.6f\n", cutoff);
      }
      double signalStart = ring.lastSignalStartHost.load();
      if (signalStart != lastSignalStart) {
        lastSignalStart = signalStart;
        double hostNow = NSProcessInfo.processInfo.systemUptime;
        double epochNow = NSDate.date.timeIntervalSince1970;
        fprintf(stderr, "PROBE output-signal-start host=%.9f epoch=%.9f\n", signalStart, epochNow + signalStart - hostNow);
      }
      auto stats = ring.timed.stats();
      if (stats.missingFrames != lastUnderflow) {
        lastUnderflow = stats.missingFrames;
        fprintf(stderr, "PROBE underflow elapsed=%.6f missingFrames=%llu lateFrames=%llu\n", elapsed,
          (unsigned long long)stats.missingFrames, (unsigned long long)stats.lateFrames);
      }
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    fprintf(stderr, "PROBE close-request epoch=%.6f\n", NSDate.date.timeIntervalSince1970);
    close.requestClose();
    double outputLatency = source.outputPresentationLatency;
    ring.gain = 0;
    if (!ring.timed.setGain(0) || ring.timed.setPlaying(false, NSProcessInfo.processInfo.systemUptime) != AudioControlResult::accepted) return 12;
    // Observe a render that has consumed the close gate before scheduling a
    // silent marker on the same mixer. Do not stop the player/engine until the
    // played-back callback: stopping can itself trigger completion callbacks.
    uint64_t closeGeneration = ++ring.controlGeneration;
    NSDate* drainDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
    if (!direct) {
      while (ring.renderedGeneration < closeGeneration && [drainDeadline timeIntervalSinceNow] > 0) {
        CefDoMessageLoopWork();
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
      }
      if (ring.renderedGeneration < closeGeneration) { fprintf(stderr, "PROBE render-gate-timeout\n"); return 14; }
      AVAudioPCMBuffer* silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:1];
      silence.frameLength = 1;
      silence.floatChannelData[0][0] = silence.floatChannelData[1][0] = 0;
      auto played = std::make_shared<std::atomic<bool>>(false);
      [drainFence scheduleBuffer:silence completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
        completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
          fprintf(stderr, "PROBE output-drain-callback type=%ld host=%.6f epoch=%.6f\n",
            (long)type, NSProcessInfo.processInfo.systemUptime, NSDate.date.timeIntervalSince1970);
          played->store(type == AVAudioPlayerNodeCompletionDataPlayedBack);
        }];
      while (!played->load() && [drainDeadline timeIntervalSinceNow] > 0) {
        CefDoMessageLoopWork();
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
      }
      if (!played->load()) { fprintf(stderr, "PROBE output-drain-timeout\n"); return 15; }
    }
    [engine stop];
    if (!close.outputStopped(ring.lastNonzeroEndHost.load(), outputLatency)) return 13;
    fprintf(stderr, "PROBE output-stopped uptime=%.6f lastRenderHost=%.6f lastNonzeroEndHost=%.6f\n",
      NSProcessInfo.processInfo.systemUptime, ring.lastRenderHost.load(), ring.lastNonzeroEndHost.load());
    if (client->browser) { client->browser->GetHost()->CloseBrowser(true); }
    end = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!client->closed && [end timeIntervalSinceNow] > 0) {
      CefDoMessageLoopWork();
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    bool success = client->loaded && client->paints > 0 &&
      (getenv("CEF_PROBE_DIRECT_CONTROL") || client->packets > 0) && client->closed;
    fprintf(stderr, "PROBE summary loaded=%d paints=%d pcm=%d closed=%d\n",
            client->loaded, client->paints.load(), client->packets.load(), client->closed);
    auto stats = ring.timed.stats();
    fprintf(stderr, "PROBE buffer overflowFrames=%llu missingFrames=%llu lateFrames=%llu preRollFrames=%llu mutedFrames=%llu staleFrames=%llu cutoffFrames=%llu invalidPackets=%llu discontinuities=%llu invalidRenders=%llu resampledFrames=%llu\n",
      (unsigned long long)stats.overflowFrames, (unsigned long long)stats.missingFrames,
      (unsigned long long)stats.lateFrames, (unsigned long long)stats.preRollFrames,
      (unsigned long long)stats.mutedFrames, (unsigned long long)stats.staleFrames,
      (unsigned long long)stats.cutoffFrames, (unsigned long long)stats.invalidPackets,
      (unsigned long long)stats.timestampDiscontinuities, (unsigned long long)(stats.invalidRenders + ring.invalidCallbacks.load()),
      (unsigned long long)stats.resampledFrames);
    if (!client->closed) return 5;
    client = nullptr;
    while (!close.resourcesReleased() && [end timeIntervalSinceNow] > 0) {
      CefDoMessageLoopWork();
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    fprintf(stderr, "PROBE close-resources released=%d streamsStarted=%llu streamsStopped=%llu callbacks=%llu errors=%llu epoch=%.6f host=%.6f estimatedPresentationDeadline=%.6f\n",
      close.resourcesReleased(), (unsigned long long)close.starts(), (unsigned long long)close.stops(),
      (unsigned long long)close.callbacks(), (unsigned long long)close.errors(),
      NSDate.date.timeIntervalSince1970, NSProcessInfo.processInfo.systemUptime, close.presentationDeadline());
    if (!close.resourcesReleased()) fprintf(stderr, "PROBE close-timeout\n");
    success = success && close.resourcesReleased();
    CefShutdown();
    return success ? 0 : 6;
  }
}
