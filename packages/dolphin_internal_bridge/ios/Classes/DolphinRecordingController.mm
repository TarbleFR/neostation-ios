// SPDX-License-Identifier: GPL-2.0-or-later
#import "DolphinRecordingController.h"
#import "DolphinRecordingTimeline.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#include <atomic>
#include <cmath>
#include <deque>
#include <vector>

namespace {
NSString* const ErrorDomain = @"NeoStation.DolphinRecording";
// About 256 KiB for typical 20 ms stereo PCM buffers. This also covers the
// first hardware-encoder/CIContext setup without an unbounded audio backlog.
constexpr unsigned AudioCapacity = 64;
constexpr int64_t Nanoseconds = 1000000000LL;
NSError* RecordingError(NSInteger code, NSString* message) {
  return [NSError errorWithDomain:ErrorDomain code:code
      userInfo:@{NSLocalizedDescriptionKey: message}];
}
int64_t TimeNs(CMTime time) {
  if (!CMTIME_IS_NUMERIC(time)) return -1;
  return CMTimeConvertScale(time, Nanoseconds, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
}
CMTime HostTime() { return CMClockGetTime(CMClockGetHostTimeClock()); }
CGImagePropertyOrientation Orientation(CMSampleBufferRef sample) {
  CFTypeRef value = CMGetAttachment(sample, (__bridge CFStringRef)RPVideoSampleOrientationKey, nullptr);
  if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
    int orientation = 1;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &orientation);
    if (orientation >= 1 && orientation <= 8) return (CGImagePropertyOrientation)orientation;
  }
  return kCGImagePropertyOrientationUp;
}
CGImagePropertyOrientation InverseOrientation(CGImagePropertyOrientation orientation) {
  if (orientation == kCGImagePropertyOrientationRight) return kCGImagePropertyOrientationLeft;
  if (orientation == kCGImagePropertyOrientationLeft) return kCGImagePropertyOrientationRight;
  return orientation;
}
CGAffineTransform TrackTransform(CGImagePropertyOrientation orientation, CGFloat width, CGFloat height) {
  switch (orientation) {
    case kCGImagePropertyOrientationUpMirrored: return CGAffineTransformMake(-1, 0, 0, 1, width, 0);
    case kCGImagePropertyOrientationDown: return CGAffineTransformMake(-1, 0, 0, -1, width, height);
    case kCGImagePropertyOrientationDownMirrored: return CGAffineTransformMake(1, 0, 0, -1, 0, height);
    case kCGImagePropertyOrientationLeftMirrored: return CGAffineTransformMake(0, 1, 1, 0, 0, 0);
    case kCGImagePropertyOrientationRight: return CGAffineTransformMake(0, 1, -1, 0, height, 0);
    case kCGImagePropertyOrientationRightMirrored: return CGAffineTransformMake(0, -1, -1, 0, height, width);
    case kCGImagePropertyOrientationLeft: return CGAffineTransformMake(0, -1, 1, 0, 0, width);
    default: return CGAffineTransformIdentity;
  }
}
}

@interface DolphinReplayKitSource : NSObject <DolphinRecordingCaptureSource>
@end
@implementation DolphinReplayKitSource
- (BOOL)isAvailable {
  return RPScreenRecorder.sharedRecorder.isAvailable && !UIScreen.mainScreen.isCaptured;
}
- (BOOL)isRecording { return RPScreenRecorder.sharedRecorder.isRecording; }
- (BOOL)isMicrophoneEnabled { return RPScreenRecorder.sharedRecorder.isMicrophoneEnabled; }
- (void)setMicrophoneEnabled:(BOOL)value { RPScreenRecorder.sharedRecorder.microphoneEnabled = value; }
- (void)startCaptureWithHandler:(DolphinRecordingSampleHandler)handler
             completionHandler:(void (^)(NSError*))completion {
  [RPScreenRecorder.sharedRecorder startCaptureWithHandler:handler completionHandler:completion];
}
- (void)stopCaptureWithHandler:(void (^)(NSError*))completion {
  [RPScreenRecorder.sharedRecorder stopCaptureWithHandler:completion];
}
@end

@interface DolphinRecordingController () {
  id<DolphinRecordingCaptureSource> _source;
  dispatch_queue_t _queue;
  dispatch_source_t _timer;
  dispatch_semaphore_t _videoGate;
  dispatch_semaphore_t _audioGate;
  std::atomic<bool> _accepting;
  std::atomic<bool> _failureRequested;
  std::atomic<uint64_t> _generation;
  std::atomic<uint64_t> _captured, _encoded, _duplicated, _dropped;
  // The fields below are either main-thread lifecycle state or queue-owned
  // writer state. Capture callbacks only touch atomics and bounded gates.
  BOOL _startInFlight, _sourceStopIssued, _deliveringFinish;
  void (^_startCompletion)(NSError*);
  NSMutableArray* _stopCompletions;
  NSError* _lastError;
  NSURL* _lastResultURL;
  id _backgroundObserver, _interruptionObserver;
  UIBackgroundTaskIdentifier _backgroundTask;

  AVAssetWriter* _writer;
  AVAssetWriterInput* _videoInput;
  AVAssetWriterInput* _audioInput;
  AVAssetWriterInputPixelBufferAdaptor* _adaptor;
  CIContext* _imageContext;
  CGColorSpaceRef _colorSpace;
  NSURL* _outputURL;
  NSError* _terminalError;
  CMTime _epoch, _hostAnchor, _stopHost;
  int64_t _anchorSourceNs, _lastVideoEndNs, _lastAudioEndNs, _appendedAudioEndNs;
  int64_t _finishDurationNs, _blockedSinceNs;
  CGImagePropertyOrientation _fixedOrientation;
  size_t _width, _height;
  DolphinRecording::Timeline _timeline;
  CMSampleBufferRef _pendingVideo, _previousVideo;
  CVPixelBufferRef _pendingPixel, _previousPixel;
  uint64_t _pendingSequence, _previousSequence, _lastEncodedSequence;
  int64_t _pendingTimeNs, _previousTimeNs;
  dispatch_semaphore_t _pendingGate;
  std::deque<CMSampleBufferRef> _audio;
  BOOL _sourceStopped, _finalizing, _finishDelivered;
}
@property(atomic, readwrite) DolphinRecordingState state;
@property(atomic, strong, readwrite, nullable) NSURL* lastRecordingURL;
@end

@implementation DolphinRecordingController
- (instancetype)init { return [self initWithCaptureSource:[DolphinReplayKitSource new]]; }
- (instancetype)initWithCaptureSource:(id<DolphinRecordingCaptureSource>)source {
  self = [super init];
  if (!self) return nil;
  _source = source;
  _queue = dispatch_queue_create("com.neostation.dolphin.recording", DISPATCH_QUEUE_SERIAL);
  dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  _stopCompletions = [NSMutableArray new];
  _state = DolphinRecordingStateIdle;
  _backgroundTask = UIBackgroundTaskInvalid;
  __weak DolphinRecordingController* weakSelf = self;
  _backgroundObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
      queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*) {
        // ReplayKit's consent prompt only resigns active; it must not stop us.
        if (weakSelf.isActive) [weakSelf stopWithCompletion:^(NSURL*, NSError*) {}];
      }];
  _interruptionObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:AVAudioSessionInterruptionNotification object:nil
      queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* notification) {
        if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] ==
            AVAudioSessionInterruptionTypeBegan && weakSelf.isActive) {
          [weakSelf requestStop:RecordingError(3, @"Recording stopped by an audio interruption.")];
        }
      }];
  return self;
}

- (BOOL)isActive { return self.state != DolphinRecordingStateIdle; }
- (NSDictionary<NSString*, NSNumber*>*)statistics {
  return @{ @"captured": @(_captured.load()), @"encoded": @(_encoded.load()),
      @"duplicated": @(_duplicated.load()), @"dropped": @(_dropped.load()), @"fps": @50 };
}
- (void)publishState:(DolphinRecordingState)state error:(NSError*)error {
  NSAssert(NSThread.isMainThread, @"Recording lifecycle must use main thread");
  self.state = state;
  if (self.statusHandler) self.statusHandler(state, error);
}
- (void)completeStart:(NSError*)error {
  void (^completion)(NSError*) = _startCompletion;
  _startCompletion = nil;
  if (completion) completion(error);
}

- (void)startWithCompletion:(void (^)(NSError*))completion {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self startWithCompletion:completion]; });
    return;
  }
  if (_deliveringFinish) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self startWithCompletion:completion]; });
    return;
  }
  if (self.isActive || _startInFlight || _source.isRecording) {
    completion(RecordingError(1, @"Another ReplayKit capture is already active or starting."));
    return;
  }
  if (!_source.isAvailable) {
    completion(RecordingError(2, @"Screen recording is unavailable."));
    return;
  }
  const uint64_t generation = ++_generation;
  _startInFlight = YES;
  _sourceStopIssued = NO;
  _startCompletion = [completion copy];
  _lastError = nil;
  _failureRequested = false;
  _captured = _encoded = _duplicated = _dropped = 0;
  _videoGate = dispatch_semaphore_create(1);
  _audioGate = dispatch_semaphore_create(AudioCapacity);
  const dispatch_semaphore_t videoGate = _videoGate;
  const dispatch_semaphore_t audioGate = _audioGate;
  [self publishState:DolphinRecordingStateStarting error:nil];
  dispatch_async(_queue, ^{ [self resetWriter]; });
  _accepting = true;
  _source.microphoneEnabled = NO;
  __weak DolphinRecordingController* weakSelf = self;
  [_source startCaptureWithHandler:^(CMSampleBufferRef sample, RPSampleBufferType type, NSError* error) {
    DolphinRecordingController* strongSelf = weakSelf;
    if (!strongSelf || generation != strongSelf->_generation.load()) return;
    if (error) { [strongSelf signalFailure:error generation:generation]; return; }
    if (!strongSelf->_accepting.load() || !sample || !CMSampleBufferDataIsReady(sample)) return;
    if (type == RPSampleBufferTypeVideo) {
      const uint64_t sequence = ++strongSelf->_captured;
      if (dispatch_semaphore_wait(videoGate, DISPATCH_TIME_NOW) != 0) {
        ++strongSelf->_dropped;
        return;
      }
      CFRetain(sample);
      dispatch_async(strongSelf->_queue, ^{
        if (generation != strongSelf->_generation.load() || strongSelf->_finalizing) {
          CFRelease(sample); dispatch_semaphore_signal(videoGate); return;
        }
        [strongSelf receiveVideo:sample sequence:sequence gate:videoGate];
      });
    } else if (type == RPSampleBufferTypeAudioApp) {
      if (dispatch_semaphore_wait(audioGate, DISPATCH_TIME_NOW) != 0) {
        [strongSelf signalFailure:RecordingError(4, @"The encoder cannot keep up with game audio. Recording stopped.")];
        return;
      }
      CFRetain(sample);
      dispatch_async(strongSelf->_queue, ^{
        if (generation != strongSelf->_generation.load() || strongSelf->_finalizing) {
          CFRelease(sample); dispatch_semaphore_signal(audioGate); return;
        }
        strongSelf->_audio.push_back(sample);
        [strongSelf updateAudioEnd:sample];
        [strongSelf drain];
      });
    }
    // Microphone buffers are never accepted, even if an external setting flips.
  } completionHandler:^(NSError* error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      DolphinRecordingController* strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf->_startInFlight = NO;
      if (generation != strongSelf->_generation.load() || strongSelf.state == DolphinRecordingStateIdle) {
        if (!error && strongSelf->_source.isRecording) {
          [strongSelf->_source stopCaptureWithHandler:^(NSError*) {}];
        }
        return;
      }
      if (error) {
        [strongSelf completeStart:error];
        [strongSelf requestStop:error];
        [strongSelf stopSource:generation];
      } else if (strongSelf.state == DolphinRecordingStateStopping) {
        [strongSelf stopSource:generation];
      } else {
        [strongSelf publishState:DolphinRecordingStateRecording error:nil];
        [strongSelf completeStart:nil];
      }
    });
  }];
}

- (void)stopWithCompletion:(void (^)(NSURL*, NSError*))completion {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self stopWithCompletion:completion]; });
    return;
  }
  if (self.state == DolphinRecordingStateIdle) {
    completion(_lastResultURL, _lastError);
    return;
  }
  [_stopCompletions addObject:[completion copy]];
  [self requestStop:nil];
}
- (void)signalFailure:(NSError*)error {
  [self signalFailure:error generation:_generation.load()];
}
- (void)signalFailure:(NSError*)error generation:(uint64_t)generation {
  if (generation != _generation.load()) return;
  if (_failureRequested.exchange(true)) return;
  _accepting = false;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (generation == self->_generation.load()) {
      [self requestStop:error ?: RecordingError(17, @"Screen recording failed.")];
    }
  });
}
- (void)requestStop:(NSError*)error {
  NSAssert(NSThread.isMainThread, @"Stop uses main thread");
  if (self.state == DolphinRecordingStateIdle) return;
  if (error && !_lastError) _lastError = error;
  if (error) dispatch_async(_queue, ^{ if (!self->_terminalError) self->_terminalError = error; });
  if (self.state == DolphinRecordingStateStopping) return;
  _accepting = false;
  const uint64_t generation = _generation.load();
  if (_backgroundTask == UIBackgroundTaskInvalid) {
    __weak DolphinRecordingController* weakSelf = self;
    _backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"DolphinRecordingFinalize"
        expirationHandler:^{
      DolphinRecordingController* strongSelf = weakSelf;
      if (!strongSelf) return;
      if (generation != strongSelf->_generation.load()) return;
      // UIKit invokes expiration on main. Release its lease immediately;
      // waiting for a stalled writer queue here can make iOS kill the app.
      UIBackgroundTaskIdentifier task = strongSelf->_backgroundTask;
      strongSelf->_backgroundTask = UIBackgroundTaskInvalid;
      if (task != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:task];
      dispatch_async(strongSelf->_queue, ^{
        if (generation != strongSelf->_generation.load() || strongSelf->_finishDelivered) return;
        strongSelf->_terminalError = strongSelf->_terminalError ?: RecordingError(18, @"iOS ended the recording finalization time.");
        strongSelf->_finalizing = YES;
        if (strongSelf->_timer) { dispatch_source_cancel(strongSelf->_timer); strongSelf->_timer = nil; }
        const BOOL completed = strongSelf->_writer.status == AVAssetWriterStatusCompleted;
        if (!completed) [strongSelf->_writer cancelWriting];
        [strongSelf deliverFinished:completed];
      });
    }];
  }
  const CMTime stopHost = HostTime();
  dispatch_async(_queue, ^{ self->_stopHost = stopHost; });
  [self publishState:DolphinRecordingStateStopping error:error];
  [self completeStart:error ?: RecordingError(5, @"Recording start was cancelled.")];
  if (!_startInFlight) [self stopSource:generation];
  // No main/capture/emulation thread waits for ReplayKit or a stalled encoder.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), _queue, ^{
    if (generation != self->_generation.load() || self->_finishDelivered) return;
    if (!self->_terminalError) self->_terminalError = RecordingError(6, @"Recording finalization timed out.");
    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation == self->_generation.load() && self->_source.isRecording) [self stopSource:generation];
    });
    [self finishAcceptedFrames];
  });
}
- (void)stopSource:(uint64_t)generation {
  if (_sourceStopIssued) return;
  _sourceStopIssued = YES;
  __weak DolphinRecordingController* weakSelf = self;
  void (^completed)(NSError*) = ^(NSError* error) {
    DolphinRecordingController* strongSelf = weakSelf;
    if (!strongSelf) return;
    dispatch_async(strongSelf->_queue, ^{
      if (generation != strongSelf->_generation.load() || strongSelf->_finalizing) return;
      if (error && !strongSelf->_terminalError) strongSelf->_terminalError = error;
      strongSelf->_sourceStopped = YES;
      strongSelf->_finishDurationNs = MAX(strongSelf->_lastVideoEndNs, strongSelf->_lastAudioEndNs);
      if (CMTIME_IS_NUMERIC(strongSelf->_hostAnchor)) {
        strongSelf->_finishDurationNs = MAX(strongSelf->_finishDurationNs,
            strongSelf->_anchorSourceNs + TimeNs(CMTimeSubtract(strongSelf->_stopHost, strongSelf->_hostAnchor)));
      }
      [strongSelf drain];
      if (!strongSelf->_writer) [strongSelf finishAcceptedFrames];
    });
  };
  if (_source.isRecording) [_source stopCaptureWithHandler:completed];
  else completed(nil);
}

- (void)resetWriter {
  _writer = nil; _videoInput = nil; _audioInput = nil; _adaptor = nil;
  _imageContext = nil; _outputURL = nil; _terminalError = nil;
  _epoch = _hostAnchor = _stopHost = kCMTimeInvalid;
  _anchorSourceNs = _lastVideoEndNs = _lastAudioEndNs = _appendedAudioEndNs = 0;
  _finishDurationNs = _blockedSinceNs = 0;
  _sourceStopped = _finalizing = _finishDelivered = NO;
  _timeline.reset();
  _pendingTimeNs = _previousTimeNs = -1;
  _pendingSequence = _previousSequence = _lastEncodedSequence = 0;
}
- (BOOL)prepareWriter:(CMSampleBufferRef)sample {
  CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
  if (!image) { [self signalFailure:RecordingError(7, @"ReplayKit supplied an invalid video frame.")]; return NO; }
  const size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image);
  if (width < 2 || height < 2 || width > 16384 || height > 16384) {
    [self signalFailure:RecordingError(7, @"ReplayKit supplied invalid video dimensions.")]; return NO;
  }
  _epoch = CMSampleBufferGetPresentationTimeStamp(sample);
  if (!CMTIME_IS_NUMERIC(_epoch)) {
    [self signalFailure:RecordingError(7, @"ReplayKit supplied an invalid video timestamp.")]; return NO;
  }
  if (!_audio.empty()) {
    const CMTime audioTime = CMSampleBufferGetPresentationTimeStamp(_audio.front());
    if (CMTIME_IS_NUMERIC(audioTime) && CMTimeCompare(audioTime, _epoch) < 0) _epoch = audioTime;
  }
  _hostAnchor = HostTime();
  _anchorSourceNs = TimeNs(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), _epoch));
  _fixedOrientation = Orientation(sample);
  const BOOL rotated = _fixedOrientation >= kCGImagePropertyOrientationLeftMirrored;
  const double scale = std::min(1.0, std::min((rotated ? 1080.0 : 1920.0) / width,
      (rotated ? 1920.0 : 1080.0) / height));
  _width = MAX(2, (size_t)(width * scale) & ~(size_t)1);
  _height = MAX(2, (size_t)(height * scale) & ~(size_t)1);
  NSError* error;
  NSURL* documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory
      inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
  NSURL* directory = [documents URLByAppendingPathComponent:@"Recordings/Dolphin" isDirectory:YES];
  if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory
      withIntermediateDirectories:YES attributes:nil error:&error]) {
    [self signalFailure:error ?: RecordingError(8, @"Cannot create the recording folder.")]; return NO;
  }
  _outputURL = [directory URLByAppendingPathComponent:
      [NSString stringWithFormat:@"Dolphin-%@.mp4", NSUUID.UUID.UUIDString]];
  _writer = [[AVAssetWriter alloc] initWithURL:_outputURL fileType:AVFileTypeMPEG4 error:&error];
  if (!_writer) { [self signalFailure:error]; return NO; }
  NSDictionary* videoSettings = @{AVVideoCodecKey: AVVideoCodecTypeH264,
      AVVideoWidthKey: @(_width), AVVideoHeightKey: @(_height),
      AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @8000000,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoAllowFrameReorderingKey: @NO, AVVideoMaxKeyFrameIntervalKey: @100,
          AVVideoExpectedSourceFrameRateKey: @50}};
  NSDictionary* audioSettings = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC),
      AVSampleRateKey: @48000, AVNumberOfChannelsKey: @2, AVEncoderBitRateKey: @128000};
  if (![_writer canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo] ||
      ![_writer canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio]) {
    [self signalFailure:RecordingError(9, @"The device cannot encode this recording format.")]; return NO;
  }
  _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
  _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
  _videoInput.expectsMediaDataInRealTime = YES;
  _audioInput.expectsMediaDataInRealTime = YES;
  _videoInput.transform = TrackTransform(_fixedOrientation, _width, _height);
  if (![_writer canAddInput:_videoInput] || ![_writer canAddInput:_audioInput]) {
    [self signalFailure:RecordingError(10, @"Cannot configure the recording tracks.")]; return NO;
  }
  [_writer addInput:_videoInput]; [_writer addInput:_audioInput];
  _adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:_videoInput
      sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
          (id)kCVPixelBufferWidthKey: @(_width), (id)kCVPixelBufferHeightKey: @(_height),
          (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES}];
  _imageContext = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
  _colorSpace = CGColorSpaceCreateDeviceRGB();
  if (![_writer startWriting]) { [self signalFailure:_writer.error]; return NO; }
  [_writer startSessionAtSourceTime:kCMTimeZero];
  for (CMSampleBufferRef audio : _audio) [self updateAudioEnd:audio];
  _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
      10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
  __weak DolphinRecordingController* weakSelf = self;
  dispatch_source_set_event_handler(_timer, ^{ [weakSelf drain]; });
  dispatch_resume(_timer);
  return YES;
}
- (void)receiveVideo:(CMSampleBufferRef)sample sequence:(uint64_t)sequence gate:(dispatch_semaphore_t)gate {
  @autoreleasepool {
    if (!CMSampleBufferGetImageBuffer(sample)) {
      CFRelease(sample); dispatch_semaphore_signal(gate);
      [self signalFailure:RecordingError(7, @"ReplayKit supplied an invalid video frame.")]; return;
    }
    if ((!_writer && ![self prepareWriter:sample]) || _writer.status != AVAssetWriterStatusWriting) {
      CFRelease(sample); dispatch_semaphore_signal(gate); return;
    }
    const int64_t relative = TimeNs(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), _epoch));
    if (relative < 0 || relative < _previousTimeNs) {
      ++_dropped; CFRelease(sample); dispatch_semaphore_signal(gate); return;
    }
    _pendingVideo = sample; _pendingGate = gate;
    _pendingSequence = sequence; _pendingTimeNs = relative;
    const int64_t duration = TimeNs(CMSampleBufferGetDuration(sample));
    _lastVideoEndNs = MAX(_lastVideoEndNs, relative + (duration > 0 ? duration : DolphinRecording::Timeline::TickNanoseconds));
    [self drain];
  }
}
- (void)updateAudioEnd:(CMSampleBufferRef)sample {
  if (!CMTIME_IS_NUMERIC(_epoch)) return;
  int64_t duration = TimeNs(CMSampleBufferGetDuration(sample));
  if (duration <= 0) {
    const AudioStreamBasicDescription* format = CMAudioFormatDescriptionGetStreamBasicDescription(
        CMSampleBufferGetFormatDescription(sample));
    if (format && format->mSampleRate > 0) {
      duration = (int64_t)llround(CMSampleBufferGetNumSamples(sample) * (double)Nanoseconds / format->mSampleRate);
    }
  }
  const int64_t start = TimeNs(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), _epoch));
  if (start >= 0 && duration > 0) _lastAudioEndNs = MAX(_lastAudioEndNs, start + duration);
}
- (CVPixelBufferRef)pixelForSample:(CMSampleBufferRef*)sample cached:(CVPixelBufferRef*)cached {
  if (*cached) return *cached;
  if (!*sample || !_adaptor.pixelBufferPool) return nullptr;
  CVPixelBufferRef pixel = nullptr;
  const CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
      _adaptor.pixelBufferPool, (__bridge CFDictionaryRef)@{(id)kCVPixelBufferPoolAllocationThresholdKey: @3}, &pixel);
  if (result == kCVReturnWouldExceedAllocationThreshold) return nullptr;
  if (result != kCVReturnSuccess || !pixel) {
    [self signalFailure:RecordingError(11, @"Cannot allocate a recording frame.")]; return nullptr;
  }
  @try { @autoreleasepool {
    CIImage* image = [CIImage imageWithCVPixelBuffer:CMSampleBufferGetImageBuffer(*sample)];
    image = [image imageByApplyingOrientation:Orientation(*sample)];
    image = [image imageByApplyingOrientation:InverseOrientation(_fixedOrientation)];
    const CGRect extent = image.extent;
    const CGFloat scale = MIN(_width / extent.size.width, _height / extent.size.height);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
        (_width - extent.size.width * scale) / 2.0, (_height - extent.size.height * scale) / 2.0)];
    const CGRect bounds = CGRectMake(0, 0, _width, _height);
    CIImage* black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:bounds];
    image = [image imageByCompositingOverImage:black];
    [_imageContext render:image toCVPixelBuffer:pixel bounds:bounds colorSpace:_colorSpace];
  } } @catch (NSException* exception) {
    CVPixelBufferRelease(pixel);
    [self signalFailure:RecordingError(11, exception.reason ?: @"Cannot resize the recording frame.")];
    return nullptr;
  }
  CFRelease(*sample); *sample = nullptr;
  *cached = pixel;
  return pixel;
}
- (void)promoteIncoming {
  if (_previousSequence && _previousSequence != _lastEncodedSequence) ++_dropped;
  if (_previousVideo) CFRelease(_previousVideo);
  if (_previousPixel) CVPixelBufferRelease(_previousPixel);
  _previousVideo = _pendingVideo; _pendingVideo = nullptr;
  _previousPixel = _pendingPixel; _pendingPixel = nullptr;
  _previousSequence = _pendingSequence; _previousTimeNs = _pendingTimeNs;
  _pendingSequence = 0; _pendingTimeNs = -1;
  if (_pendingGate) { dispatch_semaphore_signal(_pendingGate); _pendingGate = nil; }
}
- (void)drainAudio {
  while (!_audio.empty() && _audioInput.readyForMoreMediaData) {
    CMSampleBufferRef sample = _audio.front();
    const CMTime presentation = CMSampleBufferGetPresentationTimeStamp(sample);
    if (CMTIME_IS_NUMERIC(presentation) && CMTimeCompare(presentation, _epoch) < 0) {
      // ReplayKit can deliver its first PCM packet after the first picture,
      // although that packet begins a few milliseconds before the picture.
      // Trim only those leading samples; shifting the packet would desync it.
      const AudioStreamBasicDescription* format = CMAudioFormatDescriptionGetStreamBasicDescription(
          CMSampleBufferGetFormatDescription(sample));
      if (!format || format->mFormatID != kAudioFormatLinearPCM ||
          format->mSampleRate <= 0 || format->mSampleRate > 384000) {
        _audio.pop_front(); CFRelease(sample); dispatch_semaphore_signal(_audioGate);
        [self signalFailure:RecordingError(12, @"Cannot align the initial game-audio packet.")]; return;
      }
      const CMItemCount skipped = CMTimeConvertScale(CMTimeSubtract(_epoch, presentation),
          (int32_t)llround(format->mSampleRate), kCMTimeRoundingMethod_RoundAwayFromZero).value;
      const CMItemCount total = CMSampleBufferGetNumSamples(sample);
      if (skipped >= total) {
        _audio.pop_front(); CFRelease(sample); dispatch_semaphore_signal(_audioGate); continue;
      }
      CMSampleBufferRef trimmed = nullptr;
      const OSStatus trimmedStatus = CMSampleBufferCopySampleBufferForRange(kCFAllocatorDefault,
          sample, CFRangeMake((CFIndex)skipped, (CFIndex)(total - skipped)), &trimmed);
      CFRelease(sample);
      if (trimmedStatus != noErr || !trimmed) {
        if (trimmed) CFRelease(trimmed);
        _audio.pop_front(); dispatch_semaphore_signal(_audioGate);
        [self signalFailure:RecordingError(12, @"Cannot trim the initial game-audio packet.")]; return;
      }
      _audio.front() = sample = trimmed;
    }
    CMItemCount count = 0;
    OSStatus status = CMSampleBufferGetSampleTimingInfoArray(sample, 0, nullptr, &count);
    std::vector<CMSampleTimingInfo> timing(MAX((CMItemCount)1, count));
    if (status == noErr) status = CMSampleBufferGetSampleTimingInfoArray(sample, count, timing.data(), &count);
    for (CMItemCount index = 0; status == noErr && index < count; ++index) {
      timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, _epoch);
      if (CMTIME_IS_NUMERIC(timing[index].decodeTimeStamp)) timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, _epoch);
    }
    CMSampleBufferRef retimed = nullptr;
    if (status == noErr && count > 0 && CMTimeCompare(timing[0].presentationTimeStamp, kCMTimeZero) >= 0) {
      status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sample, count, timing.data(), &retimed);
    }
    const BOOL validTiming = retimed != nullptr;
    BOOL appended = retimed && [_audioInput appendSampleBuffer:retimed];
    if (retimed) CFRelease(retimed);
    if (!appended && validTiming &&
        _writer.status == AVAssetWriterStatusWriting && !_writer.error) return;
    if (appended) {
      [self updateAudioEnd:sample];
      _appendedAudioEndNs = _lastAudioEndNs;
    }
    _audio.pop_front(); CFRelease(sample); dispatch_semaphore_signal(_audioGate);
    if (!appended) {
      [self signalFailure:_writer.error ?: RecordingError(12, @"Cannot encode game audio.")];
      return;
    }
  }
}
- (void)drain {
  @autoreleasepool {
    if (_finalizing || !_writer || _writer.status != AVAssetWriterStatusWriting) {
      if (_writer.status == AVAssetWriterStatusFailed) [self signalFailure:_writer.error];
      return;
    }
    [self drainAudio];
    unsigned count = 0;
    while (count < DolphinRecording::Timeline::BurstLimit) {
      const BOOL hasIncoming = _pendingSequence != 0;
      const BOOL hasPrevious = _previousSequence != 0;
      if (!hasIncoming && !hasPrevious) break;
      int64_t horizon = _sourceStopped ? _finishDurationNs :
          MAX((int64_t)0, _anchorSourceNs + TimeNs(CMTimeSubtract(HostTime(), _hostAnchor)) - 40000000LL);
      if (hasIncoming) horizon = MAX(horizon, _pendingTimeNs);
      if (!_timeline.due(horizon, !_sourceStopped)) break;
      if (hasIncoming && _timeline.nextNanoseconds() > _pendingTimeNs) {
        [self promoteIncoming];
        continue;
      }
      if (!_videoInput.readyForMoreMediaData) break;
      const BOOL incoming = hasIncoming && _timeline.useIncoming(_pendingTimeNs, hasPrevious);
      CVPixelBufferRef pixel = incoming
          ? [self pixelForSample:&_pendingVideo cached:&_pendingPixel]
          : [self pixelForSample:&_previousVideo cached:&_previousPixel];
      if (!pixel) break;
      const CMTime timestamp = CMTimeMake(_timeline.nextIndex(), DolphinRecording::Timeline::Rate);
      if (![_adaptor appendPixelBuffer:pixel withPresentationTime:timestamp]) {
        if (_writer.status != AVAssetWriterStatusWriting || _writer.error) {
          [self signalFailure:_writer.error ?: RecordingError(13, @"Cannot encode the video frame.")];
        }
        break;
      }
      const uint64_t sequence = incoming ? _pendingSequence : _previousSequence;
      if (sequence == _lastEncodedSequence) ++_duplicated;
      _lastEncodedSequence = sequence;
      ++_encoded; _timeline.accepted(); ++count;
    }
    if (_pendingSequence && !_timeline.due(_pendingTimeNs)) [self promoteIncoming];
    const CMTime nowTime = HostTime();
    const int64_t now = TimeNs(nowTime);
    const int64_t elapsed = _anchorSourceNs + TimeNs(CMTimeSubtract(nowTime, _hostAnchor));
    const BOOL needsFrame = (_previousSequence || _pendingSequence) && _timeline.due(elapsed - 40000000LL);
    if (count || (!needsFrame && _audio.empty())) _blockedSinceNs = 0;
    else if (!_blockedSinceNs) _blockedSinceNs = now;
    if (!_sourceStopped && ((_blockedSinceNs && now - _blockedSinceNs > Nanoseconds) ||
        (_previousSequence && elapsed - _timeline.nextNanoseconds() > Nanoseconds))) {
      [self signalFailure:RecordingError(14, @"Recording stopped because the encoder is too slow.")];
    }
    if (_sourceStopped && _audio.empty() && !_pendingSequence &&
        !_timeline.due(_finishDurationNs, false)) [self finishAcceptedFrames];
  }
}
- (void)finishAcceptedFrames {
  if (_finalizing || _finishDelivered) return;
  _finalizing = YES;
  _accepting = false;
  if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
  if (!_writer || _writer.status != AVAssetWriterStatusWriting || _timeline.nextIndex() == 0) {
    if (!_terminalError) _terminalError = _writer.error ?: RecordingError(15, @"No video frame was recorded.");
    [_writer cancelWriting];
    [self deliverFinished:NO];
    return;
  }
  [_videoInput markAsFinished]; [_audioInput markAsFinished];
  // The accepted CFR grid bounds a partial clip if finalization was interrupted.
  [_writer endSessionAtSourceTime:CMTimeMake(_timeline.nextIndex(), DolphinRecording::Timeline::Rate)];
  const uint64_t generation = _generation.load();
  [_writer finishWritingWithCompletionHandler:^{
    dispatch_async(self->_queue, ^{
      if (generation != self->_generation.load() || self->_finishDelivered) return;
      if (self->_writer.status != AVAssetWriterStatusCompleted && !self->_terminalError) self->_terminalError = self->_writer.error;
      [self deliverFinished:self->_writer.status == AVAssetWriterStatusCompleted];
    });
  }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), _queue, ^{
    if (generation != self->_generation.load() || self->_finishDelivered) return;
    if (!self->_terminalError) self->_terminalError = RecordingError(16, @"The recording encoder did not finish.");
    [self->_writer cancelWriting];
    [self deliverFinished:NO];
  });
}
- (void)releaseBuffers {
  if (_pendingVideo) { CFRelease(_pendingVideo); _pendingVideo = nullptr; }
  if (_previousVideo) { CFRelease(_previousVideo); _previousVideo = nullptr; }
  if (_pendingPixel) { CVPixelBufferRelease(_pendingPixel); _pendingPixel = nullptr; }
  if (_previousPixel) { CVPixelBufferRelease(_previousPixel); _previousPixel = nullptr; }
  if (_pendingGate) { dispatch_semaphore_signal(_pendingGate); _pendingGate = nil; }
  while (!_audio.empty()) { CFRelease(_audio.front()); _audio.pop_front(); dispatch_semaphore_signal(_audioGate); }
  if (_colorSpace) { CGColorSpaceRelease(_colorSpace); _colorSpace = nullptr; }
  _imageContext = nil;
}
- (void)deliverFinished:(BOOL)completed {
  if (_finishDelivered) return;
  _finishDelivered = YES;
  [self releaseBuffers];
  NSURL* url = completed ? _outputURL : nil;
  NSError* error = _terminalError;
  if (!completed && _outputURL) [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];
  _adaptor = nil; _videoInput = nil; _audioInput = nil; _writer = nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_backgroundTask != UIBackgroundTaskInvalid) {
      UIBackgroundTaskIdentifier task = self->_backgroundTask;
      self->_backgroundTask = UIBackgroundTaskInvalid;
      [UIApplication.sharedApplication endBackgroundTask:task];
    }
    if (url) self.lastRecordingURL = url;
    self->_lastResultURL = url;
    self->_lastError = error;
    NSArray* completions = [self->_stopCompletions copy];
    [self->_stopCompletions removeAllObjects];
    self->_deliveringFinish = YES;
    [self publishState:DolphinRecordingStateIdle error:error];
    for (id callback in completions) {
      void (^completion)(NSURL*, NSError*) = callback;
      completion(url, error);
    }
    self->_deliveringFinish = NO;
  });
}
- (void)dealloc {
  _accepting = false;
  [NSNotificationCenter.defaultCenter removeObserver:_backgroundObserver];
  [NSNotificationCenter.defaultCenter removeObserver:_interruptionObserver];
  if (_timer) dispatch_source_cancel(_timer);
  if (_backgroundTask != UIBackgroundTaskInvalid) {
    UIBackgroundTaskIdentifier task = _backgroundTask;
    if (NSThread.isMainThread) [UIApplication.sharedApplication endBackgroundTask:task];
    else dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication endBackgroundTask:task]; });
  }
  if (_source.isRecording && self.state != DolphinRecordingStateIdle) [_source stopCaptureWithHandler:^(NSError*) {}];
  if (_writer.status == AVAssetWriterStatusWriting || _writer.status == AVAssetWriterStatusUnknown) [_writer cancelWriting];
  [self releaseBuffers];
}
@end
