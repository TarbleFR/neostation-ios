// Actual Foundation/CFRunLoop regression. A source-string check cannot detect
// a playable SDL loop that starves GCD launch acknowledgements and UIKit alerts.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include "../native/kartpad/core/SessionRunLoop.h"
#include <cstdio>
#include <cstdlib>

static void Require(bool value, const char* message) {
  if (!value) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
static void Pump(double seconds) {
  const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
  while (CFAbsoluteTimeGetCurrent() < deadline)
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
}
int main() {
  @autoreleasepool {
    __block bool oldEntered = false, oldDelivered = false, oldReturned = false;
    dispatch_async(dispatch_get_main_queue(), ^{
      oldEntered = true;
      dispatch_async(dispatch_get_main_queue(), ^{ oldDelivered = true; });
      Pump(0.08); // SDL's nested run-loop while RuntimeMain has not returned.
      Require(!oldDelivered, "negative control: main queue unexpectedly re-entered itself");
      oldReturned = true;
    });
    Pump(0.20);
    Require(oldEntered && oldReturned && oldDelivered,
            "negative control did not release delayed completion on runtime return");

    __block bool timerEntered = false, deliveredInside = false;
    NeoKartPadScheduleRunLoop(0.001, ^{
      timerEntered = true;
      dispatch_async(dispatch_get_main_queue(), ^{ deliveredInside = true; });
      Pump(0.08);
      Require(deliveredInside, "run-loop entry still starves queued UI/launch work");
    });
    Pump(0.20);
    Require(timerEntered && deliveredInside, "fresh runtime entry never executed");
    __block bool ioCompletionDelivered = false;
    NeoKartPadScheduleRunLoop(0.001, ^{
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NeoKartPadPerformRunLoop(^{
          Require(NSThread.isMainThread, "I/O completion ran off UIKit thread");
          ioCompletionDelivered = true;
        });
      });
      Pump(0.10);
      Require(ioCompletionDelivered, "I/O completion was starved by nested runtime loop");
    });
    Pump(0.20);
    __block bool staleEntered = false;
    NSTimer* cancelled = NeoKartPadScheduleRunLoop(0.01, ^{ staleEntered = true; });
    [cancelled invalidate];
    Pump(0.05);
    Require(!staleEntered, "cancelled session entry executed after shutdown");
    std::puts("PASS: real GCD starvation reproduced; NSTimer runtime entry services nested main-queue callbacks");
  }
}
