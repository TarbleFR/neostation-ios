#import "Armsx2InternalBridgePlugin.h"
#import "Armsx2JitBridgePlugin.h"
#import "ARMSX2CoreABI.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <os/lock.h>
#include <cmath>

static NSString* const kARMSX2Channel = @"neostation/armsx2_internal";
static const uint32_t kARMSX2ExpectedABI = NEO_ARMSX2_ABI_VERSION;

static UIViewController* ARMSX2RootViewController(void) {
  UIWindow* keyWindow = nil;
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      if (window.isKeyWindow) { keyWindow = window; break; }
    }
    if (keyWindow) break;
  }
  UIViewController* controller = keyWindow.rootViewController;
  while (controller.presentedViewController) controller = controller.presentedViewController;
  return controller;
}


@interface Armsx2VirtualStickView : UIView
@property(nonatomic, copy) void (^valueChanged)(float x, float y);
@property(nonatomic, strong) UIView* knob;
@end

@implementation Armsx2VirtualStickView
- (instancetype)init {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.34];
    self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.48].CGColor;
    self.layer.borderWidth = 1.0;
    self.knob = [[UIView alloc] initWithFrame:CGRectZero];
    self.knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.38];
    self.knob.userInteractionEnabled = NO;
    [self addSubview:self.knob];
    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:pan];
  }
  return self;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
  const CGFloat knobSize = MIN(self.bounds.size.width, self.bounds.size.height) * 0.42;
  if (CGRectEqualToRect(self.knob.frame, CGRectZero)) {
    self.knob.frame = CGRectMake(0, 0, knobSize, knobSize);
    self.knob.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  }
  self.knob.layer.cornerRadius = knobSize * 0.5;
}
- (void)handlePan:(UIPanGestureRecognizer*)pan {
  const CGFloat radius = MAX(1.0, MIN(self.bounds.size.width, self.bounds.size.height) * 0.36);
  CGPoint delta = [pan translationInView:self];
  CGFloat x = delta.x / radius;
  CGFloat y = delta.y / radius;
  const CGFloat magnitude = hypot(x, y);
  if (magnitude > 1.0) { x /= magnitude; y /= magnitude; }
  const BOOL ended = pan.state == UIGestureRecognizerStateEnded ||
      pan.state == UIGestureRecognizerStateCancelled ||
      pan.state == UIGestureRecognizerStateFailed;
  if (ended) { x = 0; y = 0; }
  self.knob.center = CGPointMake(
      CGRectGetMidX(self.bounds) + x * radius * 0.58,
      CGRectGetMidY(self.bounds) + y * radius * 0.58);
  if (self.valueChanged) self.valueChanged((float)x, (float)y);
}
@end

@interface Armsx2GameViewController : UIViewController
@property(nonatomic, assign) const NeoARMSX2API* api;
@property(nonatomic, assign) UIView* coreView;
@property(nonatomic, copy) dispatch_block_t closeHandler;
@property(nonatomic, copy) void (^commandHandler)(NSString* command, NSNumber* value);
@property(nonatomic, strong) UIView* controlsView;
@property(nonatomic, strong) UIButton* menuButton;
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, assign) BOOL touchControlsVisible;
@property(nonatomic, assign) BOOL menuReady;
@property(nonatomic, assign) float leftX;
@property(nonatomic, assign) float leftY;
@property(nonatomic, assign) float rightX;
@property(nonatomic, assign) float rightY;
@property(nonatomic, assign) float upscaleMultiplier;
@property(nonatomic, assign) uint32_t aspectRatio;
@property(nonatomic, assign) BOOL cheatsEnabled;
@property(nonatomic, assign) uint32_t saveStateMask;
- (void)updateRuntimeMenuWithUpscale:(float)upscale
                              aspect:(uint32_t)aspect
                              cheats:(BOOL)cheats
                       saveStateMask:(uint32_t)mask;
- (void)showStatus:(NSString*)message;
- (void)resetInput;
@end

@implementation Armsx2GameViewController
- (instancetype)init {
  self = [super init];
  if (self) {
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    self.touchControlsVisible = YES;
    self.upscaleMultiplier = 1.0f;
    self.aspectRatio = 0;
  }
  return self;
}

- (BOOL)isFrench {
  NSString* language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
  return [language hasPrefix:@"fr"];
}
- (NSString*)en:(NSString*)english fr:(NSString*)french {
  return self.isFrench ? french : english;
}

- (UIButton*)padButton:(NSString*)title tag:(NSInteger)tag {
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.tag = tag;
  button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.48];
  button.tintColor = UIColor.whiteColor;
  [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
  button.layer.borderWidth = 1.0;
  button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.42].CGColor;
  button.layer.cornerRadius = 20;
  [button setTitle:title forState:UIControlStateNormal];
  [button addTarget:self action:@selector(padDown:) forControlEvents:UIControlEventTouchDown];
  [button addTarget:self action:@selector(padUp:) forControlEvents:
      UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
  return button;
}

- (UIView*)buttonPair:(NSString*)first firstTag:(NSInteger)firstTag
               second:(NSString*)second secondTag:(NSInteger)secondTag {
  UIView* pair = [UIView new];
  UIButton* a = [self padButton:first tag:firstTag];
  UIButton* b = [self padButton:second tag:secondTag];
  [pair addSubview:a]; [pair addSubview:b];
  a.frame = CGRectMake(0, 0, 50, 40);
  b.frame = CGRectMake(58, 0, 50, 40);
  a.layer.cornerRadius = b.layer.cornerRadius = 12;
  return pair;
}

- (UIView*)dpad {
  UIView* pad = [UIView new];
  UIButton* up = [self padButton:@"↑" tag:0];
  UIButton* down = [self padButton:@"↓" tag:1];
  UIButton* left = [self padButton:@"←" tag:2];
  UIButton* right = [self padButton:@"→" tag:3];
  for (UIButton* button in @[up,down,left,right]) [pad addSubview:button];
  up.frame = CGRectMake(37, 0, 38, 38);
  down.frame = CGRectMake(37, 74, 38, 38);
  left.frame = CGRectMake(0, 37, 38, 38);
  right.frame = CGRectMake(74, 37, 38, 38);
  return pad;
}

- (UIView*)faceButtons {
  UIView* pad = [UIView new];
  UIButton* triangle = [self padButton:@"△" tag:7];
  UIButton* cross = [self padButton:@"×" tag:4];
  UIButton* square = [self padButton:@"□" tag:6];
  UIButton* circle = [self padButton:@"○" tag:5];
  for (UIButton* button in @[triangle,cross,square,circle]) [pad addSubview:button];
  triangle.frame = CGRectMake(37, 0, 38, 38);
  cross.frame = CGRectMake(37, 74, 38, 38);
  square.frame = CGRectMake(0, 37, 38, 38);
  circle.frame = CGRectMake(74, 37, 38, 38);
  return pad;
}

- (void)loadView {
  UIView* root = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  root.backgroundColor = UIColor.blackColor;
  self.view = root;
  char error[512] = {};
  void* raw = self.api ? self.api->create_render_view(error, sizeof(error)) : NULL;
  if (raw) {
    UIView* render = (__bridge UIView*)raw;
    render.frame = root.bounds;
    render.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:render];
    self.coreView = render;
  }

  self.controlsView = [[UIView alloc] initWithFrame:root.bounds];
  self.controlsView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.controlsView.backgroundColor = UIColor.clearColor;
  self.controlsView.accessibilityIdentifier = @"armsx2-touch-controls";
  [root addSubview:self.controlsView];

  UIView* dpad = [self dpad]; dpad.tag = 1001;
  UIView* face = [self faceButtons]; face.tag = 1002;
  Armsx2VirtualStickView* leftStick = [Armsx2VirtualStickView new]; leftStick.tag = 1003;
  Armsx2VirtualStickView* rightStick = [Armsx2VirtualStickView new]; rightStick.tag = 1004;
  UIView* leftShoulders = [self buttonPair:@"L1" firstTag:8 second:@"L2" secondTag:10]; leftShoulders.tag = 1005;
  UIView* rightShoulders = [self buttonPair:@"R1" firstTag:9 second:@"R2" secondTag:11]; rightShoulders.tag = 1006;
  UIButton* start = [self padButton:@"START" tag:12]; start.accessibilityIdentifier = @"armsx2-start";
  UIButton* select = [self padButton:@"SELECT" tag:13]; select.accessibilityIdentifier = @"armsx2-select";
  start.titleLabel.font = select.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
  for (UIView* v in @[dpad,face,leftStick,rightStick,leftShoulders,rightShoulders,start,select]) {
    [self.controlsView addSubview:v];
  }

  __weak Armsx2GameViewController* weakSelf = self;
  leftStick.valueChanged = ^(float x,float y) {
    Armsx2GameViewController* strongSelf=weakSelf; if(!strongSelf) return;
    strongSelf.leftX=x; strongSelf.leftY=y; [strongSelf sendSticks];
  };
  rightStick.valueChanged = ^(float x,float y) {
    Armsx2GameViewController* strongSelf=weakSelf; if(!strongSelf) return;
    strongSelf.rightX=x; strongSelf.rightY=y; [strongSelf sendSticks];
  };

  UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
  close.translatesAutoresizingMaskIntoConstraints = NO;
  close.tintColor = UIColor.whiteColor;
  close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
  close.layer.cornerRadius = 18;
  close.accessibilityLabel = @"Close ARMSX2";
  [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
  [close addTarget:self action:@selector(closePressed) forControlEvents:UIControlEventTouchUpInside];
  [root addSubview:close];

  self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.menuButton.translatesAutoresizingMaskIntoConstraints = NO;
  self.menuButton.tintColor = UIColor.whiteColor;
  self.menuButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
  self.menuButton.layer.cornerRadius = 18;
  self.menuButton.accessibilityLabel = [self en:@"ARMSX2 game menu" fr:@"Menu du jeu ARMSX2"];
  self.menuButton.accessibilityIdentifier = @"armsx2-game-menu";
  [self.menuButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
  self.menuButton.showsMenuAsPrimaryAction = YES;
  [root addSubview:self.menuButton];

  self.statusLabel = [UILabel new];
  self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  self.statusLabel.textColor = UIColor.whiteColor;
  self.statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.68];
  self.statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
  self.statusLabel.textAlignment = NSTextAlignmentCenter;
  self.statusLabel.numberOfLines = 2;
  self.statusLabel.layer.cornerRadius = 8;
  self.statusLabel.clipsToBounds = YES;
  self.statusLabel.alpha = 0;
  [root addSubview:self.statusLabel];

  [NSLayoutConstraint activateConstraints:@[
    [close.leadingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:12],
    [close.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12],
    [close.widthAnchor constraintEqualToConstant:44],
    [close.heightAnchor constraintEqualToConstant:44],
    [self.menuButton.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-12],
    [self.menuButton.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:12],
    [self.menuButton.widthAnchor constraintEqualToConstant:44],
    [self.menuButton.heightAnchor constraintEqualToConstant:44],
    [self.statusLabel.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
    [self.statusLabel.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:14],
    [self.statusLabel.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor multiplier:0.62],
  ]];
  [self refreshMenu];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  self.coreView.frame = self.view.bounds;
  self.controlsView.frame = self.view.bounds;
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  const CGFloat w = self.view.bounds.size.width;
  const CGFloat h = self.view.bounds.size.height;
  const BOOL portrait = h > w;
  UIView* dpad = [self.controlsView viewWithTag:1001];
  UIView* face = [self.controlsView viewWithTag:1002];
  UIView* leftStick = [self.controlsView viewWithTag:1003];
  UIView* rightStick = [self.controlsView viewWithTag:1004];
  UIView* leftShoulders = [self.controlsView viewWithTag:1005];
  UIView* rightShoulders = [self.controlsView viewWithTag:1006];
  UIButton* start = (UIButton*)[self.controlsView viewWithTag:12];
  UIButton* select = (UIButton*)[self.controlsView viewWithTag:13];

  const CGFloat bottom = safe.bottom + 14;
  dpad.frame = CGRectMake(safe.left + 12, h - bottom - 112, 112, 112);
  face.frame = CGRectMake(w - safe.right - 124, h - bottom - 112, 112, 112);
  if (portrait) {
    leftStick.frame = CGRectMake(safe.left + 24, h - bottom - 222, 92, 92);
    rightStick.frame = CGRectMake(w - safe.right - 116, h - bottom - 222, 92, 92);
    leftShoulders.frame = CGRectMake(safe.left + 12, h - bottom - 276, 108, 40);
    rightShoulders.frame = CGRectMake(w - safe.right - 120, h - bottom - 276, 108, 40);
  } else {
    leftStick.frame = CGRectMake(safe.left + 136, h - bottom - 96, 88, 88);
    rightStick.frame = CGRectMake(w - safe.right - 224, h - bottom - 96, 88, 88);
    leftShoulders.frame = CGRectMake(safe.left + 12, h - bottom - 160, 108, 40);
    rightShoulders.frame = CGRectMake(w - safe.right - 120, h - bottom - 160, 108, 40);
  }
  const CGFloat centerY = h - bottom - 42;
  select.frame = CGRectMake(w * 0.5 - 98, centerY, 78, 36);
  start.frame = CGRectMake(w * 0.5 + 20, centerY, 78, 36);
  select.layer.cornerRadius = start.layer.cornerRadius = 12;
}

- (void)padDown:(UIButton*)sender {
  if(self.api && self.api->set_button && sender.tag>=0 && sender.tag<16)
    self.api->set_button((uint32_t)sender.tag,1);
}
- (void)padUp:(UIButton*)sender {
  if(self.api && self.api->set_button && sender.tag>=0 && sender.tag<16)
    self.api->set_button((uint32_t)sender.tag,0);
}
- (void)sendSticks {
  if(self.api && self.api->set_sticks)
    self.api->set_sticks(self.leftX,self.leftY,self.rightX,self.rightY);
}
- (void)resetInput {
  if(self.api && self.api->set_button)
    for(uint32_t i=0;i<16;i++) self.api->set_button(i,0);
  self.leftX=self.leftY=self.rightX=self.rightY=0;
  [self sendSticks];
}
- (void)closePressed { [self resetInput]; if (self.closeHandler) self.closeHandler(); }

- (UIAction*)commandAction:(NSString*)title
                   command:(NSString*)command
                     value:(NSNumber*)value
                  selected:(BOOL)selected
                   enabled:(BOOL)enabled {
  __weak Armsx2GameViewController* weakSelf=self;
  UIAction* action=[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction* _) {
    Armsx2GameViewController* strongSelf=weakSelf; if(!strongSelf) return;
    if([command isEqualToString:@"toggleTouch"]) {
      strongSelf.touchControlsVisible=!strongSelf.touchControlsVisible;
      if(!strongSelf.touchControlsVisible) [strongSelf resetInput];
      strongSelf.controlsView.hidden=!strongSelf.touchControlsVisible;
      [strongSelf refreshMenu];
      return;
    }
    if(strongSelf.commandHandler) strongSelf.commandHandler(command,value);
  }];
  action.state=selected ? UIMenuElementStateOn : UIMenuElementStateOff;
  if(!enabled) action.attributes=UIMenuElementAttributesDisabled;
  return action;
}

- (void)refreshMenu {
  const BOOL ready=self.menuReady;
  NSMutableArray<UIMenuElement*>* resolution=[NSMutableArray array];
  for(NSNumber* value in @[@1.0f,@2.0f,@3.0f,@4.0f,@6.0f,@8.0f]) {
    NSString* title=[NSString stringWithFormat:@"%@×",value];
    [resolution addObject:[self commandAction:title command:@"upscale" value:value
      selected:fabsf(self.upscaleMultiplier-value.floatValue)<0.05f enabled:ready]];
  }
  NSArray<NSString*>* aspectTitles=@[
    [self en:@"Auto" fr:@"Auto"], @"4:3", @"16:9", @"10:7",
    [self en:@"Stretch" fr:@"Étendre"]
  ];
  NSMutableArray<UIMenuElement*>* aspects=[NSMutableArray array];
  for(NSUInteger i=0;i<aspectTitles.count;i++)
    [aspects addObject:[self commandAction:aspectTitles[i] command:@"aspect" value:@(i)
      selected:self.aspectRatio==i enabled:ready]];

  UIAction* touch=[self commandAction:[self en:@"Touch controls" fr:@"Commandes tactiles"]
    command:@"toggleTouch" value:@0 selected:self.touchControlsVisible enabled:YES];
  UIAction* cheats=[self commandAction:[self en:@"Enable cheats" fr:@"Activer les cheats"]
    command:@"cheats" value:@(!self.cheatsEnabled) selected:self.cheatsEnabled enabled:ready];
  UIAction* reload=[self commandAction:[self en:@"Reload cheats / patches" fr:@"Recharger cheats / patches"]
    command:@"reloadCheats" value:@0 selected:NO enabled:ready];

  NSMutableArray<UIMenuElement*>* saves=[NSMutableArray array];
  NSMutableArray<UIMenuElement*>* loads=[NSMutableArray array];
  for(uint32_t slot=1;slot<=5;slot++) {
    NSString* title=[NSString stringWithFormat:@"%@ %u",[self en:@"Slot" fr:@"Slot"],slot];
    [saves addObject:[self commandAction:title command:@"saveState" value:@(slot)
      selected:NO enabled:ready]];
    const BOOL occupied=(self.saveStateMask & (1u<<(slot-1)))!=0;
    [loads addObject:[self commandAction:title command:@"loadState" value:@(slot)
      selected:NO enabled:ready && occupied]];
  }

  UIMenu* graphics=[UIMenu menuWithTitle:[self en:@"Graphics" fr:@"Graphismes"]
    children:@[
      [UIMenu menuWithTitle:[self en:@"Internal resolution" fr:@"Résolution interne"] children:resolution],
      [UIMenu menuWithTitle:[self en:@"Screen format" fr:@"Format d’écran"] children:aspects],
    ]];
  UIMenu* cheatMenu=[UIMenu menuWithTitle:@"Cheats" children:@[cheats,reload]];
  UIMenu* states=[UIMenu menuWithTitle:[self en:@"Save states" fr:@"Save states"]
    children:@[
      [UIMenu menuWithTitle:[self en:@"Save state" fr:@"Sauvegarder l’état"] children:saves],
      [UIMenu menuWithTitle:[self en:@"Load state" fr:@"Charger l’état"] children:loads],
    ]];
  self.menuButton.menu=[UIMenu menuWithTitle:@"ARMSX2" children:@[touch,graphics,cheatMenu,states]];
}

- (void)updateRuntimeMenuWithUpscale:(float)upscale
                              aspect:(uint32_t)aspect
                              cheats:(BOOL)cheats
                       saveStateMask:(uint32_t)mask {
  self.upscaleMultiplier=upscale;
  self.aspectRatio=aspect;
  self.cheatsEnabled=cheats;
  self.saveStateMask=mask;
  self.menuReady=YES;
  [self refreshMenu];
}

- (void)showStatus:(NSString*)message {
  if(message.length==0) return;
  self.statusLabel.text=[NSString stringWithFormat:@"  %@  ",message];
  [UIView animateWithDuration:0.15 animations:^{ self.statusLabel.alpha=1; }];
  __weak Armsx2GameViewController* weakSelf=self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    Armsx2GameViewController* strongSelf=weakSelf; if(!strongSelf) return;
    [UIView animateWithDuration:0.25 animations:^{ strongSelf.statusLabel.alpha=0; }];
  });
}
@end


@interface Armsx2InternalBridgePlugin ()
@property(nonatomic, strong) FlutterMethodChannel* channel;
@property(nonatomic, strong) Armsx2GameViewController* gameController;
@property(nonatomic, assign) void* coreHandle;
@property(nonatomic, assign) const NeoARMSX2API* api;
@property(nonatomic, assign) BOOL operationBusy;
@end

@implementation Armsx2InternalBridgePlugin {
  dispatch_queue_t _runtimeQueue;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:kARMSX2Channel
            binaryMessenger:registrar.messenger];
  Armsx2InternalBridgePlugin* instance = [Armsx2InternalBridgePlugin new];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
  [Armsx2JitBridgePlugin registerWithRegistrar:registrar];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _runtimeQueue = dispatch_queue_create(
        "com.neogamelab.neostation.armsx2.runtime",
        DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString*)corePath {
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath ?: @"";
  return [frameworks stringByAppendingPathComponent:@"ARMSX2Core.framework/ARMSX2Core"];
}

- (NSString*)resourcePath {
  NSString* frameworkPath = [[self corePath] stringByDeletingLastPathComponent];
  NSBundle* bundle = [NSBundle bundleWithPath:frameworkPath];
  return bundle.resourcePath ?: frameworkPath;
}

- (BOOL)loadCore:(NSString**)error {
  if (self.api != NULL) return YES;
  if (@available(iOS 26.0, *)) {
    if (!ARMSX2JitConfirmCoreLoadHandoff()) {
      if (error) *error = @"ARMSX2 debugger nonce proof failed at the Core load boundary.";
      return NO;
    }
  }
  NSString* path = [self corePath];
  if (![NSFileManager.defaultManager isReadableFileAtPath:path]) {
    if (error) *error = [NSString stringWithFormat:@"Embedded ARMSX2 Core is missing: %@", path];
    return NO;
  }
  dlerror();
  void* handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    const char* detail = dlerror();
    if (error) *error = [NSString stringWithFormat:@"ARMSX2 Core dlopen failed: %s", detail ?: "unknown"];
    return NO;
  }
  auto getAPI = reinterpret_cast<NeoARMSX2GetAPI>(dlsym(handle, "NeoARMSX2_GetAPI"));
  const NeoARMSX2API* api = getAPI ? getAPI(kARMSX2ExpectedABI) : NULL;
  if (!api || api->version != kARMSX2ExpectedABI ||
      api->size < sizeof(NeoARMSX2API) || !api->prepare ||
      !api->request_jit_detach || !api->validate_jit || !api->boot ||
      !api->set_button || !api->set_sticks ||
      !api->get_upscale_multiplier || !api->get_aspect_ratio ||
      !api->get_cheats_enabled || !api->set_upscale_multiplier ||
      !api->set_aspect_ratio || !api->set_cheats_enabled ||
      !api->reload_cheats || !api->has_save_state ||
      !api->save_state || !api->load_state) {
    if (error) *error = @"Embedded ARMSX2 Core ABI is incompatible.";
    return NO;
  }
  self.coreHandle = handle; // Intentionally process-lifetime; never dlclose Objective-C classes.
  self.api = api;
  return YES;
}

- (void)dismissGameController {
  Armsx2GameViewController* controller = self.gameController;
  self.gameController = nil;
  if (controller) {
    [controller resetInput];
    [controller dismissViewControllerAnimated:NO completion:nil];
  }
  if (self.api && self.api->release_render_view) self.api->release_render_view();
}

- (void)failTransaction:(NSString*)message result:(FlutterResult)result {
  if (self.api) {
    char ignored[256] = {};
    self.api->request_stop();
    self.api->shutdown(30000, ignored, sizeof(ignored));
  }
  ARMSX2JitAbortTransaction();
  self.operationBusy = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self dismissGameController];
    result(@{@"success": @NO, @"message": message ?: @"ARMSX2 launch failed."});
  });
}

- (void)publishMenuStateForController:(Armsx2GameViewController*)controller
                                   message:(NSString*)message {
  if (!self.api || !controller) return;
  const float upscale = self.api->get_upscale_multiplier();
  const uint32_t aspect = self.api->get_aspect_ratio();
  const BOOL cheats = self.api->get_cheats_enabled() != 0;
  uint32_t mask = 0;
  for (uint32_t slot = 1; slot <= 5; slot++) {
    if (self.api->has_save_state(slot)) mask |= (1u << (slot - 1));
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.gameController != controller) return;
    [controller updateRuntimeMenuWithUpscale:upscale
                                      aspect:aspect
                                      cheats:cheats
                               saveStateMask:mask];
    if (message.length) [controller showStatus:message];
  });
}

- (void)performGameCommand:(NSString*)command
                     value:(NSNumber*)value
                controller:(Armsx2GameViewController*)controller {
  dispatch_async(_runtimeQueue, ^{
    if (!self.api || self.gameController != controller) return;
    char error[1024] = {};
    BOOL ok = NO;
    NSString* success = @"";

    if ([command isEqualToString:@"upscale"]) {
      ok = self.api->set_upscale_multiplier(value.floatValue, error, sizeof(error)) != 0;
      success = [controller en:[NSString stringWithFormat:@"Internal resolution: %.0f×", value.floatValue]
                            fr:[NSString stringWithFormat:@"Résolution interne : %.0f×", value.floatValue]];
    } else if ([command isEqualToString:@"aspect"]) {
      ok = self.api->set_aspect_ratio(value.unsignedIntValue, error, sizeof(error)) != 0;
      success = [controller en:@"Screen format updated." fr:@"Format d’écran mis à jour."];
    } else if ([command isEqualToString:@"cheats"]) {
      ok = self.api->set_cheats_enabled(value.boolValue ? 1 : 0, error, sizeof(error)) != 0;
      success = value.boolValue
          ? [controller en:@"Cheats enabled." fr:@"Cheats activés."]
          : [controller en:@"Cheats disabled." fr:@"Cheats désactivés."];
    } else if ([command isEqualToString:@"reloadCheats"]) {
      ok = self.api->reload_cheats(error, sizeof(error)) != 0;
      success = [controller en:@"Cheats and patches reloaded." fr:@"Cheats et patches rechargés."];
    } else if ([command isEqualToString:@"saveState"]) {
      const uint32_t slot = value.unsignedIntValue;
      ok = self.api->save_state(slot, 60000, error, sizeof(error)) != 0;
      success = [controller en:[NSString stringWithFormat:@"State saved in slot %u.", slot]
                            fr:[NSString stringWithFormat:@"État sauvegardé dans le slot %u.", slot]];
    } else if ([command isEqualToString:@"loadState"]) {
      const uint32_t slot = value.unsignedIntValue;
      ok = self.api->load_state(slot, 60000, error, sizeof(error)) != 0;
      success = [controller en:[NSString stringWithFormat:@"State loaded from slot %u.", slot]
                            fr:[NSString stringWithFormat:@"État chargé depuis le slot %u.", slot]];
    }

    NSString* message = ok ? success :
        (error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 command failed.");
    [self publishMenuStateForController:controller message:message ?: @""];
  });
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"diagnostics"]) {
    NSString* path = [self corePath];
    result(@{
      @"corePresent": @([NSFileManager.defaultManager isReadableFileAtPath:path]),
      @"coreLoaded": @(self.api != NULL),
      @"busy": @(self.operationBusy),
      @"abi": @(self.api ? self.api->version : 0),
      @"sourceRevision": self.api && self.api->source_revision
          ? [NSString stringWithUTF8String:self.api->source_revision] : @"",
    });
    return;
  }

  if ([call.method isEqualToString:@"stop"]) {
    dispatch_async(_runtimeQueue, ^{
      BOOL ok = YES;
      NSString* message = @"";
      if (self.api) {
        char error[512] = {};
        self.api->request_stop();
        ok = self.api->shutdown(30000, error, sizeof(error)) != 0;
        if (!ok && error[0]) message = [NSString stringWithUTF8String:error] ?: @"";
      }
      ARMSX2JitAbortTransaction();
      self.operationBusy = NO;
      dispatch_async(dispatch_get_main_queue(), ^{
        [self dismissGameController];
        result(@{@"success": @(ok), @"message": message});
      });
    });
    return;
  }

  if (![call.method isEqualToString:@"launch"]) {
    result(FlutterMethodNotImplemented);
    return;
  }

  if (self.operationBusy) {
    result(@{@"success": @NO, @"message": @"An ARMSX2 transaction is already active."});
    return;
  }
  NSDictionary* args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  NSNumber* transactionNumber = [args[@"transaction"] isKindOfClass:NSNumber.class] ? args[@"transaction"] : nil;
  NSString* gamePath = [args[@"gamePath"] isKindOfClass:NSString.class] ? args[@"gamePath"] : @"";
  NSString* dataPath = [args[@"dataPath"] isKindOfClass:NSString.class] ? args[@"dataPath"] : @"";
  NSString* biosDirectory = [args[@"biosDirectory"] isKindOfClass:NSString.class] ? args[@"biosDirectory"] : @"";
  NSString* biosFilename = [args[@"biosFilename"] isKindOfClass:NSString.class] ? args[@"biosFilename"] : @"";
  if (!transactionNumber || transactionNumber.unsignedLongLongValue == 0 ||
      ![gamePath hasPrefix:@"/"] || ![dataPath hasPrefix:@"/"] ||
      ![biosDirectory hasPrefix:@"/"]) {
    result(@{@"success": @NO, @"message": @"Invalid ARMSX2 launch parameters."});
    return;
  }
  if (![NSFileManager.defaultManager isReadableFileAtPath:gamePath]) {
    result(@{@"success": @NO, @"message": @"The selected PS2 game is not readable."});
    return;
  }

  self.operationBusy = YES;
  dispatch_async(_runtimeQueue, ^{
    NSString* loadError = nil;
    if (![self loadCore:&loadError]) {
      [self failTransaction:loadError result:result];
      return;
    }

    __block Armsx2GameViewController* controller = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIViewController* root = ARMSX2RootViewController();
      if (!root || root.view.window == nil) return;
      controller = [Armsx2GameViewController new];
      controller.api = self.api;
      __weak Armsx2InternalBridgePlugin* weakSelf = self;
      __weak Armsx2GameViewController* weakController = controller;
      controller.closeHandler = ^{ [weakSelf handleMethodCall:
          [FlutterMethodCall methodCallWithMethodName:@"stop" arguments:nil]
          result:^(id _){}]; };
      controller.commandHandler = ^(NSString* command, NSNumber* value) {
        Armsx2InternalBridgePlugin* strongSelf = weakSelf;
        Armsx2GameViewController* strongController = weakController;
        if (!strongSelf || !strongController) return;
        [strongSelf performGameCommand:command value:value controller:strongController];
      };
      [controller loadViewIfNeeded];
      if (!controller.coreView) { controller = nil; return; }
      [root presentViewController:controller animated:NO completion:nil];
      self.gameController = controller;
    });
    if (!controller) {
      [self failTransaction:@"ARMSX2 render view could not be created." result:result];
      return;
    }

    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dataPath withIntermediateDirectories:YES attributes:nil error:nil];

    char error[2048] = {};
    NeoARMSX2Configuration config = {};
    config.size = sizeof(config);
    config.transaction = transactionNumber.unsignedLongLongValue;
    config.data_directory = dataPath.fileSystemRepresentation;
    NSString* resources = [self resourcePath];
    config.resource_directory = resources.fileSystemRepresentation;
    config.bios_directory = biosDirectory.fileSystemRepresentation;
    config.bios_filename = biosFilename.length ? biosFilename.fileSystemRepresentation : "";
    config.event = NULL;
    config.context = NULL;

    if (!self.api->prepare(&config, 120000, error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 Core preparation failed.";
      [self failTransaction:message result:result];
      return;
    }
    memset(error, 0, sizeof(error));
    if (!self.api->request_jit_detach(error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 debugger detach request failed.";
      [self failTransaction:message result:result];
      return;
    }

    NSString* detachMessage = nil;
    if (!ARMSX2JitWaitForDetach(120.0, &detachMessage)) {
      [self failTransaction:detachMessage ?: @"ARMSX2 helper did not confirm debugger detach." result:result];
      return;
    }

    memset(error, 0, sizeof(error));
    if (!self.api->validate_jit(error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 post-detach JIT validation failed.";
      [self failTransaction:message result:result];
      return;
    }

    NSString* ext = gamePath.pathExtension.lowercaseString;
    uint32_t kind = [ext isEqualToString:@"elf"] ? NEO_ARMSX2_BOOT_ELF : NEO_ARMSX2_BOOT_DISC;
    memset(error, 0, sizeof(error));
    if (!self.api->boot(gamePath.fileSystemRepresentation, kind, 120000, error, sizeof(error))) {
      NSString* message = error[0] ? [NSString stringWithUTF8String:error] : @"ARMSX2 boot failed.";
      [self failTransaction:message result:result];
      return;
    }

    self.operationBusy = NO;
    [self publishMenuStateForController:controller message:
        [controller en:@"ARMSX2 ready." fr:@"ARMSX2 prêt."]];
    NSString* revision = self.api->source_revision
        ? [NSString stringWithUTF8String:self.api->source_revision] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
      result(@{
        @"success": @YES,
        @"transaction": transactionNumber,
        @"bootKind": kind == NEO_ARMSX2_BOOT_ELF ? @"elf" : @"disc",
        @"sourceRevision": revision ?: @"",
        @"message": @"ARMSX2 entered Running.",
      });
    });
  });
}

@end
