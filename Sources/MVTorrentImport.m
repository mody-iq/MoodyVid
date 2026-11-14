#import "MVTorrentImport.h"
#import "MVTorrentMetadata.h"
#import "MVTorrentPolicy.h"
#import "MVPaths.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const MVImportedTorrentPrefix = @"moodyvid-torrent:";

static NSString *MVImportedTorrentName(NSString *reference) {
    if (![reference isKindOfClass:NSString.class] || ![reference hasPrefix:MVImportedTorrentPrefix]) return nil;
    NSString *identifier = [reference substringFromIndex:MVImportedTorrentPrefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid || ![uuid.UUIDString isEqualToString:identifier]) return nil;
    return [identifier stringByAppendingPathExtension:@"torrent"];
}

// Only bounded regular files are read; a picker URL or private cache entry may
// have changed since it was selected. All bytes are read before validation.
static NSData *MVReadTorrentDescriptor(int fd) {
    struct stat before, after;
    if (fd < 0 || fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size <= 0 ||
        before.st_size > 2 * MV_TORRENT_MAX_METADATA_BYTES) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
    uint8_t *bytes = data.mutableBytes;
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t count = read(fd, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return nil;
        offset += (size_t)count;
    }
    if (fstat(fd, &after) != 0 || after.st_dev != before.st_dev || after.st_ino != before.st_ino ||
        after.st_size != before.st_size) return nil;
    return data;
}

@implementation MVTorrentImport {
    NSString *_directory;
}

+ (instancetype)shared {
    static MVTorrentImport *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[self alloc] initWithDirectory:[MVPaths.applicationSupport stringByAppendingPathComponent:@"TorrentImports"]];
    });
    return store;
}

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) _directory = directory.stringByStandardizingPath;
    return self;
}

+ (BOOL)isImportReference:(NSString *)reference { return MVImportedTorrentName(reference) != nil; }

- (int)openDirectoryCreating:(BOOL)create {
    if (create && ![NSFileManager.defaultManager createDirectoryAtPath:_directory
                                          withIntermediateDirectories:YES
                                                           attributes:@{NSFilePosixPermissions: @0700}
                                                                error:NULL]) return -1;
    return open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

- (NSString *)importFileURL:(NSURL *)url error:(NSString **)error {
    if (!url.isFileURL) { if (error) *error = @"This torrent file could not be read"; return nil; }
    int input = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    NSData *data = MVReadTorrentDescriptor(input);
    if (input >= 0) close(input);
    if (!data || ![MVTorrentMetadata metadataWithTorrentData:data error:NULL]) {
        if (error) *error = @"This torrent file could not be read";
        return nil;
    }
    int directory = [self openDirectoryCreating:YES];
    if (directory < 0) { if (error) *error = @"Could not save the torrent file"; return nil; }
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *temporary = [identifier stringByAppendingPathExtension:@"tmp"];
    NSString *name = [identifier stringByAppendingPathExtension:@"torrent"];
    int output = openat(directory, temporary.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    BOOL ok = output >= 0;
    size_t offset = 0;
    const uint8_t *bytes = data.bytes;
    while (ok && offset < data.length) {
        ssize_t count = write(output, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += (size_t)count;
    }
    if (ok && fsync(output) != 0) ok = NO;
    if (output >= 0 && close(output) != 0) ok = NO;
    // linkat creates the final name only if absent; unlike rename, it cannot
    // replace another file. Both names are in the same private directory.
    if (ok && linkat(directory, temporary.fileSystemRepresentation,
                     directory, name.fileSystemRepresentation, 0) != 0) ok = NO;
    if (output >= 0) unlinkat(directory, temporary.fileSystemRepresentation, 0);
    close(directory);
    if (!ok) { if (error) *error = @"Could not save the torrent file"; return nil; }
    return [MVImportedTorrentPrefix stringByAppendingString:identifier];
}

- (NSData *)dataForReference:(NSString *)reference {
    NSString *name = MVImportedTorrentName(reference);
    if (!name) return nil;
    int directory = [self openDirectoryCreating:NO];
    if (directory < 0) return nil;
    int fd = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    NSData *data = MVReadTorrentDescriptor(fd);
    if (fd >= 0) close(fd);
    close(directory);
    return data;
}

- (void)removeReference:(NSString *)reference {
    NSString *name = MVImportedTorrentName(reference);
    if (!name) return;
    int directory = [self openDirectoryCreating:NO];
    if (directory < 0) return;
    struct stat info, temporaryInfo;
    if (fstatat(directory, name.fileSystemRepresentation, &info, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(info.st_mode)) {
        // A crash between linkat and unlinkat can leave our own temporary name
        // attached to the same inode. Remove only that exact extra link.
        NSString *temporary = [name.stringByDeletingPathExtension stringByAppendingPathExtension:@"tmp"];
        if (info.st_nlink == 2 &&
            fstatat(directory, temporary.fileSystemRepresentation, &temporaryInfo, AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISREG(temporaryInfo.st_mode) && temporaryInfo.st_dev == info.st_dev && temporaryInfo.st_ino == info.st_ino) {
            unlinkat(directory, temporary.fileSystemRepresentation, 0);
        }
        if (fstatat(directory, name.fileSystemRepresentation, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISREG(info.st_mode) && info.st_nlink == 1) unlinkat(directory, name.fileSystemRepresentation, 0);
    }
    close(directory);
}
@end
