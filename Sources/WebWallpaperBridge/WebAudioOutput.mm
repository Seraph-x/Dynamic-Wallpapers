#import "WebAudioOutput.h"
#import "WebRuntimeInternal.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#include <string>

namespace {
template<typename T> T deviceProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
  AudioObjectPropertyAddress address{selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  T result{}; UInt32 size = sizeof(result);
  const auto status = AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &result);
  if (status != noErr || size != sizeof(result))
    throw std::runtime_error("Could not read native output timing: " + std::to_string(status));
  return result;
}
double playoutBufferDuration() {
  const auto device = deviceProperty<AudioDeviceID>(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice);
  if (device == kAudioObjectUnknown) throw std::runtime_error("No native audio output device is available");
  const auto frames = deviceProperty<UInt32>(device, kAudioDevicePropertyBufferFrameSize);
  const auto rate = deviceProperty<Float64>(device, kAudioDevicePropertyNominalSampleRate);
  if (!frames || !std::isfinite(rate) || rate <= 0) throw std::runtime_error("Invalid native audio output timing");
  // Queue four source packets plus two current device quanta. This is transport
  // buffering, derived per output instance; no measured developer-machine offset.
  constexpr int bufferedPackets = 4, deviceQuanta = 2;
  return bufferedPackets * double(DWWebAudioBuffer::packetFrames) / DWWebAudioBuffer::sampleRate + deviceQuanta * frames / rate;
}
}

@implementation DWWebAudioOutput {
  std::shared_ptr<DWWebAudioBuffer> _buffer;
  AVAudioEngine* _engine;
  AVAudioSourceNode* _source;
  id _configurationObserver;
  BOOL _closed;
}
- (instancetype)initWithError:(NSError**)error {
  DWRequireWebMainThread();
  if (!(self = [super init])) return nil;
  try { _buffer = std::make_shared<DWWebAudioBuffer>(playoutBufferDuration()); }
  catch (const std::exception& failure) { if (error) *error = DWWebError(@(failure.what())); return nil; }
  _engine = [[AVAudioEngine alloc] init];
  AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:DWWebAudioBuffer::sampleRate channels:2];
  auto buffer = _buffer;
  _source = [[AVAudioSourceNode alloc] initWithFormat:format
      renderBlock:^OSStatus(BOOL* silent, const AudioTimeStamp* time, AVAudioFrameCount frames, AudioBufferList* data) {
    if (!(time->mFlags & kAudioTimeStampHostTimeValid) || data->mNumberBuffers != 2) {
      buffer->fail(DWWebAudioError::render); return kAudio_ParamError;
    }
    for (UInt32 channel = 0; channel < 2; ++channel) {
      const auto& output = data->mBuffers[channel];
      if (output.mNumberChannels != 1 || !output.mData || output.mDataByteSize / sizeof(float) < frames) {
        buffer->fail(DWWebAudioError::render); return kAudio_ParamError;
      }
    }
    float* left = static_cast<float*>(data->mBuffers[0].mData);
    float* right = static_cast<float*>(data->mBuffers[1].mData);
    const bool valid = buffer->render(left, right, frames, [AVAudioTime secondsForHostTime:time->mHostTime]);
    *silent = YES;
    for (UInt32 i = 0; i < frames; ++i) if (left[i] != 0 || right[i] != 0) { *silent = NO; break; }
    return valid ? OSStatus(noErr) : OSStatus(kAudio_ParamError);
  }];
  [_engine attachNode:_source];
  [_engine connect:_source to:_engine.mainMixerNode format:format];
  NSError* failure = nil;
  if (![_engine startAndReturnError:&failure]) {
    [self close];
    if (error) *error = failure ?: DWWebError(@"Native audio output could not start");
    return nil;
  }
  _configurationObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification
      object:_engine queue:nil usingBlock:^(NSNotification*) { buffer->fail(DWWebAudioError::deviceChanged); }];
  fprintf(stderr, "DWWEB native-output-start rate=%d channels=2 bufferSeconds=%.6f\n",
          DWWebAudioBuffer::sampleRate, buffer->delaySeconds);
  return self;
}
- (std::shared_ptr<DWWebAudioBuffer>)buffer { DWRequireWebMainThread(); return _buffer; }
- (void)close {
  DWRequireWebMainThread();
  if (_closed) return;
  _closed = YES;
  if (_buffer) _buffer->beginClose(NSProcessInfo.processInfo.systemUptime);
  if (_configurationObserver) [NSNotificationCenter.defaultCenter removeObserver:_configurationObserver];
  _configurationObserver = nil;
  [_engine stop];
  if (_source) [_engine detachNode:_source];
  _source = nil; _engine = nil;
  if (_buffer) _buffer->outputStopped = true;
}
@end
