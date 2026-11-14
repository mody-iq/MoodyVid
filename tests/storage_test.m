#import <Foundation/Foundation.h>
#import "MVTrashStore.h"
#import "MVStorageScanner.h"
#import "MVTaskStore.h"
#import "MVDownloadStore.h"
#include <unistd.h>
#include <stdio.h>

@interface MVTaskStore (StorageTestFixtures)
+ (void)setTestTasks:(NSArray *)tasks;
@end
@interface MVDownloadStore (StorageTestFixtures)
+ (void)setTestRecords:(NSArray *)records;
@end
// Only the path and state accessors are needed by history cleanup.
@interface FakeHistoryItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSInteger state;
@end
@implementation FakeHistoryItem
@end

static int failures = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); failures++; } } while (0)
static BOOL writeFile(NSString *path, NSString *text) {
    return [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
static NSString *readText(NSString *path) { return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]; }

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *root = [dir stringByAppendingPathComponent:@"Downloads"];
        NSString *trash = [dir stringByAppendingPathComponent:@"Trash"];
        NSString *work = [root stringByAppendingPathComponent:@".moodyvid-work/task"];
        CHECK([fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *a = [root stringByAppendingPathComponent:@"a.mp4"];
        NSString *b = [root stringByAppendingPathComponent:@"b.mp4"];
        NSString *c = [root stringByAppendingPathComponent:@"c.mp4"];
        NSString *partial = [root stringByAppendingPathComponent:@".old.part0"];
        CHECK(writeFile(a, @"same") && writeFile(b, @"same") && writeFile(c, @"diff") && writeFile(partial, @"partial"));
        CHECK(writeFile([work stringByAppendingPathComponent:@"clip.part"], @"partial2"));
        NSString *outside = [dir stringByAppendingPathComponent:@"outside.txt"];
        CHECK(writeFile(outside, @"outside"));
        NSString *linkPath = [root stringByAppendingPathComponent:@"link"];
        CHECK(symlink(outside.fileSystemRepresentation, linkPath.fileSystemRepresentation) == 0);

        MVStorageScanner *scanner = [[MVStorageScanner alloc] initWithRoot:root maximumFiles:100 hashBudget:10000];
        NSDictionary *scan = [scanner scanProtecting:@[[root stringByAppendingPathComponent:@".old.part"]] cancelled:nil];
        CHECK([scan[@"large"] count] == 3 && [scan[@"partials"] count] == 2 && [scan[@"duplicates"] count] == 2);
        CHECK(![scan[@"limited"] boolValue]);
        NSArray *matches = scan[@"duplicates"];
        CHECK([matches[0][@"group"] isEqual:matches[1][@"group"]]);
        BOOL protectedPartial = NO;
        for (NSDictionary *entry in scan[@"partials"]) if ([entry[@"path"] isEqual:partial]) protectedPartial = [entry[@"protected"] boolValue];
        CHECK(protectedPartial);
        scanner = [[MVStorageScanner alloc] initWithRoot:root maximumFiles:100 hashBudget:3];
        CHECK([[[scanner scanProtecting:@[] cancelled:nil] objectForKey:@"limited"] boolValue]);
        CHECK([[readText(a) description] isEqualToString:@"same"] && [fm fileExistsAtPath:partial]);

        MVTrashStore *store = [[MVTrashStore alloc] initWithRoot:root trash:trash];
        NSString *error = nil;
        CHECK(![store moveToTrash:a protecting:@[a] error:&error] && [fm fileExistsAtPath:a]);
        CHECK(![store moveToTrash:outside protecting:@[] error:&error]);
        CHECK(![store moveToTrash:linkPath protecting:@[] error:&error]);
        CHECK(![store moveToTrash:work protecting:@[] error:&error]);
        FakeHistoryItem *completedTask = [FakeHistoryItem new];
        completedTask.path = a; completedTask.state = MVTaskStateCompleted;
        FakeHistoryItem *unfinishedTask = [FakeHistoryItem new];
        unfinishedTask.path = a; unfinishedTask.state = MVTaskStatePaused;
        FakeHistoryItem *otherTask = [FakeHistoryItem new];
        otherTask.path = b; otherTask.state = MVTaskStateCompleted;
        FakeHistoryItem *completedRecord = [FakeHistoryItem new];
        completedRecord.path = a; completedRecord.state = MVDownloadStateCompleted;
        FakeHistoryItem *unfinishedRecord = [FakeHistoryItem new];
        unfinishedRecord.path = a; unfinishedRecord.state = MVDownloadStatePaused;
        [MVTaskStore setTestTasks:@[completedTask, unfinishedTask, otherTask]];
        [MVDownloadStore setTestRecords:@[completedRecord, unfinishedRecord]];
        CHECK([store moveToTrash:a protecting:@[] error:&error] && ![fm fileExistsAtPath:a]);
        [MVStorageProtection forgetCompletedRecordsAtPath:a];
        CHECK([MVTaskStore.shared.tasks isEqualToArray:@[unfinishedTask, otherTask]]);
        CHECK([MVDownloadStore.shared.records isEqualToArray:@[unfinishedRecord]]);
        [MVTaskStore setTestTasks:@[]];
        [MVDownloadStore setTestRecords:@[]];
        NSArray *entries = store.entries;
        CHECK(entries.count == 1);
        NSString *identifier = entries.firstObject[@"identifier"];
        CHECK(writeFile(a, @"new")); // restore must never clobber a newer file
        NSString *restored = [store restore:identifier protecting:@[] error:&error];
        CHECK(restored.length && ![restored isEqualToString:a] && [readText(restored) isEqualToString:@"same"]);
        CHECK([readText(a) isEqualToString:@"new"] && store.entries.count == 0);

        CHECK([store moveToTrash:b protecting:@[] error:&error]);
        identifier = store.entries.firstObject[@"identifier"];
        NSString *entry = [trash stringByAppendingPathComponent:identifier];
        NSDictionary *bad = @{@"original": @"../../outside.txt", @"date": NSDate.date};
        CHECK([bad writeToFile:[entry stringByAppendingPathComponent:@"info.plist"] atomically:YES]);
        restored = [store restore:identifier protecting:@[] error:&error];
        CHECK([restored hasPrefix:[root stringByAppendingPathComponent:@"Recovered-"]] &&
              [readText(restored) isEqualToString:@"same"] && [readText(outside) isEqualToString:@"outside"]);

        CHECK([store moveToTrash:c protecting:@[] error:&error]);
        identifier = store.entries.firstObject[@"identifier"];
        entry = [trash stringByAppendingPathComponent:identifier];
        NSString *unexpected = [entry stringByAppendingPathComponent:@"extra"];
        CHECK(writeFile(unexpected, @"keep"));
        CHECK(![store deletePermanently:identifier error:&error] && [fm fileExistsAtPath:unexpected]);
        CHECK([fm removeItemAtPath:unexpected error:NULL]);
        CHECK([store deletePermanently:identifier error:&error] && store.entries.count == 0);
        CHECK([readText(outside) isEqualToString:@"outside"] && [fm fileExistsAtPath:partial]);
        [fm removeItemAtPath:dir error:NULL];
        if (!failures) puts("storage analysis and recoverable trash: OK");
    }
    return failures ? 1 : 0;
}
