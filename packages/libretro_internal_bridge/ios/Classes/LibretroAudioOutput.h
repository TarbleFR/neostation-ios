#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plays the core's interleaved stereo int16 samples through AVAudioEngine.
///
/// The core produces samples at its own rate (32040 Hz for the SNES, 44100
/// or 48000 Hz for others). A lock-free ring buffer decouples the emulation
/// thread from the render thread, which resamples to the device rate with a
/// small dynamic rate correction that keeps the buffer half full, as
/// RetroArch does, so neither crackles nor drifts.
@interface LibretroAudioOutput : NSObject

- (instancetype)initWithInputRate:(double)rate;
- (BOOL)start:(NSError *_Nullable *_Nullable)error;
- (void)stop;
- (void)setInputRate:(double)rate;

/// Emulation thread. Frames that do not fit are dropped.
- (void)pushFrames:(const int16_t *)frames count:(size_t)count;
- (void)clear;

/// Buffer fill level, 0-100.
@property(nonatomic, readonly) unsigned occupancyPercent;

@end

NS_ASSUME_NONNULL_END
