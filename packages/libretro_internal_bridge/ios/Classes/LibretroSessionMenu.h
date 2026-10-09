#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class LibretroMenuPage;

/// One row of the in-game menu. Every title comes from NeoStation's Dart
/// catalogs, already translated for the current locale.
@interface LibretroMenuRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *detail;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, assign) BOOL disclosure;
@property(nonatomic, assign) BOOL checked;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL isToggle;
@property(nonatomic, assign) BOOL toggleOn;
@property(nonatomic, copy, nullable) NSString *identifier;
@property(nonatomic, copy, nullable) void (^action)(LibretroMenuPage *page);
@property(nonatomic, copy, nullable) void (^toggle)(LibretroMenuPage *page, BOOL on);
@property(nonatomic, copy, nullable) void (^remove)(LibretroMenuPage *page);
+ (instancetype)rowWithTitle:(NSString *)title action:(nullable void (^)(LibretroMenuPage *page))action;
+ (instancetype)toggleWithTitle:(NSString *)title
                             on:(BOOL)on
                         toggle:(void (^)(LibretroMenuPage *page, BOOL on))toggle;
@end

@interface LibretroMenuSection : NSObject
@property(nonatomic, copy, nullable) NSString *title;
@property(nonatomic, copy, nullable) NSString *footer;
@property(nonatomic, copy) NSArray<LibretroMenuRow *> *rows;
+ (instancetype)sectionWithTitle:(nullable NSString *)title rows:(NSArray<LibretroMenuRow *> *)rows;
@end

/// A page of the in-game menu: dark inset-grouped table whose content is
/// rebuilt from `builder` every time it appears or is reloaded.
@interface LibretroMenuPage : UITableViewController
@property(nonatomic, copy) NSArray<LibretroMenuSection *> * (^builder)(void);
@property(nonatomic, copy, nullable) dispatch_block_t closeHandler;
@property(nonatomic, copy, nullable) NSString *closeTitle;
- (instancetype)initWithTitle:(NSString *)title builder:(NSArray<LibretroMenuSection *> * (^)(void))builder;
- (void)rebuild;
- (void)push:(LibretroMenuPage *)page;
- (void)confirmWithTitle:(NSString *)title
                 message:(nullable NSString *)message
                  action:(NSString *)action
             cancelTitle:(NSString *)cancel
             destructive:(BOOL)destructive
                 handler:(dispatch_block_t)handler;
- (void)askWithTitle:(NSString *)title
              fields:(NSArray<NSString *> *)placeholders
              secure:(NSArray<NSNumber *> *)secure
              action:(NSString *)action
         cancelTitle:(NSString *)cancel
             handler:(void (^)(NSArray<NSString *> *values))handler;
@end

NS_ASSUME_NONNULL_END
