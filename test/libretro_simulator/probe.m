// Simulator probe of the embedded libretro session.
//
// Runs NeoStation's real LibretroSession (presentation, emulation thread,
// Metal presenter, OpenGL ES and Vulkan renderers, teardown) in the iOS
// Simulator with real cores: PPSSPP and Azahar from the pinned buildbot
// artifact, and the NeoTest core of test/libretro_host. Each scenario of
// probe-config.json (in the app bundle) launches a game the way the plugin
// does, lets it run, closes it like "Quit game" and records the launch
// result, the timings, the session journal and the core log.
//
// Results: Documents/probe.json once every scenario ran. Progress:
// Documents/probe-progress.log, written line by line as it happens, so a
// process that dies leaves the step it died in (with the session journal
// in Documents/Libretro/Logs).
#import <UIKit/UIKit.h>

#import "LibretroSession.h"

#include <fcntl.h>
#include <unistd.h>

static NSString *DocumentsPath(NSString *component) {
  NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return component.length > 0 ? [documents stringByAppendingPathComponent:component] : documents;
}

static void Progress(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Progress(NSString *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  NSString *stamped = [NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), line];
  NSData *data = [stamped dataUsingEncoding:NSUTF8StringEncoding];
  int descriptor = open(DocumentsPath(@"probe-progress.log").fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
  if (descriptor >= 0) {
    write(descriptor, data.bytes, data.length);
    close(descriptor);
  }
  NSLog(@"[probe] %@", line);
}

static NSArray<NSString *> *Tail(NSArray *lines, NSUInteger count) {
  if (![lines isKindOfClass:NSArray.class]) return @[];
  if (lines.count <= count) return lines;
  return [lines subarrayWithRange:NSMakeRange(lines.count - count, count)];
}

static NSString *ReadText(NSString *path) {
  return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeAppDelegate {
  NSDictionary *_config;
  NSArray<NSDictionary *> *_scenarios;
  NSMutableArray<NSDictionary *> *_results;
  NSUInteger _index;
  LibretroSession *_session;
  NSUInteger _generation;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  UIViewController *root = [UIViewController new];
  root.view.backgroundColor = UIColor.blackColor;
  self.window.rootViewController = root;
  [self.window makeKeyAndVisible];
  [NSFileManager.defaultManager removeItemAtPath:DocumentsPath(@"probe-progress.log") error:nil];
  [NSFileManager.defaultManager removeItemAtPath:DocumentsPath(@"probe.json") error:nil];
  NSString *configPath = [NSBundle.mainBundle pathForResource:@"probe-config" ofType:@"json"];
  NSData *configData = configPath != nil ? [NSData dataWithContentsOfFile:configPath] : nil;
  id config = configData != nil ? [NSJSONSerialization JSONObjectWithData:configData options:0 error:nil] : nil;
  _config = [config isKindOfClass:NSDictionary.class] ? config : @{};
  _scenarios = [_config[@"scenarios"] isKindOfClass:NSArray.class] ? _config[@"scenarios"] : @[];
  _results = [NSMutableArray array];
  [self prepareDirectories];
  Progress(@"probe started: %lu scenarios, source %@", (unsigned long)_scenarios.count, _config[@"source"] ?: @"?");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self runNext];
  });
  return YES;
}

/// The plugin's layout: Documents/Libretro/{System,Saves,States,Config,...},
/// with the bundled system files (PPSSPP's assets) copied into System.
- (void)prepareDirectories {
  NSFileManager *files = NSFileManager.defaultManager;
  for (NSString *name in @[ @"System", @"Saves", @"States", @"Config", @"Config/Frontend", @"Cheats", @"Skins", @"Logs" ]) {
    [files createDirectoryAtPath:[DocumentsPath(@"Libretro") stringByAppendingPathComponent:name]
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }
  NSString *bundled = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LibretroSystem"];
  NSString *system = DocumentsPath(@"Libretro/System");
  for (NSString *entry in [files contentsOfDirectoryAtPath:bundled error:nil]) {
    NSString *target = [system stringByAppendingPathComponent:entry];
    if (![files fileExistsAtPath:target]) {
      [files copyItemAtPath:[bundled stringByAppendingPathComponent:entry] toPath:target error:nil];
    }
  }
}

- (LibretroSessionConfiguration *)configurationForScenario:(NSDictionary *)scenario {
  NSString *core = scenario[@"core"];
  NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
  NSString *name = [core stringByAppendingString:@"_libretro"];
  LibretroSessionConfiguration *configuration = [LibretroSessionConfiguration new];
  configuration.corePath = [frameworks stringByAppendingPathComponent:
                                           [NSString stringWithFormat:@"%@.framework/%@", name, name]];
  configuration.contentPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:scenario[@"content"]];
  configuration.gameTitle = scenario[@"name"];
  configuration.console = scenario[@"console"];
  configuration.consoleName = scenario[@"consoleName"] ?: @"";
  configuration.gameKey = [@"probe/" stringByAppendingString:[scenario[@"content"] lastPathComponent]];
  configuration.systemDirectory = DocumentsPath(@"Libretro/System");
  configuration.saveDirectory = DocumentsPath(@"Libretro/Saves");
  configuration.stateDirectory = DocumentsPath(@"Libretro/States");
  configuration.optionsDirectory = DocumentsPath(@"Libretro/Config");
  configuration.cheatsDirectory = DocumentsPath(@"Libretro/Cheats");
  NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  configuration.cacheDirectory = [caches stringByAppendingPathComponent:@"Libretro"];
  configuration.skinsDirectory = DocumentsPath(@"Libretro/Skins");
  configuration.frontendDirectory = DocumentsPath(@"Libretro/Config/Frontend");
  configuration.consoleGeometry = _config[@"consoleGeometry"] ?: @{};
  configuration.uiLocale = @"en";
  configuration.retroLanguage = 0;
  // Labels fall back to their keys: the probe checks behaviour, not text.
  configuration.uiText = @{};
  configuration.optionDefaults = scenario[@"optionDefaults"] ?: @{};
  configuration.noJitOverrides = scenario[@"noJitOverrides"] ?: @{};
  configuration.lockedOptions = scenario[@"lockedOptions"] ?: @{};
  configuration.coreSettings = @[];
  configuration.achievementsAllowed = NO;
  configuration.preferredHardwareContext = [scenario[@"preferredHardwareContext"] unsignedIntValue];
  // Present since the session journal; absent from older sources.
  SEL logs = NSSelectorFromString(@"setLogsDirectory:");
  if ([configuration respondsToSelector:logs]) {
    ((void (*)(id, SEL, NSString *))[configuration methodForSelector:logs])(configuration, logs,
                                                                            DocumentsPath(@"Libretro/Logs"));
  }
  return configuration;
}

- (void)runNext {
  if (_index >= _scenarios.count) {
    [self writeResultsFinished:YES];
    Progress(@"probe finished");
    return;
  }
  NSDictionary *scenario = _scenarios[_index++];
  NSString *name = scenario[@"name"];
  NSUInteger generation = ++_generation;
  NSMutableDictionary *result = [@{@"name" : name, @"core" : scenario[@"core"] ?: @""} mutableCopy];
  UIViewController *root = self.window.rootViewController;
  LibretroSession *session = [[LibretroSession alloc] initWithConfiguration:[self configurationForScenario:scenario]];
  _session = session;
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  double runSeconds = [scenario[@"runSeconds"] doubleValue] > 0 ? [scenario[@"runSeconds"] doubleValue] : 2.0;
  __weak ProbeAppDelegate *weakSelf = self;
  session.endedHandler = ^{
    result[@"ended"] = @YES;
    result[@"endedSeconds"] = @(CFAbsoluteTimeGetCurrent() - start);
    Progress(@"%@: session ended", name);
  };
  Progress(@"%@: launch (%@)", name, scenario[@"content"]);
  [session startFromViewController:root
                        completion:^(NSDictionary<NSString *, id> *launch) {
                          ProbeAppDelegate *probe = weakSelf;
                          if (probe == nil || generation != probe->_generation) return;
                          BOOL success = [launch[@"success"] boolValue];
                          result[@"launchSeconds"] = @(CFAbsoluteTimeGetCurrent() - start);
                          result[@"launch"] = @{
                            @"success" : @(success),
                            @"code" : launch[@"code"] ?: @"",
                            @"message" : launch[@"message"] ?: @"",
                            @"hardwareRendering" : launch[@"hardwareRendering"] ?: @"",
                            @"libraryName" : launch[@"libraryName"] ?: @"",
                            @"libraryVersion" : launch[@"libraryVersion"] ?: @"",
                            @"log" : Tail(launch[@"log"], 80),
                          };
                          Progress(@"%@: launch %@ %@ %@", name, success ? @"succeeded" : @"failed",
                                   launch[@"code"] ?: @"", launch[@"hardwareRendering"] ?: @"");
                          if (!success) {
                            // The session has dismissed its view already.
                            [probe finishScenario:result session:session];
                            return;
                          }
                          dispatch_after(
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(runSeconds * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                                result[@"activeBeforeStop"] = @(session.active);
                                result[@"presentedBeforeStop"] = @(root.presentedViewController != nil);
                                Progress(@"%@: stop requested", name);
                                CFAbsoluteTime stopStart = CFAbsoluteTimeGetCurrent();
                                [session stopWithCompletion:^{
                                  result[@"stopped"] = @YES;
                                  result[@"stopSeconds"] = @(CFAbsoluteTimeGetCurrent() - stopStart);
                                  result[@"presentedAfterStop"] = @(root.presentedViewController != nil);
                                  Progress(@"%@: stopped", name);
                                  [weakSelf finishScenario:result session:session];
                                }];
                              });
                        }];
  // A launch that never answers ends the probe: the session may still hold
  // the emulation thread.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    ProbeAppDelegate *probe = weakSelf;
    if (probe == nil || generation != probe->_generation || result[@"finished"] != nil) return;
    result[@"timeout"] = @YES;
    result[@"recentLog"] = Tail(session.recentLog, 80);
    result[@"journal"] = ReadText(DocumentsPath(@"Libretro/Logs/session.log"));
    Progress(@"%@: timed out", name);
    [probe->_results addObject:result];
    [probe writeResultsFinished:NO];
  });
}

- (void)finishScenario:(NSMutableDictionary *)result session:(LibretroSession *)session {
  result[@"finished"] = @YES;
  // The journal's END line is written in the dismissal completion, before
  // the stop completion; give the ended handler a turn as well.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    result[@"activeAfterStop"] = @(session.active);
    result[@"presentedAtEnd"] = @(self.window.rootViewController.presentedViewController != nil);
    result[@"recentLog"] = Tail(session.recentLog, 80);
    result[@"journal"] = ReadText(DocumentsPath(@"Libretro/Logs/session.log"));
    [self->_results addObject:result];
    [self writeResultsFinished:NO];
    self->_session = nil;
    Progress(@"%@: recorded", result[@"name"]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self runNext];
    });
  });
}

- (void)writeResultsFinished:(BOOL)finished {
  NSDictionary *report = @{@"finished" : @(finished), @"source" : _config[@"source"] ?: @"", @"results" : _results};
  NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
  NSString *name = finished ? @"probe.json" : @"probe-partial.json";
  [data writeToFile:DocumentsPath(name) atomically:YES];
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
  }
}
