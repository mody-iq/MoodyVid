#import "MVDownloadStore.h"
#import "MVPaths.h"

NSString *const MVDownloadStoreDidChangeNotification = @"MVDownloadStoreDidChangeNotification";

@implementation MVDownloadRecord

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    MVDownloadRecord *r = [MVDownloadRecord new];
    r.identifier = dict[@"id"] ?: NSUUID.UUID.UUIDString;
    r.url = dict[@"url"] ?: @"";
    r.title = dict[@"title"] ?: @"";
    r.path = dict[@"path"];
    r.quality = dict[@"quality"] ?: @"best";
    r.error = dict[@"error"];
    r.state = (MVDownloadState)[dict[@"state"] integerValue];
    r.progress = [dict[@"progress"] doubleValue];
    r.totalBytes = [dict[@"total"] longLongValue];
    r.createdAt = [dict[@"createdAt"] doubleValue];
    return r;
}

- (NSDictionary *)dictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = self.identifier ?: @"";
    d[@"url"] = self.url ?: @"";
    d[@"title"] = self.title ?: @"";
    d[@"quality"] = self.quality ?: @"best";
    d[@"state"] = @(self.state);
    d[@"progress"] = @(self.progress);
    d[@"total"] = @(self.totalBytes);
    d[@"createdAt"] = @(self.createdAt);
    if (self.path) d[@"path"] = self.path;
    if (self.error) d[@"error"] = self.error;
    return d;
}

- (BOOL)isActive { return self.state == MVDownloadStateActive || self.state == MVDownloadStateWaiting; }
- (BOOL)isFinished { return self.state == MVDownloadStateCompleted || self.state == MVDownloadStateFailed || self.state == MVDownloadStateCancelled; }

@end

@implementation MVDownloadStore {
    NSMutableArray<MVDownloadRecord *> *_records;
    dispatch_queue_t _lock;
}

+ (instancetype)shared {
    static MVDownloadStore *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVDownloadStore new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = dispatch_queue_create("com.moodyvid.store", DISPATCH_QUEUE_SERIAL);
        _records = [NSMutableArray array];
        [self load];
    }
    return self;
}

- (NSString *)storePath {
    return [[MVPaths documents] stringByAppendingPathComponent:@"downloads.json"];
}

- (void)load {
    NSData *data = [NSData dataWithContentsOfFile:[self storePath]];
    if (!data) return;
    NSArray *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![raw isKindOfClass:NSArray.class]) return;
    for (NSDictionary *d in raw) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        MVDownloadRecord *r = [MVDownloadRecord fromDictionary:d];
        // A record that was mid-download when the app died can never resume, so
        // show it as cancelled rather than leaving a permanently "active" row.
        if (r.state == MVDownloadStateActive || r.state == MVDownloadStateWaiting) {
            r.state = MVDownloadStateCancelled;
            r.error = nil;
        }
        // Drop finished records whose file has since been deleted.
        if (r.state == MVDownloadStateCompleted && r.path.length &&
            ![[NSFileManager defaultManager] fileExistsAtPath:r.path]) {
            continue;
        }
        [_records addObject:r];
    }
}

- (NSArray<MVDownloadRecord *> *)records {
    __block NSArray *copy;
    dispatch_sync(_lock, ^{ copy = [_records copy]; });
    return copy;
}

- (MVDownloadRecord *)addURL:(NSString *)url quality:(NSString *)quality {
    MVDownloadRecord *r = [MVDownloadRecord new];
    r.identifier = NSUUID.UUID.UUIDString;
    r.url = url ?: @"";
    r.title = url ?: @"";
    r.quality = quality ?: @"best";
    r.state = MVDownloadStateWaiting;
    r.createdAt = NSDate.date.timeIntervalSince1970;
    dispatch_sync(_lock, ^{ [_records insertObject:r atIndex:0]; });
    [self changed];
    return r;
}

- (void)update:(MVDownloadRecord *)record {
    if (!record) return;
    dispatch_sync(_lock, ^{
        NSUInteger i = [self->_records indexOfObjectPassingTest:^BOOL(MVDownloadRecord *r, NSUInteger idx, BOOL *stop) {
            return [r.identifier isEqualToString:record.identifier];
        }];
        if (i == NSNotFound) [self->_records insertObject:record atIndex:0];
    });
    [self changed];
}

- (void)remove:(MVDownloadRecord *)record {
    if (!record) return;
    dispatch_sync(_lock, ^{
        NSArray *copy = [self->_records copy];
        for (MVDownloadRecord *r in copy) {
            if ([r.identifier isEqualToString:record.identifier]) [self->_records removeObject:r];
        }
    });
    [self changed];
}

- (NSArray<MVDownloadRecord *> *)activeRecords {
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(MVDownloadRecord *r, NSDictionary *b) { return r.isActive; }];
    return [[self records] filteredArrayUsingPredicate:p];
}

- (NSArray<MVDownloadRecord *> *)finishedRecords {
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(MVDownloadRecord *r, NSDictionary *b) { return r.isFinished; }];
    return [[self records] filteredArrayUsingPredicate:p];
}

- (void)changed {
    [self save];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:MVDownloadStoreDidChangeNotification object:nil];
    });
}

- (void)save {
    NSArray *dicts;
    NSMutableArray *tmp = [NSMutableArray array];
    for (MVDownloadRecord *r in self.records) [tmp addObject:[r dictionary]];
    dicts = tmp;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dicts options:0 error:nil];
    [data writeToFile:[self storePath] atomically:YES];
}

@end
