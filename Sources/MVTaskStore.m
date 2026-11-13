#import "MVTaskStore.h"
#import "MVDownloadManager.h"
#import "MVPaths.h"
#import "MVCookiePolicy.h"
#import "MVLog.h"

NSString *const MVTaskStoreDidChangeNotification = @"MVTaskStoreDidChangeNotification";

@implementation MVTaskStore {
    NSMutableArray<MVDownloadTask *> *_tasks;
    dispatch_queue_t _ioQueue;
}

+ (instancetype)shared {
    static MVTaskStore *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVTaskStore new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _tasks = [NSMutableArray array];
        _ioQueue = dispatch_queue_create("com.moodyvid.tasks", DISPATCH_QUEUE_SERIAL);
        [self load];
    }
    return self;
}

- (NSString *)storePath {
    return [[MVPaths applicationSupport] stringByAppendingPathComponent:@"tasks.json"];
}

#pragma mark - Load / save

- (void)load {
    NSData *data = [NSData dataWithContentsOfFile:[self storePath]];
    if (!data.length) return;

    id json = nil;
    @try {
        json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } @catch (NSException *e) {
        json = nil;
    }
    if (![json isKindOfClass:NSArray.class]) {
        // Corrupt file: start clean rather than crash on every launch. The bad
        // file is kept aside so it can still be inspected if a user reports it.
        MVLogError(@"tasks: corrupt store, resetting (%lu bytes)", (unsigned long)data.length);
        [[NSFileManager defaultManager] moveItemAtPath:[self storePath]
                                                toPath:[[self storePath] stringByAppendingPathExtension:@"bad"]
                                                 error:nil];
        return;
    }

    BOOL removedUnsafeHeaders = NO;
    BOOL recoveredInterruptedTasks = NO;
    BOOL normalizedIdentifiers = NO;
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (NSDictionary *dict in (NSArray *)json) {
        if (![dict isKindOfClass:NSDictionary.class]) continue;
        id rawHeaders = dict[@"headers"];
        if ([rawHeaders isKindOfClass:NSDictionary.class] &&
            [MVCookiePolicy headersWithoutCookies:rawHeaders].count != [rawHeaders count]) {
            removedUnsafeHeaders = YES;
        }
        MVDownloadTask *task = [MVDownloadTask taskFromDictionary:dict];
        if (!task.url.length) continue;
        id rawIdentifier = dict[@"id"];
        if (![rawIdentifier isKindOfClass:NSString.class] || ![rawIdentifier isEqualToString:task.identifier])
            normalizedIdentifiers = YES;
        if ([identifiers containsObject:task.identifier]) {
            do { task.identifier = NSUUID.UUID.UUIDString; } while ([identifiers containsObject:task.identifier]);
            normalizedIdentifiers = YES;
        }
        [identifiers addObject:task.identifier];

        // Only work interrupted while running is requeued. An explicit user
        // pause/cancel must remain in force across a process restart.
        MVTaskState recovered = (MVTaskState)MVNativeStateAfterRestart((int)task.state);
        if (recovered != task.state) {
            task.state = recovered;
            task.phase = nil;
            task.error = nil;
            task.speed = 0;
            task.eta = 0;
            recoveredInterruptedTasks = YES;
        }
        // A completed task whose file vanished is stale, so drop it.
        if (task.state == MVTaskStateCompleted && task.path.length &&
            ![[NSFileManager defaultManager] fileExistsAtPath:task.path]) {
            continue;
        }
        [_tasks addObject:task];
    }
    // Rewrite a legacy store once so a stale raw Cookie cannot survive a
    // browser-data clear or be replayed after a relaunch.
    if (removedUnsafeHeaders || recoveredInterruptedTasks || normalizedIdentifiers) [self save];
    MVLogInfo(@"tasks: loaded %lu record(s)", (unsigned long)_tasks.count);
}

- (void)save {
    // Snapshot on the caller's (main) thread, write on the I/O queue.
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_tasks.count];
    for (MVDownloadTask *task in _tasks) [out addObject:[task dictionary]];
    NSString *path = [self storePath];

    dispatch_async(_ioQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        if (!data) return;
        // Atomic write: a crash mid-write leaves the previous file intact.
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    });
}

#pragma mark - Access

- (NSArray<MVDownloadTask *> *)tasks {
    return [_tasks copy];
}

- (MVDownloadTask *)add:(MVDownloadTask *)task {
    if (!task) return nil;
    if (!task.identifier.length) task.identifier = NSUUID.UUID.UUIDString;
    if (!task.createdAt) task.createdAt = NSDate.date.timeIntervalSince1970;
    task.updatedAt = NSDate.date.timeIntervalSince1970;
    [_tasks insertObject:task atIndex:0];
    [self changed];
    return task;
}

- (void)update:(MVDownloadTask *)task {
    if (!task) return;
    task.updatedAt = NSDate.date.timeIntervalSince1970;
    if (![_tasks containsObject:task]) [_tasks insertObject:task atIndex:0];
    [self changed];
}

- (void)remove:(MVDownloadTask *)task {
    if (!task) return;
    [_tasks removeObjectIdenticalTo:task];
    [self changed];
}

- (MVDownloadTask *)taskWithIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;
    for (MVDownloadTask *task in _tasks) {
        if ([task.identifier isEqualToString:identifier]) return task;
    }
    return nil;
}

- (MVDownloadTask *)taskWithURL:(NSString *)url {
    if (!url.length) return nil;
    for (MVDownloadTask *task in _tasks) {
        if ([task matchesURL:url]) return task;
    }
    return nil;
}

- (void)moveToTop:(MVDownloadTask *)task {
    if (!task) return;
    [_tasks removeObjectIdenticalTo:task];
    [_tasks insertObject:task atIndex:0];
    [self changed];
}

- (NSArray<MVDownloadTask *> *)activeTasks {
    NSMutableArray *out = [NSMutableArray array];
    for (MVDownloadTask *task in _tasks) if (task.isActive) [out addObject:task];
    return out;
}

- (NSArray<MVDownloadTask *> *)finishedTasks {
    NSMutableArray *out = [NSMutableArray array];
    for (MVDownloadTask *task in _tasks) if (task.isFinished) [out addObject:task];
    return out;
}

- (void)pruneMissingFiles {
    NSMutableArray<MVDownloadTask *> *keep = [NSMutableArray array];
    for (MVDownloadTask *task in _tasks) {
        if (task.state == MVTaskStateCompleted && task.path.length &&
            ![[NSFileManager defaultManager] fileExistsAtPath:task.path]) {
            continue;
        }
        [keep addObject:task];
    }
    if (keep.count != _tasks.count) {
        _tasks = keep;
        [self changed];
    }
}

- (void)removeFinishedTasksDeletingFiles:(BOOL)deleteFiles {
    // Use the same cancellation, ownership and torrent-folder cleanup as the
    // individual row action. Iterate a snapshot because the manager removes.
    for (MVDownloadTask *task in [_tasks copy]) {
        if (task.isFinished) [MVDownloadManager.shared removeTask:task deleteFile:deleteFiles];
    }
}

- (void)changed {
    [self save];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:MVTaskStoreDidChangeNotification object:nil];
    });
}

@end
