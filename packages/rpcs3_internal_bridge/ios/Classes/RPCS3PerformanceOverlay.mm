// SPDX-License-Identifier: GPL-3.0-or-later
#import "RPCS3PerformanceOverlay.h"
#import "RPCS3InGameLocalization.h"

#include <array>
#include <cmath>

namespace {
constexpr NSUInteger kCapacity = 120;
constexpr double kWindowMs = 60000.0;
constexpr uint32_t kFPSValid = 1u << 0;
constexpr uint64_t kGiB = 1024ULL * 1024 * 1024;

struct Sample {
  double timestampMs = 0;
  double fps = 0;
  uint64_t neoSwapBytes = 0;
  uint64_t iphoneBytes = 0;
  bool fpsValid = false;
  bool neoSwapValid = false;
  bool iphoneValid = false;
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
  uint64_t _donationTargetBytes;
}
@property(nonatomic, strong) UILabel* ratesLabel;
@property(nonatomic, strong) UILabel* memoryLabel;
@property(nonatomic, strong) UILabel* graphLabel;
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
  self.ratesLabel = [self newLabelWithSize:14 weight:UIFontWeightSemibold];
  self.memoryLabel = [self newLabelWithSize:11 weight:UIFontWeightRegular];
  self.graphLabel = [self newLabelWithSize:10 weight:UIFontWeightRegular];
  self.graphLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
  [self setLocaleIdentifier:NSLocale.preferredLanguages.firstObject ?: @"en"];
  [self reset];
  return self;
}
- (void)setLocaleIdentifier:(NSString*)localeIdentifier {
  _localeIdentifier = RPCS3CanonicalLocale(localeIdentifier);
  self.accessibilityLabel = RPCS3LocalizedString(@"performance", _localeIdentifier);
  self.graphLabel.text = @"FPS · NeoSwap · iPhone RAM · 60 s";
  if (self.ratesLabel) [self reset];
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
- (CGSize)intrinsicContentSize { return CGSizeMake(320, 250); }
- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat width = MAX(0.0, self.bounds.size.width - 20.0);
  self.ratesLabel.frame = CGRectMake(10, 8, width, 19);
  self.memoryLabel.frame = CGRectMake(10, 30, width, 17);
  self.graphLabel.frame = CGRectMake(10, 51, width, 14);
  [self setNeedsDisplay];
}
- (void)reset {
  NSAssert(NSThread.isMainThread, @"RPCS3 performance UI must run on the main thread");
  _sampleStart = 0; _sampleCount = 0; _donationTargetBytes = kGiB / 2;
  self.ratesLabel.text = @"FPS —";
  self.memoryLabel.text = @"NeoSwap — / 512 MiB · iPhone RAM —";
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
  (void)cpu; (void)gpu; (void)memoryUsed; (void)memoryTotal;
  const bool fpsValid = (validFields & kFPSValid) && std::isfinite(fps) && fps >= 0;
  self.ratesLabel.text = fpsValid ? [NSString stringWithFormat:@"FPS %.1f", fps] : @"FPS —";
  while (_sampleCount && timestampMs - _samples[_sampleStart].timestampMs > kWindowMs) {
    _sampleStart = (_sampleStart + 1) % kCapacity; --_sampleCount;
  }
  NSUInteger next = (_sampleStart + _sampleCount) % kCapacity;
  _samples[next] = {timestampMs, fps, 0, 0, fpsValid, false, false};
  if (_sampleCount < kCapacity) ++_sampleCount; else _sampleStart = (_sampleStart + 1) % kCapacity;
  self.accessibilityValue = [NSString stringWithFormat:@"%@. %@", self.ratesLabel.text, self.memoryLabel.text];
  [self setNeedsDisplay];
}
- (void)appendNeoSwapWithClient:(const NeoSwapClientStats*)client
                          host:(const NeoSwapHostStats*)host
         processFootprintBytes:(uint64_t)processFootprintBytes
                     timestamp:(double)timestampMs {
  NSAssert(NSThread.isMainThread, @"RPCS3 performance UI must run on the main thread");
  if (self.hidden) return;
  (void)client;
  const bool donorMeasured = host && host->donation_state == 2 && host->donor_count && host->donor_prepared_bytes;
  // First number is memory actively borrowed by RPCS3. The second is the
  // currently prepared verified pool, not the 5 GiB hard ceiling.
  const uint64_t donatedBytes = donorMeasured ? host->owner_donated_live_bytes[NEOSWAP_RPCS3] : 0;
  _donationTargetBytes = donorMeasured ? MAX(host->donor_prepared_bytes, kGiB / 2) : kGiB / 2;
  self.memoryLabel.text = [NSString stringWithFormat:@"NeoSwap %@ / %@ · iPhone RAM %@",
      donorMeasured ? MemoryText(donatedBytes) : @"—", MemoryText(_donationTargetBytes),
      processFootprintBytes ? MemoryText(processFootprintBytes) : @"—"];
  if (_sampleCount) {
    const NSUInteger index = (_sampleStart + _sampleCount - 1) % kCapacity;
    Sample& sample = _samples[index];
    if (std::fabs(sample.timestampMs - timestampMs) < 1000.0) {
      sample.neoSwapBytes = donatedBytes; sample.iphoneBytes = processFootprintBytes;
      sample.neoSwapValid = donorMeasured; sample.iphoneValid = processFootprintBytes != 0;
    }
  }
  self.accessibilityValue = [NSString stringWithFormat:@"%@. %@", self.ratesLabel.text, self.memoryLabel.text];
  [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
  [super drawRect:rect];
  CGContextRef context = UIGraphicsGetCurrentContext();
  if (!context) return;
  const CGFloat left = 44.0, right = 10.0;
  const CGFloat graphWidth = MAX(0.0, self.bounds.size.width - left - right);
  CGRect fpsGraph = CGRectMake(left, 78, graphWidth, 62);
  CGRect memoryGraph = CGRectMake(left, 166, graphWidth, 62);
  if (graphWidth <= 0) return;
  NSDictionary* attrs = @{NSFontAttributeName:[UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightRegular],
                           NSForegroundColorAttributeName:[UIColor colorWithWhite:0.75 alpha:1.0]};
  void (^drawGrid)(CGRect) = ^(CGRect graph) {
    for (NSUInteger row = 0; row < 3; ++row) {
      const CGFloat y = CGRectGetMinY(graph) + graph.size.height * row / 2.0;
      CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.16].CGColor);
      CGContextSetLineWidth(context, 0.5);
      CGContextMoveToPoint(context, graph.origin.x, y);
      CGContextAddLineToPoint(context, CGRectGetMaxX(graph), y);
      CGContextStrokePath(context);
    }
  };
  drawGrid(fpsGraph); drawGrid(memoryGraph);
  double fpsMaximum = 60.0;
  uint64_t memoryMaximum = MAX(_donationTargetBytes, kGiB);
  for (NSUInteger n = 0; n < _sampleCount; ++n) {
    const auto& sample = _samples[(_sampleStart + n) % kCapacity];
    if (sample.fpsValid) fpsMaximum = MAX(fpsMaximum, sample.fps);
    if (sample.iphoneValid) memoryMaximum = MAX(memoryMaximum, sample.iphoneBytes);
  }
  fpsMaximum = std::ceil(fpsMaximum / 30.0) * 30.0;
  const double memoryMaximumGiB = std::ceil((double)memoryMaximum / kGiB * 2.0) / 2.0;
  memoryMaximum = (uint64_t)(memoryMaximumGiB * kGiB);
  [[NSString stringWithFormat:@"%.0f", fpsMaximum] drawAtPoint:CGPointMake(8, CGRectGetMinY(fpsGraph)-5) withAttributes:attrs];
  [@"0" drawAtPoint:CGPointMake(28, CGRectGetMaxY(fpsGraph)-5) withAttributes:attrs];
  [[NSString stringWithFormat:@"%.1f", (double)memoryMaximum/kGiB] drawAtPoint:CGPointMake(8, CGRectGetMinY(memoryGraph)-5) withAttributes:attrs];
  [@"0" drawAtPoint:CGPointMake(28, CGRectGetMaxY(memoryGraph)-5) withAttributes:attrs];
  if (!_sampleCount) return;
  const double latest = _samples[(_sampleStart + _sampleCount - 1) % kCapacity].timestampMs;
  UIBezierPath* fpsLine=[UIBezierPath bezierPath]; UIBezierPath* swapLine=[UIBezierPath bezierPath]; UIBezierPath* iphoneLine=[UIBezierPath bezierPath];
  bool fpsStarted=false, swapStarted=false, iphoneStarted=false;
  for (NSUInteger n=0;n<_sampleCount;++n) {
    const auto& sample=_samples[(_sampleStart+n)%kCapacity];
    const CGFloat x=CGRectGetMaxX(fpsGraph)-graphWidth*(latest-sample.timestampMs)/kWindowMs;
    if(sample.fpsValid){const CGFloat y=CGRectGetMaxY(fpsGraph)-fpsGraph.size.height*sample.fps/fpsMaximum;if(!fpsStarted){[fpsLine moveToPoint:CGPointMake(x,y)];fpsStarted=true;}else[fpsLine addLineToPoint:CGPointMake(x,y)];}
    if(sample.neoSwapValid){const CGFloat y=CGRectGetMaxY(memoryGraph)-memoryGraph.size.height*std::min((double)sample.neoSwapBytes/memoryMaximum,1.0);if(!swapStarted){[swapLine moveToPoint:CGPointMake(x,y)];swapStarted=true;}else[swapLine addLineToPoint:CGPointMake(x,y)];}
    if(sample.iphoneValid){const CGFloat y=CGRectGetMaxY(memoryGraph)-memoryGraph.size.height*std::min((double)sample.iphoneBytes/memoryMaximum,1.0);if(!iphoneStarted){[iphoneLine moveToPoint:CGPointMake(x,y)];iphoneStarted=true;}else[iphoneLine addLineToPoint:CGPointMake(x,y)];}
  }
  [UIColor.systemGreenColor setStroke]; fpsLine.lineWidth=1.5; [fpsLine stroke];
  [UIColor.systemCyanColor setStroke]; swapLine.lineWidth=1.5; [swapLine stroke];
  [UIColor.systemOrangeColor setStroke]; iphoneLine.lineWidth=1.5; [iphoneLine stroke];
  [@"−60 s" drawAtPoint:CGPointMake(memoryGraph.origin.x,CGRectGetMaxY(memoryGraph)+4) withAttributes:attrs];
  [@"0 s" drawAtPoint:CGPointMake(CGRectGetMaxX(memoryGraph)-18,CGRectGetMaxY(memoryGraph)+4) withAttributes:attrs];
}
@end
