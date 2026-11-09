#import "MVSnifferStore.h"
#import "MVLog.h"

NSString *const MVSnifferStoreDidChangeNotification = @"MVSnifferStoreDidChangeNotification";

/// A cap per tab so a pathological page (an infinite gallery) cannot grow the
/// list without bound. 300 is far more than a user will ever pick from.
static const NSUInteger kMaxItemsPerTab = 300;

@implementation MVSnifferStore {
    NSMutableDictionary<NSString *, NSMutableArray<MVSnifferItem *> *> *_tabs;
}

+ (instancetype)shared {
    static MVSnifferStore *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVSnifferStore new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _tabs = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)keyForTab:(NSString *)tabID {
    return tabID.length ? tabID : @"default";
}

- (BOOL)addItem:(MVSnifferItem *)item toTab:(NSString *)tabID {
    if (!item.url.length) return NO;
    NSString *key = [self keyForTab:tabID];
    NSMutableArray<MVSnifferItem *> *list = _tabs[key];
    if (!list) {
        list = [NSMutableArray array];
        _tabs[key] = list;
    }

    for (NSUInteger i = 0; i < list.count; i++) {
        MVSnifferItem *existing = list[i];
        if (![existing.url isEqualToString:item.url]) continue;
        // Already known: keep the entry (and its probe result) but move it to the
        // top, which is what "most recently seen" should mean. Only fill in
        // details the older report lacked.
        if (!existing.mimeType.length && item.mimeType.length) existing.mimeType = item.mimeType;
        if (!existing.suggestedFilename.length && item.suggestedFilename.length) {
            existing.suggestedFilename = item.suggestedFilename;
        }
        if (i != 0) {
            [list removeObjectAtIndex:i];
            [list insertObject:existing atIndex:0];
            [self announce:key];
        }
        return NO;
    }

    [list insertObject:item atIndex:0];
    while (list.count > kMaxItemsPerTab) [list removeLastObject];
    [self announce:key];
    return YES;
}

- (void)updateItem:(MVSnifferItem *)item inTab:(NSString *)tabID {
    if (!item) return;
    NSString *key = [self keyForTab:tabID];
    NSMutableArray<MVSnifferItem *> *list = _tabs[key];
    NSUInteger index = [list indexOfObjectPassingTest:^BOOL(MVSnifferItem *candidate, NSUInteger i, BOOL *stop) {
        return [candidate.url isEqualToString:item.url];
    }];
    if (index == NSNotFound) return;
    list[index] = item;
    [self announce:key];
}

- (NSArray<MVSnifferItem *> *)itemsForTab:(NSString *)tabID {
    return [_tabs[[self keyForTab:tabID]] copy] ?: @[];
}

- (NSUInteger)countForTab:(NSString *)tabID {
    return _tabs[[self keyForTab:tabID]].count;
}

- (MVSnifferItem *)itemForURL:(NSString *)url inTab:(NSString *)tabID {
    if (!url.length) return nil;
    for (MVSnifferItem *item in _tabs[[self keyForTab:tabID]]) {
        if ([item.url isEqualToString:url]) return item;
    }
    return nil;
}

- (void)clearTab:(NSString *)tabID {
    NSString *key = [self keyForTab:tabID];
    [_tabs removeObjectForKey:key];
    [self announce:key];
}

- (void)clearAll {
    NSArray<NSString *> *keys = _tabs.allKeys;
    [_tabs removeAllObjects];
    for (NSString *key in keys) [self announce:key];
}

- (void)announce:(NSString *)tabID {
    MVLogInfo(@"sniffer: %lu item(s) in tab %@", (unsigned long)_tabs[tabID].count, tabID);
    [NSNotificationCenter.defaultCenter postNotificationName:MVSnifferStoreDidChangeNotification
                                                      object:tabID];
}

@end
