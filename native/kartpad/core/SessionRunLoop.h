#pragma once
#import <Foundation/Foundation.h>

// RuntimeMain pumps a nested UIKit run loop. Entering it from a GCD main-queue
// block prevents that queue from servicing launch replies and menu callbacks.
// Both the production entry and the Apple regression use this exact scheduler.
static inline NSTimer* NeoKartPadScheduleRunLoop(
    NSTimeInterval delay, void (^work)(void)) {
  NSTimer* timer = [NSTimer timerWithTimeInterval:delay repeats:NO
      block:^(__unused NSTimer* fired) { work(); }];
  [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  return timer;
}
