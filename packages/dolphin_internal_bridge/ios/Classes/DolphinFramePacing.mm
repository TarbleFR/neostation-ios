// SPDX-License-Identifier: GPL-3.0-or-later
#import "DolphinFramePacing.h"
#include "DolphinPacingLabels.h"
#include <sys/utsname.h>
#include <cmath>

static NSString* const DOLProfileKey=@"NeoStation.Dolphin.DisplayTrial.Profile";
static NSString* const DOLRefreshKey=@"NeoStation.Dolphin.DisplayTrial.Refresh";
static NSString* const DOLTraceKey=@"NeoStation.Dolphin.DisplayTrial.Trace";
NSInteger DOLFrameProfile(void) {
  id v=[NSUserDefaults.standardUserDefaults objectForKey:DOLProfileKey];
  return [v isKindOfClass:NSNumber.class] && [v integerValue]>=0 && [v integerValue]<=2?[v integerValue]:2;
}
static NSInteger DOLRefreshPreference(void) {
  id v=[NSUserDefaults.standardUserDefaults objectForKey:DOLRefreshKey];
  return [v isKindOfClass:NSNumber.class] && [@[@0,@60,@120] containsObject:v]?[v integerValue]:120;
}
NSInteger DOLRequestedRefresh(NSInteger requested,NSInteger maximum,BOOL lowPower,NSInteger thermal) {
  if(requested==0 || maximum<=0)return 0;
  NSInteger result=MIN(requested,maximum);
  if(lowPower || thermal>=NSProcessInfoThermalStateSerious)result=MIN(result,60);
  return MAX(1,result);
}
@class DOLDisplaySettings;
@interface DOLDisplayLinkTarget:NSObject
@property(nonatomic,weak) DolphinFramePacing* owner;
- (void)tick:(CADisplayLink*)link;
@end
@interface DolphinFramePacing ()
@property(nonatomic,strong,nullable) CADisplayLink* displayLink;
@property(nonatomic,weak,nullable) UIView* view;
@property(nonatomic,strong) NSMutableArray* records;
@property(nonatomic,assign) BOOL running;
@property(nonatomic,assign) double lastTimestamp;
@property(nonatomic,assign) double windowStart;
@property(nonatomic,assign) double observedHz;
@property(nonatomic,assign) double intervalHz;
@property(nonatomic,assign) double maxGapMs;
@property(nonatomic,assign) NSUInteger ticks;
@property(nonatomic,assign) NSInteger requestedHz;
@property(nonatomic,assign) NSInteger maximumHz;
- (void)tick:(CADisplayLink*)link;
@end
@interface DOLDisplaySettings:UITableViewController
@property(nonatomic,strong) DolphinFramePacing* pacing;
@end
@implementation DOLDisplayLinkTarget
- (void)tick:(CADisplayLink*)link {[self.owner tick:link];}
@end
@implementation DolphinFramePacing
- (instancetype)init {
  if((self=[super init])){_records=[NSMutableArray array];_locale=@"en";_gameId=@"";}
  return self;
}
- (BOOL)traceEnabled {
  id value=[NSUserDefaults.standardUserDefaults objectForKey:DOLTraceKey];
  return value==nil || [value boolValue];
}
- (void)startWithView:(UIView*)view {
  NSAssert(NSThread.isMainThread,@"Display link belongs to the main run loop");
  [self stop];self.view=view;self.running=YES;
  for(NSString* name in @[UIApplicationDidBecomeActiveNotification,UIApplicationWillResignActiveNotification,
      NSProcessInfoPowerStateDidChangeNotification,NSProcessInfoThermalStateDidChangeNotification])
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(environmentChanged:) name:name object:nil];
  [self refreshPreference];
}
- (void)environmentChanged:(NSNotification*)notification {
  if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self environmentChanged:notification];});return;}
  if([notification.name isEqual:UIApplicationWillResignActiveNotification]) {
    [self.displayLink invalidate];self.displayLink=nil;self.observedHz=0;self.windowStart=0;self.lastTimestamp=0;return;
  }
  [self refreshPreference];
}
- (void)refreshPreference {
  NSAssert(NSThread.isMainThread,@"Display hints are configured on main");
  UIScreen* screen=self.view.window.screen;
  self.maximumHz=screen.maximumFramesPerSecond;
  self.requestedHz=DOLRequestedRefresh(DOLRefreshPreference(),self.maximumHz,NSProcessInfo.processInfo.lowPowerModeEnabled,NSProcessInfo.processInfo.thermalState);
  if(!self.running || !screen || !self.requestedHz || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) {
    [self.displayLink invalidate];self.displayLink=nil;self.observedHz=0;return;
  }
  if(!self.displayLink) {
    DOLDisplayLinkTarget* target=[DOLDisplayLinkTarget new];target.owner=self;
    self.displayLink=[screen displayLinkWithTarget:target selector:@selector(tick:)];
    self.lastTimestamp=0;self.windowStart=0;self.ticks=0;
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }
  // A timing hint only. Never draw, acquire a drawable or advance emulation here.
  // Avoid a variable 80/120 request for 60-FPS games: prefer a stable 2:1 cadence.
  self.displayLink.preferredFrameRateRange=CAFrameRateRangeMake(self.requestedHz,self.requestedHz,self.requestedHz);
}
- (void)tick:(CADisplayLink*)link {
  const double now=link.timestamp;
  if(self.lastTimestamp>0)self.maxGapMs=MAX(self.maxGapMs,(now-self.lastTimestamp)*1000);
  self.lastTimestamp=now;
  const double interval=link.targetTimestamp-link.timestamp;
  if(interval>0 && std::isfinite(interval))self.intervalHz=1.0/interval;
  if(!self.windowStart){self.windowStart=now;self.ticks=0;return;}
  self.ticks++;
  if(now-self.windowStart>=1) {
    self.observedHz=self.ticks/(now-self.windowStart);self.windowStart=now;self.ticks=0;
  }
}
- (NSDictionary*)summary {
  return @{@"requestedHz":@(self.requestedHz),@"preferenceHz":@(DOLRefreshPreference()),
    @"maximumHz":@(self.maximumHz),@"displayLinkCallbackHz":@(self.observedHz),
    @"displayLinkIntervalHz":@(self.intervalHz),@"displayLinkMaxGapMs":@(self.maxGapMs),
    @"activeProfile":@(self.activeProfile),@"nextProfile":@(DOLFrameProfile()),
    @"lowPower":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"thermalState":@(NSProcessInfo.processInfo.thermalState),
    @"traceEnabled":@(self.traceEnabled),@"gameId":self.gameId?:@"",
    @"measurementNote":@"CADisplayLink timing is not panel scanout or emulator FPS. Performance samples are 2Hz aggregates, not a per-frame trace."};
}
- (NSArray*)samples {return [self.records copy];}
- (void)appendPerformance:(NSDictionary*)sample inputMs:(double)inputMs refreshed:(BOOL)refreshed {
  if(!self.traceEnabled || !self.running)return;
  NSMutableDictionary* row=[sample mutableCopy];row[@"hostSampleTime"]=@(CACurrentMediaTime());
  row[@"displayLinkHz"]=@(self.observedHz);row[@"displayLinkIntervalHz"]=@(self.intervalHz);
  row[@"inputRefreshMs"]=@(std::isfinite(inputMs)?inputMs:0);row[@"inputRefreshed"]=@(refreshed);
  row[@"thermalState"]=@(NSProcessInfo.processInfo.thermalState);row[@"requestedHz"]=@(self.requestedHz);
  if(self.records.count>=240)[self.records removeObjectAtIndex:0];
  [self.records addObject:row];
}
- (UIViewController*)settingsController {
  DOLDisplaySettings* page=[[DOLDisplaySettings alloc] initWithStyle:UITableViewStyleInsetGrouped];page.pacing=self;return page;
}
- (void)stop {
  [self.displayLink invalidate];self.displayLink=nil;self.running=NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];self.view=nil;
}
- (void)dealloc {[self.displayLink invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
@end

@implementation DOLDisplaySettings
- (NSString*)text:(NSString*)key{return DOLPacingText(key,self.pacing.locale);}
- (NSString*)profileName:(NSInteger)value{return [self text:@[@"legacy",@"metal",@"hybrid"][MAX(0,MIN(2,value))]];}
- (void)viewDidLoad {
  [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
  self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;self.title=[self text:@"title"];
  self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=64;
  self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
}
- (NSInteger)tableView:(UITableView*)table numberOfRowsInSection:(NSInteger)section {return 5;}
- (UITableViewCell*)tableView:(UITableView*)table cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;cell.textLabel.textColor=UIColor.labelColor;
  cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
  cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
  cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
  switch(path.row) {
    case 0:cell.textLabel.text=[self text:@"refresh"];
      cell.detailTextLabel.text=DOLRefreshPreference()==0?[self text:@"automatic"]:[NSString stringWithFormat:@"%ld Hz",(long)DOLRefreshPreference()];break;
    case 1:cell.textLabel.text=[self text:@"profile"];
      cell.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@: %@",[self profileName:DOLFrameProfile()],[self text:@"active"],[self profileName:self.pacing.activeProfile]];break;
    case 2:cell.textLabel.text=[self text:@"status"];
      cell.detailTextLabel.text=[NSString stringWithFormat:@"%@: %ld Hz · %@: %.1f Hz\n%@",[self text:@"request"],(long)self.pacing.requestedHz,[self text:@"callbacks"],self.pacing.observedHz,[self text:@"statusHelp"]];
      cell.accessoryType=UITableViewCellAccessoryNone;break;
    case 3:cell.textLabel.text=[self text:@"trace"];
      cell.detailTextLabel.text=[self text:self.pacing.traceEnabled?@"on":@"off"];break;
    case 4:cell.textLabel.text=[self text:@"export"];cell.detailTextLabel.text=[self text:@"traceHelp"];break;
  }
  return cell;
}
- (NSString*)tableView:(UITableView*)table titleForFooterInSection:(NSInteger)section {
  return [NSString stringWithFormat:@"%@\n\n%@",[self text:@"hzHelp"],[self text:@"profileHelp"]];
}
- (void)tableView:(UITableView*)table willDisplayFooterView:(UIView*)view forSection:(NSInteger)section {
  if([view isKindOfClass:UITableViewHeaderFooterView.class]) {
    UITableViewHeaderFooterView* footer=(id)view;footer.textLabel.textColor=UIColor.labelColor;footer.textLabel.numberOfLines=0;
  }
}
- (void)choose:(NSArray<NSNumber*>*)values names:(NSArray<NSString*>*)names key:(NSString*)key cell:(UIView*)cell {
  UIAlertController* alert=[UIAlertController alertControllerWithTitle:[self text:[key isEqual:DOLRefreshKey]?@"refresh":@"profile"]
    message:[self text:[key isEqual:DOLRefreshKey]?@"hzHelp":@"restartHelp"] preferredStyle:UIAlertControllerStyleActionSheet];
  for(NSUInteger i=0;i<values.count;i++) {
    NSNumber* value=values[i];
    UIAlertAction* action=[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction* a){
      [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
      [self.pacing refreshPreference];[self.tableView reloadData];
      if([key isEqual:DOLProfileKey])self.navigationItem.prompt=[self text:@"restartHelp"];
    }];
    // A 60-Hz screen cannot be made 120 Hz. Low-power throttling does not erase the user's selection.
    if([key isEqual:DOLRefreshKey] && value.integerValue==120 && self.pacing.maximumHz<120)action.enabled=NO;
    [alert addAction:action];
  }
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  alert.popoverPresentationController.sourceView=cell;alert.popoverPresentationController.sourceRect=cell.bounds;
  [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView*)table didSelectRowAtIndexPath:(NSIndexPath*)path {
  [table deselectRowAtIndexPath:path animated:YES];UIView* cell=[table cellForRowAtIndexPath:path];
  if(self.presentedViewController)return;
  if(path.row==0)[self choose:@[@0,@60,@120] names:@[[self text:@"automatic"],@"60 Hz",@"120 Hz"] key:DOLRefreshKey cell:cell];
  else if(path.row==1)[self choose:@[@0,@1,@2] names:@[[self text:@"legacy"],[self text:@"metal"],[self text:@"hybrid"]] key:DOLProfileKey cell:cell];
  else if(path.row==2){[self.pacing refreshPreference];[table reloadData];}
  else if(path.row==3){[NSUserDefaults.standardUserDefaults setBool:!self.pacing.traceEnabled forKey:DOLTraceKey];[table reloadData];}
  else if(path.row==4) {
    struct utsname machine;uname(&machine);
    NSDictionary* report=@{@"schema":@1,@"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]?:@"",
      @"device":@(machine.machine),@"iOS":UIDevice.currentDevice.systemVersion,@"summary":self.pacing.summary,@"samples":self.pacing.samples};
    NSData* bytes=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    NSURL* url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"NeoStation-Dolphin-FramePacing.json"]];
    if(!bytes || ![bytes writeToURL:url options:NSDataWritingAtomic error:nil])return;
    UIActivityViewController* share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView=cell;share.popoverPresentationController.sourceRect=cell.bounds;
    [self presentViewController:share animated:YES completion:nil];
  }
}
@end
