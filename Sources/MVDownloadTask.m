#import "MVDownloadTask.h"
#import "MVCookiePolicy.h"
#import "MVPaths.h"
#include <math.h>

static NSNumber *MVTaskNumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : @0;
}

@implementation MVDownloadTask

@synthesize headers = _headers;

- (void)setHeaders:(NSDictionary<NSString *, NSString *> *)headers {
    // Legacy/raw Cookie headers have no reliable scope or expiry, and could
    // survive a browser-data clear. Never retain or replay them.
    _headers = [[MVCookiePolicy headersWithoutCookies:headers] copy];
}

- (NSString *)resourceContextURL {
    return self.referer.length ? self.referer : self.url;
}

+ (instancetype)taskFromDictionary:(NSDictionary *)dict {
    MVDownloadTask *task = [MVDownloadTask new];
    task.segments = @[];
    NSString *identifier = [dict[@"id"] isKindOfClass:NSString.class] ? dict[@"id"] : nil;
    task.identifier = identifier.length ? identifier : NSUUID.UUID.UUIDString;
    task.source = (MVTaskSource)MVTaskNumber(dict[@"source"]).integerValue;
    // Invalid, fractional or missing states must not turn into Queued when
    // narrowed during recovery and unexpectedly start a download.
    id rawState = dict[@"state"];
    double value = [rawState isKindOfClass:NSNumber.class] ? [rawState doubleValue] : NAN;
    task.state = isfinite(value) && floor(value) == value && value >= MVNativeQueued && value <= MVNativeCancelled ?
                 (MVTaskState)(NSInteger)value : MVTaskStateFailed;
    task.url = [dict[@"url"] isKindOfClass:NSString.class] ? dict[@"url"] : @"";
    task.headers = [dict[@"headers"] isKindOfClass:NSDictionary.class] ? dict[@"headers"] : @{};
    task.referer = [dict[@"referer"] isKindOfClass:NSString.class] ? dict[@"referer"] : nil;
    task.title = [dict[@"title"] isKindOfClass:NSString.class] ? dict[@"title"] : @"";
    task.suggestedFilename = [dict[@"filename"] isKindOfClass:NSString.class] ? dict[@"filename"] : nil;
    task.category = [dict[@"category"] isKindOfClass:NSString.class] ? dict[@"category"] : @"Other";
    task.path = [dict[@"path"] isKindOfClass:NSString.class] ? dict[@"path"] : nil;
    task.tempPath = [dict[@"tempPath"] isKindOfClass:NSString.class] ? dict[@"tempPath"] : nil;
    task.totalBytes = MAX(0LL, MVTaskNumber(dict[@"total"]).longLongValue);
    task.doneBytes = MAX(0LL, MVTaskNumber(dict[@"done"]).longLongValue);
    task.error = [dict[@"error"] isKindOfClass:NSString.class] ? dict[@"error"] : nil;
    task.phase = [dict[@"phase"] isKindOfClass:NSString.class] ? dict[@"phase"] : nil;
    task.acceptsRanges = MVTaskNumber(dict[@"ranges"]).boolValue;
    task.connections = (NSUInteger)MAX(1, MIN(16, MVTaskNumber(dict[@"connections"]).integerValue));
    NSMutableArray<NSArray<NSNumber *> *> *segments = [NSMutableArray array];
    if ([dict[@"segments"] isKindOfClass:NSArray.class]) {
        for (id pair in dict[@"segments"]) {
            if (![pair isKindOfClass:NSArray.class] || [pair count] != 2) continue;
            if (![pair[0] isKindOfClass:NSNumber.class] || ![pair[1] isKindOfClass:NSNumber.class]) continue;
            [segments addObject:@[pair[0], pair[1]]];
        }
    }
    task.segments = segments;
    task.etag = [dict[@"etag"] isKindOfClass:NSString.class] ? dict[@"etag"] : nil;
    task.lastModified = [dict[@"lastModified"] isKindOfClass:NSString.class] ? dict[@"lastModified"] : nil;
    task.createdAt = MVTaskNumber(dict[@"createdAt"]).doubleValue;
    task.updatedAt = MVTaskNumber(dict[@"updatedAt"]).doubleValue;
    task.priority = MVTaskNumber(dict[@"priority"]).integerValue;
    if (!task.createdAt) task.createdAt = NSDate.date.timeIntervalSince1970;
    return task;
}

- (NSDictionary *)dictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"id"] = self.identifier ?: @"";
    dict[@"source"] = @(self.source);
    dict[@"state"] = @(self.state);
    dict[@"url"] = self.url ?: @"";
    if (self.headers.count) dict[@"headers"] = self.headers;
    if (self.referer) dict[@"referer"] = self.referer;
    dict[@"title"] = self.title ?: @"";
    if (self.suggestedFilename) dict[@"filename"] = self.suggestedFilename;
    dict[@"category"] = self.category ?: @"Other";
    if (self.path) dict[@"path"] = self.path;
    if (self.tempPath) dict[@"tempPath"] = self.tempPath;
    dict[@"total"] = @(self.totalBytes);
    dict[@"done"] = @(self.doneBytes);
    if (self.error) dict[@"error"] = self.error;
    if (self.phase) dict[@"phase"] = self.phase;
    dict[@"ranges"] = @(self.acceptsRanges);
    dict[@"connections"] = @(self.connections);
    if (self.segments.count) dict[@"segments"] = self.segments;
    if (self.etag) dict[@"etag"] = self.etag;
    if (self.lastModified) dict[@"lastModified"] = self.lastModified;
    dict[@"createdAt"] = @(self.createdAt);
    dict[@"updatedAt"] = @(self.updatedAt);
    dict[@"priority"] = @(self.priority);
    return dict;
}

- (double)progress {
    if (self.totalBytes <= 0) return self.state == MVTaskStateCompleted ? 1.0 : 0.0;
    return MIN(1.0, MAX(0.0, (double)self.doneBytes / (double)self.totalBytes));
}

- (BOOL)isActive {
    return self.state == MVTaskStateQueued || self.state == MVTaskStateRunning ||
           self.state == MVTaskStatePaused;
}

- (BOOL)isFinished {
    return self.state == MVTaskStateCompleted || self.state == MVTaskStateFailed ||
           self.state == MVTaskStateCancelled;
}

- (BOOL)matchesURL:(NSString *)url {
    if (!url.length || !self.url.length) return NO;
    return [self.url isEqualToString:url];
}

@end
