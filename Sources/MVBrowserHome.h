#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One shortcut tile on the browser's home page.
@interface MVBrowserShortcut : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSString *color;   ///< "#RRGGBB"
+ (instancetype)name:(NSString *)name url:(NSString *)url symbol:(NSString *)symbol color:(NSString *)color;
- (NSDictionary *)dictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

@class MVBrowserHomeView;

@protocol MVBrowserHomeViewDelegate <NSObject>
- (void)homeView:(MVBrowserHomeView *)homeView didSelectURL:(NSString *)url title:(nullable NSString *)title;
- (void)homeViewDidRequestClearHistory:(MVBrowserHomeView *)homeView;
@end

/// The new-tab page: an editable shortcut grid, the saved bookmarks, and the
/// browsing history with a search field and a clear action.
///
/// It reads MVBrowserHistory for bookmarks/history and stores the shortcut grid
/// in NSUserDefaults, so the user's own tiles survive a restart. Everything is
/// built with plain stacks: the page is short, so a collection view would be
/// more machinery than it earns.
@interface MVBrowserHomeView : UIView

@property (nonatomic, weak, nullable) id<MVBrowserHomeViewDelegate> delegate;

/// The shortcuts, in display order. Defaults to the built-in site list.
+ (NSArray<MVBrowserShortcut *> *)shortcuts;
+ (void)setShortcuts:(NSArray<MVBrowserShortcut *> *)shortcuts;

/// Re-reads bookmarks/history and rebuilds. Called when the page appears.
- (void)reload;

/// The history filter text currently typed.
@property (nonatomic, copy) NSString *searchText;

@end

NS_ASSUME_NONNULL_END
