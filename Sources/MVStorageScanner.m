#import "MVStorageScanner.h"
#import "MVFileProtection.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

static BOOL MVIsPartial(NSString *path) {
    NSString *name = path.lastPathComponent.lowercaseString;
    if ([path containsString:@"/.moodyvid-work/"]) return YES;
    if (![name hasPrefix:@"."]) return NO;
    return [name hasPrefix:@".moodyvid-"] || [name containsString:@".part"] ||
           [name containsString:@".seg"] || [name containsString:@".joining-"];
}

static NSString *MVHashFile(NSString *path, unsigned long long expected, BOOL (^cancel)(void)) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat before, after;
    if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_nlink != 1 ||
        before.st_size < 0 || (unsigned long long)before.st_size != expected) { close(fd); return nil; }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[65536];
    unsigned long long readTotal = 0;
    BOOL okay = YES;
    for (;;) {
        if (cancel && cancel()) { okay = NO; break; }
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { okay = NO; break; }
        if (count == 0) break;
        readTotal += (unsigned long long)count;
        if (readTotal > expected) { okay = NO; break; }
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    if (fstat(fd, &after) != 0 || after.st_dev != before.st_dev || after.st_ino != before.st_ino ||
        after.st_size != before.st_size || after.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec ||
        after.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec || readTotal != expected) okay = NO;
    close(fd);
    if (!okay) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof(digest) * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

@implementation MVStorageScanner {
    NSString *_root;
    NSUInteger _maximumFiles;
    unsigned long long _hashBudget;
}

- (instancetype)initWithRoot:(NSString *)root maximumFiles:(NSUInteger)maximumFiles hashBudget:(unsigned long long)hashBudget {
    if ((self = [super init])) { _root = root.stringByStandardizingPath; _maximumFiles = maximumFiles; _hashBudget = hashBudget; }
    return self;
}

- (NSDictionary *)scanProtecting:(NSArray<NSString *> *)protectedPaths cancelled:(BOOL (^)(void))cancel {
    NSMutableArray *large = [NSMutableArray array], *partials = [NSMutableArray array], *duplicates = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSDictionary *> *> *sizes = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:[NSURL fileURLWithPath:_root isDirectory:YES]
        includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    NSString *root = _root.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSUInteger count = 0;
    BOOL limited = NO;
    for (NSURL *url in enumerator) {
        if (cancel && cancel()) { limited = YES; break; }
        NSString *path = url.path.stringByStandardizingPath;
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0) continue;
        if (S_ISDIR(info.st_mode)) {
            if ([path.lastPathComponent hasPrefix:@"."] && ![path.lastPathComponent isEqualToString:@".moodyvid-work"]) {
                [enumerator skipDescendants];
            }
            continue;
        }
        if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_size < 0) continue;
        NSString *resolved = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
        if (![resolved hasPrefix:[root stringByAppendingString:@"/"]]) continue;
        BOOL partial = MVIsPartial(path);
        if (!partial && [path.lastPathComponent hasPrefix:@"."]) continue;
        if (count >= _maximumFiles) { limited = YES; break; }
        count++;
        BOOL protected = [MVFileProtection path:path conflictsWithPaths:protectedPaths];
        NSDictionary *entry = @{@"path": path, @"size": @((unsigned long long)info.st_size), @"protected": @(protected)};
        if (partial) { [partials addObject:entry]; continue; }
        [large addObject:entry];
        if (!protected && info.st_size > 0) {
            NSNumber *size = entry[@"size"];
            if (!sizes[size]) sizes[size] = [NSMutableArray array];
            [sizes[size] addObject:entry];
        }
    }
    NSComparator biggestFirst = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        unsigned long long x = [a[@"size"] unsignedLongLongValue], y = [b[@"size"] unsignedLongLongValue];
        return x > y ? NSOrderedAscending : (x < y ? NSOrderedDescending : [a[@"path"] compare:b[@"path"]]);
    };
    [large sortUsingComparator:biggestFirst];
    [partials sortUsingComparator:biggestFirst];

    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *hashes = [NSMutableDictionary dictionary];
    unsigned long long budget = _hashBudget;
    for (NSNumber *size in sizes) {
        NSArray *bucket = sizes[size];
        if (bucket.count < 2) continue;
        for (NSDictionary *entry in bucket) {
            if (cancel && cancel()) { limited = YES; break; }
            unsigned long long bytes = [size unsignedLongLongValue];
            if (bytes > budget) { limited = YES; continue; }
            budget -= bytes;
            NSString *hash = MVHashFile(entry[@"path"], bytes, cancel);
            if (!hash) continue;
            NSString *key = [NSString stringWithFormat:@"%@:%@", size, hash];
            if (!hashes[key]) hashes[key] = [NSMutableArray array];
            [hashes[key] addObject:entry];
        }
        if (cancel && cancel()) break;
    }
    NSUInteger group = 0;
    for (NSString *key in [[hashes allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray *matches = hashes[key];
        if (matches.count < 2) continue;
        group++;
        for (NSDictionary *entry in matches) {
            NSMutableDictionary *copy = [entry mutableCopy];
            copy[@"group"] = @(group);
            [duplicates addObject:copy];
        }
    }
    return @{@"large": large, @"duplicates": duplicates, @"partials": partials, @"limited": @(limited)};
}
@end
