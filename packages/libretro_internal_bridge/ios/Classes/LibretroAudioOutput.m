#import "LibretroAudioOutput.h"

#import <AVFoundation/AVFoundation.h>

#include <stdatomic.h>
#include <stdlib.h>

#define LIBRETRO_RING_FRAMES 16384u
#define LIBRETRO_RING_MASK (LIBRETRO_RING_FRAMES - 1u)

/// Shared with the real-time render block, which must not message
/// Objective-C objects. Freed only after the engine has stopped.
typedef struct {
  int16_t samples[LIBRETRO_RING_FRAMES * 2];
  _Atomic uint32_t writeIndex;
  _Atomic uint32_t readIndex;
  _Atomic double inputRate;
  double outputRate;
  double fraction;
  bool primed;
} LibretroAudioState;

static const double kTargetFill = 0.25;
static const double kMaxRateDelta = 0.005;

static void RenderAudio(LibretroAudioState *state, AVAudioFrameCount frameCount, AudioBufferList *output) {
  float *left = output->mNumberBuffers > 0 ? (float *)output->mBuffers[0].mData : NULL;
  float *right = output->mNumberBuffers > 1 ? (float *)output->mBuffers[1].mData : left;
  if (left == NULL) return;
  uint32_t read = atomic_load_explicit(&state->readIndex, memory_order_relaxed);
  uint32_t write = atomic_load_explicit(&state->writeIndex, memory_order_acquire);
  uint32_t available = write - read;
  // Start (and restart after an underrun) only once the buffer holds the
  // target latency, so playback does not stutter on every callback.
  if (!state->primed && (double)available < kTargetFill * LIBRETRO_RING_FRAMES) {
    for (AVAudioFrameCount silent = 0; silent < frameCount; silent++) {
      left[silent] = 0.0f;
      if (right != left) right[silent] = 0.0f;
    }
    return;
  }
  state->primed = true;
  double fill = (double)available / (double)LIBRETRO_RING_FRAMES;
  double correction = (fill - kTargetFill) / kTargetFill;
  if (correction > 1.0) correction = 1.0;
  if (correction < -1.0) correction = -1.0;
  double inputRate = atomic_load_explicit(&state->inputRate, memory_order_relaxed);
  double step = inputRate / state->outputRate * (1.0 + correction * kMaxRateDelta);
  double position = state->fraction;
  AVAudioFrameCount frame = 0;
  for (; frame < frameCount; frame++) {
    uint32_t base = (uint32_t)position;
    if (base + 1 >= available) break;
    double t = position - (double)base;
    uint32_t first = (read + base) & LIBRETRO_RING_MASK;
    uint32_t second = (read + base + 1) & LIBRETRO_RING_MASK;
    float l = (float)((double)state->samples[first * 2] * (1.0 - t) + (double)state->samples[second * 2] * t);
    float r = (float)((double)state->samples[first * 2 + 1] * (1.0 - t) + (double)state->samples[second * 2 + 1] * t);
    left[frame] = l / 32768.0f;
    if (right != left) right[frame] = r / 32768.0f;
    position += step;
  }
  for (AVAudioFrameCount silent = frame; silent < frameCount; silent++) {
    left[silent] = 0.0f;
    if (right != left) right[silent] = 0.0f;
  }
  uint32_t consumed = (uint32_t)position;
  if (consumed > available) consumed = available;
  state->fraction = position - (double)consumed;
  if (frame < frameCount) {
    state->fraction = 0.0;
    state->primed = false;
  }
  atomic_store_explicit(&state->readIndex, read + consumed, memory_order_release);
}

@implementation LibretroAudioOutput {
  LibretroAudioState *_state;
  AVAudioEngine *_engine;
  AVAudioSourceNode *_source;
  AVAudioSessionCategory _previousCategory;
  AVAudioSessionMode _previousMode;
  AVAudioSessionCategoryOptions _previousOptions;
  BOOL _running;
}

- (instancetype)initWithInputRate:(double)rate {
  self = [super init];
  if (self) {
    _state = calloc(1, sizeof(LibretroAudioState));
    atomic_store(&_state->inputRate, rate > 0 ? rate : 44100.0);
    _state->outputRate = 48000.0;
  }
  return self;
}

- (void)dealloc {
  [self stop];
  free(_state);
}

- (BOOL)start:(NSError **)error {
  if (_running) return YES;
  AVAudioSession *session = AVAudioSession.sharedInstance;
  _previousCategory = session.category;
  _previousMode = session.mode;
  _previousOptions = session.categoryOptions;
  [session setCategory:AVAudioSessionCategoryPlayback
                  mode:AVAudioSessionModeDefault
               options:AVAudioSessionCategoryOptionMixWithOthers
                 error:nil];
  [session setPreferredIOBufferDuration:0.01 error:nil];
  [session setActive:YES error:nil];

  _engine = [AVAudioEngine new];
  double outputRate = [_engine.outputNode outputFormatForBus:0].sampleRate;
  if (outputRate <= 0) outputRate = session.sampleRate > 0 ? session.sampleRate : 48000.0;
  _state->outputRate = outputRate;
  AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:outputRate channels:2];
  LibretroAudioState *state = _state;
  _source = [[AVAudioSourceNode alloc]
      initWithFormat:format
         renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount,
                               AudioBufferList *outputData) {
           RenderAudio(state, frameCount, outputData);
           return noErr;
         }];
  [_engine attachNode:_source];
  [_engine connect:_source to:_engine.mainMixerNode format:format];
  [_engine prepare];
  if (![_engine startAndReturnError:error]) {
    [_engine detachNode:_source];
    _source = nil;
    _engine = nil;
    return NO;
  }
  _running = YES;
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserver:self
             selector:@selector(audioInterrupted:)
                 name:AVAudioSessionInterruptionNotification
               object:session];
  [center addObserver:self
             selector:@selector(engineConfigurationChanged:)
                 name:AVAudioEngineConfigurationChangeNotification
               object:_engine];
  return YES;
}

- (void)audioInterrupted:(NSNotification *)notification {
  NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
  if (type == AVAudioSessionInterruptionTypeEnded) [self restartEngine];
}

- (void)engineConfigurationChanged:(NSNotification *)notification {
  [self restartEngine];
}

- (void)restartEngine {
  if (!_running || _engine == nil || _engine.isRunning) return;
  [AVAudioSession.sharedInstance setActive:YES error:nil];
  [_engine startAndReturnError:nil];
}

- (void)stop {
  if (!_running) return;
  _running = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [_engine stop];
  if (_source != nil) [_engine detachNode:_source];
  _source = nil;
  _engine = nil;
  AVAudioSession *session = AVAudioSession.sharedInstance;
  if (_previousCategory != nil) {
    [session setCategory:_previousCategory mode:_previousMode ?: AVAudioSessionModeDefault options:_previousOptions error:nil];
  }
}

- (void)setInputRate:(double)rate {
  if (rate > 0) atomic_store(&_state->inputRate, rate);
}

- (void)pushFrames:(const int16_t *)frames count:(size_t)count {
  if (frames == NULL || count == 0) return;
  uint32_t write = atomic_load_explicit(&_state->writeIndex, memory_order_relaxed);
  uint32_t read = atomic_load_explicit(&_state->readIndex, memory_order_acquire);
  uint32_t space = LIBRETRO_RING_FRAMES - (write - read);
  size_t accepted = count < space ? count : space;
  for (size_t index = 0; index < accepted; index++) {
    uint32_t slot = (write + (uint32_t)index) & LIBRETRO_RING_MASK;
    _state->samples[slot * 2] = frames[index * 2];
    _state->samples[slot * 2 + 1] = frames[index * 2 + 1];
  }
  atomic_store_explicit(&_state->writeIndex, write + (uint32_t)accepted, memory_order_release);
}

- (void)clear {
  uint32_t write = atomic_load_explicit(&_state->writeIndex, memory_order_acquire);
  atomic_store_explicit(&_state->readIndex, write, memory_order_release);
}

- (unsigned)occupancyPercent {
  uint32_t write = atomic_load_explicit(&_state->writeIndex, memory_order_acquire);
  uint32_t read = atomic_load_explicit(&_state->readIndex, memory_order_acquire);
  return (unsigned)((uint64_t)(write - read) * 100u / LIBRETRO_RING_FRAMES);
}

@end
