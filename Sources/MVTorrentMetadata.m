#import "MVTorrentMetadata.h"
#import "MVBencode.h"
#import "MVSHA1.h"

static const NSInteger kPieceHashLength = 20;

@implementation MVTorrentFile

- (NSString *)relativePath {
    return [self.path componentsJoinedByString:@"/"];
}

@end

@implementation MVTorrentMetadata

+ (instancetype)metadataWithTorrentData:(NSData *)data error:(NSString **)error {
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
    if (!infoBytes.length) {
        if (error) *error = @"torrent has no info dictionary";
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
    MVTorrentMetadata *meta = [MVTorrentMetadata new];
    meta.infoHash = infoHash;
    meta.trackers = trackers ?: @[];

    NSData *nameData = info[@"name"];
    NSString *name = [nameData isKindOfClass:NSData.class]
        ? [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] : nil;
    meta.name = name.length ? name : (infoHash.length ? [MVSHA1 hexString:infoHash] : @"torrent");

    NSNumber *pieceLength = info[@"piece length"];
    meta.pieceLength = [pieceLength isKindOfClass:NSNumber.class] ? pieceLength.longLongValue : 0;

    NSData *pieces = info[@"pieces"];
    meta.pieceHashes = [pieces isKindOfClass:NSData.class] ? pieces : [NSData data];

    NSNumber *privateFlag = info[@"private"];
    meta.isPrivate = [privateFlag isKindOfClass:NSNumber.class] && privateFlag.integerValue == 1;

    // Files: a "length" key means one file; "files" means a multi-file torrent
    // (BEP 3 / BEP 47). Both are flattened to one stream with running offsets.
    NSMutableArray<MVTorrentFile *> *files = [NSMutableArray array];
    NSNumber *singleLength = info[@"length"];
    if ([singleLength isKindOfClass:NSNumber.class]) {
        MVTorrentFile *file = [MVTorrentFile new];
        file.path = @[meta.name];
        file.length = singleLength.longLongValue;
        file.offset = 0;
        [files addObject:file];
    } else {
        NSArray *entries = info[@"files"];
        if (![entries isKindOfClass:NSArray.class]) {
            if (error) *error = @"torrent lists neither length nor files";
            return nil;
        }
        long long offset = 0;
        for (id entry in entries) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *dict = entry;
            NSNumber *length = dict[@"length"];
            if (![length isKindOfClass:NSNumber.class]) continue;
            NSMutableArray<NSString *> *components = [NSMutableArray array];
            for (id part in (dict[@"path"] ?: @[])) {
                if (![part isKindOfClass:NSData.class]) continue;
                NSString *piece = [[NSString alloc] initWithData:part encoding:NSUTF8StringEncoding];
                if (piece.length) [components addObject:piece];
            }
            if (!components.count) [components addObject:meta.name];

            MVTorrentFile *file = [MVTorrentFile new];
            file.path = components;
            file.length = length.longLongValue;
            file.offset = offset;
            // A BEP 47 padding file occupies stream space but has no content on
            // disk; the "attr" string carries a 'p' to mark it.
            NSData *attr = dict[@"attr"];
            if ([attr isKindOfClass:NSData.class]) {
                NSString *text = [[NSString alloc] initWithData:attr encoding:NSUTF8StringEncoding];
                file.isPadding = [text containsString:@"p"];
            }
            offset += file.length;
            [files addObject:file];
        }
    }
    meta.files = files;

    if (!meta.pieceLength) {
        if (error) *error = @"torrent has no piece length";
        return nil;
    }
    if (meta.pieceHashes.length % kPieceHashLength != 0) {
        if (error) *error = @"torrent piece hashes are malformed";
        return nil;
    }
    if (!files.count) {
        if (error) *error = @"torrent has no files";
        return nil;
    }
    long long expected = (meta.totalLength + meta.pieceLength - 1) / meta.pieceLength;
    if (expected != meta.pieceCount) {
        if (error) *error = @"torrent piece count does not match its files";
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
