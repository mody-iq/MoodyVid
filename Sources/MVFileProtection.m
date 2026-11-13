#import "MVFileProtection.h"
#import "MVPaths.h"
#import "MVTaskStore.h"
#import "MVDownloadStore.h"
#include <sys/stat.h>
#include <errno.h>

static NSString *MVNormalizedPath(NSString *path, BOOL resolve) {
    if (resolve) path = path.stringByResolvingSymlinksInPath;
    return path.stringByStandardizingPath.precomposedStringWithCanonicalMapping.lowercaseString;
}

// A temp base is not itself a directory: its files are siblings formed by
// appending a numeric segment or a dot suffix. Compare in both directions so
// a reference to an individual part also protects its base and vice versa.
static BOOL MVDerivedPath(NSString *path, NSString *base) {
    if (path.length <= base.length || ![path hasPrefix:base]) return NO;
    unichar next = [path characterAtIndex:base.length];
    return next == '.' || (next >= '0' && next <= '9');
}

@implementation MVFileProtection

+ (NSArray<NSString *> *)pathsExcludingTask:(MVDownloadTask *)task record:(MVDownloadRecord *)record {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (MVDownloadTask *other in MVTaskStore.shared.tasks) {
        if (other == task) continue;
        if (other.path.length) [paths addObject:[other.path copy]];
        if (other.tempPath.length) [paths addObject:[other.tempPath copy]];
    }
    for (MVDownloadRecord *other in MVDownloadStore.shared.records) {
        if (other != record && other.path.length) [paths addObject:[other.path copy]];
    }
    return paths;
}

+ (BOOL)path:(NSString *)path conflictsWithPaths:(NSArray<NSString *> *)paths {
    if (!path.length) return NO;
    for (NSString *reference in paths) {
        if (!reference.length) continue;
        if ([MVPaths path:path overlapsPath:reference]) return YES;
        for (NSInteger resolved = 0; resolved <= 1; resolved++) {
            NSString *a = MVNormalizedPath(path, resolved != 0);
            NSString *b = MVNormalizedPath(reference, resolved != 0);
            if (MVDerivedPath(a, b) || MVDerivedPath(b, a)) return YES;
        }
    }
    return NO;
}

+ (BOOL)isSafePartialBase:(NSString *)base {
    if (!base.length || !base.isAbsolutePath || ![base.lastPathComponent hasPrefix:@"."] ||
        [base.lastPathComponent isEqualToString:@"."] || [base.lastPathComponent isEqualToString:@".."]) return NO;
    NSString *downloads = MVPaths.downloads;
    struct stat rootInfo;
    if (!downloads.length || lstat(downloads.fileSystemRepresentation, &rootInfo) != 0 ||
        !S_ISDIR(rootInfo.st_mode) || S_ISLNK(rootInfo.st_mode)) return NO;
    NSString *root = downloads.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *parent = base.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (!root.length || (![parent isEqualToString:root] && ![parent hasPrefix:[root stringByAppendingString:@"/"]])) return NO;
    NSString *directory = base.stringByDeletingLastPathComponent;
    NSString *stem = base.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
    struct stat info;
    if (lstat(base.fileSystemRepresentation, &info) == 0) {
        if (!S_ISREG(info.st_mode) || info.st_nlink != 1) return NO;
    } else if (errno != ENOENT) return NO;
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    if (!names) return NO;
    for (NSString *name in names) {
        if (!MVDerivedPath(name.precomposedStringWithCanonicalMapping.lowercaseString, stem)) continue;
        NSString *candidate = [directory stringByAppendingPathComponent:name];
        if (lstat(candidate.fileSystemRepresentation, &info) == 0) {
            if (!S_ISREG(info.st_mode) || info.st_nlink != 1) return NO;
        } else if (errno != ENOENT) return NO;
    }
    return YES;
}

+ (BOOL)isSafePartialItemAtPath:(NSString *)path {
    if (!path.length) return NO;
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return errno == ENOENT;
    return S_ISREG(info.st_mode) && info.st_nlink == 1;
}

+ (BOOL)removePartialItemAtPath:(NSString *)path protecting:(NSArray<NSString *> *)paths {
    if (!path.length) return NO;
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return errno == ENOENT;
    if (!S_ISREG(info.st_mode) && !S_ISLNK(info.st_mode)) return NO;
    return [self removeItemAtPath:path protecting:paths];
}

+ (BOOL)removeItemAtPath:(NSString *)path protecting:(NSArray<NSString *> *)paths {
    if (!path.length || [self path:path conflictsWithPaths:paths]) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    // A broken symlink is still an item and must be removed with lstat, not a
    // fileExistsAtPath: check which follows it and reports it missing.
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return errno == ENOENT;
    return [fm removeItemAtPath:path error:nil];
}
@end
