// Foundation-only persisted-model/restart tests in a disposable directory.
#import <Foundation/Foundation.h>
#import "MVDownloadTask.h"
#import "MVDownloadStore.h"
#import "MVTaskStore.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)
static NSString *fixtureDirectory;

@interface MVPaths : NSObject
+ (NSString *)documents;
+ (NSString *)applicationSupport;
@end
@implementation MVPaths
+ (NSString *)documents { return fixtureDirectory; }
+ (NSString *)applicationSupport { return fixtureDirectory; }
@end

@interface MVCookiePolicy : NSObject
+ (NSDictionary *)headersWithoutCookies:(NSDictionary *)headers;
@end
@implementation MVCookiePolicy
+ (NSDictionary *)headersWithoutCookies:(NSDictionary *)headers {
    if (![headers isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (id key in headers) {
        id value = headers[key];
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class] &&
            [key caseInsensitiveCompare:@"cookie"] != NSOrderedSame &&
            [key caseInsensitiveCompare:@"cookie2"] != NSOrderedSame) clean[key] = value;
    }
    return clean;
}
@end

@interface MVLog : NSObject
+ (void)log:(NSString *)level format:(NSString *)format, ...;
@end
@implementation MVLog
+ (void)log:(NSString *)level format:(NSString *)format, ... { (void)level; (void)format; }
@end

@interface MVDownloadManager : NSObject
+ (instancetype)shared;
- (void)removeTask:(MVDownloadTask *)task deleteFile:(BOOL)deleteFile;
@end
@implementation MVDownloadManager
+ (instancetype)shared { return [self new]; }
- (void)removeTask:(MVDownloadTask *)task deleteFile:(BOOL)deleteFile { (void)task; (void)deleteFile; }
@end

static MVDownloadTask *Task(NSArray<MVDownloadTask *> *tasks, NSString *identifier) {
    for (MVDownloadTask *task in tasks) if ([task.identifier isEqualToString:identifier]) return task;
    return nil;
}
static MVDownloadRecord *Record(NSArray<MVDownloadRecord *> *records, NSString *identifier) {
    for (MVDownloadRecord *record in records) if ([record.identifier isEqualToString:identifier]) return record;
    return nil;
}

int main(void) {
    @autoreleasepool {
        fixtureDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *fm = NSFileManager.defaultManager;
        CHECK([fm createDirectoryAtPath:fixtureDirectory withIntermediateDirectories:YES attributes:nil error:nil], "fixture folder created");
        NSString *url = @"https://example.test/file";
        NSArray *tasks = @[
            @{@"id": @"running", @"url": url, @"source": @1, @"state": @1},
            @{@"id": @"paused", @"url": url, @"source": @1, @"state": @2},
            @{@"id": @"cancelled", @"url": url, @"source": @1, @"state": @5},
            @{@"id": @"bad", @"url": url, @"source": @1, @"state": @[], @"total": @{},
              @"connections": @[], @"priority": @[], @"headers": @{@"Cookie": @"secret", @"X-Test": @"ok"}},
            @{@"id": @"running", @"url": url, @"source": @1, @"state": @2},
            @{@"id": @"huge", @"url": url, @"source": @1, @"state": @4294967297LL},
            @{@"id": @"missing-state", @"url": url, @"source": @1},
        ];
        NSData *data = [NSJSONSerialization dataWithJSONObject:tasks options:0 error:nil];
        CHECK([data writeToFile:[fixtureDirectory stringByAppendingPathComponent:@"tasks.json"] atomically:YES], "task fixture written");
        MVTaskStore *taskStore = [MVTaskStore new];
        CHECK(taskStore.tasks.count == 7, "native fixtures loaded");
        CHECK(Task(taskStore.tasks, @"running").state == MVTaskStateQueued, "running native job is requeued");
        CHECK(Task(taskStore.tasks, @"paused").state == MVTaskStatePaused, "native pause survives restart");
        CHECK(Task(taskStore.tasks, @"cancelled").state == MVTaskStateCancelled, "native cancellation survives restart");
        MVDownloadTask *bad = Task(taskStore.tasks, @"bad");
        CHECK(bad && bad.state == MVTaskStateFailed && bad.totalBytes == 0 && bad.connections == 1, "malformed native fields do not crash or auto-run");
        CHECK(!bad.headers[@"Cookie"] && [bad.headers[@"X-Test"] isEqualToString:@"ok"], "stored raw cookies are stripped");
        if (taskStore.tasks.count == 7) {
            MVDownloadTask *duplicate = taskStore.tasks[4];
            CHECK(![duplicate.identifier isEqualToString:@"running"] && duplicate.state == MVTaskStatePaused,
                  "duplicate native identifiers are isolated");
        }
        CHECK(Task(taskStore.tasks, @"huge").state == MVTaskStateFailed &&
              Task(taskStore.tasks, @"missing-state").state == MVTaskStateFailed,
              "invalid native state cannot narrow to running or queued");

        NSArray *records = @[
            @{@"id": @"active", @"url": url, @"state": @1},
            @{@"id": @"paused", @"url": url, @"state": @5},
            @{@"id": @"cancelled", @"url": url, @"state": @4},
            @{@"id": @"bad", @"url": url, @"state": @{}, @"path": @[], @"total": @[], @"quality": @{}},
            @{@"id": @"active", @"url": url, @"state": @5},
            @{@"id": @"huge", @"url": url, @"state": @4294967297LL},
            @{@"id": @"missing-state", @"url": url},
            @{@"id": @"missing-url", @"url": @{}, @"state": @1},
        ];
        data = [NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
        CHECK([data writeToFile:[fixtureDirectory stringByAppendingPathComponent:@"downloads.json"] atomically:YES], "record fixture written");
        MVDownloadStore *store = [MVDownloadStore new];
        CHECK(store.records.count == 7, "Python fixtures loaded, invalid URL skipped");
        CHECK(Record(store.records, @"active").state == MVDownloadStateWaiting, "active Python job is requeued");
        CHECK(Record(store.records, @"paused").state == MVDownloadStatePaused, "Python pause survives restart");
        CHECK(Record(store.records, @"cancelled").state == MVDownloadStateCancelled, "Python cancellation survives restart");
        MVDownloadRecord *badRecord = Record(store.records, @"bad");
        CHECK(badRecord && badRecord.state == MVDownloadStateFailed && !badRecord.path &&
              badRecord.totalBytes == 0 && [badRecord.quality isEqualToString:@"best"], "malformed Python fields are contained");
        if (store.records.count == 7) {
            MVDownloadRecord *duplicate = store.records[4];
            CHECK(![duplicate.identifier isEqualToString:@"active"] && duplicate.state == MVDownloadStatePaused,
                  "duplicate Python identifiers are isolated");
        }
        CHECK(Record(store.records, @"huge").state == MVDownloadStateFailed &&
              Record(store.records, @"missing-state").state == MVDownloadStateFailed,
              "invalid Python state cannot narrow to active or waiting");
        CHECK(!Record(store.records, @"missing-url"), "records without a usable URL are not started");
        [fm removeItemAtPath:fixtureDirectory error:nil];
        if (!failures) puts("persisted queue recovery: OK");
    }
    return failures ? 1 : 0;
}
