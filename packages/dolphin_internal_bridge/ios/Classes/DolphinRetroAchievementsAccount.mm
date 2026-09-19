#import "DolphinRetroAchievementsAccount.h"
#import <Security/Security.h>

// Shared by the menu and bridge so native callers cannot bypass validation.
NSData* DOLSerializeMenuRequest(id request) {
  @try {
    if (![request isKindOfClass:NSDictionary.class] ||
        ![request[@"kind"] isKindOfClass:NSString.class] ||
        ![request[@"kind"] length] || ![NSJSONSerialization isValidJSONObject:request]) return nil;
    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
    return error ? nil : data;
  } @catch (NSException* exception) {
    // Never log requests: callers might accidentally include credentials.
    return nil;
  }
}


static NSUInteger DOLAccountRevision = 0;
static NSUInteger DOLSessionAccountRevision = 0;

static NSDictionary* DOLAccountQuery(void) {
  NSString* bundle = NSBundle.mainBundle.bundleIdentifier ?: @"neostation";
  return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: [bundle stringByAppendingString:@".dolphin.retroachievements"],
    (__bridge id)kSecAttrAccount: @"emulator-player"};
}

static BOOL DOLValidCredentials(id value) {
  if (![value isKindOfClass:NSDictionary.class]) return NO;
  id user = value[@"username"], token = value[@"token"];
  return [user isKindOfClass:NSString.class] && [user length] > 0 && [user length] <= 256 &&
      [token isKindOfClass:NSString.class] && [token length] > 0 && [token length] <= 4096;
}

static BOOL DOLSaveCredentials(NSDictionary* credentials) {
  if (!DOLValidCredentials(credentials)) return NO;
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:credentials options:0 error:&error];
  if (!data || error) return NO;
  NSDictionary* attributes = @{(__bridge id)kSecValueData: data,
    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)DOLAccountQuery(),
                                  (__bridge CFDictionaryRef)attributes);
  if (status == errSecItemNotFound) {
    NSMutableDictionary* item = [DOLAccountQuery() mutableCopy];
    [item addEntriesFromDictionary:attributes];
    status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
  }
  if (status != errSecSuccess) return NO;
  @synchronized(DolphinRetroAchievementsAccount.class) { ++DOLAccountRevision; }
  return YES;
}

@interface DolphinRetroAchievementsAccount ()
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* labels;
@property(nonatomic, strong) UITextField* usernameField;
@property(nonatomic, strong) UITextField* passwordField;
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong) UIButton* linkButton;
@property(nonatomic, strong) UIButton* unlinkButton;
@property(nonatomic, strong, nullable) NSURLSession* session;
@property(nonatomic, strong, nullable) NSURLSessionDataTask* task;
@property(nonatomic, assign) NSUInteger requestGeneration;
@property(nonatomic, assign) BOOL busy;
@end

@implementation DolphinRetroAchievementsAccount

+ (NSDictionary<NSString*, NSString*>*)credentials {
  NSMutableDictionary* query = [DOLAccountQuery() mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  id data = CFBridgingRelease(result);
  if (status != errSecSuccess || ![data isKindOfClass:NSData.class]) return nil;
  id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return DOLValidCredentials(decoded) ? decoded : nil;
}

+ (void)beginSession {
  @synchronized(self) { DOLSessionAccountRevision = DOLAccountRevision; }
}

+ (BOOL)hasPendingChanges {
  @synchronized(self) { return DOLAccountRevision != DOLSessionAccountRevision; }
}

+ (NSURLRequest*)loginRequestForUsername:(NSString*)username password:(NSString*)password {
  if (![username isKindOfClass:NSString.class] || ![password isKindOfClass:NSString.class]) return nil;
  NSString* user = [username stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!user.length || user.length > 256 || !password.length || password.length > 4096) return nil;
  NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
  NSString* body = [NSString stringWithFormat:@"r=login2&u=%@&p=%@",
      [user stringByAddingPercentEncodingWithAllowedCharacters:allowed],
      [password stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:
      [NSURL URLWithString:@"https://retroachievements.org/dorequest.php"]
      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
  request.HTTPMethod = @"POST";
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  [request setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"NeoStation-iOS/267 (Dolphin account login)" forHTTPHeaderField:@"User-Agent"];
  return request;
}

+ (NSDictionary<NSString*, NSString*>*)credentialsFromResponse:(NSData*)data {
  if (![data isKindOfClass:NSData.class] || !data.length || data.length > 65536) return nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![json isKindOfClass:NSDictionary.class] ||
      ![json[@"Success"] isKindOfClass:NSNumber.class] || ![json[@"Success"] boolValue]) return nil;
  NSDictionary* value = @{@"username": json[@"User"] ?: NSNull.null,
                          @"token": json[@"Token"] ?: NSNull.null};
  return DOLValidCredentials(value) ? value : nil;
}

- (instancetype)initWithLabels:(NSDictionary<NSString*, NSString*>*)labels {
  self = [super initWithNibName:nil bundle:nil];
  if (self) _labels = [labels copy];
  return self;
}

- (NSString*)text:(NSString*)key { return self.labels[key] ?: key; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = [self text:@"raAccount"];
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  UIScrollView* scroll = [UIScrollView new];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  [self.view addSubview:scroll];
  UIStackView* form = [UIStackView new];
  form.axis = UILayoutConstraintAxisVertical;
  form.spacing = 16;
  form.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:form];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    [form.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
    [form.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
    [form.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
    [form.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
    [form.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
  ]];
  UILabel* help = [UILabel new];
  help.text = [self text:@"raLoginHelp"];
  help.numberOfLines = 0;
  help.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  help.adjustsFontForContentSizeCategory = YES;
  [form addArrangedSubview:help];
  self.usernameField = [UITextField new];
  self.usernameField.placeholder = [self text:@"raUsername"];
  self.usernameField.accessibilityLabel = self.usernameField.placeholder;
  self.usernameField.textContentType = UITextContentTypeUsername;
  self.usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
  self.usernameField.borderStyle = UITextBorderStyleRoundedRect;
  self.usernameField.text = [DolphinRetroAchievementsAccount credentials][@"username"] ?: @"";
  [form addArrangedSubview:self.usernameField];
  self.passwordField = [UITextField new];
  self.passwordField.placeholder = [self text:@"raPassword"];
  self.passwordField.accessibilityLabel = self.passwordField.placeholder;
  self.passwordField.textContentType = UITextContentTypePassword;
  self.passwordField.secureTextEntry = YES;
  self.passwordField.autocorrectionType = UITextAutocorrectionTypeNo;
  self.passwordField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.passwordField.borderStyle = UITextBorderStyleRoundedRect;
  [form addArrangedSubview:self.passwordField];
  self.linkButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.linkButton setTitle:[self text:@"raLink"] forState:UIControlStateNormal];
  self.linkButton.configuration = UIButtonConfiguration.filledButtonConfiguration;
  [self.linkButton addTarget:self action:@selector(linkAccount) forControlEvents:UIControlEventTouchUpInside];
  [form addArrangedSubview:self.linkButton];
  self.unlinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.unlinkButton setTitle:[self text:@"raUnlink"] forState:UIControlStateNormal];
  [self.unlinkButton addTarget:self action:@selector(unlinkAccount) forControlEvents:UIControlEventTouchUpInside];
  self.unlinkButton.enabled = [DolphinRetroAchievementsAccount credentials] != nil;
  [form addArrangedSubview:self.unlinkButton];
  self.statusLabel = [UILabel new];
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  self.statusLabel.adjustsFontForContentSizeCategory = YES;
  self.statusLabel.accessibilityIdentifier = @"dolphin.ra.status";
  [form addArrangedSubview:self.statusLabel];
}

- (void)setOperationBusy:(BOOL)busy {
  self.busy = busy;
  self.linkButton.enabled = !busy;
  self.usernameField.enabled = !busy;
  self.passwordField.enabled = !busy;
  self.unlinkButton.enabled = !busy && [DolphinRetroAchievementsAccount credentials] != nil;
}

- (void)showStatus:(NSString*)key {
  self.statusLabel.text = [self text:key];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.statusLabel.text);
}

- (void)linkAccount {
  if (self.busy) return;
  NSURLRequest* request = [DolphinRetroAchievementsAccount
      loginRequestForUsername:self.usernameField.text ?: @"" password:self.passwordField.text ?: @""];
  if (!request) { [self showStatus:@"raLoginFailed"]; return; }
  self.passwordField.text = @""; // Never persist the password, even after a failed request.
  [self.view endEditing:YES];
  [self setOperationBusy:YES];
  [self showStatus:@"raLoginBusy"];
  const NSUInteger generation = ++self.requestGeneration;
  NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.HTTPCookieStorage = nil;
  configuration.URLCache = nil;
  configuration.HTTPShouldSetCookies = NO;
  configuration.timeoutIntervalForRequest = 30;
  configuration.timeoutIntervalForResource = 30;
  self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
  __weak DolphinRetroAchievementsAccount* weakSelf = self;
  self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      DolphinRetroAchievementsAccount* screen = weakSelf;
      if (!screen || generation != screen.requestGeneration ||
          screen.navigationController.topViewController != screen) return;
      [screen.session finishTasksAndInvalidate];
      screen.session = nil;
      screen.task = nil;
      [screen setOperationBusy:NO];
      if (error || ![response isKindOfClass:NSHTTPURLResponse.class]) {
        [screen showStatus:@"raNetworkFailed"]; return;
      }
      NSInteger status = ((NSHTTPURLResponse*)response).statusCode;
      if (status < 200 || status >= 300) {
        [screen showStatus:status == 401 || status == 403 ? @"raLoginFailed" : @"raNetworkFailed"]; return;
      }
      NSDictionary* credentials = [DolphinRetroAchievementsAccount credentialsFromResponse:data];
      if (!credentials) { [screen showStatus:@"raLoginFailed"]; return; }
      if (!DOLSaveCredentials(credentials)) { [screen showStatus:@"raStorageFailed"]; return; }
      screen.usernameField.text = credentials[@"username"];
      [screen setOperationBusy:NO];
      [screen showStatus:@"raLinked"];
    });
  }];
  [self.task resume];
}

- (void)unlinkAccount {
  if (self.busy) return;
  OSStatus status = SecItemDelete((__bridge CFDictionaryRef)DOLAccountQuery());
  if (status != errSecSuccess && status != errSecItemNotFound) {
    [self showStatus:@"raStorageFailed"]; return;
  }
  @synchronized(DolphinRetroAchievementsAccount.class) { ++DOLAccountRevision; }
  self.usernameField.text = @"";
  self.passwordField.text = @"";
  [self setOperationBusy:NO];
  [self showStatus:@"raUnlinked"];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  ++self.requestGeneration;
  [self.task cancel];
  [self.session invalidateAndCancel];
  self.task = nil;
  self.session = nil;
  self.passwordField.text = @"";
  [self setOperationBusy:NO];
}

// Never redirect a password-bearing request to another URL or downgrade TLS.
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request
    completionHandler:(void (^)(NSURLRequest* _Nullable))completionHandler {
  completionHandler(nil);
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
