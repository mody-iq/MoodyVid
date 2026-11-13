#import "MVDownloadManager.h"
#import "MVTaskStore.h"
#import "MVDownloadStore.h"
#import "MVFastDownloader.h"
#import "MVHLSDownloader.h"
#import "MVMPDDownloader.h"
#import "MVTorrentDownloader.h"
#import "MVPaths.h"
#import "MVFileProtection.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVLog.h"
#import "MVBackgroundKeeper.h"
#import "MVNetworkPolicy.h"
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>

/// A per-task throttle cap when the user has not set one. Kept here rather than
/// in the downloader so the default lives with the other queue settings.
static const NSUInteger kDefaultConnections = 6;
static const NSUInteger kDefaultConcurrent = 3;

@implementation MVDownloadManager {
    UIBackgroundTaskIdentifier _backgroundTask;
    BOOL _awake;
    NSMutableDictionary<NSString *, NSString *> *_runTokens;
}

+ (instancetype)shared {
    static MVDownloadManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MVDownloadManager new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _backgroundTask = UIBackgroundTaskInvalid;
        _runTokens = [NSMutableDictionary dictionary];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _maxConnections = [defaults objectForKey:@"MVMaxConnections"] ? [defaults integerForKey:@"MVMaxConnections"] : kDefaultConnections;
        _maxConcurrentTasks = [defaults objectForKey:@"MVMaxConcurrent"] ? [defaults integerForKey:@"MVMaxConcurrent"] : kDefaultConcurrent;
        _speedLimit = [defaults integerForKey:@"MVSpeedLimit"];
        [MVFastDownloader shared].speedLimit = _speedLimit;
        [MVHLSDownloader shared].speedLimit = _speedLimit;
        [MVMPDDownloader shared].speedLimit = _speedLimit;
        [MVTorrentDownloader shared].speedLimit = _speedLimit;
        _maxConnections = MIN(16, MAX(1, _maxConnections));
        _maxConcurrentTasks = MIN(5, MAX(1, _maxConcurrentTasks));

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pump)
                                                   name:MVTaskStoreDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pump)
                                                   name:MVNetworkPolicyDidChangeNotification object:nil];
        (void)MVNetworkPolicy.shared; // start observing the default path
    }
    return self;
}

#pragma mark - Settings

- (void)setMaxConnections:(NSUInteger)maxConnections {
    _maxConnections = MIN(16, MAX(1, maxConnections));
    [NSUserDefaults.standardUserDefaults setInteger:_maxConnections forKey:@"MVMaxConnections"];
}

- (void)setMaxConcurrentTasks:(NSUInteger)maxConcurrentTasks {
    _maxConcurrentTasks = MIN(5, MAX(1, maxConcurrentTasks));
    [NSUserDefaults.standardUserDefaults setInteger:_maxConcurrentTasks forKey:@"MVMaxConcurrent"];
    [self pump];
}

- (void)setSpeedLimit:(long long)speedLimit {
    _speedLimit = MAX(0, speedLimit);
    [NSUserDefaults.standardUserDefaults setInteger:_speedLimit forKey:@"MVSpeedLimit"];
    [MVFastDownloader shared].speedLimit = _speedLimit;
    [MVHLSDownloader shared].speedLimit = _speedLimit;
    [MVMPDDownloader shared].speedLimit = _speedLimit;
    [MVTorrentDownloader shared].speedLimit = _speedLimit;
}

- (BOOL)wifiOnly { return MVNetworkPolicy.shared.wifiOnly; }

- (void)setWifiOnly:(BOOL)wifiOnly {
    MVNetworkPolicy.shared.wifiOnly = wifiOnly;
}

#pragma mark - Enqueue

- (MVDownloadTask *)enqueueDirectURL:(NSString *)url
                             headers:(NSDictionary<NSString *, NSString *> *)headers
                             referer:(NSString *)referer
                               title:(NSString *)title
                       suggestedName:(NSString *)suggestedFilename
                            category:(NSString *)category
                            expected:(long long)totalBytes
                             created:(BOOL *)created {
    if (created) *created = NO;
    if (!url.length) return nil;

    // Skip duplicates: re-adding the same URL moves the existing row to the top.
    MVDownloadTask *existing = [MVTaskStore.shared taskWithURL:url];
    if (existing) {
        [MVTaskStore.shared moveToTop:existing];
        if (existing.state == MVTaskStateFailed) [self resumeTask:existing];
        return existing;
    }
    if (created) *created = YES;

    MVDownloadTask *task = [MVDownloadTask new];
    task.identifier = NSUUID.UUID.UUIDString;
    task.source = MVTaskSourceDirect;
    task.state = MVTaskStateQueued;
    task.url = url;
    task.headers = headers ?: @{};
    task.referer = referer;
    task.title = title.length ? title : (suggestedFilename.length ? suggestedFilename : url);
    task.suggestedFilename = suggestedFilename;
    task.totalBytes = MAX(0, totalBytes);
    task.connections = self.maxConnections;
    task.category = category.length ? category : [MVPaths categoryForFilename:task.suggestedFilename ?: url];
    task.createdAt = NSDate.date.timeIntervalSince1970;
    task.priority = (NSInteger)task.createdAt;

    // The .part file is created up front so a crash leaves resumable bytes.
    NSString *directory = [MVPaths directoryForCategory:task.category];
    NSString *name = [MVPaths sanitizeFilename:task.suggestedFilename ?: url.lastPathComponent];
    if (!name.length) name = @"download";
    NSString *tempName = [NSString stringWithFormat:@".%@.%@.part", task.identifier, name];
    task.tempPath = [directory stringByAppendingPathComponent:tempName];

    [MVTaskStore.shared add:task];
    MVLogInfo(@"manager: queued direct %@ (%@)", task.title, task.category);
    [self pump];
    return task;
}

- (MVDownloadTask *)enqueueItem:(MVSnifferItem *)item {
    return [self enqueueItem:item added:NULL];
}

- (MVDownloadTask *)enqueueItem:(MVSnifferItem *)item added:(BOOL *)added {
    if (added) *added = NO;
    if (!item.url.length) return nil;

    // An engine that does not exist yet must fail loudly and clearly, not sit at
    // 0% forever. The task is created so the user sees the row and the reason,
    // and the retry path can pick it up once the engine ships.
    switch (item.kind) {
        case MVSniffKindHLS:
            return [self enqueueHLSItem:item added:added];
        case MVSniffKindDASH:
            return [self enqueueDASHItem:item added:added];
        case MVSniffKindTorrent:
            return [self enqueueTorrentItem:item added:added];
        default:
            break;
    }

    BOOL created = NO;
    MVDownloadTask *task = [self enqueueDirectURL:item.url
                                          headers:nil
                                          referer:item.referer ?: item.pageURL
                                            title:item.pageTitle.length ? item.pageTitle : item.displayName
                                    suggestedName:item.suggestedFilename.length ? item.suggestedFilename : item.displayName
                                         category:nil
                                         expected:item.totalBytes
                                          created:&created];
    if (added) *added = created;
    return task;
}

/// The shared path for every engine that downloads from a sniffed item: they
/// differ only in the source tag, the category and the filename, so the
/// queueing, de-duplication and logging live here once.
- (MVDownloadTask *)enqueueItem:(MVSnifferItem *)item
                         source:(MVTaskSource)source
                       category:(NSString *)category
                       filename:(NSString *)filename
                          label:(NSString *)label
                          added:(BOOL *)added {
    MVDownloadTask *existing = [MVTaskStore.shared taskWithURL:item.url];
    if (existing) {
        [MVTaskStore.shared moveToTop:existing];
        if (existing.state == MVTaskStateFailed) [self resumeTask:existing];
        return existing;
    }
    if (added) *added = YES;
    MVDownloadTask *task = [MVDownloadTask new];
    task.identifier = NSUUID.UUID.UUIDString;
    task.source = source;
    task.state = MVTaskStateQueued;
    task.url = item.url;
    task.referer = item.referer ?: item.pageURL;
    task.title = item.pageTitle.length ? item.pageTitle : item.displayName;
    task.suggestedFilename = filename.length ? filename : item.displayName;
    task.category = category;
    task.totalBytes = MAX(0, item.totalBytes);
    task.createdAt = NSDate.date.timeIntervalSince1970;
    task.priority = (NSInteger)task.createdAt;
    [MVTaskStore.shared add:task];
    MVLogInfo(@"manager: queued %@ %@", label, task.title);
    [self pump];
    return task;
}

/// Queues an HLS stream (`.m3u8`).
- (MVDownloadTask *)enqueueHLSItem:(MVSnifferItem *)item added:(BOOL *)added {
    return [self enqueueItem:item source:MVTaskSourceHLS category:@"Videos"
                    filename:[self mp4NameForItem:item] label:@"HLS" added:added];
}

/// Queues a DASH stream (`.mpd`). The engine reads the manifest and joins the
/// segments.
- (MVDownloadTask *)enqueueDASHItem:(MVSnifferItem *)item added:(BOOL *)added {
    return [self enqueueItem:item source:MVTaskSourceDASH category:@"Videos"
                    filename:[self mp4NameForItem:item] label:@"DASH" added:added];
}

/// Queues a .torrent file or a tracker-backed v1 magnet link.
- (MVDownloadTask *)enqueueTorrentItem:(MVSnifferItem *)item added:(BOOL *)added {
    BOOL created = NO;
    MVDownloadTask *task = [self enqueueItem:item source:MVTaskSourceTorrent category:@"Torrents"
                                    filename:item.suggestedFilename label:@"torrent" added:&created];
    // Several .torrent links on one page share the page's title, so the rows
    // would be indistinguishable — including a failed one, whose metadata never
    // loads. The .torrent's own filename is distinct; the metadata name replaces
    // it once the file is read.
    if (created && task && item.suggestedFilename.length) {
        task.title = item.suggestedFilename;
        [MVTaskStore.shared update:task];
    }
    if (added) *added = created;
    return task;
}

/// A stream has no filename of its own, so the title becomes one with an .mp4
/// extension. The segment list cannot be probed for a total size up front, so
/// the progress bar stays indeterminate until the join finishes.
- (NSString *)mp4NameForItem:(MVSnifferItem *)item {
    NSString *base = item.displayName.length ? item.displayName : item.pageTitle;
    if (!base.length) base = @"stream";
    base = [MVPaths sanitizeFilename:base];
    NSString *ext = base.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"mpd"] || !ext.length) {
        base = [base stringByDeletingPathExtension];
        base = [base stringByAppendingPathExtension:@"mp4"];
    }
    return base.length ? base : @"stream.mp4";
}

#pragma mark - Queue

- (NSUInteger)runningCount {
    NSUInteger count = 0;
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        if (task.state == MVTaskStateRunning) count++;
    }
    return count;
}

/// Called on the main queue; a network change wakes a queue held for Wi-Fi.
- (void)pump {
    if (!MVNetworkPolicy.shared.allowsNewDownloads) {
        [self updateBackgroundTask];
        return;
    }
    NSMutableArray<MVDownloadTask *> *queued = [NSMutableArray array];
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        if (task.state == MVTaskStateQueued) [queued addObject:task];
    }
    // Highest priority (lowest number) first, then oldest.
    [queued sortUsingComparator:^NSComparisonResult(MVDownloadTask *a, MVDownloadTask *b) {
        if (a.priority != b.priority) return a.priority < b.priority ? NSOrderedAscending : NSOrderedDescending;
        return a.createdAt < b.createdAt ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (MVDownloadTask *task in queued) {
        if (self.runningCount >= self.maxConcurrentTasks) break;
        if (task.source != MVTaskSourceDirect && task.source != MVTaskSourceHLS &&
            task.source != MVTaskSourceDASH && task.source != MVTaskSourceTorrent) continue;
        [self startTask:task];
    }
    [self updateBackgroundTask];
}

/// A legacy partial base can be shared with another saved row, or have been
/// replaced with a symlink. Do not reuse it in either case: leave it untouched
/// and start in a fresh hidden base belonging to this task.
- (BOOL)preparePartialBaseForTask:(MVDownloadTask *)task {
    if (task.source == MVTaskSourceTorrent) return YES;
    NSMutableArray<NSString *> *protected = [[MVFileProtection pathsExcludingTask:task record:nil] mutableCopy];
    if (task.path.length) [protected addObject:task.path];
    if ([MVFileProtection isSafePartialBase:task.tempPath] &&
        ![MVFileProtection path:task.tempPath conflictsWithPaths:protected]) return YES;

    NSString *directory = [MVPaths directoryForCategory:task.category];
    NSString *base = [directory stringByAppendingPathComponent:
                      [NSString stringWithFormat:@".moodyvid-%@", NSUUID.UUID.UUIDString]];
    if (![MVFileProtection isSafePartialBase:base] ||
        [MVFileProtection path:base conflictsWithPaths:protected]) return NO;
    task.tempPath = base;
    task.segments = @[];
    task.doneBytes = 0;
    task.acceptsRanges = NO;
    task.etag = nil;
    task.lastModified = nil;
    return YES;
}

- (void)startTask:(MVDownloadTask *)task {
    if (task.state != MVTaskStateQueued) return;   // pump is re-entrant
    if (![self preparePartialBaseForTask:task]) {
        task.state = MVTaskStateFailed;
        task.error = [MVLang t:@"Could not save the file"];
        [MVTaskStore.shared update:task];
        return;
    }
    NSString *token = NSUUID.UUID.UUIDString;
    _runTokens[task.identifier] = token;
    task.state = MVTaskStateRunning;
    task.error = nil;
    task.phase = nil;
    task.connections = (task.source == MVTaskSourceTorrent) ? 0 : self.maxConnections;
    [MVTaskStore.shared update:task];

    __weak typeof(self) weakSelf = self;
    BOOL (^isCurrent)(MVDownloadTask *) = ^BOOL(MVDownloadTask *t) {
        typeof(self) self_ = weakSelf;
        return self_ && t.state == MVTaskStateRunning &&
            [self_->_runTokens[t.identifier] isEqualToString:token] &&
            [MVTaskStore.shared taskWithIdentifier:t.identifier] == t;
    };
    void (^onProgress)(MVDownloadTask *) = ^(MVDownloadTask *t) {
        if (!isCurrent(t)) return;
        [weakSelf updateSpeedForTask:t];
        [MVTaskStore.shared update:t];
    };
    void (^onFinished)(MVDownloadTask *) = ^(MVDownloadTask *t) {
        typeof(self) self_ = weakSelf;
        if (!self_ || !isCurrent(t)) return;
        [self_->_runTokens removeObjectForKey:t.identifier];
        t.state = MVTaskStateCompleted;
        t.error = nil;
        t.phase = nil;
        [MVTaskStore.shared update:t];
        [self_ notifyFinished:t];
        [self_ pump];
    };
    void (^onFailed)(MVDownloadTask *, NSString *) = ^(MVDownloadTask *t, NSString *message) {
        typeof(self) self_ = weakSelf;
        if (!self_ || !isCurrent(t)) return;
        [self_->_runTokens removeObjectForKey:t.identifier];
        t.state = MVTaskStateFailed;
        t.error = message;
        t.phase = nil;
        [MVTaskStore.shared update:t];
        [self_ pump];
    };

    if (task.source == MVTaskSourceHLS) {
        [[MVHLSDownloader shared] startTask:task progress:onProgress finished:onFinished failed:onFailed];
    } else if (task.source == MVTaskSourceDASH) {
        [[MVMPDDownloader shared] startTask:task progress:onProgress finished:onFinished failed:onFailed];
    } else if (task.source == MVTaskSourceTorrent) {
        [[MVTorrentDownloader shared] startTask:task progress:onProgress finished:onFinished failed:onFailed];
    } else {
        [[MVFastDownloader shared] startTask:task progress:onProgress finished:onFinished failed:onFailed];
    }
    [self updateBackgroundTask];
}

/// Converts the byte counter into a rate and an ETA. Averages over the sample
/// window rather than the whole run, so the number reacts when the network
/// changes. Cheap: two arithmetic ops per callback.
- (void)updateSpeedForTask:(MVDownloadTask *)task {
    static NSMutableDictionary<NSString *, NSDictionary *> *samples;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ samples = [NSMutableDictionary dictionary]; });

    NSDictionary *previous = samples[task.identifier];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (previous) {
        NSTimeInterval elapsed = now - [previous[@"t"] doubleValue];
        long long delta = task.doneBytes - [previous[@"b"] longLongValue];
        if (elapsed > 0.05) {
            double instant = (double)delta / elapsed;
            double smoothed = previous[@"s"] ? ([previous[@"s"] doubleValue] * 0.6 + instant * 0.4) : instant;
            task.speed = MAX(0, smoothed);
            if (task.speed > 1 && task.totalBytes > task.doneBytes) {
                task.eta = (double)(task.totalBytes - task.doneBytes) / task.speed;
            } else {
                task.eta = 0;
            }
        }
    }
    samples[task.identifier] = @{@"t": @(now), @"b": @(task.doneBytes), @"s": @(task.speed)};
}

#pragma mark - Controls

- (BOOL)path:(NSString *)path isReferencedBesidesTask:(MVDownloadTask *)task {
    return [MVFileProtection path:path
               conflictsWithPaths:[MVFileProtection pathsExcludingTask:task record:nil]];
}

- (void)resumeTask:(MVDownloadTask *)task {
    if (!task) return;
    // Repeated Resume while queued or running must not create a second engine.
    if (task.state != MVTaskStatePaused && task.state != MVTaskStateFailed &&
        task.state != MVTaskStateCancelled) return;
    task.state = MVTaskStateQueued;
    task.error = nil;
    task.phase = nil;
    [MVTaskStore.shared update:task];
    [self pump];
}

- (void)pauseTask:(MVDownloadTask *)task {
    if (!task) return;
    if (task.state == MVTaskStateRunning) {
        [_runTokens removeObjectForKey:task.identifier];
        if (task.source == MVTaskSourceHLS) [[MVHLSDownloader shared] pauseTask:task];
        else if (task.source == MVTaskSourceDASH) [[MVMPDDownloader shared] pauseTask:task];
        else if (task.source == MVTaskSourceTorrent) [[MVTorrentDownloader shared] pauseTask:task];
        else [[MVFastDownloader shared] pauseTask:task];
    }
    if (task.state == MVTaskStateQueued || task.state == MVTaskStateRunning) {
        task.state = MVTaskStatePaused;
        task.speed = 0;
        task.eta = 0;
        [MVTaskStore.shared update:task];
    }
    [self updateBackgroundTask];
}

- (void)cancelTask:(MVDownloadTask *)task deleteFile:(BOOL)deleteFile {
    if (!task) return;
    [_runTokens removeObjectForKey:task.identifier];
    if (task.source == MVTaskSourceHLS) [[MVHLSDownloader shared] cancelTask:task];
    else if (task.source == MVTaskSourceDASH) [[MVMPDDownloader shared] cancelTask:task];
    else if (task.source == MVTaskSourceTorrent) [[MVTorrentDownloader shared] cancelTask:task deletingFiles:deleteFile];
    else [[MVFastDownloader shared] cancelTask:task];
    if (deleteFile) {
        // The sweep checks every individual part, not just its base path.
        if (task.source == MVTaskSourceHLS) [MVHLSDownloader removePartFilesForTask:task];
        else if (task.source == MVTaskSourceDASH) [MVMPDDownloader removePartFilesForTask:task];
        else if (task.source != MVTaskSourceTorrent) [MVFastDownloader removePartFilesForTask:task];
        // Torrent cleanup waits for peer writes to stop.
        if (task.source != MVTaskSourceTorrent && task.path.length &&
            ![self path:task.path isReferencedBesidesTask:task])
            [[NSFileManager defaultManager] removeItemAtPath:task.path error:nil];
    }
    task.state = MVTaskStateCancelled;
    task.speed = 0;
    task.eta = 0;
    [MVTaskStore.shared update:task];
    [self updateBackgroundTask];
}

- (void)removeTask:(MVDownloadTask *)task deleteFile:(BOOL)deleteFile {
    if (!task) return;
    [_runTokens removeObjectForKey:task.identifier];
    if (task.source == MVTaskSourceHLS) [[MVHLSDownloader shared] cancelTask:task];
    else if (task.source == MVTaskSourceDASH) [[MVMPDDownloader shared] cancelTask:task];
    else if (task.source == MVTaskSourceTorrent) [[MVTorrentDownloader shared] cancelTask:task deletingFiles:deleteFile];
    else [[MVFastDownloader shared] cancelTask:task];
    if (deleteFile) {
        if (task.source == MVTaskSourceHLS) [MVHLSDownloader removePartFilesForTask:task];
        else if (task.source == MVTaskSourceDASH) [MVMPDDownloader removePartFilesForTask:task];
        else if (task.source != MVTaskSourceTorrent) [MVFastDownloader removePartFilesForTask:task];
        // Torrent cleanup waits for peer writes to stop.
        if (task.source != MVTaskSourceTorrent && task.path.length &&
            ![self path:task.path isReferencedBesidesTask:task])
            [[NSFileManager defaultManager] removeItemAtPath:task.path error:nil];
    }
    [MVTaskStore.shared remove:task];
    [self updateBackgroundTask];
}

- (void)pauseAll {
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        if (task.state == MVTaskStateQueued || task.state == MVTaskStateRunning) {
            [self pauseTask:task];
        }
    }
}

- (void)resumeAll {
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        if (task.state == MVTaskStatePaused) [self resumeTask:task];
    }
    [self pump];
}

- (void)retryAllFailed {
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        if (task.state == MVTaskStateFailed) [self resumeTask:task];
    }
    [self pump];
}

- (void)moveTaskUp:(MVDownloadTask *)task {
    if (!task) return;
    task.priority = task.priority - 1;
    [MVTaskStore.shared update:task];
}

- (void)moveTaskDown:(MVDownloadTask *)task {
    if (!task) return;
    task.priority = task.priority + 1;
    [MVTaskStore.shared update:task];
}

- (void)resumeInterrupted {
    // The store synchronously converts interrupted Running records to Queued
    // while loading. Repeated calls must never requeue a live in-process run.
    [self pump];
}

#pragma mark - Background time

- (void)updateBackgroundTask {
    // Paused rows and a queue waiting for Wi-Fi must not keep silent audio on.
    BOOL busy = self.runningCount > 0;
    if (busy) {
        if (!_awake) {
            _awake = YES;
            [[MVBackgroundKeeper shared] begin];
        }
        if (_backgroundTask == UIBackgroundTaskInvalid) {
            __weak typeof(self) weakSelf = self;
            _backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"MoodyVid downloads"
                                                                        expirationHandler:^{
                typeof(self) self_ = weakSelf;
                if (!self_) return;
                [self_ endBackgroundTask];
            }];
        }
    } else {
        if (_awake) {
            _awake = NO;
            [[MVBackgroundKeeper shared] end];
        }
        if (_backgroundTask != UIBackgroundTaskInvalid) [self endBackgroundTask];
    }
}

- (void)endBackgroundTask {
    if (_backgroundTask == UIBackgroundTaskInvalid) return;
    [UIApplication.sharedApplication endBackgroundTask:_backgroundTask];
    _backgroundTask = UIBackgroundTaskInvalid;
}

#pragma mark - Notifications

- (void)notifyFinished:(MVDownloadTask *)task {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = [MVLang t:@"Downloaded successfully"];
    content.body = task.title.length ? task.title : task.url;
    content.sound = nil;   // a finished download is not urgent
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:task.identifier
                                                                         content:content
                                                                         trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

@end
