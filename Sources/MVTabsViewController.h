#import <UIKit/UIKit.h>
#import "MVBrowserTab.h"

NS_ASSUME_NONNULL_BEGIN

/// The tab switcher: a grid of open tabs, each closing on its own button, plus a
/// "new tab" tile. Presented as a sheet from the browser's toolbar.
@interface MVTabsViewController : UIViewController

- (instancetype)initWithTabs:(NSArray<MVBrowserTab *> *)tabs activeIdentifier:(NSString *)activeID;

@property (nonatomic, copy, nullable) void (^onSelect)(NSString *identifier);
@property (nonatomic, copy, nullable) void (^onClose)(NSString *identifier);
@property (nonatomic, copy, nullable) void (^onNewTab)(void);

@end

NS_ASSUME_NONNULL_END
