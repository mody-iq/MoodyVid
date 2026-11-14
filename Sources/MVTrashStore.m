#import "MVTrashStore.h"
#import "MVPaths.h"
#import "MVFileProtection.h"
#import "MVTaskStore.h"
#import "MVDownloadStore.h"
#include <sys/stat.h>
#include <unistd.h>

NSNotificationName const MVTrashDidChangeNotification = @"MVTrashDidChangeNotification";

static BOOL MVContainsPath(NSString *parent, NSString *child) {
    parent = parent.stringByStandardizingPath;
    child = child.stringByStandardizingPath;
    return parent.length && [child hasPrefix:[parent stringByAppendingString:@"/"]];
}

static BOOL MVRegularUnlinkedFile(NSString *path, struct stat *info) {
    struct stat local;
    if (!info) info = &local;
    return path.length && lstat(path.fileSystemRepresentation, info) == 0 &&
           S_ISREG(info->st_mode) && info->st_nlink == 1;
}

@implementation MVStorageProtection
+ (NSArray<NSString *> *)protectedPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        // Even a paused, failed or cancelled row can be resumed later.
        if (task.tempPath.length) [paths addObject:task.tempPath];
        if (task.state != MVTaskStateCompleted && task.path.length) [paths addObject:task.path];
    }
    for (MVDownloadRecord *record in MVDownloadStore.shared.records) {
        NSString *work = [MVPaths pythonWorkDirectoryForIdentifier:record.identifier];
        if (work.length) [paths addObject:work];
        if (record.state != MVDownloadStateCompleted && record.path.length) [paths addObject:record.path];
    }
    return paths;
}

+ (void)forgetCompletedRecordsAtPath:(NSString *)path {
    if (!path.length) return;
    NSString *standard = path.stringByStandardizingPath;
    // A completed history row must not keep pointing at the original pathname:
    // another file may later appear there, or restore may choose a new name.
    // Remove only completed rows for the exact path, without deleting bytes.
    for (MVDownloadTask *task in MVTaskStore.shared.tasks) {
        if (task.state == MVTaskStateCompleted && task.path.length &&
            [task.path.stringByStandardizingPath isEqualToString:standard]) {
            [MVTaskStore.shared remove:task];
        }
    }
    for (MVDownloadRecord *record in MVDownloadStore.shared.records) {
        if (record.state == MVDownloadStateCompleted && record.path.length &&
            [record.path.stringByStandardizingPath isEqualToString:standard]) {
            [MVDownloadStore.shared remove:record];
        }
    }
}
@end

@implementation MVTrashStore {
    NSString *_root;
    NSString *_trash;
}

+ (instancetype)shared {
    static MVTrashStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[self alloc] initWithRoot:MVPaths.downloads
                                    trash:[MVPaths.applicationSupport stringByAppendingPathComponent:@"Trash"]];
    });
    return store;
}

- (instancetype)initWithRoot:(NSString *)root trash:(NSString *)trash {
    if ((self = [super init])) { _root = root.stringByStandardizingPath; _trash = trash.stringByStandardizingPath; }
    return self;
}

- (NSString *)entryDirectory:(NSString *)identifier {
    struct stat trashInfo;
    if (lstat(_trash.fileSystemRepresentation, &trashInfo) != 0 || !S_ISDIR(trashInfo.st_mode)) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid || ![uuid.UUIDString isEqualToString:identifier.uppercaseString]) return nil;
    NSString *directory = [_trash stringByAppendingPathComponent:uuid.UUIDString];
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) return nil;
    return directory;
}

- (NSString *)relativeForPath:(NSString *)path {
    struct stat rootInfo;
    if (lstat(_root.fileSystemRepresentation, &rootInfo) != 0 || !S_ISDIR(rootInfo.st_mode)) return nil;
    NSString *standard = path.stringByStandardizingPath;
    NSString *resolvedRoot = _root.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *resolved = standard.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (!MVContainsPath(_root, standard) || !MVContainsPath(resolvedRoot, resolved)) return nil;
    return [standard substringFromIndex:_root.length + 1];
}

- (BOOL)isSafeRelativePath:(NSString *)relative {
    if (![relative isKindOfClass:NSString.class] || !relative.length || relative.isAbsolutePath) return NO;
    for (NSString *part in relative.pathComponents) {
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            [part rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    }
    return YES;
}

- (NSArray<NSDictionary *> *)entries {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:_trash error:NULL] ?: @[];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *identifier in names) {
        NSString *directory = [self entryDirectory:identifier];
        NSString *payload = [directory stringByAppendingPathComponent:@"content"];
        struct stat info;
        if (!directory || !MVRegularUnlinkedFile(payload, &info)) continue;
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"info.plist"]];
        NSString *relative = [metadata[@"original"] isKindOfClass:NSString.class] ? metadata[@"original"] : nil;
        if (![self isSafeRelativePath:relative]) relative = nil;
        NSString *name = relative.lastPathComponent ?: [NSString stringWithFormat:@"Recovered-%@", identifier];
        NSDate *date = [metadata[@"date"] isKindOfClass:NSDate.class] ? metadata[@"date"] : [NSDate distantPast];
        [entries addObject:@{@"identifier": identifier, @"name": name, @"original": relative ?: @"",
                             @"size": @((long long)info.st_size), @"date": date}];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"date"] compare:a[@"date"]]; }];
    return entries;
}

- (BOOL)moveToTrash:(NSString *)path protecting:(NSArray<NSString *> *)protectedPaths error:(NSString **)error {
    NSString *relative = [self relativeForPath:path];
    struct stat info;
    if (!relative || ![self isSafeRelativePath:relative] || !MVRegularUnlinkedFile(path, &info)) {
        if (error) *error = @"Only regular files inside Downloads can be moved to Trash.";
        return NO;
    }
    if ([MVFileProtection path:path conflictsWithPaths:protectedPaths]) {
        if (error) *error = @"This file is needed by a saved download. Remove its task first, or leave it in place.";
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    struct stat trashInfo;
    if (![fm createDirectoryAtPath:_trash withIntermediateDirectories:YES attributes:nil error:NULL] ||
        lstat(_trash.fileSystemRepresentation, &trashInfo) != 0 || !S_ISDIR(trashInfo.st_mode)) {
        if (error) *error = @"Could not move the file to Trash.";
        return NO;
    }
    NSString *directory = [_trash stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL]) {
        if (error) *error = @"Could not move the file to Trash.";
        return NO;
    }
    NSDictionary *metadata = @{@"original": relative, @"date": NSDate.date};
    NSString *infoPath = [directory stringByAppendingPathComponent:@"info.plist"];
    NSString *payload = [directory stringByAppendingPathComponent:@"content"];
    if (![metadata writeToFile:infoPath atomically:YES]) {
        [fm removeItemAtPath:infoPath error:NULL];
        rmdir(directory.fileSystemRepresentation); // only an empty directory
        if (error) *error = @"Could not move the file to Trash.";
        return NO;
    }
    // Recheck the object immediately before the move. The filesystem can still
    // change concurrently through Files; never delete the source on failure.
    struct stat current;
    if (!MVRegularUnlinkedFile(path, &current) || current.st_dev != info.st_dev || current.st_ino != info.st_ino ||
        ![fm moveItemAtPath:path toPath:payload error:NULL]) {
        // If a filesystem operation partly succeeded, never remove the new
        // payload: keep it recoverable even when the API reported an error.
        struct stat landed;
        if (lstat(payload.fileSystemRepresentation, &landed) != 0) {
            [fm removeItemAtPath:infoPath error:NULL];
            rmdir(directory.fileSystemRepresentation);
        }
        if (error) *error = @"Could not move the file to Trash.";
        return NO;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:MVTrashDidChangeNotification object:self];
    return YES;
}

- (NSString *)restore:(NSString *)identifier protecting:(NSArray<NSString *> *)protectedPaths error:(NSString **)error {
    struct stat rootInfo;
    if (lstat(_root.fileSystemRepresentation, &rootInfo) != 0 || !S_ISDIR(rootInfo.st_mode)) {
        if (error) *error = @"Could not restore the file."; return nil;
    }
    NSString *directory = [self entryDirectory:identifier];
    NSString *payload = [directory stringByAppendingPathComponent:@"content"];
    if (!directory || !MVRegularUnlinkedFile(payload, NULL)) {
        if (error) *error = @"This item is no longer in Trash.";
        return nil;
    }
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"info.plist"]];
    NSString *relative = [metadata[@"original"] isKindOfClass:NSString.class] ? metadata[@"original"] : nil;
    if (![self isSafeRelativePath:relative]) relative = [NSString stringWithFormat:@"Recovered-%@", identifier];
    NSString *destination = [_root stringByAppendingPathComponent:relative].stringByStandardizingPath;
    if (!MVContainsPath(_root, destination)) { if (error) *error = @"Could not restore the file."; return nil; }
    NSString *parent = destination.stringByDeletingLastPathComponent;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *resolvedRoot = _root.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *resolvedParent = parent.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (![resolvedParent isEqualToString:resolvedRoot] && !MVContainsPath(resolvedRoot, resolvedParent)) {
        if (error) *error = @"Could not restore the file."; return nil;
    }
    if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:NULL]) {
        if (error) *error = @"Could not restore the file."; return nil;
    }
    resolvedParent = parent.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (![resolvedParent isEqualToString:resolvedRoot] && !MVContainsPath(resolvedRoot, resolvedParent)) {
        if (error) *error = @"Could not restore the file."; return nil;
    }
    struct stat existing;
    if (lstat(destination.fileSystemRepresentation, &existing) == 0) {
        NSString *name = destination.lastPathComponent;
        NSString *stem = name.stringByDeletingPathExtension, *ext = name.pathExtension;
        destination = nil;
        for (NSUInteger i = 1; i <= 10000; i++) {
            NSString *candidate = [NSString stringWithFormat:@"%@ (restored %lu)", stem, (unsigned long)i];
            if (ext.length) candidate = [candidate stringByAppendingPathExtension:ext];
            candidate = [parent stringByAppendingPathComponent:candidate];
            if (lstat(candidate.fileSystemRepresentation, &existing) != 0) { destination = candidate; break; }
        }
    }
    if (!destination || [MVFileProtection path:destination conflictsWithPaths:protectedPaths] ||
        ![fm moveItemAtPath:payload toPath:destination error:NULL]) {
        if (error) *error = @"Could not restore the file."; return nil;
    }
    [fm removeItemAtPath:[directory stringByAppendingPathComponent:@"info.plist"] error:NULL];
    rmdir(directory.fileSystemRepresentation); // only if empty; never recurse into user bytes
    [NSNotificationCenter.defaultCenter postNotificationName:MVTrashDidChangeNotification object:self];
    return destination;
}

- (BOOL)deletePermanently:(NSString *)identifier error:(NSString **)error {
    NSString *directory = [self entryDirectory:identifier];
    NSArray *children = directory ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL] : nil;
    NSSet *allowed = [NSSet setWithArray:@[@"content", @"info.plist"]];
    BOOL hasUnexpectedFiles = NO;
    for (NSString *child in children) if (![allowed containsObject:child]) { hasUnexpectedFiles = YES; break; }
    if (!directory || !children || hasUnexpectedFiles ||
        !MVRegularUnlinkedFile([directory stringByAppendingPathComponent:@"content"], NULL) ||
        ![NSFileManager.defaultManager removeItemAtPath:directory error:NULL]) {
        if (error) *error = @"Could not delete this item.";
        return NO;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:MVTrashDidChangeNotification object:self];
    return YES;
}
@end
