// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#include <cmath>
#import "DolphinRecordingController.h"

@interface RecordingTestSource : NSObject <DolphinRecordingCaptureSource>
@property(nonatomic, getter=isAvailable) BOOL available;
@property(nonatomic, getter=isRecording) BOOL recording;
@property(nonatomic, getter=isMicrophoneEnabled) BOOL microphoneEnabled;
@property(nonatomic) BOOL delayStart;
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSUInteger stops;
@property(nonatomic, copy) DolphinRecordingSampleHandler samples;
@property(nonatomic, copy) void (^started)(NSError*);
- (void)completeStart;
@end
@implementation RecordingTestSource
- (instancetype)init {
  self = [super init];
  if (self) { _available = YES; _microphoneEnabled = YES; }
  return self;
}
- (void)startCaptureWithHandler:(DolphinRecordingSampleHandler)handler
             completionHandler:(void (^)(NSError*))completion {
  ++self.starts;
  self.samples = handler;
  self.started = completion;
  if (!self.delayStart) [self completeStart];
}
- (void)completeStart {
  self.recording = YES;
  void (^completion)(NSError*) = self.started;
  self.started = nil;
  if (completion) completion(nil);
}
- (void)stopCaptureWithHandler:(void (^)(NSError*))completion {
  ++self.stops;
  self.recording = NO;
  completion(nil);
}
@end

static CMSampleBufferRef TestVideo(int index, int rate, int orientation = 6) CF_RETURNS_RETAINED {
  CVPixelBufferRef pixel = nullptr;
  NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
      (id)kCVPixelBufferMetalCompatibilityKey: @YES};
  if (CVPixelBufferCreate(kCFAllocatorDefault, 360, 640, kCVPixelFormatType_32BGRA,
      (__bridge CFDictionaryRef)attributes, &pixel) != kCVReturnSuccess) return nullptr;
  CVPixelBufferLockBaseAddress(pixel, 0);
  uint8_t* bytes = (uint8_t*)CVPixelBufferGetBaseAddress(pixel);
  const size_t stride = CVPixelBufferGetBytesPerRow(pixel);
  for (size_t row = 0; row < 640; ++row) {
    for (size_t column = 0; column < 360; ++column) {
      uint8_t* value = bytes + row * stride + column * 4;
      value[0] = index % 256; value[1] = column % 256; value[2] = row % 256; value[3] = 255;
    }
  }
  CVPixelBufferUnlockBaseAddress(pixel, 0);
  CMVideoFormatDescriptionRef format = nullptr;
  CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &format);
  CMSampleTimingInfo timing = {CMTimeMake(1, rate), CMTimeMake(100 * rate + index, rate), kCMTimeInvalid};
  CMSampleBufferRef sample = nullptr;
  CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, format, &timing, &sample);
  if (sample) CMSetAttachment(sample, (__bridge CFStringRef)RPVideoSampleOrientationKey,
      (__bridge CFTypeRef)@(orientation), kCMAttachmentMode_ShouldPropagate);
  if (format) CFRelease(format);
  CVPixelBufferRelease(pixel);
  return sample;
}
static CMSampleBufferRef TestAudio(int index, int offsetSamples = 0) CF_RETURNS_RETAINED {
  AudioStreamBasicDescription stream = {};
  stream.mSampleRate = 48000; stream.mFormatID = kAudioFormatLinearPCM;
  stream.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
  stream.mBytesPerPacket = stream.mBytesPerFrame = 4;
  stream.mFramesPerPacket = 1; stream.mChannelsPerFrame = 2; stream.mBitsPerChannel = 16;
  CMAudioFormatDescriptionRef format = nullptr;
  CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &stream, 0, nullptr, 0, nullptr, nullptr, &format);
  CMBlockBufferRef block = nullptr;
  CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, 960 * 4,
      kCFAllocatorDefault, nullptr, 0, 960 * 4, 0, &block);
  CMBlockBufferFillDataBytes(0, block, 0, 960 * 4);
  CMSampleBufferRef sample = nullptr;
  CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, format,
      960, CMTimeMake(4800000 + index * 960 + offsetSamples, 48000), nullptr, &sample);
  if (format) CFRelease(format);
  if (block) CFRelease(block);
  return sample;
}

@interface RecordingControllerTests : XCTestCase
@end
@implementation RecordingControllerTests
- (void)testRefusesAnExistingCaptureAndDisablesMicrophone {
  RecordingTestSource* source = [RecordingTestSource new];
  source.recording = YES;
  DolphinRecordingController* recorder = [[DolphinRecordingController alloc] initWithCaptureSource:source];
  XCTestExpectation* refused = [self expectationWithDescription:@"capture refused"];
  [recorder startWithCompletion:^(NSError* error) {
    XCTAssertTrue(NSThread.isMainThread); XCTAssertNotNil(error); [refused fulfill];
  }];
  [self waitForExpectations:@[refused] timeout:2];
  XCTAssertEqual(source.starts, 0u);
  XCTAssertEqual(recorder.state, DolphinRecordingStateIdle);
  XCTAssertTrue(source.isRecording); // Never stop someone else's capture.
}

- (void)testStopWhileStartingFinishesOnceAfterConsentCompletes {
  RecordingTestSource* source = [RecordingTestSource new];
  source.delayStart = YES;
  DolphinRecordingController* recorder = [[DolphinRecordingController alloc] initWithCaptureSource:source];
  XCTestExpectation* start = [self expectationWithDescription:@"cancel start"];
  XCTestExpectation* stop = [self expectationWithDescription:@"stop once"];
  XCTestExpectation* idle = [self expectationWithDescription:@"cancelled recording became idle"];
  recorder.statusHandler = ^(DolphinRecordingState state, NSError*) {
    if (state == DolphinRecordingStateIdle) [idle fulfill];
  };
  __block NSUInteger stops = 0;
  [recorder startWithCompletion:^(NSError* error) { XCTAssertNotNil(error); [start fulfill]; }];
  XCTAssertFalse(source.isMicrophoneEnabled);
  [recorder stopWithCompletion:^(NSURL* url, NSError* error) {
    ++stops; XCTAssertTrue(NSThread.isMainThread); XCTAssertNil(url);
    XCTAssertNotNil(error); XCTAssertEqual(recorder.state, DolphinRecordingStateIdle);
    [stop fulfill];
  }];
  [source completeStart];
  [self waitForExpectations:@[start, stop, idle] timeout:3];
  XCTAssertEqual(stops, 1u); XCTAssertEqual(source.stops, 1u);
  XCTAssertFalse(source.isRecording);
}

- (void)testBackgroundStopsButReplayKitConsentResignDoesNot {
  RecordingTestSource* source = [RecordingTestSource new];
  DolphinRecordingController* recorder = [[DolphinRecordingController alloc] initWithCaptureSource:source];
  XCTestExpectation* started = [self expectationWithDescription:@"started"];
  XCTestExpectation* stopped = [self expectationWithDescription:@"background stopped"];
  recorder.statusHandler = ^(DolphinRecordingState state, NSError*) {
    if (state == DolphinRecordingStateIdle) [stopped fulfill];
  };
  [recorder startWithCompletion:^(NSError* error) { XCTAssertNil(error); [started fulfill]; }];
  [self waitForExpectations:@[started] timeout:2];
  [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
  XCTAssertTrue(recorder.isActive); XCTAssertEqual(source.stops, 0u);
  [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
  [self waitForExpectations:@[stopped] timeout:3];
  XCTAssertEqual(recorder.state, DolphinRecordingStateIdle);
  XCTAssertEqual(source.stops, 1u);
}

- (void)testRealWriterProduces50HzVideoWithAudioAndFixedOrientation {
  RecordingTestSource* source = [RecordingTestSource new];
  DolphinRecordingController* recorder = [[DolphinRecordingController alloc] initWithCaptureSource:source];
  XCTestExpectation* start = [self expectationWithDescription:@"capture starts"];
  [recorder startWithCompletion:^(NSError* error) { XCTAssertNil(error); [start fulfill]; }];
  [self waitForExpectations:@[start] timeout:2];
  XCTAssertFalse(source.isMicrophoneEnabled);
  XCTestExpectation* stopped = [self expectationWithDescription:@"real mp4 finalized"];
  XCTestExpectation* idle = [self expectationWithDescription:@"encoded recording became idle"];
  recorder.statusHandler = ^(DolphinRecordingState state, NSError*) {
    if (state == DolphinRecordingStateIdle) [idle fulfill];
  };
  __block NSURL* result;
  // A real-time source, including a pause in new pictures: the CFR writer
  // must hold the previous image while app audio continues at its own PTS.
  for (int index = 0; index < 60; ++index) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(index * NSEC_PER_SEC / 60.0)),
        dispatch_get_main_queue(), ^{
      if (index >= 25 && index < 38) return;
      CMSampleBufferRef sample = TestVideo(index, 60, index < 40 ? 6 : 8);
      XCTAssertNotEqual(sample, nullptr);
      if (sample) { source.samples(sample, RPSampleBufferTypeVideo, nil); CFRelease(sample); }
    });
  }
  for (int index = 0; index < 50; ++index) {
    // The first audio packet arrives after the first video but begins 10 ms
    // before its PTS. Only that negative prefix may be trimmed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (index == 0 ? 3 : index * 20) * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
      CMSampleBufferRef sample = TestAudio(index, index == 0 ? -480 : 0);
      XCTAssertNotEqual(sample, nullptr);
      if (sample) { source.samples(sample, RPSampleBufferTypeAudioApp, nil); CFRelease(sample); }
    });
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1050 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [recorder stopWithCompletion:^(NSURL* url, NSError* error) {
      XCTAssertTrue(NSThread.isMainThread); XCTAssertNil(error);
      XCTAssertNotNil(url); result = url; [stopped fulfill];
    }];
  });
  [self waitForExpectations:@[stopped, idle] timeout:10];
  XCTAssertFalse(source.isRecording); XCTAssertEqual(source.stops, 1u);
  XCTAssertTrue([result.path containsString:@"/Documents/Recordings/Dolphin/"]);
  if (!result) return;
  NSError* error;
  AVURLAsset* asset = [AVURLAsset URLAssetWithURL:result options:nil];
  NSArray<AVAssetTrack*>* videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
  NSArray<AVAssetTrack*>* audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
  XCTAssertEqual(videoTracks.count, 1u); XCTAssertEqual(audioTracks.count, 1u);
  if (videoTracks.count == 1 && audioTracks.count == 1) {
    AVAssetTrack* video = videoTracks.firstObject;
    const CGAffineTransform transform = video.preferredTransform;
    XCTAssertEqualWithAccuracy(transform.a, 0, 0.001);
    XCTAssertEqualWithAccuracy(transform.b, 1, 0.001);
    XCTAssertEqualWithAccuracy(transform.c, -1, 0.001);
    CGSize displayed = CGSizeApplyAffineTransform(video.naturalSize, transform);
    XCTAssertLessThanOrEqual(fabs(displayed.width), 1920);
    XCTAssertLessThanOrEqual(fabs(displayed.height), 1080);
    AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    XCTAssertNotNil(reader); XCTAssertNil(error);
    AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc] initWithTrack:video outputSettings:nil];
    [reader addOutput:output]; XCTAssertTrue([reader startReading]);
    NSUInteger frames = 0;
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
      const double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
      XCTAssertEqualWithAccuracy(time, frames / 50.0, 0.00002);
      ++frames; CFRelease(sample);
    }
    XCTAssertEqual(reader.status, AVAssetReaderStatusCompleted);
    XCTAssertGreaterThanOrEqual(frames, 50u);
    XCTAssertLessThan(frames, 80u);
    XCTAssertEqual(frames, recorder.statistics[@"encoded"].unsignedIntegerValue);
    XCTAssertGreaterThan(recorder.statistics[@"duplicated"].unsignedIntegerValue, 5u);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(video.timeRange.duration), frames / 50.0, 0.021);
    XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(audioTracks.firstObject.timeRange.duration), 0.95);
    XCTAssertLessThan(fabs(CMTimeGetSeconds(asset.duration) - 1.05), 0.25);
  }
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:result.path]);
  XCTAssertEqualObjects(recorder.lastRecordingURL, result);
  [NSFileManager.defaultManager removeItemAtURL:result error:nil];
}
@end
