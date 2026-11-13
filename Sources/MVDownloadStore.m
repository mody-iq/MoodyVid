#import "MVDownloadStore.h"
#import "MVPaths.h"
#include <math.h>

NSString *const MVDownloadStoreDidChangeNotification = @"MVDownloadStoreDidChangeNotification";

static NSString *MVRecordString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSNumber *MVRecordNumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : @0;
}

@implementation MVDownloadRecord

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    MVDownloadRecord *r = [MVDownloadRecord new];
    NSString *identifier = MVRecordString(dict[@"id"]);
    r.identifier = identifier.length ? identifier : NSUUID.UUID.UUIDString;
    r.url = MVRecordString(dict[@"url"]) ?: @"";
    r.title = MVRecordString(dict[@"title"]) ?: @"";
    r.path = MVRecordString(dict[@"path"]);
    r.quality = MVRecordString(dict[@"quality"]) ?: @"best";
    r.error = MVRecordString(dict[@"error"]);
    id rawState = dict[@"state"];
    double state = [rawState isKindOfClass:NSNumber.class] ? [rawState doubleValue] : NAN;
    r.state = isfinite(state) && floor(state) == state && state >= MVPythonWaiting && state <= MVPythonPaused ?
              (MVDownloadState)(NSInteger)state : MVDownloadStateFailed;
    r.progress = MAX(0.0, MIN(1.0, MVRecordNumber(dict[@"progress"]).doubleValue));
    r.totalBytes = MAX(0LL, MVRecordNumber(dict[@"total"]).longLongValue);
    r.createdAt = MVRecordNumber(dict[@"createdAt"]).doubleValue;
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

- (BOOL)isActive { return self.state == MVDownloadStateActive || self.state == MVDownloadStateWaiting || self.state == MVDownloadStatePaused; }
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
    BOOL recoveredInterruptedRecords = NO;
    BOOL normalizedIdentifiers = NO;
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (NSDictionary *d in raw) {
        if (![d isKindOfClass:NSDictionary.class]) continue;
        MVDownloadRecord *r = [MVDownloadRecord fromDictionary:d];
        if (!r.url.length) continue;
        id rawIdentifier = d[@"id"];
        if (![rawIdentifier isKindOfClass:NSString.class] || ![rawIdentifier isEqualToString:r.identifier])
            normalizedIdentifiers = YES;
        if ([identifiers containsObject:r.identifier]) {
            do { r.identifier = NSUUID.UUID.UUIDString; } while ([identifiers containsObject:r.identifier]);
            normalizedIdentifiers = YES;
        }
        [identifiers addObject:r.identifier];
        // A process cannot still be downloading after relaunch. Requeue only
        // interrupted work; a manual pause or cancellation remains intentional.
        MVDownloadState recovered = (MVDownloadState)MVPythonStateAfterRestart((int)r.state);
        if (recovered != r.state) {
            r.state = recovered;
            r.error = nil;
            r.speed = 0;
            r.eta = 0;
            recoveredInterruptedRecords = YES;
        }
        // Drop finished records whose file has since been deleted.
        if (r.state == MVDownloadStateCompleted && r.path.length &&
            ![[NSFileManager defaultManager] fileExistsAtPath:r.path]) {
            continue;
        }
        [_records addObject:r];
    }
    if (recoveredInterruptedRecords || normalizedIdentifiers) [self save];
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
