#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#import "MVTorrentStorage.h"
#import "MVTorrentPolicy.h"
#import "MVPaths.h"
#import "MVSHA1.h"

/// A file descriptor kept open for the life of the download.
@interface MVTorrentFileHandle : NSObject
@property (nonatomic) int fd;
@property (nonatomic) long long length;
@property (nonatomic) long long offset;
@end
@implementation MVTorrentFileHandle
- (instancetype)init { if ((self = [super init])) _fd = -1; return self; }
- (void)dealloc { if (_fd >= 0) close(_fd); }
@end

@implementation MVTorrentStorage {
    NSMutableArray<MVTorrentFileHandle *> *_handles;
}

- (instancetype)initWithMetadata:(MVTorrentMetadata *)metadata root:(NSString *)root {
    if ((self = [super init])) {
        _metadata = metadata;
        _root = [root copy];
        _handles = [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSString *> *)safeComponentsForFile:(MVTorrentFile *)file {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in file.path) [components addObject:[MVPaths sanitizeFilename:component]];
    return components;
}

- (NSString *)outputPath {
    if (self.metadata.isSingleFile) {
        NSString *path = self.root;
        for (NSString *component in [self safeComponentsForFile:self.metadata.files.firstObject]) {
            path = [path stringByAppendingPathComponent:component];
        }
        return path;
    }
    return self.root;
}

/// Refuse names which become identical, or a file used as a parent directory,
/// after sanitization. On common iOS filesystems case and Unicode variants also
/// alias. Check the entire layout before creating or truncating any file.
- (BOOL)hasUnambiguousLayout {
    NSMutableSet<NSString *> *files = [NSMutableSet set];
    NSMutableSet<NSString *> *directories = [NSMutableSet set];
    for (MVTorrentFile *file in self.metadata.files) {
        if (file.isPadding) continue;
        NSArray<NSString *> *components = [self safeComponentsForFile:file];
        if (!components.count) return NO;
        NSString *key = @"";
        for (NSUInteger i = 0; i < components.count; i++) {
            NSString *component = components[i].precomposedStringWithCanonicalMapping.lowercaseString;
            key = key.length ? [key stringByAppendingFormat:@"/%@", component] : component;
            if (i + 1 < components.count) {
                if ([files containsObject:key]) return NO;
                [directories addObject:key];
            } else {
                if ([files containsObject:key] || [directories containsObject:key]) return NO;
                [files addObject:key];
            }
        }
    }
    return YES;
}

/// Open every directory and file relative to a trusted root descriptor. Unlike
/// path-based create/open, O_NOFOLLOW will not follow an existing symlink into a
/// different download. Reject hard-linked files too, so writes stay task-owned.
- (int)openFile:(MVTorrentFile *)file relativeTo:(int)rootFD {
    NSArray<NSString *> *components = [self safeComponentsForFile:file];
    if (!components.count) return -1;
    int directory = dup(rootFD);
    if (directory < 0) return -1;
    for (NSUInteger i = 0; i + 1 < components.count; i++) {
        const char *name = components[i].fileSystemRepresentation;
        if (mkdirat(directory, name, 0700) != 0 && errno != EEXIST) {
            close(directory);
            return -1;
        }
        int next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(directory);
        if (next < 0) return -1;
        directory = next;
    }
    int fd = openat(directory, components.lastObject.fileSystemRepresentation,
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    close(directory);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_nlink != 1 ||
        ftruncate(fd, (off_t)file.length) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

- (BOOL)prepare:(NSString **)error {
    if (![self hasUnambiguousLayout]) {
        if (error) *error = @"Torrent file paths collide after sanitizing";
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:self.root withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (error) *error = @"Could not create the download folder";
        return NO;
    }
    int rootFD = open(self.root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (rootFD < 0) {
        if (error) *error = @"Could not safely open the torrent folder";
        return NO;
    }
    [_handles removeAllObjects];
    for (MVTorrentFile *file in self.metadata.files) {
        if (file.isPadding) continue;
        int fd = [self openFile:file relativeTo:rootFD];
        if (fd < 0) {
            close(rootFD);
            [_handles removeAllObjects];
            if (error) *error = @"Could not safely create the torrent file";
            return NO;
        }
        MVTorrentFileHandle *handle = [MVTorrentFileHandle new];
        handle.fd = fd;
        handle.length = file.length;
        handle.offset = file.offset;
        [_handles addObject:handle];
    }
    close(rootFD);
    return YES;
}

- (BOOL)validRangeAtOffset:(long long)offset length:(long long)length {
    long long total = self.metadata.totalLength;
    return offset >= 0 && length >= 0 && offset <= total && length <= total - offset;
}

- (MVTorrentFileHandle *)handleForOffset:(long long)offset {
    for (MVTorrentFileHandle *handle in _handles) {
        if (offset >= handle.offset && offset - handle.offset < handle.length) return handle;
    }
    return nil;
}

- (MVTorrentFile *)paddingForOffset:(long long)offset {
    for (MVTorrentFile *file in self.metadata.files) {
        if (file.isPadding && offset >= file.offset && offset - file.offset < file.length) return file;
    }
    return nil;
}

- (BOOL)writeData:(NSData *)data atOffset:(long long)offset error:(NSString **)error {
    if (data.length > (NSUInteger)LLONG_MAX || ![self validRangeAtOffset:offset length:(long long)data.length]) {
        if (error) *error = @"write outside the torrent";
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    long long written = 0, total = (long long)data.length;
    while (written < total) {
        long long position = offset + written;
        MVTorrentFileHandle *handle = [self handleForOffset:position];
        if (!handle) {
            MVTorrentFile *padding = [self paddingForOffset:position];
            if (!padding) { if (error) *error = @"write outside a torrent file"; return NO; }
            long long skip = MIN(total - written, padding.length - (position - padding.offset));
            // BEP 47 padding represents zero bytes. Do not claim a piece was
            // stored if discarding nonzero bytes would make it unverifiable.
            for (long long i = 0; i < skip; i++) {
                if (bytes[written + i] != 0) { if (error) *error = @"torrent padding is not zero"; return NO; }
            }
            written += skip;
            continue;
        }
        long long inFile = position - handle.offset;
        long long chunk = MIN(total - written, handle.length - inFile);
        ssize_t n = pwrite(handle.fd, bytes + written, (size_t)chunk, (off_t)inFile);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (error) *error = @"Could not write to disk"; return NO; }
        written += n;
    }
    return YES;
}

- (nullable NSData *)readAtOffset:(long long)offset length:(long long)length error:(NSString **)error {
    if (length > MV_TORRENT_MAX_PIECE_BYTES || ![self validRangeAtOffset:offset length:length]) {
        if (error) *error = @"read outside the torrent or too large";
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)length];
    uint8_t *bytes = out.mutableBytes;
    long long read = 0;
    while (read < length) {
        long long position = offset + read;
        MVTorrentFileHandle *handle = [self handleForOffset:position];
        if (!handle) {
            MVTorrentFile *padding = [self paddingForOffset:position];
            if (!padding) { if (error) *error = @"read outside a torrent file"; return nil; }
            read += MIN(length - read, padding.length - (position - padding.offset));
            continue; // NSMutableData starts as zero; padding is not stored.
        }
        long long inFile = position - handle.offset;
        long long chunk = MIN(length - read, handle.length - inFile);
        ssize_t n = pread(handle.fd, bytes + read, (size_t)chunk, (off_t)inFile);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (error) *error = @"Could not read from disk"; return nil; }
        read += n;
    }
    return out;
}

- (nullable NSData *)readPiece:(NSInteger)index error:(NSString **)error {
    if (index < 0 || index >= self.metadata.pieceCount) return nil;
    long long offset = (long long)index * self.metadata.pieceLength;
    long long length = MIN(self.metadata.pieceLength, self.metadata.totalLength - offset);
    return [self readAtOffset:offset length:length error:error];
}

- (BOOL)verifyPiece:(NSInteger)index {
    NSData *expected = [self.metadata hashForPiece:index];
    if (!expected.length) return NO;
    NSData *data = [self readPiece:index error:nil];
    return data && [MVSHA1 data:data matchesDigest:expected];
}

- (void)removeAll {
    for (MVTorrentFileHandle *handle in _handles) {
        if (handle.fd >= 0) { close(handle.fd); handle.fd = -1; }
    }
    [_handles removeAllObjects];
    [NSFileManager.defaultManager removeItemAtPath:self.root error:nil];
}

@end
