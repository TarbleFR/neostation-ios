#import "LibretroAchievements.h"

#import "LibretroCoreHost.h"

#import <Security/Security.h>

#include <stdatomic.h>

#include "rc_api_request.h"
#include "rc_client.h"
#include "rc_hash.h"
#include "rc_libretro.h"

static NSString *const kEnabledKey = @"libretro.achievements.enabled";
static NSString *const kKeychainAccount = @"emulator-player";

/// rc_libretro's memory-info callback carries no context pointer.
static __unsafe_unretained LibretroCoreHost *gAchievementHost = nil;

static NSString *KeychainService(void) {
  NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"neostation";
  return [bundle stringByAppendingString:@".libretro.retroachievements"];
}

static NSDictionary *KeychainQuery(void) {
  return @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : KeychainService(),
    (__bridge id)kSecAttrAccount : kKeychainAccount,
  };
}

static NSDictionary<NSString *, NSString *> *StoredLogin(void) {
  NSMutableDictionary *query = [KeychainQuery() mutableCopy];
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || result == NULL) return nil;
  NSData *data = (__bridge_transfer NSData *)result;
  NSDictionary *login = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![login isKindOfClass:NSDictionary.class]) return nil;
  NSString *username = login[@"username"];
  NSString *token = login[@"token"];
  if (![username isKindOfClass:NSString.class] || ![token isKindOfClass:NSString.class] || token.length == 0) {
    return nil;
  }
  return @{@"username" : username, @"token" : token};
}

static void StoreLogin(NSString *username, NSString *token) {
  SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"username" : username, @"token" : token} options:0 error:nil];
  if (data == nil) return;
  NSMutableDictionary *item = [KeychainQuery() mutableCopy];
  item[(__bridge id)kSecValueData] = data;
  item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
  SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}

static void ClearLogin(void) {
  SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
}

@implementation LibretroAchievements {
  rc_client_t *_client;
  rc_libretro_memory_regions_t _regions;
  BOOL _regionsReady;
  unsigned _consoleId;
  LibretroCoreHost *_host;
  NSURLSession *_urlSession;
  NSString *_userAgent;
  NSString *_contentPath;
  _Atomic bool _loadStarted;
  _Atomic bool _gameReady;
  _Atomic bool _shutdown;
  _Atomic unsigned _totalAchievements;
  _Atomic unsigned _unlockedAchievements;
}

+ (BOOL)enabled {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  return [defaults objectForKey:kEnabledKey] != nil ? [defaults boolForKey:kEnabledKey] : YES;
}

+ (void)setEnabled:(BOOL)enabled {
  [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabledKey];
}

+ (BOOL)hasStoredLogin {
  return StoredLogin() != nil;
}

#pragma mark - rcheevos callbacks

static void CoreMemoryInfo(uint32_t identifier, rc_libretro_core_memory_info_t *info) {
  size_t size = 0;
  info->data = (uint8_t *)[gAchievementHost memoryDataForIdentifier:identifier size:&size];
  info->size = info->data != NULL ? size : 0;
}

static uint32_t ReadMemory(uint32_t address, uint8_t *buffer, uint32_t count, rc_client_t *client) {
  LibretroAchievements *achievements = (__bridge LibretroAchievements *)rc_client_get_userdata(client);
  if (achievements == nil || !achievements->_regionsReady) return 0;
  return rc_libretro_memory_read(&achievements->_regions, address, buffer, count);
}

static void ServerCall(const rc_api_request_t *request, rc_client_server_callback_t callback, void *callbackData,
                       rc_client_t *client) {
  LibretroAchievements *achievements = (__bridge LibretroAchievements *)rc_client_get_userdata(client);
  NSURL *url = request->url != NULL ? [NSURL URLWithString:[NSString stringWithUTF8String:request->url]] : nil;
  if (achievements == nil || url == nil) {
    rc_api_server_response_t failure = {NULL, 0, RC_API_SERVER_RESPONSE_CLIENT_ERROR};
    callback(&failure, callbackData);
    return;
  }
  NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
  [urlRequest setValue:achievements->_userAgent forHTTPHeaderField:@"User-Agent"];
  if (request->post_data != NULL) {
    urlRequest.HTTPMethod = @"POST";
    urlRequest.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
    NSString *type = request->content_type != NULL ? [NSString stringWithUTF8String:request->content_type]
                                                   : @"application/x-www-form-urlencoded";
    [urlRequest setValue:type forHTTPHeaderField:@"Content-Type"];
  }
  NSURLSessionDataTask *task = [achievements->_urlSession
      dataTaskWithRequest:urlRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          if (atomic_load(&achievements->_shutdown)) return;
          rc_api_server_response_t serverResponse;
          memset(&serverResponse, 0, sizeof(serverResponse));
          serverResponse.body = data.bytes;
          serverResponse.body_length = data.length;
          if (error != nil) {
            serverResponse.http_status_code = RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;
          } else if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            serverResponse.http_status_code = (int)((NSHTTPURLResponse *)response).statusCode;
          } else {
            serverResponse.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
          }
          callback(&serverResponse, callbackData);
        }];
  [task resume];
}

static void EventHandler(const rc_client_event_t *event, rc_client_t *client) {
  LibretroAchievements *achievements = (__bridge LibretroAchievements *)rc_client_get_userdata(client);
  if (achievements == nil || event == NULL) return;
  if (event->type == RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED && event->achievement != NULL) {
    NSString *title = event->achievement->title != NULL ? [NSString stringWithUTF8String:event->achievement->title] : @"";
    [achievements refreshSummary];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (achievements.unlocked != nil) achievements.unlocked(title ?: @"");
    });
  }
}

static void GameLoaded(int result, const char *message, rc_client_t *client, void *userdata) {
  LibretroAchievements *achievements = (__bridge LibretroAchievements *)rc_client_get_userdata(client);
  if (achievements == nil || atomic_load(&achievements->_shutdown)) return;
  if (result == RC_OK) {
    atomic_store(&achievements->_gameReady, true);
    [achievements refreshSummary];
  } else {
    NSLog(@"[Libretro] RetroAchievements game not loaded (%d): %s", result, message ?: "");
  }
  [achievements notifyStateChanged];
}

static void TokenLogin(int result, const char *message, rc_client_t *client, void *userdata) {
  LibretroAchievements *achievements = (__bridge LibretroAchievements *)rc_client_get_userdata(client);
  if (achievements == nil || atomic_load(&achievements->_shutdown)) return;
  if (result == RC_OK) {
    [achievements loadGame];
  } else {
    NSLog(@"[Libretro] RetroAchievements token login failed (%d): %s", result, message ?: "");
  }
  [achievements notifyStateChanged];
}

static void PasswordLogin(int result, const char *message, rc_client_t *client, void *userdata) {
  void (^completion)(BOOL) = (__bridge_transfer void (^)(BOOL))userdata;
  LibretroAchievements *achievements = (__bridge LibretroAchievements *)rc_client_get_userdata(client);
  BOOL success = result == RC_OK && achievements != nil && !atomic_load(&achievements->_shutdown);
  if (success) {
    const rc_client_user_t *user = rc_client_get_user_info(client);
    if (user != NULL && user->username != NULL && user->token != NULL) {
      StoreLogin([NSString stringWithUTF8String:user->username], [NSString stringWithUTF8String:user->token]);
    }
    if ([LibretroAchievements enabled]) [achievements loadGame];
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (completion != nil) completion(success);
  });
}

#pragma mark - Lifecycle

- (instancetype)initWithConsoleId:(unsigned)consoleId host:(LibretroCoreHost *)host {
  self = [super init];
  if (self) {
    _consoleId = consoleId;
    _host = host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      rc_hash_init_default_cdreader();
    });
    _client = rc_client_create(ReadMemory, ServerCall);
    rc_client_set_userdata(_client, (__bridge void *)self);
    rc_client_set_event_handler(_client, EventHandler);
    rc_client_set_hardcore_enabled(_client, 0);
    char clause[128] = {0};
    rc_client_get_user_agent_clause(_client, clause, sizeof(clause));
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
    _userAgent = [NSString stringWithFormat:@"NeoStation/%@ %s", version, clause];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    _urlSession = [NSURLSession sessionWithConfiguration:configuration];
  }
  return self;
}

- (void)dealloc {
  [self shutdown];
}

- (void)notifyStateChanged {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.stateChanged != nil) self.stateChanged();
  });
}

- (void)refreshSummary {
  if (_client == NULL) return;
  rc_client_user_game_summary_t summary;
  memset(&summary, 0, sizeof(summary));
  rc_client_get_user_game_summary(_client, &summary);
  atomic_store(&_totalAchievements, summary.num_core_achievements);
  atomic_store(&_unlockedAchievements, summary.num_unlocked_achievements);
}

- (BOOL)loggedIn {
  return _client != NULL && rc_client_get_user_info(_client) != NULL;
}

- (NSString *)username {
  if (_client == NULL) return nil;
  const rc_client_user_t *user = rc_client_get_user_info(_client);
  if (user == NULL) return nil;
  const char *name = user->display_name != NULL ? user->display_name : user->username;
  return name != NULL ? [NSString stringWithUTF8String:name] : nil;
}

- (BOOL)gameLoaded {
  return atomic_load(&_gameReady);
}

- (unsigned)totalCount {
  return atomic_load(&_totalAchievements);
}

- (unsigned)unlockedCount {
  return atomic_load(&_unlockedAchievements);
}

- (void)prepareMemory {
  if (_regionsReady) return;
  unsigned count = 0;
  const struct retro_memory_descriptor *descriptors = [_host memoryDescriptors:&count];
  struct retro_memory_map map = {descriptors, count};
  gAchievementHost = _host;
  _regionsReady = rc_libretro_memory_init(&_regions, count > 0 ? &map : NULL, CoreMemoryInfo, _consoleId) != 0;
}

- (void)startWithContentPath:(NSString *)path {
  NSString *source = _host.loadedContentPath ?: path;
  _contentPath = [source copy];
  if (![LibretroAchievements enabled] || _client == NULL) return;
  [self prepareMemory];
  if (rc_client_get_user_info(_client) != NULL) {
    [self loadGame];
    return;
  }
  NSDictionary<NSString *, NSString *> *login = StoredLogin();
  if (login == nil) return;
  rc_client_begin_login_with_token(_client, login[@"username"].UTF8String, login[@"token"].UTF8String, TokenLogin, NULL);
}

- (void)loadGame {
  if (_client == NULL || _contentPath == nil || atomic_exchange(&_loadStarted, true)) return;
  rc_client_begin_identify_and_load_game(_client, _consoleId, _contentPath.fileSystemRepresentation, NULL, 0, GameLoaded,
                                         NULL);
}

- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(void (^)(BOOL success))completion {
  if (_client == NULL || username.length == 0 || password.length == 0) {
    if (completion != nil) completion(NO);
    return;
  }
  void *context = (__bridge_retained void *)[completion copy];
  rc_client_begin_login_with_password(_client, username.UTF8String, password.UTF8String, PasswordLogin, context);
}

- (void)logout {
  if (_client != NULL) rc_client_logout(_client);
  ClearLogin();
  atomic_store(&_gameReady, false);
  atomic_store(&_loadStarted, false);
  atomic_store(&_totalAchievements, 0);
  atomic_store(&_unlockedAchievements, 0);
}

- (void)doFrame {
  if (_client != NULL && atomic_load(&_gameReady)) rc_client_do_frame(_client);
}

- (void)idle {
  if (_client != NULL) rc_client_idle(_client);
}

- (void)resetGame {
  if (_client != NULL && atomic_load(&_gameReady)) rc_client_reset(_client);
}

- (void)shutdown {
  if (atomic_exchange(&_shutdown, true)) return;
  [_urlSession invalidateAndCancel];
  if (_client != NULL) {
    rc_client_destroy(_client);
    _client = NULL;
  }
  if (_regionsReady) {
    rc_libretro_memory_destroy(&_regions);
    _regionsReady = NO;
  }
  if (gAchievementHost == _host) gAchievementHost = nil;
}

@end
