#import <Foundation/Foundation.h>
#import "MVMagnet.h"

NS_ASSUME_NONNULL_BEGIN

/// One file inside a torrent, with its absolute offset in the torrent's byte
/// stream (pieces span file boundaries, so the offset is what maps a piece to a
/// file).
@interface MVTorrentFile : NSObject

/// The path components after the torrent name, e.g. @[@"sub", @"clip.mp4"].
@property (nonatomic, copy) NSArray<NSString *> *path;
@property (nonatomic) long long length;
@property (nonatomic) long long offset;
/// YES for a BEP 47 padding file: it occupies stream space but is not written.
@property (nonatomic) BOOL isPadding;

/// The path joined for display, e.g. "sub/clip.mp4".
@property (nonatomic, readonly) NSString *relativePath;

@end

/// What a torrent knows before any peer is contacted: its name, its piece
/// geometry, its files and its trackers. Built from a `.torrent` file, or from a
/// magnet link once the metadata has been fetched from a peer.
@interface MVTorrentMetadata : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic) long long pieceLength;
/// Concatenated 20-byte SHA-1 piece hashes; piece i is at i*20.
@property (nonatomic, copy) NSData *pieceHashes;
/// The files in stream order, each carrying its own offset.
@property (nonatomic, copy) NSArray<MVTorrentFile *> *files;
/// The 20-byte SHA-1 of the info dictionary: the torrent's identity.
@property (nonatomic, copy) NSData *infoHash;
@property (nonatomic, copy) NSArray<NSString *> *trackers;
/// YES when the torrent declares itself private (BEP 27): no DHT, no PEX.
@property (nonatomic) BOOL isPrivate;

@property (nonatomic, readonly) long long totalLength;
@property (nonatomic, readonly) NSInteger pieceCount;
@property (nonatomic, readonly) BOOL isSingleFile;
@property (nonatomic, readonly) NSString *infoHashHex;

/// Parses a `.torrent` file's bytes. Fills `error` and returns nil when the
/// data is not a torrent this engine can use.
+ (nullable instancetype)metadataWithTorrentData:(NSData *)data error:(NSString *_Nullable *_Nullable)error;

/// Rebuilds the metadata from an info dictionary that a peer sent (BEP 9), with
/// the info-hash already known from the magnet link.
+ (nullable instancetype)metadataWithInfoDict:(NSDictionary *)info
                                     infoHash:(NSData *)infoHash
                                     trackers:(NSArray<NSString *> *)trackers
                                        error:(NSString *_Nullable *_Nullable)error;

/// A placeholder from a magnet link: name and trackers only, no pieces. Used to
/// show a row before the metadata arrives.
+ (instancetype)metadataWithMagnet:(MVMagnet *)magnet;

/// The 20-byte hash of piece `index`, or nil when out of range.
- (nullable NSData *)hashForPiece:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
