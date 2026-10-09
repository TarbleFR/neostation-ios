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
/// Optional preview drawn at the leading edge (skin pickers). When
/// `imageLoader` is set the cell shows a placeholder of `imageSize` and the
/// loader delivers the image asynchronously (on the main queue).
@property(nonatomic, strong, nullable) UIImage *image;
@property(nonatomic, assign) CGSize imageSize;
@property(nonatomic, copy, nullable) void (^imageLoader)(void (^deliver)(UIImage *_Nullable image));
/// VoiceOver label of the cell when it differs from the title.
@property(nonatomic, copy, nullable) NSString *spokenLabel;
/// Slider rows (shader parameters, opacity), drawn by a dedicated cell (a
/// UISlider below the title, full width). The value is snapped to `step`;
/// the detail label is updated in place through `valueFormatter` while
/// dragging (no table reload during a drag); `sliderChanged` gets
/// finished = NO while dragging and YES once on release (persist then). The
/// VoiceOver value comes from `valueFormatter` and increments follow `step`.
@property(nonatomic, assign) BOOL isSlider;
@property(nonatomic, assign) float sliderValue;
@property(nonatomic, assign) float sliderMinimum;
@property(nonatomic, assign) float sliderMaximum;
@property(nonatomic, assign) float sliderStep;
@property(nonatomic, copy, nullable) NSString * (^valueFormatter)(float value);
@property(nonatomic, copy, nullable) void (^sliderChanged)(LibretroMenuPage *page, float value, BOOL finished);
+ (instancetype)rowWithTitle:(NSString *)title action:(nullable void (^)(LibretroMenuPage *page))action;
+ (instancetype)toggleWithTitle:(NSString *)title
                             on:(BOOL)on
                         toggle:(void (^)(LibretroMenuPage *page, BOOL on))toggle;
+ (instancetype)sliderWithTitle:(NSString *)title
                          value:(float)value
                        minimum:(float)minimum
                        maximum:(float)maximum
                           step:(float)step
                      formatter:(NSString * (^)(float value))formatter
                        changed:(void (^)(LibretroMenuPage *page, float value, BOOL finished))changed;
@end

@interface LibretroMenuSection : NSObject
@property(nonatomic, copy, nullable) NSString *title;
@property(nonatomic, copy, nullable) NSString *footer;
@property(nonatomic, copy) NSArray<LibretroMenuRow *> *rows;
+ (instancetype)sectionWithTitle:(nullable NSString *)title rows:(NSArray<LibretroMenuRow *> *)rows;
@end

/// Navigation controller of the in-game menu: supportedInterfaceOrientations
/// returns LibretroOrientationGameMask() (portrait and landscape) instead of
/// forcing landscape; its view background is clear so pages that preview
/// the game can show it.
@interface LibretroMenuNavigationController : UINavigationController
@end

/// A page of the in-game menu: dark inset-grouped table whose content is
/// rebuilt from `builder` every time it appears or is reloaded. Titles and
/// details wrap on several lines so long translations stay readable.
@interface LibretroMenuPage : UITableViewController
@property(nonatomic, copy) NSArray<LibretroMenuSection *> * (^builder)(void);
/// Pages whose changes are visible on the game (Format d'écran, Shaders,
/// Disposition des écrans, Skins): the table background is transparent,
/// cells are 85 % opaque, and the table only covers the trailing half of
/// the screen in landscape (bottom half in portrait), so the redrawn game
/// stays visible.
@property(nonatomic, assign) BOOL previewsGame;
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
