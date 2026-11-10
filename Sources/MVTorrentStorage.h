#import <Foundation/Foundation.h>
#import "MVTorrentMetadata.h"

NS_ASSUME_NONNULL_BEGIN

/// The torrent's bytes on disk.
///
/// A torrent is one long byte stream cut into pieces; the pieces are spread
/// across the torrent's files. This class is the only place that mapping lives:
/// it turns "write these bytes at stream offset N" into the right file seeks,
/// reads a piece back for its hash check, and lays out the folder a multi-file
/// torrent needs.
@interface MVTorrentStorage : NSObject

/// `root` is the folder the torrent owns; the files are created inside it.
- (instancetype)initWithMetadata:(MVTorrentMetadata *)metadata root:(NSString *)root;

@property (nonatomic, readonly) MVTorrentMetadata *metadata;
@property (nonatomic, readonly) NSString *root;
/// For a single-file torrent, the file's path; for a multi-file one, the folder.
@property (nonatomic, readonly) NSString *outputPath;

/// Creates the folder and the (sparse) files, so writes and seeks work.
- (BOOL)prepare:(NSString *_Nullable *_Nullable)error;

/// Writes `data` starting at the absolute stream offset, crossing file
/// boundaries as needed.
- (BOOL)writeData:(NSData *)data atOffset:(long long)offset error:(NSString *_Nullable *_Nullable)error;

/// Reads `length` bytes at the absolute stream offset. Returns nil on a short
/// read (a file that was not created).
- (nullable NSData *)readAtOffset:(long long)offset length:(long long)length error:(NSString *_Nullable *_Nullable)error;

/// Reads piece `index` in full (the last piece is shorter than pieceLength).
- (nullable NSData *)readPiece:(NSInteger)index error:(NSString *_Nullable *_Nullable)error;

/// Reads piece `index` back and checks its SHA-1 against the metadata.
- (BOOL)verifyPiece:(NSInteger)index;

/// Deletes everything the torrent wrote.
- (void)removeAll;

@end

NS_ASSUME_NONNULL_END
