// SPDX-License-Identifier: GPL-2.0-or-later
#import "DolphinPerformanceOverlay.h"
#include <array>
#include <cmath>

namespace {
constexpr NSUInteger DOLPerformanceCapacity = 120;
constexpr double DOLPerformanceWindowMs = 60000.0;
struct DOLPerformanceSample {
  double timestampMs = 0;
  double frameTimeMs = 0;
};

bool ReadMetric(NSDictionary* snapshot, NSString* key, double* value) {
  id number = snapshot[key];
  if (![number isKindOfClass:NSNumber.class]) return false;
  const double metric = [number doubleValue];
  if (!std::isfinite(metric) || metric < 0) return false;
  *value = metric;
  return true;
}
}

@interface DolphinPerformanceOverlay () {
  std::array<DOLPerformanceSample, DOLPerformanceCapacity> _samples;
  NSUInteger _sampleStart;
  NSUInteger _sampleCount;
}
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* labels;
@property(nonatomic, strong) UILabel* ratesLabel;
@property(nonatomic, strong) UILabel* frameTimeLabel;
@property(nonatomic, strong) UILabel* resolutionLabel;
@property(nonatomic, strong) UILabel* graphLabel;
@end

@implementation DolphinPerformanceOverlay
- (NSString*)label:(NSString*)key fallback:(NSString*)fallback {
  NSString* value = self.labels[key];
  return [value isKindOfClass:NSString.class] && value.length ? value : fallback;
}

- (instancetype)initWithLabels:(NSDictionary<NSString*, NSString*>*)labels {
  self = [super initWithFrame:CGRectZero];
  if (!self) return nil;
  self.labels = [labels copy];
  self.opaque = NO;
  self.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.88];
  self.layer.cornerRadius = 12;
  self.clipsToBounds = YES;
  self.userInteractionEnabled = NO;
  self.isAccessibilityElement = YES;
  self.accessibilityTraits = UIAccessibilityTraitStaticText;
  self.accessibilityLabel = [self label:@"performance" fallback:@"Performance"];
  self.accessibilityIdentifier = @"dolphin.performance.overlay";
  self.ratesLabel = [self newLabelWithSize:13 weight:UIFontWeightSemibold];
  self.frameTimeLabel = [self newLabelWithSize:11 weight:UIFontWeightRegular];
  self.resolutionLabel = [self newLabelWithSize:11 weight:UIFontWeightRegular];
  self.graphLabel = [self newLabelWithSize:10 weight:UIFontWeightRegular];
  self.graphLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1];
  self.ratesLabel.accessibilityIdentifier = @"dolphin.performance.rates";
  self.frameTimeLabel.accessibilityIdentifier = @"dolphin.performance.frameTime";
  self.resolutionLabel.accessibilityIdentifier = @"dolphin.performance.resolution";
  self.graphLabel.text = [self label:@"sampledFrameTime" fallback:@"Sampled frame time (ms)"];
  [self reset];
  return self;
}

- (UILabel*)newLabelWithSize:(CGFloat)size weight:(UIFontWeight)weight {
  UILabel* label = [UILabel new];
  label.font = [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
  label.textColor = UIColor.whiteColor;
  label.adjustsFontSizeToFitWidth = YES;
  label.minimumScaleFactor = 0.75;
  label.isAccessibilityElement = NO;
  [self addSubview:label];
  return label;
}

- (CGSize)intrinsicContentSize { return CGSizeMake(310, 164); }

- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = MAX(0, self.bounds.size.width - 20);
  self.ratesLabel.frame = CGRectMake(10, 8, width, 18);
  self.frameTimeLabel.frame = CGRectMake(10, 28, width, 16);
  self.resolutionLabel.frame = CGRectMake(10, 45, width, 16);
  self.graphLabel.frame = CGRectMake(10, 64, width, 14);
  [self setNeedsDisplay];
}

- (void)reset {
  NSAssert(NSThread.isMainThread, @"Performance UI must run on the main thread");
  _sampleStart = 0;
  _sampleCount = 0;
  self.ratesLabel.text = @"FPS — · VPS — · —%";
  self.frameTimeLabel.text = [NSString stringWithFormat:@"%@: — ms",
      [self label:@"frameTime" fallback:@"Frame time"]];
  self.resolutionLabel.text = [NSString stringWithFormat:@"%@: —",
      [self label:@"resolution" fallback:@"Internal resolution"]];
  [self updateAccessibilityValue];
  [self setNeedsDisplay];
}

- (void)appendSnapshot:(NSDictionary*)snapshot {
  NSAssert(NSThread.isMainThread, @"Performance UI must run on the main thread");
  if (self.hidden || ![snapshot isKindOfClass:NSDictionary.class]) return;
  double fps, vps, speed, average, last, deviation, width, height, timestamp;
  // Reject incomplete/non-numeric samples rather than drawing synthetic zeros.
  if (!ReadMetric(snapshot, @"fps", &fps) || !ReadMetric(snapshot, @"vps", &vps) ||
      !ReadMetric(snapshot, @"speedPercent", &speed) ||
      !ReadMetric(snapshot, @"frameTimeMs", &average) ||
      !ReadMetric(snapshot, @"lastFrameTimeMs", &last) ||
      !ReadMetric(snapshot, @"frameTimeStdMs", &deviation) ||
      !ReadMetric(snapshot, @"timestampMs", &timestamp)) return;
  // Delayed responses from before reset/session changes are not a new frame.
  if (_sampleCount) {
    NSUInteger latest = (_sampleStart + _sampleCount - 1) % DOLPerformanceCapacity;
    if (timestamp <= _samples[latest].timestampMs) return;
  }
  self.ratesLabel.text = [NSString stringWithFormat:@"FPS %.1f · VPS %.1f · %.0f%%", fps, vps, speed];
  self.frameTimeLabel.text = average > 0 ?
      [NSString stringWithFormat:@"%@: %.1f ± %.1f ms",
          [self label:@"frameTime" fallback:@"Frame time"], average, deviation] :
      [NSString stringWithFormat:@"%@: — ms", [self label:@"frameTime" fallback:@"Frame time"]];
  BOOL validSize = ReadMetric(snapshot, @"renderWidth", &width) &&
      ReadMetric(snapshot, @"renderHeight", &height) && width > 0 && height > 0 &&
      width <= 65536 && height <= 65536;
  self.resolutionLabel.text = validSize ?
      [NSString stringWithFormat:@"%@: %.0f × %.0f",
          [self label:@"resolution" fallback:@"Internal resolution"], width, height] :
      [NSString stringWithFormat:@"%@: —", [self label:@"resolution" fallback:@"Internal resolution"]];

  // Zero means no completed frame yet at startup. Keep the graph empty.
  if (last > 0 && fps > 0) {
    while (_sampleCount && timestamp - _samples[_sampleStart].timestampMs > DOLPerformanceWindowMs) {
      _sampleStart = (_sampleStart + 1) % DOLPerformanceCapacity;
      --_sampleCount;
    }
    NSUInteger next = (_sampleStart + _sampleCount) % DOLPerformanceCapacity;
    _samples[next] = {timestamp, last};
    if (_sampleCount < DOLPerformanceCapacity) ++_sampleCount;
    else _sampleStart = (_sampleStart + 1) % DOLPerformanceCapacity;
  }
  [self updateAccessibilityValue];
  [self setNeedsDisplay];
}

- (void)updateAccessibilityValue {
  self.accessibilityValue = [NSString stringWithFormat:@"%@. %@. %@",
      self.ratesLabel.text, self.frameTimeLabel.text, self.resolutionLabel.text];
}

- (void)drawRect:(CGRect)rect {
  [super drawRect:rect];
  CGContextRef context = UIGraphicsGetCurrentContext();
  if (!context) return;
  CGRect graph = CGRectMake(40, 84, MAX(0, self.bounds.size.width - 50),
                            MAX(0, self.bounds.size.height - 110));
  if (graph.size.width <= 0 || graph.size.height <= 0) return;
  double maximum = 33.4;
  for (NSUInteger index = 0; index < _sampleCount; ++index)
    maximum = MAX(maximum, _samples[(_sampleStart + index) % DOLPerformanceCapacity].frameTimeMs);
  maximum = std::ceil(maximum / 10.0) * 10.0;
  NSDictionary* attributes = @{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightRegular],
      NSForegroundColorAttributeName: [UIColor colorWithWhite:0.75 alpha:1]};
  for (NSUInteger index = 0; index < 3; ++index) {
    CGFloat y = CGRectGetMinY(graph) + graph.size.height * index / 2.0;
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.16].CGColor);
    CGContextSetLineWidth(context, 0.5);
    CGContextMoveToPoint(context, graph.origin.x, y);
    CGContextAddLineToPoint(context, CGRectGetMaxX(graph), y);
    CGContextStrokePath(context);
    [[NSString stringWithFormat:@"%.0f", maximum * (1.0 - index / 2.0)]
        drawAtPoint:CGPointMake(8, y - 5) withAttributes:attributes];
  }
  [@"−60 s" drawAtPoint:CGPointMake(graph.origin.x, CGRectGetMaxY(graph) + 4) withAttributes:attributes];
  [@"0 s" drawAtPoint:CGPointMake(CGRectGetMaxX(graph) - 18, CGRectGetMaxY(graph) + 4) withAttributes:attributes];
  if (!_sampleCount) return;
  double latest = _samples[(_sampleStart + _sampleCount - 1) % DOLPerformanceCapacity].timestampMs;
  UIBezierPath* line = [UIBezierPath bezierPath];
  for (NSUInteger index = 0; index < _sampleCount; ++index) {
    const auto& sample = _samples[(_sampleStart + index) % DOLPerformanceCapacity];
    CGFloat x = CGRectGetMaxX(graph) - graph.size.width * (latest - sample.timestampMs) / DOLPerformanceWindowMs;
    CGFloat y = CGRectGetMaxY(graph) - graph.size.height * sample.frameTimeMs / maximum;
    if (index == 0) [line moveToPoint:CGPointMake(x, y)];
    else [line addLineToPoint:CGPointMake(x, y)];
  }
  [[UIColor colorWithRed:0.25 green:0.9 blue:0.85 alpha:1] setStroke];
  line.lineWidth = 1.5;
  [line stroke];
}
@end
