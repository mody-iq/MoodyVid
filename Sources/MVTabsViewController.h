#import <UIKit/UIKit.h>
#import "MVBrowserTab.h"

NS_ASSUME_NONNULL_BEGIN

/// The tab switcher: a sheet of open tabs, each closing on its own button, plus
/// a "new tab" tile. Presenting it full height (rather than as a medium-detent
/// sheet with a visible Done-less header) is what makes it read as a switcher
/// rather than a stray panel.
@interface MVTabsViewController : UIViewController

- (instancetype)initWithTabs:(NSArray<MVBrowserTab *> *)tabs activeIdentifier:(NSString *)activeID;

@property (nonatomic, copy, nullable) void (^onSelect)(NSString *identifier);
@property (nonatomic, copy, nullable) void (^onClose)(NSString *identifier);
@property (nonatomic, copy, nullable) void (^onNewTab)(void);

@end

NS_ASSUME_NONNULL_END
