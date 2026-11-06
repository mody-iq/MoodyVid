#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The app shell: four tabs (Home, Downloads, Files, Settings).
///
/// Re-reads its titles and colours when the language or theme changes, so a
/// switch takes effect without a restart.
@interface MVTabBarController : UITabBarController

@end

NS_ASSUME_NONNULL_END
