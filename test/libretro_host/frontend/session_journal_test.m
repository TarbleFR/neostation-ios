// Behavioural test of LibretroSessionJournal, the per-session log kept in
// Documents/Libretro/Logs: notes written at once, the END line, rotation
// to previous-session.log, a session that ended without END (process
// killed during a teardown step) kept as unfinished-session.log with its
// last step, one line per note, notes ignored after END, and concurrent
// writers never interleaving within a line.
#import <Foundation/Foundation.h>

#import "LibretroSessionJournal.h"

#include <stdio.h>

static int failures = 0;

static void Report(BOOL passed, NSString *message, int line) {
  if (passed) {
    printf("PASS %s\n", message.UTF8String);
  } else {
    printf("FAIL %s (%s:%d)\n", message.UTF8String, __FILE__, line);
    failures++;
  }
}

#define CHECK(condition, ...) Report((condition) ? YES : NO, [NSString stringWithFormat:__VA_ARGS__], __LINE__)

static NSString *Read(NSString *path) {
  return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

static NSArray<NSString *> *Lines(NSString *text) {
  NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
  if ([lines.lastObject isEqualToString:@""]) [lines removeLastObject];
  return lines;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString *base = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();
    NSString *directory = [base stringByAppendingPathComponent:@"Logs"];
    NSString *current = [directory stringByAppendingPathComponent:@"session.log"];
    NSString *previous = [directory stringByAppendingPathComponent:@"previous-session.log"];
    NSString *unfinished = [directory stringByAppendingPathComponent:@"unfinished-session.log"];

    CHECK([LibretroSessionJournal journalInDirectory:@""] == nil, @"no directory, no journal");

    // First session: created with its directory, finished normally.
    LibretroSessionJournal *first = [LibretroSessionJournal journalInDirectory:directory];
    CHECK(first != nil && [first.path isEqualToString:current], @"the journal starts session.log in a new directory");
    CHECK(!first.previousSessionUnfinished, @"no previous session");
    [first note:@"launch: one"];
    CHECK([Read(current) containsString:@"launch: one"], @"a note is on disk at once, before the session ends");
    [first note:@"two\nlines"];
    [first noteLines:@[ @"[INFO] alpha", @"[ERROR] beta" ] title:@"core log"];
    [first finishWithOutcome:@"closed"];
    [first note:@"after the end"];
    NSString *text = Read(current);
    NSArray<NSString *> *lines = Lines(text);
    CHECK([lines.firstObject hasPrefix:@"NeoStation libretro session journal 1"], @"header line");
    CHECK([text containsString:@" two | lines\n"], @"a multi-line note stays on one line");
    CHECK([text containsString:@"---- core log (2 lines) ----\n  [INFO] alpha\n  [ERROR] beta\n---- end of core log ----\n"],
          @"a titled block of lines");
    CHECK([lines.lastObject isEqualToString:@"END closed"], @"the END line closes the journal");
    CHECK(![text containsString:@"after the end"], @"notes after END are ignored");
    NSRegularExpression *timestamped =
        [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z \\+\\d+\\.\\d{3}s "
                                                  options:0
                                                    error:nil];
    NSString *noteLine = lines.count > 1 ? lines[1] : @"";
    CHECK([timestamped numberOfMatchesInString:noteLine options:0 range:NSMakeRange(0, noteLine.length)] == 1,
          @"notes carry the UTC time and the seconds since the start: %@", noteLine);

    // Second session: the first becomes previous-session.log.
    LibretroSessionJournal *second = [LibretroSessionJournal journalInDirectory:directory];
    CHECK(!second.previousSessionUnfinished, @"a finished session is not reported unfinished");
    CHECK([Read(previous) containsString:@"launch: one"], @"the finished session is kept as previous-session.log");
    [second note:@"teardown: retro_unload_game called"];
    second = nil;  // The process ends here: no END line.

    // Third session: the second is kept as unfinished-session.log.
    LibretroSessionJournal *third = [LibretroSessionJournal journalInDirectory:directory];
    CHECK(third.previousSessionUnfinished, @"a session without END is reported unfinished");
    NSArray<NSString *> *kept = Lines(Read(unfinished));
    CHECK([kept.lastObject hasSuffix:@"teardown: retro_unload_game called"],
          @"the unfinished journal ends with the step that never returned");
    CHECK([Read(current) containsString:@"kept as unfinished-session.log"], @"the new journal says so");
    [third finishWithOutcome:@"closed"];

    // Fourth session: a finished third keeps the unfinished file as it was.
    LibretroSessionJournal *fourth = [LibretroSessionJournal journalInDirectory:directory];
    CHECK(!fourth.previousSessionUnfinished, @"the previous session finished");
    CHECK([Lines(Read(unfinished)).lastObject hasSuffix:@"teardown: retro_unload_game called"],
          @"unfinished-session.log stays until another session is unfinished");

    // Two threads writing at once: every line is whole.
    dispatch_group_t group = dispatch_group_create();
    for (int writer = 0; writer < 2; writer++) {
      dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int index = 0; index < 200; index++) [fourth note:[NSString stringWithFormat:@"writer %d note %d", writer, index]];
      });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [fourth finishWithOutcome:@"closed"];
    NSUInteger whole = 0;
    BOOL wellFormed = YES;
    for (NSString *line in Lines(Read(current))) {
      if (![line containsString:@" writer "]) continue;
      whole++;
      if ([timestamped numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)] != 1) wellFormed = NO;
    }
    CHECK(whole == 400 && wellFormed, @"400 concurrent notes, each on its own well-formed line (%lu)", (unsigned long)whole);
  }
  printf("%s: %d failure(s)\n", failures == 0 ? "session_journal_test passed" : "session_journal_test FAILED", failures);
  return failures == 0 ? 0 : 1;
}
