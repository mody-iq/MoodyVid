#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One visited page.
@interface MVBrowserEntry : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) NSTimeInterval visitedAt;
@property (nonatomic) BOOL favorite;
@end

/// Browsing history and favorites for the in-app browser, persisted as JSON in
/// Documents so both lists survive a restart.
@interface MVBrowserHistory : NSObject

+ (instancetype)shared;

/// Most recent first, capped so the file cannot grow without bound.
@property (nonatomic, readonly) NSArray<MVBrowserEntry *> *history;

/// Favorites, most recently saved first.
@property (nonatomic, readonly) NSArray<MVBrowserEntry *> *favorites;

/// Records a visit. Re-visiting a page moves it to the top instead of adding a
/// second row, which is what a history list should look like.
- (void)record:(nullable NSString *)url title:(nullable NSString *)title;

- (BOOL)isFavorite:(nullable NSString *)url;
- (void)setFavorite:(nullable NSString *)url title:(nullable NSString *)title favorite:(BOOL)favorite;

- (void)remove:(MVBrowserEntry *)entry;
- (void)clearHistory;

@end

NS_ASSUME_NONNULL_END
