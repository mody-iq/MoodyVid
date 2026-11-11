#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The round accent button that floats above the bottom of a screen and opens a
/// small menu of "add" actions.
///
/// Used on Downloads (and reused on Home) so both screens grow the same way. The
/// button sits above the tab bar; the caller pins it and supplies the actions.
@interface MVFloatingAddButton : UIButton

+ (instancetype)button;

/// The menu actions to show, in order. Each is `@[title, symbolName, handler]`.
/// Rebuilding the menu is done by setting this property.
- (void)setActions:(NSArray<NSArray *> *)actions;

/// Adds a light pulse, used when something new is detected and the user's
/// attention is wanted. Respects Reduce Motion.
- (void)pulse;

@end

NS_ASSUME_NONNULL_END
