#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#import "MVTorrentStorage.h"
#import "MVPaths.h"
#import "MVSHA1.h"

/// A file descriptor kept open for the life of the download, so a write never
/// has to reopen and re-seek. The offsets make it cheap to reuse.
@interface MVTorrentFileHandle : NSObject
@property (nonatomic) int fd;
@property (nonatomic) long long length;
@property (nonatomic) long long offset;
@property (nonatomic, copy) NSString *path;
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
        _root = root;
        _handles = [NSMutableArray array];
    }
    return self;
}

- (NSString *)outputPath {
    if (self.metadata.isSingleFile) {
        // Must match exactly where -prepare wrote the file, so the sanitising in
        // -pathForFile: is applied here too.
        return [self pathForFile:self.metadata.files.firstObject inFolder:self.root];
    }
    return self.root;
}

- (BOOL)prepare:(NSString **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    // The files of a torrent live under the folder the caller passes.
    NSString *folder = self.root;
    if (![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (error) *error = @"Could not create the download folder";
        return NO;
    }

    for (MVTorrentFile *file in self.metadata.files) {
        if (file.isPadding) continue;
        NSString *path = [self pathForFile:file inFolder:folder];
        if (file.length <= 0) continue;
        if (![fm fileExistsAtPath:path]) {
            if (![fm createFileAtPath:path contents:nil attributes:nil]) {
                if (error) *error = @"Could not create the torrent file";
                return NO;
            }
        }
        int fd = open(path.fileSystemRepresentation, O_RDWR);
        if (fd < 0) {
            if (error) *error = @"Could not open the torrent file for writing";
            return NO;
        }
        MVTorrentFileHandle *handle = [MVTorrentFileHandle new];
        handle.fd = fd;
        handle.length = file.length;
        handle.offset = file.offset;
        handle.path = path;
        [_handles addObject:handle];
    }
    return YES;
}

/// Builds the on-disk path of a file, creating intermediate folders.
- (NSString *)pathForFile:(MVTorrentFile *)file inFolder:(NSString *)folder {
    NSString *path = folder;
    NSArray<NSString *> *components = file.path;
    for (NSUInteger i = 0; i < components.count; i++) {
        NSString *component = [MVPaths sanitizeFilename:components[i]];
        if (!component.length) component = @"file";
        path = [path stringByAppendingPathComponent:component];
        if (i < components.count - 1) {
            [NSFileManager.defaultManager createDirectoryAtPath:path
                                    withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
    return path;
}

- (BOOL)writeData:(NSData *)data atOffset:(long long)offset error:(NSString **)error {
    const uint8_t *bytes = data.bytes;
    long long written = 0;
    long long total = (long long)data.length;
    while (written < total) {
        long long position = offset + written;
        MVTorrentFileHandle *handle = [self handleForOffset:position];
        if (!handle) {
            // Padding regions have no handle; skip the bytes that fall in them.
            long long skip = [self bytesToNextHandleFrom:position];
            if (skip <= 0) { if (error) *error = @"write past the end of the torrent"; return NO; }
            written += skip;
            continue;
        }
        long long inFile = position - handle.offset;
        long long room = handle.length - inFile;
        long long chunk = MIN(total - written, room);
        if (chunk <= 0) { if (error) *error = @"write outside a file"; return NO; }
        if (pwrite(handle.fd, bytes + written, (size_t)chunk, inFile) != chunk) {
            if (error) *error = @"Could not write to disk";
            return NO;
        }
        written += chunk;
    }
    return YES;
}

- (nullable NSData *)readAtOffset:(long long)offset length:(long long)length error:(NSString **)error {
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)length];
    uint8_t *bytes = out.mutableBytes;
    long long read = 0;
    while (read < length) {
        long long position = offset + read;
        MVTorrentFileHandle *handle = [self handleForOffset:position];
        if (!handle) {
            long long skip = [self bytesToNextHandleFrom:position];
            if (skip <= 0) { if (error) *error = @"read past the end of the torrent"; return nil; }
            // Padding bytes read back as zero, matching what a peer sends.
            read += skip;
            continue;
        }
        long long inFile = position - handle.offset;
        long long room = handle.length - inFile;
        long long chunk = MIN(length - read, room);
        if (chunk <= 0) { if (error) *error = @"read outside a file"; return nil; }
        ssize_t got = pread(handle.fd, bytes + read, (size_t)chunk, inFile);
        if (got != chunk) { if (error) *error = @"Could not read from disk"; return nil; }
        read += chunk;
    }
    return out;
}

- (nullable NSData *)readPiece:(NSInteger)index error:(NSString **)error {
    long long offset = (long long)index * self.metadata.pieceLength;
    long long length = self.metadata.pieceLength;
    long long remaining = self.metadata.totalLength - offset;
    if (remaining < length) length = remaining;
    if (length <= 0) return nil;
    return [self readAtOffset:offset length:length error:error];
}

- (BOOL)verifyPiece:(NSInteger)index {
    NSData *expected = [self.metadata hashForPiece:index];
    if (!expected.length) return NO;
    NSData *data = [self readPiece:index error:nil];
    if (!data) return NO;
    return [MVSHA1 data:data matchesDigest:expected];
}

- (MVTorrentFileHandle *)handleForOffset:(long long)offset {
    for (MVTorrentFileHandle *handle in _handles) {
        if (offset >= handle.offset && offset < handle.offset + handle.length) return handle;
    }
    return nil;
}

/// How far until the next real file starts, so padding is skipped in one hop.
- (long long)bytesToNextHandleFrom:(long long)position {
    long long best = -1;
    for (MVTorrentFileHandle *handle in _handles) {
        if (handle.offset > position) {
            long long distance = handle.offset - position;
            if (best < 0 || distance < best) best = distance;
        }
    }
    return best;
}

- (void)removeAll {
    for (MVTorrentFileHandle *handle in _handles) {
        if (handle.fd >= 0) { close(handle.fd); handle.fd = -1; }
    }
    [_handles removeAllObjects];
    [NSFileManager.defaultManager removeItemAtPath:self.root error:nil];
}

@end
