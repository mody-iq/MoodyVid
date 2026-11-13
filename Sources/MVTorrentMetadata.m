#import "MVTorrentMetadata.h"
#import "MVBencode.h"
#import "MVSHA1.h"
#import "MVTorrentPolicy.h"
#include <limits.h>

static const NSInteger kPieceHashLength = 20;
static const NSUInteger kMaxTorrentFiles = 4096;
static const NSUInteger kMaxPathComponents = 64;

// A path component is one filename, never a path or a C-string with an
// embedded terminator. Reject invalid metadata rather than changing its layout.
static NSString *MVTorrentPathComponent(id value) {
    if (![value isKindOfClass:NSData.class]) return nil;
    NSString *name = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) return nil;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c < 0x20 || c == 0x7f || c == '/' || c == '\\') return nil;
    }
    return name;
}

@implementation MVTorrentFile

- (NSString *)relativePath {
    return [self.path componentsJoinedByString:@"/"];
}

@end

@implementation MVTorrentMetadata

+ (instancetype)metadataWithTorrentData:(NSData *)data error:(NSString **)error {
    // Bound parser allocations for a downloaded .torrent as well as BEP 9.
    if (!data.length || data.length > (NSUInteger)(2 * MV_TORRENT_MAX_METADATA_BYTES) ||
        [MVBencode byteLengthOfValueIn:data] != (NSInteger)data.length) {
        if (error) *error = @"torrent data is malformed or too large";
        return nil;
    }
    NSString *decodeError = nil;
    id root = [MVBencode decode:data error:&decodeError];
    if (![root isKindOfClass:NSDictionary.class]) {
        if (error) *error = decodeError ?: @"not a .torrent file";
        return nil;
    }
    NSDictionary *top = root;

    // Slice the info dictionary's original bytes rather than re-encoding it:
    // the info-hash must match what the swarm computes.
    NSData *infoBytes = [MVBencode rawValueForTopLevelKey:@"info" inData:data];
    if (!infoBytes.length || infoBytes.length > (NSUInteger)MV_TORRENT_MAX_METADATA_BYTES) {
        if (error) *error = @"torrent has no usable info dictionary";
        return nil;
    }
    NSDictionary *info = [MVBencode decode:infoBytes error:&decodeError];
    if (![info isKindOfClass:NSDictionary.class]) {
        if (error) *error = decodeError ?: @"torrent info is malformed";
        return nil;
    }

    NSData *infoHash = [MVSHA1 digest:infoBytes];
    NSArray<NSString *> *trackers = [self trackersFromTopLevel:top];
    return [self buildWithInfoDict:info infoHash:infoHash trackers:trackers error:error];
}

+ (instancetype)metadataWithInfoDict:(NSDictionary *)info
                            infoHash:(NSData *)infoHash
                            trackers:(NSArray<NSString *> *)trackers
                               error:(NSString **)error {
    return [self buildWithInfoDict:info infoHash:infoHash trackers:trackers error:error];
}

+ (instancetype)metadataWithMagnet:(MVMagnet *)magnet {
    MVTorrentMetadata *meta = [MVTorrentMetadata new];
    meta.name = magnet.displayName.length ? magnet.displayName : [magnet infoHashHex];
    meta.infoHash = magnet.infoHash;
    meta.trackers = magnet.trackers;
    meta.files = @[];
    meta.pieceHashes = [NSData data];
    return meta;
}

+ (instancetype)buildWithInfoDict:(NSDictionary *)info
                         infoHash:(NSData *)infoHash
                         trackers:(NSArray<NSString *> *)trackers
                            error:(NSString **)error {
    if (![info isKindOfClass:NSDictionary.class] || infoHash.length != kPieceHashLength) {
        if (error) *error = @"torrent info or hash is malformed";
        return nil;
    }
    MVTorrentMetadata *meta = [MVTorrentMetadata new];
    meta.infoHash = infoHash;
    meta.trackers = trackers ?: @[];
    meta.name = MVTorrentPathComponent(info[@"name"]);
    if (!meta.name) {
        if (error) *error = @"torrent name is invalid";
        return nil;
    }

    NSNumber *pieceLength = info[@"piece length"];
    meta.pieceLength = [pieceLength isKindOfClass:NSNumber.class] ? pieceLength.longLongValue : 0;
    NSData *pieces = info[@"pieces"];
    if (![pieces isKindOfClass:NSData.class] || pieces.length % kPieceHashLength != 0 ||
        pieces.length / kPieceHashLength > (NSUInteger)MV_TORRENT_MAX_PIECES) {
        if (error) *error = @"torrent piece hashes are malformed or too numerous";
        return nil;
    }
    meta.pieceHashes = pieces;
    NSNumber *privateFlag = info[@"private"];
    meta.isPrivate = [privateFlag isKindOfClass:NSNumber.class] && privateFlag.integerValue == 1;

    // A torrent is one ordered stream. Skipping an invalid file would change all
    // subsequent offsets and make valid-looking data land in the wrong file.
    NSMutableArray<MVTorrentFile *> *files = [NSMutableArray array];
    id singleLength = info[@"length"];
    id entries = info[@"files"];
    long long total = 0;
    if (singleLength) {
        if (entries || ![singleLength isKindOfClass:NSNumber.class] || [singleLength longLongValue] < 0) {
            if (error) *error = @"torrent file length is invalid";
            return nil;
        }
        MVTorrentFile *file = [MVTorrentFile new];
        file.path = @[meta.name];
        file.length = [singleLength longLongValue];
        file.offset = 0;
        total = file.length;
        [files addObject:file];
    } else {
        if (![entries isKindOfClass:NSArray.class] || ![entries count] || [entries count] > kMaxTorrentFiles) {
            if (error) *error = @"torrent file list is invalid or too large";
            return nil;
        }
        for (id entry in entries) {
            if (![entry isKindOfClass:NSDictionary.class]) {
                if (error) *error = @"torrent file entry is malformed";
                return nil;
            }
            id length = entry[@"length"];
            id path = entry[@"path"];
            if (![length isKindOfClass:NSNumber.class] || [length longLongValue] < 0 ||
                ![path isKindOfClass:NSArray.class] || ![path count] || [path count] > kMaxPathComponents ||
                [length longLongValue] > LLONG_MAX - total) {
                if (error) *error = @"torrent file length or path is invalid";
                return nil;
            }
            NSMutableArray<NSString *> *components = [NSMutableArray array];
            for (id part in path) {
                NSString *component = MVTorrentPathComponent(part);
                if (!component) {
                    if (error) *error = @"torrent path contains an invalid component";
                    return nil;
                }
                [components addObject:component];
            }
            MVTorrentFile *file = [MVTorrentFile new];
            file.path = components;
            file.length = [length longLongValue];
            file.offset = total;
            NSData *attr = entry[@"attr"];
            if ([attr isKindOfClass:NSData.class]) {
                NSString *text = [[NSString alloc] initWithData:attr encoding:NSUTF8StringEncoding];
                file.isPadding = [text containsString:@"p"];
            }
            total += file.length;
            [files addObject:file];
        }
    }
    meta.files = files;
    if (!MVTorrentValidGeometry(total, meta.pieceLength, (int64_t)(pieces.length / kPieceHashLength))) {
        if (error) *error = @"torrent piece geometry does not match its files or exceeds supported limits";
        return nil;
    }
    return meta;
}

+ (NSArray<NSString *> *)trackersFromTopLevel:(NSDictionary *)top {
    NSMutableArray<NSString *> *trackers = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *url) {
        if (!url.length || [seen containsObject:url]) return;
        [seen addObject:url];
        [trackers addObject:url];
    };
    NSData *announce = top[@"announce"];
    if ([announce isKindOfClass:NSData.class]) {
        add([[NSString alloc] initWithData:announce encoding:NSUTF8StringEncoding]);
    }
    NSArray *list = top[@"announce-list"];
    if ([list isKindOfClass:NSArray.class]) {
        for (id tier in list) {
            if ([tier isKindOfClass:NSArray.class]) {
                for (id entry in (NSArray *)tier) {
                    if ([entry isKindOfClass:NSData.class]) {
                        add([[NSString alloc] initWithData:entry encoding:NSUTF8StringEncoding]);
                    }
                }
            } else if ([tier isKindOfClass:NSData.class]) {
                add([[NSString alloc] initWithData:(NSData *)tier encoding:NSUTF8StringEncoding]);
            }
        }
    }
    return trackers;
}

- (long long)totalLength {
    long long total = 0;
    for (MVTorrentFile *file in _files) total += file.length;
    return total;
}

- (NSInteger)pieceCount {
    return (NSInteger)(_pieceHashes.length / kPieceHashLength);
}

- (BOOL)isSingleFile {
    return _files.count == 1;
}

- (NSString *)infoHashHex {
    return _infoHash.length ? [MVSHA1 hexString:_infoHash] : @"";
}

- (NSData *)hashForPiece:(NSInteger)index {
    if (index < 0 || index >= self.pieceCount) return nil;
    return [_pieceHashes subdataWithRange:NSMakeRange((NSUInteger)index * kPieceHashLength, kPieceHashLength)];
}

@end
