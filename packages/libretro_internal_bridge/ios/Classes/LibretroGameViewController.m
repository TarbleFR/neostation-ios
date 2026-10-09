#import "LibretroGameViewController.h"

#import "LibretroInputState.h"
#import "LibretroTouchOverlay.h"

@interface LibretroMetalView : UIView
@end

@implementation LibretroMetalView
+ (Class)layerClass {
  return CAMetalLayer.class;
}
@end

@implementation LibretroGameViewController {
  NSString *_profile;
  LibretroInputState *_input;
  LibretroMetalView *_metalView;
  UIButton *_menuButton;
  UILabel *_statusLabel;
  UIActivityIndicatorView *_spinner;
  CADisplayLink *_displayLink;
  NSUInteger _statusGeneration;
}

- (instancetype)initWithProfile:(NSString *)profile input:(LibretroInputState *)input {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _profile = [profile copy];
    _input = input;
    _touchControlsEnabled = YES;
    _menuAccessibilityLabel = @"Menu";
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
  }
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [_displayLink invalidate];
}

- (CAMetalLayer *)metalLayer {
  [self loadViewIfNeeded];
  return (CAMetalLayer *)_metalView.layer;
}

- (void)loadView {
  UIView *root = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  root.backgroundColor = UIColor.blackColor;
  self.view = root;

  _metalView = [[LibretroMetalView alloc] initWithFrame:root.bounds];
  _metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _metalView.contentScaleFactor = UIScreen.mainScreen.nativeScale;
  _metalView.backgroundColor = UIColor.blackColor;
  [root addSubview:_metalView];

  _overlay = [[LibretroTouchOverlay alloc] initWithProfile:_profile input:_input];
  _overlay.frame = root.bounds;
  _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [root addSubview:_overlay];

  _menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_menuButton setImage:[UIImage systemImageNamed:@"line.3.horizontal"] forState:UIControlStateNormal];
  _menuButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
  _menuButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
  _menuButton.layer.cornerRadius = 20;
  _menuButton.accessibilityIdentifier = @"libretro-game-menu";
  _menuButton.accessibilityLabel = _menuAccessibilityLabel;
  [_menuButton addTarget:self action:@selector(menuPressed) forControlEvents:UIControlEventTouchUpInside];
  [root addSubview:_menuButton];

  _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  _statusLabel.textColor = UIColor.whiteColor;
  _statusLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
  _statusLabel.textAlignment = NSTextAlignmentCenter;
  _statusLabel.numberOfLines = 2;
  _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
  _statusLabel.layer.cornerRadius = 10;
  _statusLabel.layer.masksToBounds = YES;
  _statusLabel.alpha = 0;
  [root addSubview:_statusLabel];

  _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
  _spinner.color = UIColor.whiteColor;
  _spinner.hidesWhenStopped = YES;
  [root addSubview:_spinner];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserver:self
             selector:@selector(applicationWillResignActive)
                 name:UIApplicationWillResignActiveNotification
               object:nil];
  [center addObserver:self
             selector:@selector(applicationDidBecomeActive)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];
}

- (void)setMenuAccessibilityLabel:(NSString *)menuAccessibilityLabel {
  _menuAccessibilityLabel = [menuAccessibilityLabel copy];
  _menuButton.accessibilityLabel = _menuAccessibilityLabel;
}

- (void)applicationWillResignActive {
  [_overlay releaseAllTouches];
  if (self.activeHandler != nil) self.activeHandler(NO);
}

- (void)applicationDidBecomeActive {
  if (self.activeHandler != nil) self.activeHandler(YES);
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGRect bounds = self.view.bounds;
  _metalView.frame = bounds;
  _overlay.frame = bounds;
  UIEdgeInsets insets = self.view.safeAreaInsets;
  _menuButton.frame = CGRectMake(CGRectGetMidX(bounds) - 22, insets.top + 6, 44, 40);
  _spinner.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
  CGFloat scale = _metalView.contentScaleFactor;
  if (self.layoutHandler != nil) {
    self.layoutHandler(CGSizeMake(bounds.size.width * scale, bounds.size.height * scale));
  }
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_displayLink == nil) {
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  }
}

- (void)stopInputPolling {
  [_displayLink invalidate];
  _displayLink = nil;
  [_overlay releaseAllTouches];
}

- (void)tick {
  BOOL menuRequested = [_input pollControllers];
  _overlay.hidden = !self.touchControlsEnabled || _input.hasPhysicalController;
  if (self.videoRectProvider != nil) {
    CGRect normalized = self.videoRectProvider();
    CGSize size = _overlay.bounds.size;
    _overlay.videoRect = CGRectMake(normalized.origin.x * size.width, normalized.origin.y * size.height,
                                    normalized.size.width * size.width, normalized.size.height * size.height);
  }
  if (menuRequested && self.presentedViewController == nil) [self menuPressed];
}

- (void)menuPressed {
  if (self.presentedViewController != nil) return;
  [_overlay releaseAllTouches];
  if (self.menuHandler != nil) self.menuHandler();
}

- (void)showStatus:(NSString *)message {
  if (message.length == 0) return;
  NSUInteger generation = ++_statusGeneration;
  _statusLabel.text = message;
  CGRect bounds = self.view.bounds;
  CGSize fit = [_statusLabel sizeThatFits:CGSizeMake(bounds.size.width * 0.7, 80)];
  CGFloat width = MIN(bounds.size.width * 0.8, fit.width + 32);
  _statusLabel.frame = CGRectMake(CGRectGetMidX(bounds) - width / 2, CGRectGetMaxY(_menuButton.frame) + 10, width,
                                  fit.height + 16);
  [UIView animateWithDuration:0.2 animations:^{
    self->_statusLabel.alpha = 1;
  }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (generation != self->_statusGeneration) return;
    [UIView animateWithDuration:0.3 animations:^{
      self->_statusLabel.alpha = 0;
    }];
  });
}

- (void)setLoading:(BOOL)loading {
  if (loading) {
    [_spinner startAnimating];
  } else {
    [_spinner stopAnimating];
  }
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return YES;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
  return UIRectEdgeAll;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

@end
