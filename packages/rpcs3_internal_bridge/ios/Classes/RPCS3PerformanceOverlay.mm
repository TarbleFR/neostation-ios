// SPDX-License-Identifier: GPL-3.0-or-later
#import "RPCS3PerformanceOverlay.h"
#import "RPCS3InGameLocalization.h"
#include "NeoSwapUsagePolicy.h"
#include <algorithm>
#include <array>
#include <cmath>

namespace {
constexpr NSUInteger kCapacity = 120;
constexpr double kWindowMs = 60000.0;
struct Sample {
  double timestampMs = 0;
  NeoSwapMemoryGraphPoint memory;
};
}

@interface RPCS3PerformanceOverlay () {
  std::array<Sample, kCapacity> _samples;
  NSUInteger _sampleStart;
  NSUInteger _sampleCount;
}
@property(nonatomic, strong) UILabel* ratesLabel;
// Two series since 7 October 2026 (maintainer request): the RAM the device
// spends on the session (RPCS3 resident merged with the NeoSwap microprocess
// backing) and the NeoSwap contribution. Microprocesses are not drawn apart.
@property(nonatomic, strong) UILabel* deviceLabel;
@property(nonatomic, strong) UILabel* neoswapLabel;
@property(nonatomic, strong) UILabel* graphLabel;
@property(nonatomic, strong) NSNumberFormatter* numberFormatter;
@property(nonatomic, copy) NSString* localeIdentifier;
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
  self.accessibilityIdentifier = @"rpcs3.performance.overlay";
  self.ratesLabel = [self newLabelWithSize:15];
  self.deviceLabel = [self newLabelWithSize:12];
  self.deviceLabel.textColor = UIColor.systemOrangeColor;
  self.neoswapLabel = [self newLabelWithSize:12];
  self.neoswapLabel.textColor = UIColor.systemGreenColor;
  self.graphLabel = [self newLabelWithSize:10];
  self.numberFormatter = [NSNumberFormatter new];
  self.numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
  self.numberFormatter.usesGroupingSeparator = NO;
  self.numberFormatter.minimumFractionDigits = 2;
  self.numberFormatter.maximumFractionDigits = 2;
  [self setLocaleIdentifier:NSLocale.preferredLanguages.firstObject ?: @"en"];
  return self;
}
- (void)setLocaleIdentifier:(NSString*)localeIdentifier {
  _localeIdentifier = RPCS3CanonicalLocale(localeIdentifier);
  self.numberFormatter.locale = [NSLocale localeWithLocaleIdentifier:_localeIdentifier];
  self.accessibilityLabel = RPCS3LocalizedString(@"performance", _localeIdentifier);
  self.graphLabel.text = [NSString stringWithFormat:@"%@ · 60 s",
      RPCS3LocalizedString(@"memoryUnitGB", _localeIdentifier)];
  if (self.deviceLabel) [self reset];
}
- (UILabel*)newLabelWithSize:(CGFloat)size {
  UILabel* label = [UILabel new];
  label.font = [UIFont monospacedDigitSystemFontOfSize:size weight:UIFontWeightRegular];
  label.textColor = UIColor.whiteColor;
  label.adjustsFontSizeToFitWidth = YES;
  label.minimumScaleFactor = 0.72;
  label.isAccessibilityElement = NO;
  [self addSubview:label];
  return label;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(320, 274); }
- (void)layoutSubviews {
  [super layoutSubviews];
  const CGFloat width = MAX(0.0, self.bounds.size.width - 20.0);
  self.ratesLabel.frame = CGRectMake(10, 7, width, 21);
  self.deviceLabel.frame = CGRectMake(10, 32, width, 22);
  self.neoswapLabel.frame = CGRectMake(10, 56, width, 22);
  self.graphLabel.frame = CGRectMake(10, 81, width, 14);
  [self setNeedsDisplay];
}
- (NSString*)memoryText:(uint64_t)bytes valid:(BOOL)valid {
  NSString* value = valid ? [self.numberFormatter stringFromNumber:@(NeoSwapDecimalGB(bytes))] : @"—";
  return [NSString stringWithFormat:@"%@ %@", value,
      RPCS3LocalizedString(@"memoryUnitGB", _localeIdentifier)];
}
- (void)showPoint:(NeoSwapMemoryGraphPoint)point {
  // RPCS3 resident pages merged with the NeoSwap backing charged to its
  // microprocesses: the RAM the device spends on this session.
  self.deviceLabel.text = [NSString stringWithFormat:@"%@: %@",
      RPCS3LocalizedString(@"memoryDevice", _localeIdentifier),
      [self memoryText:point.deviceRam valid:point.deviceRamValid]];
  // Host data served outside the footprint by NeoSwap (relay host loans and
  // donor loans); guest pages are part of the device line above.
  self.neoswapLabel.text = [NSString stringWithFormat:@"%@: %@",
      RPCS3LocalizedString(@"memoryNeoSwap", _localeIdentifier),
      [self memoryText:point.hostLoans valid:point.hostLoansValid]];
  self.accessibilityValue = [NSString stringWithFormat:@"%@. %@. %@",
      self.ratesLabel.text, self.deviceLabel.text, self.neoswapLabel.text];
}
- (void)reset {
  NSAssert(NSThread.isMainThread, @"RPCS3 performance UI must run on the main thread");
  _sampleStart = 0;
  _sampleCount = 0;
  self.ratesLabel.text = @"FPS —";
  [self showPoint:NeoSwapMemoryGraphPoint{}];
  [self setNeedsDisplay];
}
- (void)appendMetricsWithFPS:(double)fps cpu:(double)cpu gpu:(double)gpu
                  memoryUsed:(uint64_t)memoryUsed memoryTotal:(uint64_t)memoryTotal
                 validFields:(uint32_t)validFields timestamp:(double)timestampMs {
  NSAssert(NSThread.isMainThread, @"RPCS3 performance UI must run on the main thread");
  (void)cpu; (void)gpu; (void)memoryUsed; (void)memoryTotal;
  if (self.hidden || !std::isfinite(timestampMs)) return;
  if (_sampleCount && timestampMs < _samples[(_sampleStart + _sampleCount - 1) % kCapacity].timestampMs)
    [self reset];
  self.ratesLabel.text = NeoSwapFPSValid(fps, validFields)
      ? [NSString localizedStringWithFormat:@"FPS %.1f", fps] : @"FPS —";
  self.accessibilityValue = [NSString stringWithFormat:@"%@. %@. %@",
      self.ratesLabel.text, self.deviceLabel.text, self.neoswapLabel.text];
  while (_sampleCount && timestampMs - _samples[_sampleStart].timestampMs > kWindowMs) {
    _sampleStart = (_sampleStart + 1) % kCapacity;
    --_sampleCount;
  }
  const NSUInteger next = (_sampleStart + _sampleCount) % kCapacity;
  _samples[next] = {timestampMs, {}};
  if (_sampleCount < kCapacity) ++_sampleCount;
  else _sampleStart = (_sampleStart + 1) % kCapacity;
  [self setNeedsDisplay];
}
- (void)appendNeoSwapWithClient:(const NeoSwapClientStats*)client
                          host:(const NeoSwapHostStats*)host
                relayLiveBytes:(uint64_t)relayLiveBytes
                 relayMeasured:(BOOL)relayMeasured
         processFootprintBytes:(uint64_t)processFootprintBytes
                     timestamp:(double)timestampMs {
  NSAssert(NSThread.isMainThread, @"RPCS3 performance UI must run on the main thread");
  if (self.hidden || !std::isfinite(timestampMs)) return;
  (void)client;
  const auto point = NeoSwapMemoryGraph(host, relayLiveBytes, relayMeasured, processFootprintBytes);
  [self showPoint:point];
  if (_sampleCount) {
    Sample& sample = _samples[(_sampleStart + _sampleCount - 1) % kCapacity];
    if (std::fabs(sample.timestampMs - timestampMs) < 1000.0) sample.memory = point;
  }
  [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
  [super drawRect:rect];
  CGContextRef context = UIGraphicsGetCurrentContext();
  if (!context) return;
  const CGRect graph = CGRectMake(44, 110, MAX(0.0, self.bounds.size.width - 54),
      MAX(0.0, self.bounds.size.height - 134));
  if (graph.size.width <= 0 || graph.size.height <= 0) return;
  double maximumGB = 0.5;
  for (NSUInteger n = 0; n < _sampleCount; ++n) {
    const auto& point = _samples[(_sampleStart + n) % kCapacity].memory;
    if (point.deviceRamValid) maximumGB = std::max(maximumGB, NeoSwapDecimalGB(point.deviceRam));
    if (point.hostLoansValid) maximumGB = std::max(maximumGB, NeoSwapDecimalGB(point.hostLoans));
  }
  maximumGB = std::ceil(maximumGB * 2.0) / 2.0;
  NSDictionary* attrs = @{NSFontAttributeName:[UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightRegular],
      NSForegroundColorAttributeName:[UIColor colorWithWhite:0.75 alpha:1.0]};
  for (NSUInteger row = 0; row < 3; ++row) {
    const CGFloat y = graph.origin.y + graph.size.height * row / 2.0;
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.16].CGColor);
    CGContextSetLineWidth(context, 0.5);
    CGContextMoveToPoint(context, graph.origin.x, y);
    CGContextAddLineToPoint(context, CGRectGetMaxX(graph), y);
    CGContextStrokePath(context);
  }
  [[self.numberFormatter stringFromNumber:@(maximumGB)] drawAtPoint:CGPointMake(4, graph.origin.y - 5) withAttributes:attrs];
  [@"0" drawAtPoint:CGPointMake(28, CGRectGetMaxY(graph) - 5) withAttributes:attrs];
  [@"−60 s" drawAtPoint:CGPointMake(graph.origin.x, CGRectGetMaxY(graph) + 4) withAttributes:attrs];
  [@"0 s" drawAtPoint:CGPointMake(CGRectGetMaxX(graph) - 18, CGRectGetMaxY(graph) + 4) withAttributes:attrs];
  if (!_sampleCount) return;
  const double latest = _samples[(_sampleStart + _sampleCount - 1) % kCapacity].timestampMs;
  UIBezierPath* deviceLine = [UIBezierPath bezierPath];
  UIBezierPath* neoswapLine = [UIBezierPath bezierPath];
  bool deviceStarted = false, neoswapStarted = false;
  for (NSUInteger n = 0; n < _sampleCount; ++n) {
    const auto& sample = _samples[(_sampleStart + n) % kCapacity];
    const CGFloat x = CGRectGetMaxX(graph) - graph.size.width * (latest - sample.timestampMs) / kWindowMs;
    auto append = [&](UIBezierPath* line, uint64_t bytes, bool valid, bool& started) {
      if (!valid) { started = false; return; }
      const CGFloat y = CGRectGetMaxY(graph) - graph.size.height * NeoSwapDecimalGB(bytes) / maximumGB;
      if (!started) [line moveToPoint:CGPointMake(x, y)];
      else [line addLineToPoint:CGPointMake(x, y)];
      started = true;
    };
    append(deviceLine, sample.memory.deviceRam, sample.memory.deviceRamValid, deviceStarted);
    append(neoswapLine, sample.memory.hostLoans, sample.memory.hostLoansValid, neoswapStarted);
  }
  [UIColor.systemOrangeColor setStroke];
  deviceLine.lineWidth = 1.5;
  [deviceLine stroke];
  [UIColor.systemGreenColor setStroke];
  neoswapLine.lineWidth = 1.5;
  [neoswapLine stroke];
}
@end
