#import "MVDownloadManager.h"
#import "MVTaskStore.h"
#import "MVFastDownloader.h"
#import "MVPaths.h"
#import "MVMediaProbe.h"
#import "MVLang.h"
#import "MVLog.h"
#import "MVBackgroundKeeper.h"
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <string.h>

/// A per-task throttle cap when the user has not set one. Kept here rather than
/// in the downloader so the default lives with the other queue settings.
static const NSUInteger kDefaultConnections = 6;
static const NSUInteger kDefaultConcurrent = 3;

@implementation MVDownloadManager {
    UIBackgroundTaskIdentifier _backgroundTask;
    BOOL _awake;
    NSTimer *_ticker;
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
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _maxConnections = [defaults objectForKey:@"MVMaxConnections"] ? [defaults integerForKey:@"MVMaxConnections"] : kDefaultConnections;
        _maxConcurrentTasks = [defaults objectForKey:@"MVMaxConcurrent"] ? [defaults integerForKey:@"MVMaxConcurrent"] : kDefaultConcurrent;
        _speedLimit = [defaults integerForKey:@"MVSpeedLimit"];
        _wifiOnly = [defaults boolForKey:@"MVWifiOnly"];
        [MVFastDownloader shared].speedLimit = _speedLimit;
        _maxConnections = MIN(16, MAX(1, _maxConnections));
        _maxConcurrentTasks = MIN(5, MAX(1, _maxConcurrentTasks));

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(pump)
                                                   name:MVTaskStoreDidChangeNotification object:nil];
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
}

- (void)setWifiOnly:(BOOL)wifiOnly {
    _wifiOnly = wifiOnly;
    [NSUserDefaults.standardUserDefaults setBool:wifiOnly forKey:@"MVWifiOnly"];
    [self pump];
}

#pragma mark - Enqueue

- (MVDownloadTask *)enqueueDirectURL:(NSString *)url
                             headers:(NSDictionary<NSString *, NSString *> *)headers
                             referer:(NSString *)referer
                               title:(NSString *)title
                       suggestedName:(NSString *)suggestedFilename
                            category:(NSString *)category
                            expected:(long long)totalBytes {
    if (!url.length) return nil;

    // Skip duplicates: re-adding the same URL moves the existing row to the top.
    MVDownloadTask *existing = [MVTaskStore.shared taskWithURL:url];
    if (existing) {
        [MVTaskStore.shared moveToTop:existing];
        if (existing.state == MVTaskStateFailed) [self resumeTask:existing];
        return existing;
    }

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
    if (!item.url.length) return nil;

    // An engine that does not exist yet must fail loudly and clearly, not sit at
    // 0% forever. The task is created so the user sees the row and the reason,
    // and the retry path can pick it up once the engine ships.
    switch (item.kind) {
        case MVSniffKindHLS:
        case MVSniffKindDASH:
            return [self enqueueDeferredItem:item reason:[MVLang t:@"Stream downloads arrive in a later update"]];
        case MVSniffKindTorrent:
            return [self enqueueDeferredItem:item reason:[MVLang t:@"Torrent downloads arrive in a later update"]];
        default:
            break;
    }

    return [self enqueueDirectURL:item.url
                          headers:nil
                          referer:item.referer ?: item.pageURL
                            title:item.pageTitle.length ? item.pageTitle : item.displayName
                    suggestedName:item.suggestedFilename.length ? item.suggestedFilename : item.displayName
                         category:nil
                         expected:item.totalBytes];
}

/// Records a task for a kind whose engine is not built yet, with an explicit,
/// localised reason. The UI shows the reason and a Retry that will work later.
- (MVDownloadTask *)enqueueDeferredItem:(MVSnifferItem *)item reason:(NSString *)reason {
    MVDownloadTask *existing = [MVTaskStore.shared taskWithURL:item.url];
    if (existing) {
        [MVTaskStore.shared moveToTop:existing];
        return existing;
    }
    MVDownloadTask *task = [MVDownloadTask new];
    task.identifier = NSUUID.UUID.UUIDString;
    task.source = (item.kind == MVSniffKindTorrent) ? MVTaskSourceTorrent : MVTaskSourceHLS;
    task.state = MVTaskStateFailed;
    task.url = item.url;
    task.referer = item.referer ?: item.pageURL;
    task.title = item.pageTitle.length ? item.pageTitle : item.displayName;
    task.suggestedFilename = item.suggestedFilename.length ? item.suggestedFilename : item.displayName;
    task.category = [MVPaths categoryForFilename:task.suggestedFilename ?: item.url];
    task.error = reason;
    task.createdAt = NSDate.date.timeIntervalSince1970;
    task.priority = (NSInteger)task.createdAt;
    [MVTaskStore.shared add:task];
    MVLogWarn(@"manager: deferred %@ (%@)", task.title, reason);
    return task;
}

#pragma mark - Queue

- (NSUInteger)runningCount {
    NSUInteger count = 0;
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        if (task.state == MVTaskStateRunning) count++;
    }
    return count;
}

/// Starts queued direct tasks while there is room, respecting Wi-Fi-only.
/// Called on the main queue, and idempotent, so it is safe from a notification.
- (void)pump {
    if (self.wifiOnly && !self.isOnWifi) {
        MVLogInfo(@"manager: holding queue, Wi-Fi only");
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
        if (task.source != MVTaskSourceDirect) continue;   // other engines come later
        [self startTask:task];
    }
    [self updateBackgroundTask];
}

- (void)startTask:(MVDownloadTask *)task {
    if (task.state == MVTaskStateRunning) return;   // pump is re-entrant
    task.state = MVTaskStateRunning;
    task.error = nil;
    task.phase = nil;
    task.connections = self.maxConnections;
    [MVTaskStore.shared update:task];

    __weak typeof(self) weakSelf = self;
    [[MVFastDownloader shared] startTask:task
        progress:^(MVDownloadTask *t) {
            // The downloader already computed the rate; the manager only stores.
            [weakSelf updateSpeedForTask:t];
            [MVTaskStore.shared update:t];
        }
        finished:^(MVDownloadTask *t) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            t.state = MVTaskStateCompleted;
            t.error = nil;
            t.phase = nil;
            [MVTaskStore.shared update:t];
            [self_ notifyFinished:t];
            [self_ pump];
        }
        failed:^(MVDownloadTask *t, NSString *message) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            t.state = MVTaskStateFailed;
            t.error = message;
            [MVTaskStore.shared update:t];
            [self_ pump];
        }];
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
    NSTimeInterval now = NSDate.date.timeIntervalSinceNow;
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

- (void)resumeTask:(MVDownloadTask *)task {
    if (!task) return;
    if (task.source != MVTaskSourceDirect) {
        // Not built yet: keep the honest reason rather than pretending.
        task.state = MVTaskStateFailed;
        task.error = (task.source == MVTaskSourceTorrent)
            ? [MVLang t:@"Torrent downloads arrive in a later update"]
            : [MVLang t:@"Stream downloads arrive in a later update"];
        [MVTaskStore.shared update:task];
        return;
    }
    if (task.state == MVTaskStateCompleted) return;
    task.state = MVTaskStateQueued;
    task.error = nil;
    task.phase = nil;
    [MVTaskStore.shared update:task];
    [self pump];
}

- (void)pauseTask:(MVDownloadTask *)task {
    if (!task) return;
    if (task.state == MVTaskStateRunning) [[MVFastDownloader shared] pauseTask:task];
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
    [[MVFastDownloader shared] cancelTask:task];
    if (deleteFile) {
        if (task.tempPath.length) [[NSFileManager defaultManager] removeItemAtPath:task.tempPath error:nil];
        if (task.path.length) [[NSFileManager defaultManager] removeItemAtPath:task.path error:nil];
    }
    task.state = MVTaskStateCancelled;
    task.speed = 0;
    task.eta = 0;
    [MVTaskStore.shared update:task];
    [self updateBackgroundTask];
}

- (void)removeTask:(MVDownloadTask *)task deleteFile:(BOOL)deleteFile {
    if (!task) return;
    [[MVFastDownloader shared] cancelTask:task];
    if (deleteFile) {
        if (task.tempPath.length) [[NSFileManager defaultManager] removeItemAtPath:task.tempPath error:nil];
        if (task.path.length) [[NSFileManager defaultManager] removeItemAtPath:task.path error:nil];
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
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        // A task left Running was killed with the process; it is resumable, so
        // re-queue it rather than making the user press Retry on every row.
        if (task.state == MVTaskStateRunning) {
            task.state = MVTaskStateQueued;
            [MVTaskStore.shared update:task];
        }
    }
    // One pass now, and one after a short delay: a row that was left "Running"
    // is only correct once the store's load has finished replacing it, and the
    // second pass also picks up a queue the user restored in the meantime.
    [self pump];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self pump]; });
}

#pragma mark - Wi-Fi

/// Wi-Fi is the only network the "Wi-Fi only" rule allows, so a cellular or
/// unknown connection reports NO and the queue waits for Wi-Fi.
///
/// getifaddrs is used because it reports the interface type without the Network
/// framework. An "en" interface with a routable IPv4 address is Wi-Fi; "pdp_ip"
/// is cellular. The syscall never touches the network itself.
- (BOOL)isOnWifi {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return YES;   // fail open rather than stall
    BOOL wifi = NO;
    for (struct ifaddrs *ifa = interfaces; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (strncmp(ifa->ifa_name, "en", 2) == 0) { wifi = YES; break; }
    }
    freeifaddrs(interfaces);
    return wifi;
}

#pragma mark - Background time

- (void)updateBackgroundTask {
    BOOL busy = self.runningCount > 0 || MVTaskStore.shared.activeTasks.count > 0;
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
