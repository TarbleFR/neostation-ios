// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <ReplayKit/ReplayKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DolphinRecordingState) {
  DolphinRecordingStateIdle,
  DolphinRecordingStateStarting,
  DolphinRecordingStateRecording,
  DolphinRecordingStateStopping,
};

typedef void (^DolphinRecordingSampleHandler)(CMSampleBufferRef _Nullable sample,
    RPSampleBufferType type, NSError* _Nullable error);

/// Injection boundary for the simulator test; the default source is ReplayKit.
@protocol DolphinRecordingCaptureSource <NSObject>
@property(nonatomic, readonly, getter=isAvailable) BOOL available;
@property(nonatomic, readonly, getter=isRecording) BOOL recording;
@property(nonatomic, getter=isMicrophoneEnabled) BOOL microphoneEnabled;
- (void)startCaptureWithHandler:(DolphinRecordingSampleHandler)handler
             completionHandler:(void (^)(NSError* _Nullable error))completion;
- (void)stopCaptureWithHandler:(void (^)(NSError* _Nullable error))completion;
@end

/// Explicit, bounded ReplayKit capture. A completed file is retained in
/// Documents/Recordings/Dolphin and can be shared without Photos permission.
@interface DolphinRecordingController : NSObject
@property(atomic, readonly) DolphinRecordingState state;
@property(atomic, readonly, getter=isActive) BOOL active;
@property(atomic, strong, readonly, nullable) NSURL* lastRecordingURL;
@property(nonatomic, copy, nullable) void (^statusHandler)(DolphinRecordingState state,
    NSError* _Nullable error);
@property(nonatomic, readonly) NSDictionary<NSString*, NSNumber*>* statistics;

- (instancetype)init;
- (instancetype)initWithCaptureSource:(id<DolphinRecordingCaptureSource>)source
    NS_DESIGNATED_INITIALIZER;
// All completions and status notifications run on the main thread.
- (void)startWithCompletion:(void (^)(NSError* _Nullable error))completion;
- (void)stopWithCompletion:(void (^)(NSURL* _Nullable url, NSError* _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
