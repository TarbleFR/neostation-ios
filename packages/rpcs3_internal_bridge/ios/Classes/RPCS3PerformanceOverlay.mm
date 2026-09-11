// SPDX-License-Identifier: GPL-3.0-or-later
#import "RPCS3PerformanceOverlay.h"

#include <array>
#include <cmath>

namespace {
constexpr NSUInteger kCapacity = 120;
constexpr double kWindowMs = 60000.0;
constexpr uint32_t kFPSValid = 1u << 0;
constexpr uint32_t kCPUValid = 1u << 1;
constexpr uint32_t kGPUValid = 1u << 2;
constexpr uint32_t kMemoryValid = 1u << 3;

struct Sample {
  double timestampMs = 0;
  double frameTimeMs = 0;
};

NSString* MemoryText(uint64_t value) {
  const double mib = (double)value / (1024.0 * 1024.0);
  if (mib >= 1024.0) return [NSString stringWithFormat:@"%.2f GiB", mib / 1024.0];
  return [NSString stringWithFormat:@"%.0f MiB", mib];
}
}

@interface RPCS3PerformanceOverlay () {
  std::array<Sample, kCapacity> _samples;
  NSUInteger _sampleStart;
  NSUInteger _sampleCount;
}
@property(nonatomic, strong) UILabel* ratesLabel;
@property(nonatomic, strong) UILabel* memoryLabel;
@property(nonatomic, strong) UILabel* graphLabel;
@end

@implementation RPCS3PerformanceOverlay

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (!self) return nil;
  self.opaque = NO;
  self.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.88];
  self.layer.cornerRadius = 12.0;
  self.clipsToBounds = YES;
  self.userInteractionEnabled = NO;
  self.isAccessibilityElement = YES;
  self.accessibilityTraits = UIAccessibilityTraitStaticText;
  self.accessibilityLabel = @"RPCS3 Performance";
  self.accessibilityIdentifier = @"rpcs3.performance.overlay";

  self.ratesLabel = [self newLabelWithSize:13 weight:UIFontWeightSemibold];
  self.memoryLabel = [self newLabelWithSize:11 weight:UIFontWeightRegular];
  self.graphLabel = [self newLabelWithSize:10 weight:UIFontWeightRegular];
  self.graphLabel.text = @"Frame time (ms) · 60 s";
  self.graphLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
  [self reset];
  return self;
}

- (UILabel*)newLabelWithSize:(CGFloat)size weight:(UIFontWeight)weight {
  UILabel* label = [UILabel new];
  label.font = [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
  label.textColor = UIColor.whiteColor;
  label.adjustsFontSizeToFitWidth = YES;
  label.minimumScaleFactor = 0.72;
  label.isAccessibilityElement = NO;
  [self addSubview:label];
  return label;
}

- (CGSize)intrinsicContentSize { return CGSizeMake(310, 150); }

- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = MAX(0.0, self.bounds.size.width - 20.0);
  self.ratesLabel.frame = CGRectMake(10, 8, width, 18);
  self.memoryLabel.frame = CGRectMake(10, 29, width, 16);
  self.graphLabel.frame = CGRectMake(10, 50, width, 14);
  [self setNeedsDisplay];
}

- (void)reset {
  NSAssert(NSThread.isMainThread, @"RPCS3 performance UI must run on the main thread");
  _sampleStart = 0;
  _sampleCount = 0;
  self.ratesLabel.text = @"FPS — · CPU — · RSX —";
  self.memoryLabel.text = @"Memory —";
  self.accessibilityValue = [NSString stringWithFormat:@"%@. %@", self.ratesLabel.text, self.memoryLabel.text];
  [self setNeedsDisplay];
}

- (void)appendMetricsWithFPS:(double)fps
                         cpu:(double)cpu
                         gpu:(double)gpu
                  memoryUsed:(uint64_t)memoryUsed
                 memoryTotal:(uint64_t)memoryTotal
                 validFields:(uint32_t)validFields
                   timestamp:(double)timestampMs {
  NSAssert(NSThread.isMainThread, @"RPCS3 performance UI must run on the main thread");
  if (self.hidden || !std::isfinite(timestampMs)) return;

  NSString* fpsText = (validFields & kFPSValid) && std::isfinite(fps) && fps >= 0
      ? [NSString stringWithFormat:@"%.1f", fps] : @"—";
  NSString* cpuText = (validFields & kCPUValid) && std::isfinite(cpu) && cpu >= 0
      ? [NSString stringWithFormat:@"%.0f%%", cpu] : @"—";
  NSString* gpuText = (validFields & kGPUValid) && std::isfinite(gpu) && gpu >= 0
      ? [NSString stringWithFormat:@"%.0f%%", gpu] : @"—";
  self.ratesLabel.text = [NSString stringWithFormat:@"FPS %@ · CPU %@ · RSX %@", fpsText, cpuText, gpuText];

  if ((validFields & kMemoryValid) && memoryTotal > 0 && memoryUsed <= memoryTotal) {
    self.memoryLabel.text = [NSString stringWithFormat:@"Memory %@ / %@", MemoryText(memoryUsed), MemoryText(memoryTotal)];
  } else {
    self.memoryLabel.text = @"Memory —";
  }

  if ((validFields & kFPSValid) && std::isfinite(fps) && fps > 0) {
    while (_sampleCount && timestampMs - _samples[_sampleStart].timestampMs > kWindowMs) {
      _sampleStart = (_sampleStart + 1) % kCapacity;
      --_sampleCount;
    }
    const double frameTime = 1000.0 / fps;
    NSUInteger next = (_sampleStart + _sampleCount) % kCapacity;
    _samples[next] = {timestampMs, frameTime};
    if (_sampleCount < kCapacity) ++_sampleCount;
    else _sampleStart = (_sampleStart + 1) % kCapacity;
  }
  self.accessibilityValue = [NSString stringWithFormat:@"%@. %@", self.ratesLabel.text, self.memoryLabel.text];
  [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
  [super drawRect:rect];
  CGContextRef context = UIGraphicsGetCurrentContext();
  if (!context) return;
  CGRect graph = CGRectMake(40, 69, MAX(0.0, self.bounds.size.width - 50.0),
                            MAX(0.0, self.bounds.size.height - 94.0));
  if (graph.size.width <= 0 || graph.size.height <= 0) return;

  double maximum = 33.4;
  for (NSUInteger index = 0; index < _sampleCount; ++index)
    maximum = MAX(maximum, _samples[(_sampleStart + index) % kCapacity].frameTimeMs);
  maximum = std::ceil(maximum / 10.0) * 10.0;
  NSDictionary* attrs = @{
    NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightRegular],
    NSForegroundColorAttributeName: [UIColor colorWithWhite:0.75 alpha:1.0],
  };
  for (NSUInteger index = 0; index < 3; ++index) {
    CGFloat y = CGRectGetMinY(graph) + graph.size.height * index / 2.0;
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.16].CGColor);
    CGContextSetLineWidth(context, 0.5);
    CGContextMoveToPoint(context, graph.origin.x, y);
    CGContextAddLineToPoint(context, CGRectGetMaxX(graph), y);
    CGContextStrokePath(context);
    [[NSString stringWithFormat:@"%.0f", maximum * (1.0 - index / 2.0)]
        drawAtPoint:CGPointMake(8, y - 5) withAttributes:attrs];
  }
  [@"−60 s" drawAtPoint:CGPointMake(graph.origin.x, CGRectGetMaxY(graph) + 4) withAttributes:attrs];
  [@"0 s" drawAtPoint:CGPointMake(CGRectGetMaxX(graph) - 18, CGRectGetMaxY(graph) + 4) withAttributes:attrs];
  if (!_sampleCount) return;

  double latest = _samples[(_sampleStart + _sampleCount - 1) % kCapacity].timestampMs;
  UIBezierPath* line = [UIBezierPath bezierPath];
  for (NSUInteger index = 0; index < _sampleCount; ++index) {
    const auto& sample = _samples[(_sampleStart + index) % kCapacity];
    CGFloat x = CGRectGetMaxX(graph) - graph.size.width * (latest - sample.timestampMs) / kWindowMs;
    CGFloat y = CGRectGetMaxY(graph) - graph.size.height * sample.frameTimeMs / maximum;
    if (index == 0) [line moveToPoint:CGPointMake(x, y)];
    else [line addLineToPoint:CGPointMake(x, y)];
  }
  [UIColor.systemGreenColor setStroke];
  line.lineWidth = 1.5;
  [line stroke];
}

@end
