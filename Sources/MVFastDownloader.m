#import "MVFastDownloader.h"
#import "MVPaths.h"
#import "MVFileProtection.h"
#import "MVMediaProbe.h"
#import "MVHTTPSession.h"
#import "MVByteRange.h"
#import "MVThrottle.h"
#import "MVLang.h"
#import "MVLog.h"
#include <limits.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/// How many times a dropped connection is retried before its segment fails.
/// Each retry resumes from the byte offset already on disk, so it is cheap.
static const NSInteger kMaxRetries = 3;
/// The throttle wakes this often. Small enough that a large file still streams,
/// large enough that the timer costs nothing.
static const NSTimeInterval kThrottleInterval = 0.25;
/// A file smaller than this is not worth splitting: the connection overhead
/// outweighs the gain, and the progress bar would jump in ugly steps.
static const long long kMinSegmentSize = 2 * 1024 * 1024;
/// A segment must be at least this large, so a huge connection count on a small
/// file is clamped instead of producing hundreds of tiny requests.
static const long long kMinBytesPerConnection = 512 * 1024;

/// The taskDescription index that marks the size/Range probe rather than a
/// segment.
static const NSInteger kProbeIndex = -1;

/// The state of one segment file. Held per connection.
typedef NS_ENUM(NSInteger, MVSegmentState) {
    MVSegmentStateIdle = 0,
    MVSegmentStateRunning,
    MVSegmentStateDone,
};

@interface MVFastDownloader () <NSURLSessionDataDelegate>
@end

/// One piece of a multi-connection transfer. Each has its own session, its own
/// `.partN` file and its own byte range, so a stalled segment never blocks the
/// others and a resumed run continues each piece where it stopped.
@interface MVSegment : NSObject
@property (nonatomic) NSInteger index;
@property (atomic) long long start;        ///< inclusive
@property (atomic) long long end;          ///< inclusive; -1 until known
@property (atomic) long long written;      ///< bytes already on disk
@property (atomic) MVSegmentState state;
@property (atomic) BOOL writeFailed;
@property (atomic) BOOL throttleSuspended;
@property (nonatomic) NSInteger retries;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *dataTask;
@property (nonatomic, strong, nullable) NSFileHandle *handle;
@end

@implementation MVSegment
- (long long)expectedLength {
    @synchronized (self) { return (self.end >= self.start) ? (self.end - self.start + 1) : 0; }
}
@end

/// One in-flight transfer: the task, its segments, and the callbacks. Held by
/// the downloader in a dictionary keyed by task identifier.
@interface MVTransfer : NSObject
@property (nonatomic, strong) MVDownloadTask *task;
@property (atomic, strong) NSMutableArray<MVSegment *> *segments;
@property (atomic, copy, nullable) NSString *etag;
@property (atomic, copy, nullable) NSString *lastModified;
@property (atomic) BOOL forceSingle;          ///< a 200 to a ranged segment proved it
@property (nonatomic, copy, nullable) void (^progressBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^finishedBlock)(MVDownloadTask *task);
@property (nonatomic, copy, nullable) void (^failedBlock)(MVDownloadTask *task, NSString *message);
@property (nonatomic) MVThrottleBudget throttleBudget;
@property (nonatomic) NSInteger retries;        ///< retries of the whole transfer
@property (atomic) BOOL paused;
@property (atomic) BOOL cancelled;
@property (nonatomic, copy) NSString *runToken;
@property (nonatomic, copy) NSString *tempPath;
@property (nonatomic) BOOL finishing;           ///< guards a double finish
@property (atomic) BOOL throttling;
@property (atomic) long long expectedTotal; // probed resource length, 0 if unknown
@property (nonatomic, strong, nullable) NSTimer *throttleTimer;
/// The initial request that learns size/Range support before the plan is fixed.
@property (nonatomic, strong, nullable) NSURLSession *probeSession;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *probeTask;
@end

@implementation MVTransfer
- (instancetype)init {
    if ((self = [super init])) _segments = [NSMutableArray array];
    return self;
}
@end

@implementation MVFastDownloader {
    NSMutableDictionary<NSString *, MVTransfer *> *_transfers;
    dispatch_queue_t _writeQueue;
}

+ (instancetype)shared {
    static MVFastDownloader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVFastDownloader new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _transfers = [NSMutableDictionary dictionary];
        // One serial queue for all file writes: two connections must never
        // interleave writes into the same file handle.
        _writeQueue = dispatch_queue_create("com.moodyvid.dl.write", DISPATCH_QUEUE_SERIAL);
        _speedLimit = 0;
    }
    return self;
}

- (BOOL)isRunningTask:(MVDownloadTask *)task {
    if (!task.identifier.length) return NO;
    @synchronized (self) {
        MVTransfer *transfer = _transfers[task.identifier];
        return transfer != nil && !transfer.paused;
    }
}

#pragma mark - Start / pause / cancel

- (void)startTask:(MVDownloadTask *)task
         progress:(void (^)(MVDownloadTask *))progress
         finished:(void (^)(MVDownloadTask *))finished
           failed:(void (^)(MVDownloadTask *, NSString *))failed {
    if (!task.url.length) {
        if (failed) failed(task, [MVLang t:@"Unknown error"]);
        return;
    }

    MVTransfer *transfer = [MVTransfer new];
    transfer.task = task;
    transfer.progressBlock = progress;
    transfer.finishedBlock = finished;
    transfer.failedBlock = failed;
    transfer.runToken = NSUUID.UUID.UUIDString;
    (void)[self segmentPathFor:task index:0]; // establish a stable base on the main queue
    transfer.tempPath = task.tempPath;

    @synchronized (self) { _transfers[task.identifier] = transfer; }
    [self beginTransfer:transfer];
}

- (void)pauseTask:(MVDownloadTask *)task {
    MVTransfer *transfer = nil;
    @synchronized (self) {
        transfer = _transfers[task.identifier];
        if (transfer) {
            transfer.paused = YES;
            [_transfers removeObjectForKey:task.identifier];
        }
    }
    if (!transfer) return;
    [self stopTransfer:transfer];
    MVLogInfo(@"dl: paused %@ at %lld bytes", task.title, task.doneBytes);
}

- (void)cancelTask:(MVDownloadTask *)task {
    MVTransfer *transfer = nil;
    @synchronized (self) {
        transfer = _transfers[task.identifier];
        if (transfer) {
            transfer.cancelled = YES;
            [_transfers removeObjectForKey:task.identifier];
        }
    }
    if (transfer) [self stopTransfer:transfer];
    // The .part files are kept: "cancel" on an interrupted row should still leave
    // the bytes it already paid for, and the manager removes them if the user
    // really deletes the row.
}

/// Tears down every session/handle without touching the files on disk.
- (void)stopTransfer:(MVTransfer *)transfer {
    [self invalidateThrottle:transfer];
    for (MVSegment *segment in transfer.segments) {
        [segment.dataTask cancel];
        [self closeSegment:segment];
    }
    NSURLSession *probe = transfer.probeSession;
    transfer.probeSession = nil;
    transfer.probeTask = nil;
    [probe invalidateAndCancel];
}

#pragma mark - Planning

/// The first request is a probe: it learns the size, whether Range works, and
/// the filename. If the server can resume and the file is big enough, the
/// transfer is then split into `connections` segments.
- (void)beginTransfer:(MVTransfer *)transfer {
    MVDownloadTask *task = transfer.task;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (transfer.paused || transfer.cancelled) return;
        NSDictionary *headers = [MVMediaProbe headersForURL:task.url
                                                     referer:task.referer
                                           additionalHeaders:task.headers];
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.url]
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:60];
        request.HTTPShouldHandleCookies = NO;
        for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];

        // One byte is enough to establish the size and whether Range works.
        [request setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 24 * 3600;
        config.HTTPShouldSetCookies = NO;
        config.HTTPCookieStorage = nil;
        config.URLCredentialStorage = nil;
        config.URLCache = nil;

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                             delegate:self
                                                        delegateQueue:nil];
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request];
        dataTask.taskDescription = [NSString stringWithFormat:@"%@#%@#%ld", task.identifier, transfer.runToken, (long)kProbeIndex];
        @synchronized (self) {
            if (_transfers[task.identifier] != transfer || transfer.paused || transfer.cancelled) {
                [session invalidateAndCancel];
                return;
            }
            transfer.probeSession = session;
            transfer.probeTask = dataTask;
            [dataTask resume];
        }
        MVLogInfo(@"dl: probing %@ (connections %lu)", task.url, (unsigned long)task.connections);
    });
}

- (BOOL)validatorsForTask:(MVDownloadTask *)task matchETag:(NSString *)etag modified:(NSString *)modified {
    NSString *oldTag = task.etag;
    BOOL oldStrong = oldTag.length && ![oldTag hasPrefix:@"W/"];
    BOOL newStrong = etag.length && ![etag hasPrefix:@"W/"];
    if (oldStrong || newStrong) return oldStrong && newStrong && [oldTag isEqualToString:etag];
    return task.lastModified.length && modified.length && [task.lastModified isEqualToString:modified];
}

/// Builds the segment plan from the probed size, reusing a saved plan when one
/// exists so a relaunch keeps the same ranges.
- (void)planSegmentsFor:(MVTransfer *)transfer total:(long long)total ranges:(BOOL)ranges {
    MVDownloadTask *task = transfer.task;
    if (![MVFileProtection isSafePartialBase:transfer.tempPath] ||
        [MVFileProtection path:transfer.tempPath conflictsWithPaths:
         [MVFileProtection pathsExcludingTask:task record:nil]]) {
        [self fail:transfer message:[MVLang t:@"Could not save the file"]];
        return;
    }
    task.totalBytes = total;
    task.acceptsRanges = ranges;
    transfer.expectedTotal = total;
    transfer.etag = [task.etag copy];
    transfer.lastModified = [task.lastModified copy];

    NSUInteger wanted = MAX(1, MIN(task.connections, (NSUInteger)16));
    BOOL strongETag = task.etag.length && ![task.etag hasPrefix:@"W/"];
    BOOL hasValidator = strongETag || task.lastModified.length > 0;
    // Without a validator independent range requests could join different
    // versions of the resource. Use a single connection in that case.
    if (transfer.forceSingle || !ranges || !hasValidator || total <= 0 || total < kMinSegmentSize) wanted = 1;
    while (wanted > 1 && total / (long long)wanted < kMinBytesPerConnection) wanted--;

    NSMutableArray<NSArray<NSNumber *> *> *plan = [NSMutableArray array];
    if (wanted <= 1) {
        [plan addObject:@[@(0), @(total > 0 ? total - 1 : -1)]];
    } else {
        long long chunk = total / (long long)wanted;
        long long start = 0;
        for (NSUInteger i = 0; i < wanted; i++) {
            long long end = (i == wanted - 1) ? (total - 1) : (start + chunk - 1);
            [plan addObject:@[@(start), @(end)]];
            start = end + 1;
        }
    }

    // The saved plan is kept only when it is byte-for-byte the same, which is the
    // relaunch case: the part files then hold the right offsets and resume. A
    // different shape means the old pieces describe other ranges, so they must
    // go or the join would write bytes to the wrong offsets.
    if (![self plan:task.segments equals:plan]) {
        [MVFastDownloader removePartFilesForTask:task];
        task.segments = plan;
    }
    [self rebuildSegmentsFromPlan:transfer];
    [self startSegmentsFor:transfer];
}

- (BOOL)plan:(NSArray<NSArray<NSNumber *> *> *)a equals:(NSArray<NSArray<NSNumber *> *> *)b {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (a[i].count != 2 || b[i].count != 2) return NO;
        if (a[i][0].longLongValue != b[i][0].longLongValue) return NO;
        if (a[i][1].longLongValue != b[i][1].longLongValue) return NO;
    }
    return YES;
}

/// Recreates the in-memory segment objects from `task.segments`, reading the
/// `.partN` sizes off disk so a resume continues where it stopped.
- (void)rebuildSegmentsFromPlan:(MVTransfer *)transfer {
    NSMutableArray<MVSegment *> *newSegments = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger i = 0; i < transfer.task.segments.count; i++) {
        NSArray<NSNumber *> *pair = transfer.task.segments[i];
        MVSegment *segment = [MVSegment new];
        segment.index = (NSInteger)i;
        segment.start = pair[0].longLongValue;
        segment.end = pair[1].longLongValue;
        segment.state = MVSegmentStateIdle;
        NSString *path = [self segmentPathForTransfer:transfer index:(NSInteger)i];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        segment.written = [attrs[NSFileSize] longLongValue];
        if (segment.written > 0 && (segment.expectedLength <= 0 || segment.written > segment.expectedLength)) {
            [fm removeItemAtPath:path error:nil]; // unknown or stale length: never append to it
            segment.written = 0;
        }
        if (segment.written >= segment.expectedLength && segment.expectedLength > 0) {
            segment.state = MVSegmentStateDone;
        }
        [newSegments addObject:segment];
    }
    @synchronized (self) { transfer.segments = newSegments; }
}

- (NSString *)segmentPathFor:(MVDownloadTask *)task index:(NSInteger)index {
    NSString *base = task.tempPath;
    if (!base.length) {
        NSString *directory = [MVPaths directoryForCategory:task.category];
        NSString *name = [MVPaths sanitizeFilename:task.suggestedFilename ?: task.url.lastPathComponent];
        if (!name.length) name = @"download";
        base = [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@.part", task.identifier, name]];
        task.tempPath = base;
    }
    return [NSString stringWithFormat:@"%@%ld", base, (long)index];
}

- (NSString *)segmentPathForTransfer:(MVTransfer *)transfer index:(NSInteger)index {
    return [NSString stringWithFormat:@"%@%ld", transfer.tempPath, (long)index];
}

#pragma mark - Segments

- (BOOL)isCurrentTransfer:(MVTransfer *)transfer {
    @synchronized (self) {
        return _transfers[transfer.task.identifier] == transfer && !transfer.paused && !transfer.cancelled;
    }
}

// Call under @synchronized(self). The transfer object survives a collapse from
// many ranges to one, so a run token alone cannot identify its old segments.
- (BOOL)ownsSegment:(MVSegment *)segment transfer:(MVTransfer *)transfer task:(NSURLSessionTask *)urlTask {
    if (_transfers[transfer.task.identifier] != transfer || transfer.paused || transfer.cancelled ||
        (transfer.forceSingle && transfer.segments.count > 1)) return NO;
    NSInteger index = segment.index;
    if (index < 0 || index >= (NSInteger)transfer.segments.count || transfer.segments[(NSUInteger)index] != segment) return NO;
    return !urlTask || segment.dataTask == urlTask;
}

- (void)startSegmentsFor:(MVTransfer *)transfer {
    if (transfer.paused || transfer.cancelled) return;
    BOOL allDone = transfer.segments.count > 0;
    for (MVSegment *segment in transfer.segments) {
        if (segment.state == MVSegmentStateDone) continue;
        allDone = NO;
        if (segment.state == MVSegmentStateRunning) continue;
        [self startSegment:segment transfer:transfer];
    }
    [self recomputeProgress:transfer];
    if (allDone) { [self finish:transfer]; return; }
    if (self.speedLimit > 0) [self startThrottleFor:transfer];
}

- (void)startSegment:(MVSegment *)segment transfer:(MVTransfer *)transfer {
    MVDownloadTask *task = transfer.task;
    if (![MVFileProtection isSafePartialBase:transfer.tempPath] ||
        [MVFileProtection path:transfer.tempPath conflictsWithPaths:
         [MVFileProtection pathsExcludingTask:task record:nil]]) {
        [self fail:transfer message:[MVLang t:@"Could not save the file"]];
        return;
    }
    @synchronized (self) {
        if (![self ownsSegment:segment transfer:transfer task:nil] || segment.state != MVSegmentStateIdle) return;
        segment.state = MVSegmentStateRunning;
        segment.writeFailed = NO;
        segment.throttleSuspended = NO;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (transfer.paused || transfer.cancelled) return;

        NSString *path = [self segmentPathForTransfer:transfer index:segment.index];
        @synchronized (self) {
            if (![self ownsSegment:segment transfer:transfer task:nil]) return;
            [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            // The response handler creates/opens the part without following a
            // final-component symlink; do not pre-create it via NSFileManager.
        }

        NSDictionary *headers = [MVMediaProbe headersForURL:task.url
                                                     referer:task.referer
                                           additionalHeaders:task.headers];
        NSMutableURLRequest *request =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.url]
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:60];
        request.HTTPShouldHandleCookies = NO;
        for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];

        long long from = segment.start + segment.written;
        long long to = segment.end;
        // "bytes=0--1" would be malformed, so an unknown end becomes an open
        // range that asks the server for the rest of the file.
        NSString *range = (to >= from) ? [NSString stringWithFormat:@"bytes=%lld-%lld", from, to]
                                       : [NSString stringWithFormat:@"bytes=%lld-", from];
        [request setValue:range forHTTPHeaderField:@"Range"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        // If-Range: a changed file makes the server answer 200, which is detected
        // and turns the whole transfer back into a single clean download.
        NSString *validator = (transfer.etag.length && ![transfer.etag hasPrefix:@"W/"]) ? transfer.etag : transfer.lastModified;
        if (validator.length) [request setValue:validator forHTTPHeaderField:@"If-Range"];

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 24 * 3600;
        config.HTTPShouldSetCookies = NO;
        config.HTTPCookieStorage = nil;
        config.URLCredentialStorage = nil;
        config.URLCache = nil;

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                             delegate:self
                                                        delegateQueue:nil];
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request];
        dataTask.taskDescription = [NSString stringWithFormat:@"%@#%@#%ld", task.identifier, transfer.runToken, (long)segment.index];
        @synchronized (self) {
            if (![self ownsSegment:segment transfer:transfer task:nil]) {
                [session invalidateAndCancel];
                return;
            }
            segment.session = session;
            segment.dataTask = dataTask;
            [dataTask resume];
        }
    });
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    [MVHTTPSession handleRedirectForTask:task response:response newRequest:request completion:completionHandler];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    MVTransfer *transfer = [self transferForTask:dataTask];
    if (!transfer) { completionHandler(NSURLSessionResponseCancel); return; }
    MVDownloadTask *task = transfer.task;
    NSInteger index = [self segmentIndexForTask:dataTask];

    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        completionHandler(NSURLSessionResponseCancel);
        [self fail:transfer message:[MVLang t:@"Could not open the stream"]];
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSDictionary *all = http.allHeaderFields;

    if (http.statusCode >= 400) {
        completionHandler(NSURLSessionResponseCancel);
        NSString *message = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
        if (index == kProbeIndex) {
            NSURLSession *probe = transfer.probeSession;
            transfer.probeSession = nil;
            transfer.probeTask = nil;
            [probe finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ [self fail:transfer message:message]; });
        } else {
            [self segmentFailedForTask:dataTask message:message];
        }
        return;
    }

    // --- Probe response: decide the plan, then start the real segments. ---
    if (index == kProbeIndex) {
        completionHandler(NSURLSessionResponseCancel);   // no body needed
        long long total = 0;
        BOOL ranges = NO;
        if (http.statusCode == 206) {
            MVContentRange parsed;
            NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];
            NSString *encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
            if (!MVParseContentRange(contentRange.UTF8String, &parsed) ||
                !MVContentRangeMatches(&parsed, 0, 0, -1) ||
                (encoding.length && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame)) {
                [self fail:transfer message:[MVLang t:@"Server did not honor the requested byte range"]];
                return;
            }
            total = MAX(0, parsed.total);
            ranges = YES;
        } else if (http.statusCode == 200) {
            total = MAX(0, http.expectedContentLength);
        } else {
            [self fail:transfer message:[MVLang t:@"Could not open the stream"]];
            return;
        }
        NSString *newETag = [http valueForHTTPHeaderField:@"ETag"];
        NSString *newModified = [http valueForHTTPHeaderField:@"Last-Modified"];

        NSURLSession *probe = transfer.probeSession;
        transfer.probeSession = nil;
        transfer.probeTask = nil;
        [probe finishTasksAndInvalidate];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (transfer.paused || transfer.cancelled) return;
            if (![MVFileProtection isSafePartialBase:transfer.tempPath] ||
                [MVFileProtection path:transfer.tempPath conflictsWithPaths:
                 [MVFileProtection pathsExcludingTask:task record:nil]]) {
                [self fail:transfer message:[MVLang t:@"Could not save the file"]];
                return;
            }
            // A same-sized resource can still have changed. Only reuse saved
            // ranges when a strong ETag or Last-Modified validator still matches.
            if (task.segments.count && ![self validatorsForTask:task matchETag:newETag modified:newModified]) {
                [MVFastDownloader removePartFilesForTask:task];
                task.segments = @[];
            }
            task.etag = newETag;
            task.lastModified = newModified;
            [self captureFilenameFrom:all for:task];
            [self planSegmentsFor:transfer total:total ranges:ranges];
        });
        return;
    }

    // --- Segment response. ---
    MVSegment *segment = [self segmentForTask:dataTask];
    if (!segment) { completionHandler(NSURLSessionResponseCancel); return; }

    if (http.statusCode != 200 && http.statusCode != 206) {
        completionHandler(NSURLSessionResponseCancel);
        [self segmentFailedForTask:dataTask message:[MVLang t:@"Download incomplete"]];
        return;
    }
    NSString *encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
    if (encoding.length && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame) {
        completionHandler(NSURLSessionResponseCancel);
        [self segmentFailedForTask:dataTask message:[MVLang t:@"Server did not honor the requested byte range"]];
        return;
    }
    if (http.statusCode == 206) {
        NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];
        MVContentRange parsed;
        long long expectedStart, expectedEnd;
        @synchronized (segment) {
            expectedStart = segment.start + segment.written;
            expectedEnd = segment.end;
        }
        long long expectedTotal = transfer.expectedTotal > 0 ? transfer.expectedTotal : -1;
        BOOL valid = MVParseContentRange(contentRange.UTF8String, &parsed) &&
            MVContentRangeMatches(&parsed, expectedStart, expectedEnd, expectedTotal);
        // An open-ended request must actually end at the resource's known end;
        // an unknown total cannot prove the resulting file is complete.
        if (valid && expectedEnd < 0) valid = parsed.total > 0 && parsed.last == parsed.total - 1;
        if (!valid) {
            completionHandler(NSURLSessionResponseCancel);
            [self segmentFailedForTask:dataTask message:[MVLang t:@"Server did not honor the requested byte range"]];
            return;
        }
        @synchronized (segment) { if (segment.end < 0) segment.end = parsed.last; }
    }

    // A callback from a segment of the old plan may arrive during a collapse.
    // Never let it truncate the new plan's files.
    BOOL multiSegment;
    @synchronized (self) {
        if (![self ownsSegment:segment transfer:transfer task:dataTask]) {
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
        multiSegment = transfer.segments.count > 1;
    }
    // A 200 to a ranged request means the server ignored Range and is sending
    // the whole file. Drop a multi-segment plan, including when segment 0 sees it.
    if (http.statusCode == 200 && multiSegment) {
        completionHandler(NSURLSessionResponseCancel);
        dispatch_async(dispatch_get_main_queue(), ^{ [self collapseToSingleConnection:transfer]; });
        return;
    }
    NSString *responseTag = [http valueForHTTPHeaderField:@"ETag"];
    NSString *responseModified = [http valueForHTTPHeaderField:@"Last-Modified"];
    BOOL strongETag = transfer.etag.length && ![transfer.etag hasPrefix:@"W/"];
    BOOL changed = strongETag && responseTag.length && ![transfer.etag isEqualToString:responseTag];
    if (!strongETag && transfer.lastModified.length && responseModified.length &&
        ![transfer.lastModified isEqualToString:responseModified]) changed = YES;
    if (changed) {
        completionHandler(NSURLSessionResponseCancel);
        [self failSegment:segment transfer:transfer task:dataTask
                   message:[MVLang t:@"The file changed on the server; retry the download"]];
        return;
    }
    if (http.statusCode == 200) {
        // Even segment 0 must restart from zero in this case.
        if (![self truncateSegment:segment transfer:transfer task:dataTask]) {
            completionHandler(NSURLSessionResponseCancel);
            [self failSegment:segment transfer:transfer task:dataTask message:[MVLang t:@"Could not save the file"]];
            return;
        }
        @synchronized (segment) {
            segment.start = 0;
            segment.written = 0;
            segment.end = http.expectedContentLength > 0 ? http.expectedContentLength - 1 : -1;
        }
    }
    if (![self openSegmentForAppend:segment transfer:transfer task:dataTask]) {
        completionHandler(NSURLSessionResponseCancel);
        [self failSegment:segment transfer:transfer task:dataTask message:[MVLang t:@"Could not save the file"]];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isCurrentTransfer:transfer] && !transfer.finishing) [self recomputeProgress:transfer];
    });
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    MVTransfer *transfer = [self transferForTask:dataTask];
    if (!transfer || transfer.paused || transfer.cancelled) return;
    MVSegment *segment = [self segmentForTask:dataTask];
    if (!segment) return;

    NSData *chunk = [data copy];
    BOOL overrun = NO;
    @synchronized (self) {
        if (![self ownsSegment:segment transfer:transfer task:dataTask]) return;
        @synchronized (segment) {
            long long expected = segment.expectedLength;
            overrun = chunk.length > (NSUInteger)LLONG_MAX || segment.written < 0 ||
                (long long)chunk.length > LLONG_MAX - segment.written ||
                (expected > 0 && (segment.written > expected ||
                 (long long)chunk.length > expected - segment.written));
            if (!overrun) segment.written += (long long)chunk.length;
        }
        if (!overrun) {
            // Enqueue while ownership is locked. A pause/collapse closes the
            // handle only after already-enqueued writes have drained.
            dispatch_async(_writeQueue, ^{
                NSFileHandle *handle = segment.handle;
                if (!handle) { segment.writeFailed = YES; return; }
                @try { [handle writeData:chunk]; }
                @catch (NSException *e) {
                    segment.writeFailed = YES;
                    MVLogError(@"dl: write failed: %@", e.reason);
                }
            });
        }
    }
    if (overrun) {
        [dataTask cancel];
        [self failSegment:segment transfer:transfer task:dataTask message:[MVLang t:@"Download incomplete"]];
        return;
    }

    // While throttled the timer drives progress; otherwise update on each chunk.
    // Both the byte counter and the callback live on the main queue so the
    // progress value has exactly one writer.
    if (!transfer.throttling) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentTransfer:transfer] || transfer.finishing) return;
            [self recomputeProgress:transfer];
            if (transfer.progressBlock) transfer.progressBlock(transfer.task);
        });
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)urlTask
didCompleteWithError:(NSError *)error {
    MVTransfer *transfer = [self transferForTask:urlTask];
    if (!transfer) return;
    if (transfer.paused || transfer.cancelled) return;
    if (error && error.code == NSURLErrorCancelled) return;

    // Probe finished with an error before it produced a plan: retry the probe.
    if ([self segmentIndexForTask:urlTask] == kProbeIndex) {
        if (error) {
            if (transfer.retries < kMaxRetries) {
                transfer.retries++;
                NSTimeInterval delay = pow(2.0, transfer.retries - 1);
                MVLogWarn(@"dl: probe retry %ld for %@ in %.0fs", (long)transfer.retries, transfer.task.title, delay);
                NSURLSession *probe = transfer.probeSession;
                transfer.probeSession = nil;
                transfer.probeTask = nil;
                [probe finishTasksAndInvalidate];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (transfer.paused || transfer.cancelled) return;
                    [self beginTransfer:transfer];
                });
            } else {
                [self fail:transfer message:error.localizedDescription ?: [MVLang t:@"Unknown error"]];
            }
        }
        return;
    }

    MVSegment *segment = [self segmentForTask:urlTask];
    if (!segment) return;
    dispatch_sync(_writeQueue, ^{}); // observe queued write failures before deciding success
    if (segment.writeFailed) {
        [self failSegment:segment transfer:transfer task:urlTask message:[MVLang t:@"Could not save the file"]];
        return;
    }
    if (error) {
        [self segmentFailedForTask:urlTask message:error.localizedDescription ?: [MVLang t:@"Unknown error"]];
        return;
    }
    // Short read: the segment did not reach its end.
    long long written;
    @synchronized (segment) { written = segment.written; }
    if (segment.expectedLength > 0 && written != segment.expectedLength) {
        [self segmentFailedForTask:urlTask message:[MVLang t:@"Download incomplete"]];
        return;
    }
    [self closeSegment:segment];
    if (segment.writeFailed) {
        [self failSegment:segment transfer:transfer task:nil message:[MVLang t:@"Could not save the file"]];
        return;
    }
    segment.state = MVSegmentStateDone;
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) { if (![self ownsSegment:segment transfer:transfer task:nil]) return; }
        if (transfer.finishing) return;
        [self recomputeProgress:transfer];
        BOOL allDone = YES;
        for (MVSegment *s in transfer.segments) {
            if (s.state != MVSegmentStateDone) { allDone = NO; break; }
        }
        if (allDone) [self finish:transfer];
    });
}

/// A segment error is retried in place, resuming from the bytes on disk. Only
/// when every retry is spent does the whole transfer fail.
- (void)segmentFailedForTask:(NSURLSessionTask *)urlTask message:(NSString *)message {
    // Store snapshots and partial cleanup belong to the main queue.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self segmentFailedForTask:urlTask message:message]; });
        return;
    }
    MVTransfer *transfer = [self transferForTask:urlTask];
    if (!transfer || transfer.paused || transfer.cancelled) return;
    MVSegment *segment = [self segmentForTask:urlTask];
    if (!segment) return;
    [self closeSegment:segment];
    if (segment.writeFailed) {
        [self failSegment:segment transfer:transfer task:nil message:[MVLang t:@"Could not save the file"]];
        return;
    }

    NSInteger retry = 0;
    @synchronized (self) {
        if (![self ownsSegment:segment transfer:transfer task:nil]) return;
        if (segment.retries < kMaxRetries) {
            BOOL strongETag = transfer.etag.length && ![transfer.etag hasPrefix:@"W/"];
            if (!strongETag && !transfer.lastModified.length) {
                // Without a validator, bytes from a retry cannot safely be
                // appended to an earlier response of the resource.
                NSString *path = [self segmentPathForTransfer:transfer index:segment.index];
                NSArray *protected = [MVFileProtection pathsExcludingTask:transfer.task record:nil];
                if (![MVFileProtection isSafePartialBase:transfer.tempPath] ||
                    ![MVFileProtection removePartialItemAtPath:path protecting:protected]) {
                    [self failSegment:segment transfer:transfer task:nil message:[MVLang t:@"Could not save the file"]];
                    return;
                }
                @synchronized (segment) { segment.written = 0; }
            }
            segment.retries++;
            segment.state = MVSegmentStateIdle;
            retry = segment.retries;
        }
    }
    if (retry) {
        NSTimeInterval delay = pow(2.0, retry - 1);
        MVLogWarn(@"dl: segment %ld retry %ld in %.0fs (%@)", (long)segment.index, (long)retry, delay, message);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self startSegment:segment transfer:transfer]; });
        return;
    }
    [self failSegment:segment transfer:transfer task:nil message:message];
}

/// The server refused to range: throw the plan away and download as one stream.
- (void)collapseToSingleConnection:(MVTransfer *)transfer {
    if (transfer.paused || transfer.cancelled) return;
    // Several segments can report a 200 at once; only the first collapses.
    if (transfer.forceSingle) return;
    MVLogWarn(@"dl: server ignored Range for %@, single connection", transfer.task.title);
    // Do not re-probe: the server already answered a ranged request with a full
    // 200, so probing again would only repeat the same decision in a loop.
    transfer.forceSingle = YES;
    [self stopTransfer:transfer];
    // Changing the plan discards all old parts; a server that ignores Range
    // must provide a fresh, complete response from byte zero.
    [self planSegmentsFor:transfer total:transfer.task.totalBytes ranges:NO];
}

#pragma mark - Progress

- (void)recomputeProgress:(MVTransfer *)transfer {
    long long done = 0, total = 0;
    for (MVSegment *segment in transfer.segments) {
        long long expected = segment.expectedLength;
        long long written;
        @synchronized (segment) { written = segment.written; }
        done += (expected > 0) ? MIN(written, expected) : written;
        total += MAX(0, expected);
    }
    transfer.task.doneBytes = done;
    if (total > 0) transfer.task.totalBytes = total;
}

#pragma mark - File handling

- (BOOL)openSegmentForAppend:(MVSegment *)segment transfer:(MVTransfer *)transfer task:(NSURLSessionTask *)urlTask {
    NSString *path = [self segmentPathForTransfer:transfer index:segment.index];
    __block BOOL opened = NO;
    @synchronized (self) {
        if (![self ownsSegment:segment transfer:transfer task:urlTask]) return NO;
        dispatch_sync(_writeQueue, ^{
            int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (fd < 0) return;
            struct stat info;
            if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_nlink != 1 ||
                info.st_size != segment.written) { close(fd); return; }
            NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
            if (!handle) { close(fd); return; }
            @try {
                opened = [handle seekToEndOfFile] == (unsigned long long)segment.written;
                if (opened) segment.handle = handle;
                else [handle closeFile];
            } @catch (NSException *exception) {
                @try { [handle closeFile]; } @catch (NSException *ignored) {}
                opened = NO;
            }
        });
    }
    return opened;
}

- (BOOL)truncateSegment:(MVSegment *)segment transfer:(MVTransfer *)transfer task:(NSURLSessionTask *)urlTask {
    NSString *path = [self segmentPathForTransfer:transfer index:segment.index];
    __block BOOL created = NO;
    @synchronized (self) {
        if (![self ownsSegment:segment transfer:transfer task:urlTask]) return NO;
        // The 200 response belongs to the current session. Reset only the file,
        // not the session which still needs to deliver the response body.
        dispatch_sync(_writeQueue, ^{
            @try { [segment.handle closeFile]; } @catch (NSException *e) {}
            segment.handle = nil;
            int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (fd < 0) return;
            struct stat info;
            created = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_nlink == 1 && ftruncate(fd, 0) == 0;
            close(fd);
        });
    }
    return created;
}

- (void)closeSegment:(MVSegment *)segment {
    __block NSURLSession *session;
    @synchronized (self) {
        session = segment.session;
        segment.session = nil;
        segment.dataTask = nil;
    }
    [session finishTasksAndInvalidate];
    dispatch_sync(_writeQueue, ^{
        NSFileHandle *handle = segment.handle;
        segment.handle = nil;
        if (!handle) return;
        @try { [handle synchronizeFile]; [handle closeFile]; }
        @catch (NSException *e) {
            segment.writeFailed = YES;
            @try { [handle closeFile]; } @catch (NSException *ignored) {}
        }
    });
}

#pragma mark - Finish / fail

/// Joins the segment files into the final one, in order, streaming through a
/// buffer so a multi-gigabyte video never sits in memory.
- (void)finish:(MVTransfer *)transfer {
    if (transfer.finishing) return;
    transfer.finishing = YES;

    [self invalidateThrottle:transfer];
    for (MVSegment *segment in transfer.segments) [self closeSegment:segment];

    // The join copies every byte of the file, so it runs off the main thread;
    // only the state change and the callback hop back.
    NSArray<MVSegment *> *segments = [transfer.segments copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self joinTransfer:transfer segments:segments];
    });
}

- (void)joinTransfer:(MVTransfer *)transfer segments:(NSArray<MVSegment *> *)segments {
    NSFileManager *fm = NSFileManager.defaultManager;
    // A run-specific staging path prevents an old join from overwriting a new
    // run or a completed download. Never delete the source parts off-thread.
    NSString *staging = [transfer.tempPath stringByAppendingFormat:@".joining-%@", transfer.runToken];
    int fd = open(staging.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    BOOL created = fd >= 0;
    NSFileHandle *out = created ? [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES] : nil;
    if (created && !out) close(fd);
    BOOL ok = out != nil && segments.count > 0;
    for (MVSegment *segment in segments) {
        if (!ok) break;
        NSString *path = [self segmentPathForTransfer:transfer index:segment.index];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        long long size = [attrs[NSFileSize] longLongValue];
        if (!attrs || (segment.expectedLength > 0 && size != segment.expectedLength)) { ok = NO; break; }
        NSFileHandle *in = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!in) { ok = NO; break; }
        @try {
            while (YES) {
                @autoreleasepool {
                    NSData *chunk = [in readDataOfLength:1024 * 1024];
                    if (!chunk.length) break;
                    [out writeData:chunk];
                }
            }
        } @catch (NSException *e) { ok = NO; }
        @try { [in closeFile]; } @catch (NSException *e) { ok = NO; }
        if (!ok) break;
    }
    @try { [out synchronizeFile]; [out closeFile]; } @catch (NSException *e) { ok = NO; }

    dispatch_async(dispatch_get_main_queue(), ^{
        MVDownloadTask *task = transfer.task;
        void (^discardStaging)(void) = ^{
            if (created) [MVFileProtection removePartialItemAtPath:staging protecting:
                          [MVFileProtection pathsExcludingTask:task record:nil]];
        };
        BOOL current;
        @synchronized (self) { current = _transfers[task.identifier] == transfer; }
        if (!current || transfer.paused || transfer.cancelled) {
            discardStaging();
            return;
        }
        if (!ok) {
            discardStaging();
            [self fail:transfer message:[MVLang t:@"Could not save the file"]];
            return;
        }
        NSString *directory = [MVPaths directoryForCategory:task.category];
        NSString *name = task.suggestedFilename.length ? task.suggestedFilename : task.url.lastPathComponent;
        NSString *final = [MVPaths uniquePathInDirectory:directory filename:name];
        if (![fm moveItemAtPath:staging toPath:final error:nil]) {
            discardStaging();
            [self fail:transfer message:[MVLang t:@"Could not save the file"]];
            return;
        }
        [MVFastDownloader removePartFilesForTask:task];
        long long size = [[fm attributesOfItemAtPath:final error:nil][NSFileSize] longLongValue];
        task.path = final;
        if (size > 0) task.totalBytes = size;
        task.doneBytes = task.totalBytes;
        task.speed = 0;
        task.eta = 0;
        task.tempPath = nil;
        task.segments = @[];
        @synchronized (self) { if (_transfers[task.identifier] == transfer) [_transfers removeObjectForKey:task.identifier]; }
        MVLogInfo(@"dl: finished %@ (%lld bytes) -> %@", task.title, task.totalBytes, final);
        if (transfer.finishedBlock) transfer.finishedBlock(task);
    });
}

- (void)failSegment:(MVSegment *)segment transfer:(MVTransfer *)transfer
               task:(NSURLSessionTask *)urlTask message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (![self ownsSegment:segment transfer:transfer task:urlTask]) return;
        }
        [self fail:transfer message:message];
    });
}

- (void)fail:(MVTransfer *)transfer message:(NSString *)message {
    void (^finishFailure)(void) = ^{
        MVDownloadTask *task = transfer.task;
        @synchronized (self) {
            if (_transfers[task.identifier] != transfer || transfer.paused || transfer.cancelled) return;
            transfer.cancelled = YES;
            [_transfers removeObjectForKey:task.identifier];
        }
        [self stopTransfer:transfer];
        MVLogError(@"dl: failed %@: %@", task.title, message);
        if (transfer.failedBlock) transfer.failedBlock(task, message);
    };
    if (NSThread.isMainThread) finishFailure();
    else dispatch_async(dispatch_get_main_queue(), finishFailure);
}

#pragma mark - Throttle

/// Approximate per-transfer token bucket. Bytes already delivered by NSURLSession
/// can overshoot, so their debt carries forward instead of being forgiven on the
/// next tick. Short transfers and system buffering may still exceed the target.
- (void)startThrottleFor:(MVTransfer *)transfer {
    if (transfer.throttling) return;
    transfer.throttling = YES;
    MVThrottleBudget budget;
    MVThrottleInit(&budget, transfer.task.doneBytes, NSProcessInfo.processInfo.systemUptime);
    transfer.throttleBudget = budget;
    __weak MVTransfer *weakTransfer = transfer;
    transfer.throttleTimer = [NSTimer scheduledTimerWithTimeInterval:kThrottleInterval
                                                             repeats:YES
                                                               block:^(NSTimer *timer) {
        MVTransfer *t = weakTransfer;
        if (!t || t.paused || t.cancelled) { [timer invalidate]; return; }
        [self throttleTick:t];
    }];
}

- (void)throttleTick:(MVTransfer *)transfer {
    if (![self isCurrentTransfer:transfer] || transfer.finishing) return;
    // When throttled, data callbacks deliberately defer UI updates to this
    // timer; sample the actual segment counters before computing the allowance.
    [self recomputeProgress:transfer];
    MVThrottleBudget budget = transfer.throttleBudget;
    long long delta = MAX(0, transfer.task.doneBytes - budget.last_bytes);
    BOOL over = MVThrottleShouldSuspend(&budget, transfer.task.doneBytes,
                                        NSProcessInfo.processInfo.systemUptime, self.speedLimit);
    transfer.throttleBudget = budget;
    @synchronized (self) {
        if (_transfers[transfer.task.identifier] != transfer || transfer.paused || transfer.cancelled) return;
        for (MVSegment *segment in transfer.segments) {
            if (segment.state != MVSegmentStateRunning) continue;
            NSURLSessionTask *task = segment.dataTask;
            if (!task) continue;
            if (over && !segment.throttleSuspended) {
                segment.throttleSuspended = YES;
                [task suspend];
            } else if (!over && segment.throttleSuspended) {
                segment.throttleSuspended = NO;
                [task resume];
            }
        }
    }
    if (delta > 0 && transfer.progressBlock) transfer.progressBlock(transfer.task);
}

- (void)invalidateThrottle:(MVTransfer *)transfer {
    [transfer.throttleTimer invalidate];
    transfer.throttleTimer = nil;
    transfer.throttling = NO;
}

+ (void)removePartFilesForTask:(MVDownloadTask *)task {
    if (![MVFileProtection isSafePartialBase:task.tempPath]) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *protected = [MVFileProtection pathsExcludingTask:task record:nil];
    [MVFileProtection removePartialItemAtPath:task.tempPath protecting:protected];
    // Check each suffix separately: another row can refer to one part even if
    // it does not refer to the base name.
    for (NSInteger i = 0; i < 24; i++) {
        [MVFileProtection removePartialItemAtPath:[NSString stringWithFormat:@"%@%ld", task.tempPath, (long)i]
                                protecting:protected];
    }
    NSString *directory = task.tempPath.stringByDeletingLastPathComponent;
    NSString *prefix = [task.tempPath.lastPathComponent stringByAppendingString:@".joining-"];
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if ([name hasPrefix:prefix])
            [MVFileProtection removePartialItemAtPath:[directory stringByAppendingPathComponent:name] protecting:protected];
    }
}

#pragma mark - Helpers

/// Delegate callbacks carry the task; its description names the transfer and
/// the segment, so the lookup is O(1) rather than a scan on every data chunk.
- (MVTransfer *)transferForTask:(NSURLSessionTask *)urlTask {
    NSArray<NSString *> *parts = [urlTask.taskDescription componentsSeparatedByString:@"#"];
    if (parts.count != 3 || !parts[0].length) return nil;
    @synchronized (self) {
        MVTransfer *transfer = _transfers[parts[0]];
        if (!transfer || transfer.paused || transfer.cancelled || ![transfer.runToken isEqualToString:parts[1]]) return nil;
        NSInteger index = parts[2].integerValue;
        if (index == kProbeIndex) return transfer.probeTask == urlTask ? transfer : nil;
        if (index < 0 || index >= (NSInteger)transfer.segments.count) return nil;
        return transfer.segments[(NSUInteger)index].dataTask == urlTask ? transfer : nil;
    }
}

- (NSInteger)segmentIndexForTask:(NSURLSessionTask *)urlTask {
    NSArray<NSString *> *parts = [urlTask.taskDescription componentsSeparatedByString:@"#"];
    if (parts.count != 3) return kProbeIndex;
    return parts[2].integerValue;
}

- (MVSegment *)segmentForTask:(NSURLSessionTask *)urlTask {
    NSInteger index = [self segmentIndexForTask:urlTask];
    if (index == kProbeIndex) return nil;
    MVTransfer *transfer = [self transferForTask:urlTask];
    if (index < 0 || index >= (NSInteger)transfer.segments.count) return nil;
    return transfer.segments[(NSUInteger)index];
}

/// A filename from the server beats the URL's last path component.
- (void)captureFilenameFrom:(NSDictionary *)headers for:(MVDownloadTask *)task {
    if (task.suggestedFilename.length) return;
    NSString *disposition = headers[@"Content-Disposition"];
    if (![disposition isKindOfClass:NSString.class]) return;
    NSRange r = [disposition rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return;
    NSString *name = [[disposition substringFromIndex:NSMaxRange(r)]
                      componentsSeparatedByString:@";"].firstObject;
    name = [name stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
    if (name.length) task.suggestedFilename = [name stringByRemovingPercentEncoding] ?: name;
}

@end
