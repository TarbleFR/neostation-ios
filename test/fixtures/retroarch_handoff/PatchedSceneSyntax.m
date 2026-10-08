#import <UIKit/UIKit.h>
@interface RetroArch_iOS : NSObject
@property(nonatomic, retain) UIWindow *window;
+ (instancetype)get;
- (void)applicationDidBecomeActive:(UIApplication *)app;
- (void)applicationWillResignActive:(UIApplication *)app;
- (void)applicationDidEnterBackground:(UIApplication *)app;
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options;
@end
API_AVAILABLE(ios(13.0), tvos(13.0))
@interface RetroArchSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end
@implementation RetroArchSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
   RetroArch_iOS *app = [RetroArch_iOS get];
   app.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];

   [app.window makeKeyAndVisible];

   /* UIKit delivers a cold launch URL in connection options, not in the
    * existing-scene openURLContexts callback. Preserve it once and dispatch
    * after scene construction; the normal URL handler keeps all protocol
    * parsing and playlist/core resolution unchanged. */
   NSSet<UIOpenURLContext *> *initialURLs = connectionOptions.URLContexts;
   if (initialURLs.count)
      dispatch_async(dispatch_get_main_queue(), ^{
         [self scene:scene openURLContexts:initialURLs];
      });
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
   RetroArch_iOS *app = [RetroArch_iOS get];
   [app applicationDidBecomeActive:[UIApplication sharedApplication]];
}

- (void)sceneWillResignActive:(UIScene *)scene {
   RetroArch_iOS *app = [RetroArch_iOS get];
   [app applicationWillResignActive:[UIApplication sharedApplication]];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
   RetroArch_iOS *app = [RetroArch_iOS get];
   [app applicationDidEnterBackground:[UIApplication sharedApplication]];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
   RetroArch_iOS *app = [RetroArch_iOS get];
   for (UIOpenURLContext *urlContext in URLContexts) {
      [app application:(UIApplication *)app openURL:urlContext.URL options:@{}];
   }
}

@end
