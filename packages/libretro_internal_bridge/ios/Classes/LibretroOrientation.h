#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lets an embedded libretro game rotate to portrait although NeoStation's
/// Info.plist and Flutter screens are landscape only, without changing the
/// Info.plist, lib/main.dart or the other engines.
///
/// Installation happens in +load of the bridge (a dynamic framework loaded
/// before UIApplicationMain), i.e. before UIKit assigns and caches the
/// application delegate: application:supportedInterfaceOrientationsForWindow:
/// is added to FlutterAppDelegate when it does not implement it (or wraps an
/// existing implementation of the delegate class). If FlutterAppDelegate is
/// not found at +load, `LibretroOrientationInstall()` (plugin registration)
/// installs it on the delegate's class and re-assigns the delegate
/// (delegate = nil, then back, keeping a strong reference) so UIKit
/// re-reads what it responds to.
///
/// While no game asks for more (mask 0) the method returns exactly what the
/// app supported before: the original implementation's value, else the
/// Info.plist UISupportedInterfaceOrientations(~ipad). While a libretro game
/// is shown it returns the game's mask.
///
/// Rules for the session: set the game mask BEFORE presenting the game view
/// controller and restore 0 only in the dismissal completion; never pass a
/// mask with nothing in common with the app's (the game defaults to
/// UIInterfaceOrientationMaskAllButUpsideDown); after a change call
/// setNeedsUpdateOfSupportedInterfaceOrientations on the game view
/// controller (in viewDidAppear too, so a phone already held in portrait
/// rotates) and on the window's root view controller. Do not call
/// requestGeometryUpdate.
FOUNDATION_EXPORT void LibretroOrientationInstall(void);

/// Mask requested by the libretro game on screen; 0 restores the app's
/// normal orientations. Main thread.
FOUNDATION_EXPORT void LibretroOrientationSetGameMask(UIInterfaceOrientationMask mask);
FOUNDATION_EXPORT UIInterfaceOrientationMask LibretroOrientationGameMask(void);
/// YES once the delegate method is in place (for diagnostics and tests).
FOUNDATION_EXPORT BOOL LibretroOrientationIsInstalled(void);

NS_ASSUME_NONNULL_END
