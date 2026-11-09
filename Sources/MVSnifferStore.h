#import <Foundation/Foundation.h>
#import "MVSnifferItem.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted when the set of sniffed items for a tab changes, so the sheet and the
/// badge can refresh. The notification's object is the tab identifier.
extern NSString *const MVSnifferStoreDidChangeNotification;

/// Holds the media/file links found in each browser tab.
///
/// One tab = one ordered, de-duplicated list, newest first. The store is shared
/// so the browser, the download sheet and the badge all read the same truth. It
/// is only ever touched on the main thread (the sniffer's message handler runs
/// there), so it needs no lock.
@interface MVSnifferStore : NSObject

+ (instancetype)shared;

/// Adds an item to a tab. Returns YES when it was new. An existing URL is moved
/// to the top instead of being added twice, and its MIME/size are refreshed when
/// the new report carries better information.
- (BOOL)addItem:(MVSnifferItem *)item toTab:(NSString *)tabID;

/// Replaces an existing item in place (used when a probe fills in size/type).
- (void)updateItem:(MVSnifferItem *)item inTab:(NSString *)tabID;

/// The tab's items, newest first.
- (NSArray<MVSnifferItem *> *)itemsForTab:(NSString *)tabID;

/// How many items the tab has (drives the badge).
- (NSUInteger)countForTab:(NSString *)tabID;

/// The item with this URL, or nil.
- (nullable MVSnifferItem *)itemForURL:(NSString *)url inTab:(NSString *)tabID;

- (void)clearTab:(NSString *)tabID;

/// Drops every list; used when the browser's data is cleared.
- (void)clearAll;

@end

NS_ASSUME_NONNULL_END
