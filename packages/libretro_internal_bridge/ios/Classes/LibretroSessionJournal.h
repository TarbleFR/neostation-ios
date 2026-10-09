#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plain-text journal of one embedded libretro session, written line by
/// line with write(2) as the session goes: launch, startup confirmation,
/// stop request and every teardown step (context_destroy,
/// retro_unload_game, retro_deinit, renderer release, dlclose, dismissal),
/// then the core's log and an END line. A process that ends during a
/// session (crash, iOS termination) leaves a journal without END: the
/// kernel keeps what was written, and the next session keeps that file as
/// `unfinished-session.log`, its last line naming the step that never
/// returned.
///
/// Files, in Files › NeoStation › Libretro › Logs: `session.log` (current
/// or last session), `previous-session.log`, `unfinished-session.log`.
/// Thread-safe.
@interface LibretroSessionJournal : NSObject

/// Starts `session.log` in `directory` (created when missing), after
/// rotating the previous file. nil when the file cannot be created.
+ (nullable instancetype)journalInDirectory:(NSString *)directory;

/// The session before this one never wrote its END line.
@property(nonatomic, readonly) BOOL previousSessionUnfinished;
@property(nonatomic, copy, readonly) NSString *path;

/// One timestamped line (UTC time and seconds since the session started).
- (void)note:(NSString *)line;

/// A titled block of lines (the core's log), indented.
- (void)noteLines:(NSArray<NSString *> *)lines title:(NSString *)title;

/// Writes "END <outcome>" and closes the file; later notes are ignored.
- (void)finishWithOutcome:(NSString *)outcome;

@end

NS_ASSUME_NONNULL_END
