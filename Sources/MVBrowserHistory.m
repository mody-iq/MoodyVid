#import "MVBrowserHistory.h"
#import "MVPaths.h"

static const NSUInteger kMaxHistory = 300;

@implementation MVBrowserEntry

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    MVBrowserEntry *e = [MVBrowserEntry new];
    e.url = dict[@"url"] ?: @"";
    e.title = dict[@"title"] ?: @"";
    e.visitedAt = [dict[@"visitedAt"] doubleValue];
    e.favorite = [dict[@"favorite"] boolValue];
    return e;
}

- (NSDictionary *)dictionary {
    return @{@"url": self.url ?: @"",
             @"title": self.title ?: @"",
             @"visitedAt": @(self.visitedAt),
             @"favorite": @(self.favorite)};
}

@end

@implementation MVBrowserHistory {
    NSMutableArray<MVBrowserEntry *> *_entries;
    NSLock *_lock;
}

+ (instancetype)shared {
    static MVBrowserHistory *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVBrowserHistory new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _entries = [NSMutableArray array];
        [self load];
    }
    return self;
}

- (NSString *)storePath {
    return [[MVPaths documents] stringByAppendingPathComponent:@"browser.json"];
}

- (void)load {
    NSData *data = [NSData dataWithContentsOfFile:[self storePath]];
    if (!data.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) return;
    for (NSDictionary *dict in json) {
        if ([dict isKindOfClass:NSDictionary.class]) [_entries addObject:[MVBrowserEntry fromDictionary:dict]];
    }
}

- (void)save {
    NSMutableArray *out = [NSMutableArray array];
    for (MVBrowserEntry *e in _entries) [out addObject:[e dictionary]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    [data writeToFile:[self storePath] atomically:YES];
}

- (NSArray<MVBrowserEntry *> *)history {
    [_lock lock];
    NSArray *copy = [_entries copy];
    [_lock unlock];
    return copy;
}

- (NSArray<MVBrowserEntry *> *)favorites {
    NSMutableArray *out = [NSMutableArray array];
    for (MVBrowserEntry *e in [self history]) if (e.favorite) [out addObject:e];
    return out;
}

- (void)record:(NSString *)url title:(NSString *)title {
    if (!url.length || [url hasPrefix:@"about:"] || [url hasPrefix:@"data:"]) return;
    [_lock lock];
    MVBrowserEntry *existing = nil;
    for (MVBrowserEntry *e in _entries) {
        if ([e.url isEqualToString:url]) { existing = e; break; }
    }
    if (existing) {
        [_entries removeObject:existing];
        if (title.length) existing.title = title;
        existing.visitedAt = NSDate.date.timeIntervalSince1970;
        [_entries insertObject:existing atIndex:0];
    } else {
        MVBrowserEntry *e = [MVBrowserEntry new];
        e.url = url;
        e.title = title.length ? title : url;
        e.visitedAt = NSDate.date.timeIntervalSince1970;
        [_entries insertObject:e atIndex:0];
    }
    while (_entries.count > kMaxHistory) [_entries removeLastObject];
    [_lock unlock];
    [self save];
}

- (MVBrowserEntry *)entryFor:(NSString *)url {
    for (MVBrowserEntry *e in _entries) if ([e.url isEqualToString:url]) return e;
    return nil;
}

- (BOOL)isFavorite:(NSString *)url {
    if (!url.length) return NO;
    return [self entryFor:url].favorite;
}

- (void)setFavorite:(NSString *)url title:(NSString *)title favorite:(BOOL)favorite {
    if (!url.length) return;
    [_lock lock];
    MVBrowserEntry *e = [self entryFor:url];
    if (!e) {
        e = [MVBrowserEntry new];
        e.url = url;
        e.title = title.length ? title : url;
        e.visitedAt = NSDate.date.timeIntervalSince1970;
        [_entries insertObject:e atIndex:0];
    }
    e.favorite = favorite;
    [_lock unlock];
    [self save];
}

- (void)remove:(MVBrowserEntry *)entry {
    if (!entry) return;
    [_lock lock];
    [_entries removeObject:entry];
    [_lock unlock];
    [self save];
}

- (void)clearHistory {
    [_lock lock];
    // Clearing history keeps favorites, which the user saved on purpose.
    NSMutableArray *keep = [NSMutableArray array];
    for (MVBrowserEntry *e in _entries) if (e.favorite) [keep addObject:e];
    _entries = keep;
    [_lock unlock];
    [self save];
}

@end
