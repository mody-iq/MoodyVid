// Local HTTP integration tests for the real native transfer engines.
#import <Foundation/Foundation.h>
#import "MVFastDownloader.h"
#import "MVHLSDownloader.h"
#import "MVMPDDownloader.h"
#import "MVFileProtection.h"
#import "MVTaskStore.h"
#import "MVDownloadStore.h"
#include <stdio.h>
#include <unistd.h>

@interface MVTaskStore (TestFixtures)
+ (void)setTestTasks:(NSArray *)tasks;
@end
@interface MVDownloadStore (TestFixtures)
+ (void)setTestRecords:(NSArray *)records;
@end

static int failures = 0;
#define CHECK(x, message) do { if (!(x)) { fprintf(stderr, "FAIL: %s\n", message); failures++; } } while (0)

@interface MVHLSDownloader (TestNetworking)
- (NSData *)syncGet:(NSString *)url headers:(NSDictionary *)headers error:(NSError **)error;
@end
@interface MVMPDDownloader (TestNetworking)
- (NSData *)syncGet:(NSString *)url headers:(NSDictionary *)headers error:(NSError **)error;
@end

static NSData *expectedPayload(void) {
    NSUInteger length = 2 * 1024 * 1024 + 2000;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    unsigned char *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) bytes[i] = (unsigned char)(i % 251);
    return data;
}

// mode: 0 normal, 1 pause/resume, 2 cancel/delete and immediately restart.
static void runDirect(NSString *base, NSString *route, BOOL shouldSucceed, NSInteger mode) {
    MVFastDownloader *engine = [MVFastDownloader new];
    MVDownloadTask *task = [MVDownloadTask new];
    task.identifier = NSUUID.UUID.UUIDString;
    task.url = [base stringByAppendingString:route];
    task.title = route;
    task.category = @"Other";
    task.suggestedFilename = [NSString stringWithFormat:@"%@.bin", task.identifier];
    task.headers = @{};
    task.connections = mode || [route isEqualToString:@"/wrong"] ? 1 : 4;
    task.state = MVTaskStateRunning;
    __block BOOL done = NO, succeeded = NO, restarted = NO;
    __block NSString *errorMessage = nil;
    __block __weak void (^weakProgress)(MVDownloadTask *);
    void (^finished)(MVDownloadTask *) = ^(MVDownloadTask *completed) { succeeded = YES; done = YES; };
    void (^failed)(MVDownloadTask *, NSString *) = ^(MVDownloadTask *failedTask, NSString *message) { errorMessage = message; done = YES; };
    void (^progress)(MVDownloadTask *) = ^(MVDownloadTask *updated) {
        if (!mode || restarted || updated.doneBytes < 65536) return;
        restarted = YES;
        if (mode == 1) {
            [engine pauseTask:updated];
        } else {
            [engine cancelTask:updated];
            [MVFastDownloader removePartFilesForTask:updated];
            updated.url = [base stringByAppendingString:@"/normal"];
            updated.segments = @[];
            updated.etag = nil;
            updated.lastModified = nil;
            updated.doneBytes = 0;
        }
        [engine startTask:updated progress:weakProgress finished:finished failed:failed];
    };
    weakProgress = progress;
    [engine startTask:task progress:progress finished:finished failed:failed];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    if (!done || succeeded != shouldSucceed || (mode && !restarted)) {
        fprintf(stderr, "FAIL: direct %s mode %ld: done=%d success=%d restarted=%d error=%s\n",
                route.UTF8String, (long)mode, done, succeeded, restarted, errorMessage.UTF8String ?: "");
        failures++;
    }
    if (succeeded) {
        NSData *actual = [NSData dataWithContentsOfFile:task.path];
        CHECK([actual isEqualToData:expectedPayload()], "direct transfer output must match exactly");
        [NSFileManager.defaultManager removeItemAtPath:task.path error:nil];
    }
    [engine cancelTask:task];
    [MVFastDownloader removePartFilesForTask:task];
}

static void testStreams(NSString *base) {
    NSDictionary *range = @{@"Range": @"bytes=10-19"};
    MVHLSDownloader *hls = [MVHLSDownloader new];
    MVMPDDownloader *dash = [MVMPDDownloader new];
    for (id engine in @[hls, dash]) {
        NSError *error = nil;
        NSData *data = [engine syncGet:[base stringByAppendingString:@"/stream"] headers:range error:&error];
        CHECK(data.length == 10 && !error, "stream accepts a valid 206 range");
        error = nil;
        data = [engine syncGet:[base stringByAppendingString:@"/stream-ignored"] headers:range error:&error];
        CHECK(!data && error, "stream rejects a server that ignores Range");
        error = nil;
        data = [engine syncGet:[base stringByAppendingString:@"/stream-bad"] headers:range error:&error];
        CHECK(!data && error, "stream rejects malformed Content-Range");
        error = nil;
        data = [engine syncGet:[base stringByAppendingString:@"/stream-unsolicited"] headers:@{} error:&error];
        CHECK(!data && error, "stream rejects unsolicited partial response");
    }
}

static void testPartialOwnership(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *directory = NSProcessInfo.processInfo.environment[@"MV_TRANSFER_TEST_DIR"];
    for (NSInteger kind = 0; kind < 3; kind++) {
        MVDownloadTask *owner = [MVDownloadTask new];
        owner.tempPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".owner-%@", NSUUID.UUID.UUIDString]];
        NSString *shared = [owner.tempPath stringByAppendingString:kind == 0 ? @"0" : @".seg0"];
        NSString *unshared = [owner.tempPath stringByAppendingString:kind == 0 ? @"1" : @".seg1"];
        NSData *content = [@"keep" dataUsingEncoding:NSUTF8StringEncoding];
        CHECK([content writeToFile:shared atomically:YES] && [content writeToFile:unshared atomically:YES], "partial fixtures created");
        NSString *alias = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"alias-%@", NSUUID.UUID.UUIDString]];
        CHECK(symlink(shared.fileSystemRepresentation, alias.fileSystemRepresentation) == 0, "reference alias created");
        MVDownloadTask *other = [MVDownloadTask new];
        other.path = alias;
        [MVTaskStore setTestTasks:@[owner]];
        [MVDownloadStore setTestRecords:@[other]]; // only .path is used on a record
        if (kind == 0) [MVFastDownloader removePartFilesForTask:owner];
        else if (kind == 1) [MVHLSDownloader removePartFilesForTask:owner];
        else [MVMPDDownloader removePartFilesForTask:owner];
        CHECK([fm fileExistsAtPath:shared] && ![fm fileExistsAtPath:unshared],
              "each cleanup keeps a symlink-referenced partial but removes its unshared sibling");
        [MVDownloadStore setTestRecords:@[]];
        other.tempPath = owner.tempPath;
        [MVTaskStore setTestTasks:@[owner, other]];
        if (kind == 0) [MVFastDownloader removePartFilesForTask:owner];
        else if (kind == 1) [MVHLSDownloader removePartFilesForTask:owner];
        else [MVMPDDownloader removePartFilesForTask:owner];
        CHECK([fm fileExistsAtPath:shared], "another task's base protects its individual parts");
        [MVTaskStore setTestTasks:@[]];
        [fm removeItemAtPath:alias error:nil];
        [fm removeItemAtPath:shared error:nil];
    }

    NSString *base = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@".unsafe-%@", NSUUID.UUID.UUIDString]];
    NSString *part = [base stringByAppendingString:@"0"];
    NSString *target = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"sentinel-%@", NSUUID.UUID.UUIDString]];
    [@"sentinel" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CHECK(symlink(target.fileSystemRepresentation, part.fileSystemRepresentation) == 0 &&
          ![MVFileProtection isSafePartialBase:base] && ![MVFileProtection isSafePartialItemAtPath:part],
          "a symlinked partial is not reused");
    [fm removeItemAtPath:part error:nil];
    CHECK(link(target.fileSystemRepresentation, part.fileSystemRepresentation) == 0 &&
          ![MVFileProtection isSafePartialBase:base] && ![MVFileProtection isSafePartialItemAtPath:part],
          "a multiply linked partial is not reused");
    [fm removeItemAtPath:part error:nil];
    [fm createDirectoryAtPath:part withIntermediateDirectories:NO attributes:nil error:nil];
    CHECK(![MVFileProtection isSafePartialBase:base] &&
          ![MVFileProtection removePartialItemAtPath:part protecting:@[]] && [fm fileExistsAtPath:part],
          "a directory that looks like a partial is never recursively removed");
    [fm removeItemAtPath:part error:nil];
    [fm removeItemAtPath:target error:nil];
    CHECK(![MVFileProtection isSafePartialBase:@"/outside/.part"], "partial bases outside downloads are rejected");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "Usage: transfer_integration BASE_URL\n"); return 2; }
        NSString *base = [NSString stringWithUTF8String:argv[1]];
        testPartialOwnership();
        runDirect(base, @"/normal", YES, 0);
        runDirect(base, @"/ignore", YES, 0);
        runDirect(base, @"/collapse", YES, 0);
        runDirect(base, @"/badprobe", NO, 0);
        runDirect(base, @"/wrong", NO, 0);
        runDirect(base, @"/slow", YES, 1);
        runDirect(base, @"/stale", YES, 2);
        testStreams(base);
        if (!failures) puts("native HTTP transfer integration: OK");
    }
    return failures ? 1 : 0;
}
